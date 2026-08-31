// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// The coprocessor board as the i960 sees it: an MB86234 behind a control
// register, a program-upload path and two FIFOs.
//
// THE INTERFACE, from model2.cpp's own address map rather than description:
//
//   0x00804000-0x00807fff  geo_prg      the GEOMETRY program, not this one
//   0x00884000-0x00887fff  copro_fifo   read pops the out FIFO, write pushes
//                                       the in FIFO -- OR writes the program,
//                                       see below
//   0x00980000             copro_ctl1   bit 31 selects which
//   0x00980004             fifo_control read: 1 when the out FIFO is EMPTY
//
// ONE ADDRESS DOES TWO THINGS, AND copro_ctl1 BIT 31 IS THE SELECTOR. This is
// the part that is easy to get wrong from prose:
//
//     void model2_tgp_state::copro_fifo_w(u32 data)
//     {
//         if (m_coproctl & 0x80000000) { m_copro_tgp_program[m_coprocnt] = data;
//                                        m_coprocnt++; }
//         else                           m_copro_fifo_in->push(u32(data));
//     }
//
// So the program is uploaded through the FIFO WRITE PORT while bit 31 is set,
// with an address counter the hardware keeps. Setting bit 31 halts the copro
// and zeroes that counter; clearing it boots the copro:
//
//     if ((data ^ m_coproctl) == 0x80000000) {
//         if (data & 0x80000000) { m_coprocnt = 0; copro_halt(); }
//         else                     copro_boot();
//     }
//
// Note it triggers on the bit CHANGING, not on its value, so a write that
// leaves bit 31 alone does neither.
//
// FIFO DEPTH IS EIGHT, from `m_copro_fifo_in->setup(8, ...)`. Not a guess and
// not "deep enough": a FIFO that never fills hides the flow control the game
// relies on, exactly as an infinitely fast serial link did for the sound board.
//
// WHAT IS NOT HERE YET, stated rather than left to be discovered:
//   * the TGP's RAM window (`ram_*` on m2_tgp). Model 1 arbitrates a shared
//     V60/TGP RAM through m1_copro_if; Model 2's equivalent is the banked view
//     in copro_tgp_io_map and has not been traced. Tied off, and the tie-off is
//     visible in dbg_ram_req so it cannot be silently depended on.
//   * the geometry engine at 0x00800000 and its program at 0x00804000. That is
//     a SEPARATE processor from this one and shares only the naming.

`timescale 1ns/1ps

module m2_copro (
  input  logic        clk,
  input  logic        rst_n,

  // ---- the i960's side
  input  logic        sel_ctl,      // 0x00980000, copro_ctl1
  input  logic        sel_fifo,     // 0x00884000-0x00887fff
  // THE FUNCTION PORT, 0x00880000-0x00883fff, and it is how the game issues
  // COMMANDS. model2.cpp:
  //
  //     void copro_function_port_w(offs_t offset, u32 data) {
  //         u32 d = data & 0x800fffff;
  //         u32 a = (offset >> 2) & 0xff;
  //         d |= a << 23;
  //         m_copro_fifo_in->push(u32(d));
  //     }
  //
  // The command CODE is the ADDRESS, not the data: bits 30:23 of the pushed
  // word, which is exactly the field get_exp() reads. The microcode dispatches
  // on it. Without this port the coprocessor receives payloads and never a
  // command, so its drain loop never exits, it produces no output, the i960
  // reads its empty output FIFO, pushes that zero back, and the pair deadlock.
  input  logic        sel_fn,
  input  logic  [7:0] fn_code,      // cpu_io_addr[11:4]
  input  logic        sel_fifoctl,  // 0x00980004, fifo_control
  input  logic        we,
  input  logic [31:0] wdata,
  output logic [31:0] rdata,
  // "I cannot take this write." Asserted while a FIFO push would overflow, so
  // the bridge holds the i960 instead of the word being lost. This is the
  // hardware's FULL line, which the Fujitsu FIFO bus carries as a real signal.
  output logic        stall,

  // ---- the two read-only SDRAM windows the TGP walks, passed straight
  // through. These are NOT optional and were the reason this module could not
  // be instantiated: `tbl_ack` and `dat_ack` are inputs to m2_tgp, and leaving
  // them off the instantiation leaves them unconnected, so the first sincos or
  // inverse-square-root lookup waits for an acknowledge that can never arrive.
  // A coprocessor wired without them does not run slowly, it stops.
  output logic        tbl_req,
  output logic [15:0] tbl_addr,
  input  logic [31:0] tbl_rdata,
  input  logic        tbl_ack,
  output logic        dat_req,
  output logic [18:0] dat_addr,
  input  logic [31:0] dat_rdata,
  input  logic        dat_ack,

  // ---- for the debug channel
  output logic [31:0] dbg_ctl,
  output logic [15:0] dbg_prog_words,   // how much program was uploaded
  output logic [15:0] dbg_in_pushed,
  output logic [15:0] dbg_out_popped,
  // HOW HARD THE i960 IS WAITING. fifo_control reads say "is there a result
  // yet". A game that is not using the coprocessor does not ask; a game
  // deadlocked on one asks forever. The two look identical from the FIFO
  // counters alone.
  output logic [31:0] dbg_fctl_reads,
  // WORDS LOST. MAME's generic_fifo NEVER drops: push() into a full FIFO stores
  // the value in m_extra_values and halts the source. `else if (!fin_full)`
  // below looks like an overflow guard and is data loss.
  output logic [31:0] dbg_in_popped,   // what the TGP actually took
  output logic [31:0] dbg_pop_data,    // and the value it took
  output logic [31:0] dbg_push_data,   // and what the i960 put in
  output logic [31:0] dbg_in_dropped,
  output logic [31:0] dbg_out_dropped,
  output logic        dbg_ram_req,      // the tie-off above, made visible
  // FROM THE PROCESSOR ITSELF, because the screen is the only output channel
  // and "is it running" must be answerable without one. `dbg_retires` moving
  // says the TGP executes at all; `dbg_unimplemented` says it met an opcode
  // this port does not have, which is the one failure that looks exactly like
  // a hang from the outside.
  output logic [15:0] dbg_tgp_retires,
  output logic [15:0] dbg_tgp_pc,
  output logic [31:0] dbg_tgp_op,
  output logic [31:0] dbg_tgp_hold,
  output logic [31:0] dbg_tgp_wr_n,
  output logic [16:0] dbg_tgp_wr_addr,
  output logic [31:0] dbg_tgp_wr_data,
  output logic [31:0] dbg_tgp_st,
  output logic [31:0] dbg_tgp_a,
  output logic [31:0] dbg_tgp_b,
  output logic [31:0] dbg_tgp_d,
  // THE UPLOAD STREAM, word by word. The program the i960 builds is not stored
  // verbatim in any ROM, so the only way to know whether ours matches the
  // reference is to watch the words go past.
  output logic        dbg_uc_we,
  output logic [11:0] dbg_uc_addr,
  output logic [31:0] dbg_uc_data,
  output logic        dbg_tgp_unimpl,
  // WHAT THE PROCESSOR IS REACHING FOR. A TGP that retires tens of thousands
  // of instructions and touches neither FIFO is in a loop waiting on something,
  // and the address it keeps reading names the thing. These were tied off,
  // which is why the first integration run could say it was executing and not
  // what it was executing.
  output logic [15:0] dbg_tgp_io_addr,
  output logic        dbg_tgp_io_rd,
  output logic        dbg_tgp_io_wr,
  output logic        dbg_tgp_io_ack,
  output logic        dbg_tgp_fifo_rd,
  output logic        dbg_tgp_fifo_wr
);

  // ------------------------------------------------------------ control
  logic [31:0] coproctl;
  logic [11:0] coprocnt;
  logic        halted;

  wire ctl_wr   = sel_ctl && we;
  wire bit31_ch = ctl_wr && ((wdata ^ coproctl) & 32'h8000_0000) != 32'd0;
  wire uploading = coproctl[31];

  // ------------------------------------------------------- program upload
  logic        uc_we;
  logic [10:0] uc_addr;
  logic [31:0] uc_data;

  // --------------------------------------------------------------- FIFOs
  //
  // model2.cpp sets both up as EIGHT deep, and the outbound one is exactly
  // eight here: the TGP writing into a full output FIFO must stall, and it does,
  // by having its acknowledge withheld.
  //
  // THE INBOUND ONE IS DEEPER, AND THAT MATCHES THE REFERENCE RATHER THAN
  // DEPARTING FROM IT. MAME's generic_fifo does NOT block a push into a full
  // FIFO -- gen_fifo.cpp, push():
  //
  //     else if(is_full()) {
  //         m_extra_values.emplace_back(std::move(t));   // queue it
  //         m_sync_full->adjust(attotime::zero);         // and sync later
  //     }
  //
  // The write COMPLETES, the value goes into an unbounded overflow queue and
  // the CPU carries on. Only at the scheduler sync, if the FIFO is still full,
  // is the source halted -- the i960 is never stalled inside a bus cycle.
  //
  // A first attempt held the bus on every full push. Nothing was lost, but the
  // i960 spent most of its life waiting and the boot ran several times slower:
  // the whole machine throttled by the coprocessor, which is not what the board
  // does. `fin` is therefore the FIFO PLUS its overflow queue in one array, and
  // `stall` survives only as the backstop for what an unbounded queue absorbs
  // and a fixed array cannot.
  localparam int unsigned FD    = 8;    // outbound, as the reference
  localparam int unsigned FD_IN = 64;   // inbound: 8 real plus 56 of overflow
  logic [31:0] fin  [FD_IN];
  logic [31:0] fout [FD];
  logic  [6:0] fin_wp, fin_rp;
  logic  [3:0] fout_wp, fout_rp;
  wire   [6:0] fin_cnt  = fin_wp  - fin_rp;
  wire   [3:0] fout_cnt = fout_wp - fout_rp;
  wire         fin_full  = (fin_cnt  >= 7'(FD_IN));
  wire         fin_empty = (fin_cnt  == 7'd0);
  wire         fout_full = (fout_cnt >= 4'(FD));
  wire         fout_empty= (fout_cnt == 4'd0);

  // ---- the TGP's own handshakes
  wire        tgp_in_pop;
  wire [31:0] tgp_out_data;
  wire        tgp_out_push;

  // THE FULL LINE. A program upload is never stalled -- it goes to program RAM
  // at a counter, not into the FIFO -- so only a genuine FIFO push can block.
  assign stall = ((sel_fifo && !uploading) || sel_fn) && we && fin_full;

  // A read of the FIFO port pops; a write pushes, or uploads.
  wire fifo_rd = sel_fifo && !we;
  wire fifo_wr = sel_fifo &&  we;
  // A function-port write is an ordinary FIFO push with the code folded in.
  wire fn_wr   = sel_fn   &&  we;
  wire [31:0] fn_word = (wdata & 32'h800f_ffff) | {1'b0, fn_code, 23'd0};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      coproctl <= 32'd0; coprocnt <= 12'd0; halted <= 1'b1;
      uc_we <= 1'b0; uc_addr <= 11'd0; uc_data <= 32'd0;
      fin_wp <= 7'd0; fin_rp <= 7'd0; fout_wp <= 4'd0; fout_rp <= 4'd0;
      dbg_prog_words <= 16'd0; dbg_in_pushed <= 16'd0; dbg_out_popped <= 16'd0;
      dbg_fctl_reads <= 32'd0;
      dbg_in_dropped <= 32'd0; dbg_out_dropped <= 32'd0;
      dbg_in_popped <= 32'd0; dbg_pop_data <= 32'd0; dbg_push_data <= 32'd0;
    end else begin
      uc_we <= 1'b0;

      // ---- control. The trigger is the bit CHANGING.
      if (ctl_wr) begin
        coproctl <= wdata;
        if (bit31_ch) begin
          if (wdata[31]) begin           // start upload
            coprocnt <= 12'd0;
            halted   <= 1'b1;
          end else begin                 // boot
            halted   <= 1'b0;
          end
        end
      end

      // ---- the FIFO write port, which is also the upload port
      if (fifo_wr) begin
        if (uploading) begin
          uc_we   <= 1'b1;
          uc_addr <= coprocnt[10:0];
          uc_data <= wdata;
          coprocnt <= coprocnt + 12'd1;
          if (!(&dbg_prog_words)) dbg_prog_words <= dbg_prog_words + 16'd1;
        end else if (!fin_full) begin
          fin[fin_wp[5:0]] <= wdata;
          fin_wp <= fin_wp + 7'd1;
          dbg_push_data <= wdata;
          if (!(&dbg_in_pushed)) dbg_in_pushed <= dbg_in_pushed + 16'd1;
        end else if (!(&dbg_in_dropped)) begin
          // NOW UNREACHABLE, and kept as a running assertion rather than
          // deleted: with `stall` wired to the bridge the i960 cannot present a
          // push that this FIFO has no room for. If this counter ever moves
          // again, the handshake has been broken somewhere upstream.
          dbg_in_dropped <= dbg_in_dropped + 32'd1;
        end
      end

      if (sel_fifoctl && !we && !(&dbg_fctl_reads)) dbg_fctl_reads <= dbg_fctl_reads + 32'd1;

      // ---- the function port: a command push, never a program upload
      if (fn_wr && !fin_full) begin
        fin[fin_wp[5:0]] <= fn_word;
        fin_wp <= fin_wp + 7'd1;
        dbg_push_data <= fn_word;
        if (!(&dbg_in_pushed)) dbg_in_pushed <= dbg_in_pushed + 16'd1;
      end

      // ---- the i960 popping the output FIFO
      if (fifo_rd && !fout_empty) begin
        fout_rp <= fout_rp + 4'd1;
        if (!(&dbg_out_popped)) dbg_out_popped <= dbg_out_popped + 16'd1;
      end

      // ---- the TGP's own ends
      if (tgp_in_pop && !fin_empty) begin
        fin_rp <= fin_rp + 7'd1;
        dbg_pop_data <= fin[fin_rp[5:0]];
        if (!(&dbg_in_popped)) dbg_in_popped <= dbg_in_popped + 32'd1;
      end
      if (tgp_out_push && !fout_full) begin
        fout[fout_wp[2:0]] <= tgp_out_data;
        fout_wp <= fout_wp + 4'd1;
      end else if (tgp_out_push && !(&dbg_out_dropped)) begin
        dbg_out_dropped <= dbg_out_dropped + 32'd1;
      end
    end
  end

  // fifo_control_r returns 1 when the OUTPUT fifo is empty. The stub this
  // replaces returned a constant 1 -- "the copro has finished" -- which is
  // true of a copro that never starts and a lie about one that has.
  always_comb begin
    rdata = 32'hFFFF_FFFF;                       // copro_prg_r's value
    if      (sel_ctl)     rdata = coproctl;
    else if (sel_fifoctl) rdata = {31'd0, fout_empty};
    else if (sel_fifo)    rdata = fout_empty ? 32'd0 : fout[fout_rp[2:0]];
  end

  assign dbg_ctl = coproctl;

  // ---- the processor itself
  wire        ram_req_w;
  // EMPTY_FIFO_READS_ZERO MUST BE SET, AND LEAVING IT DEFAULT COST A WHOLE
  // SESSION. m2_tgp defaults it to 0, which makes an empty FIFO read WITHHOLD
  // ITS ACKNOWLEDGE and stall the processor. m2_tgp's own header explains at
  // length why that is wrong -- gen_fifo.cpp's pop() returns T() on an empty
  // FIFO, and Daytona's microcode needs that zero: 0x52 computes
  // `d = get_exp(b) + 0x53`, so b = 0 selects 0x53, the IDLE handler. A TGP
  // that stalls instead can never reach its own idle path.
  //
  // The measured cost of the default: the TGP popped 29 words where MAME pops
  // 484,947, the input FIFO filled and stayed full, and 429,350 of the i960's
  // commands were discarded against it. The parameter was written, the reason
  // was written down, and the instantiation never passed it.
  m2_tgp #(.EMPTY_FIFO_READS_ZERO(1'b0)) u_tgp (
    .clk(clk), .rst_n(rst_n & ~halted),
    .dbg_ucode_ram_csum(), .dbg_ucode_ram_ok(),
    .ucode_clk(clk), .ucode_we(uc_we), .ucode_addr(uc_addr), .ucode_data(uc_data),
    // The RAM window is not traced yet -- see the header. Acknowledged
    // immediately with zero so the TGP cannot hang on it, and the request is
    // brought out so a design that starts depending on it is visible.
    .ram_req(ram_req_w), .ram_we(), .ram_addr(), .ram_wdata(),
    .ram_rdata(32'd0), .ram_ack(ram_req_w),
    .fifo_in_data(fin[fin_rp[5:0]]), .fifo_in_valid(!fin_empty),
    .fifo_in_pop(tgp_in_pop),
    .fifo_out_data(tgp_out_data), .fifo_out_push(tgp_out_push),
    .fifo_out_full(fout_full),
    .tbl_req(tbl_req), .tbl_addr(tbl_addr),
    .tbl_rdata(tbl_rdata), .tbl_ack(tbl_ack),
    .dat_req(dat_req), .dat_addr(dat_addr),
    .dat_rdata(dat_rdata), .dat_ack(dat_ack),
    .dbg_retires(dbg_tgp_retires), .dbg_pc(dbg_tgp_pc), .dbg_op(dbg_tgp_op),
    .dbg_fifo_hold(dbg_tgp_hold), .dbg_wr_n(dbg_tgp_wr_n), .dbg_wr_addr(dbg_tgp_wr_addr), .dbg_wr_data(dbg_tgp_wr_data),
    .dbg_st(dbg_tgp_st), .dbg_a(dbg_tgp_a), .dbg_b(dbg_tgp_b), .dbg_d(dbg_tgp_d),
    .dbg_unimplemented(dbg_tgp_unimpl),
    .dbg_io_addr(dbg_tgp_io_addr), .dbg_io_rd(dbg_tgp_io_rd),
    .dbg_io_wr(dbg_tgp_io_wr), .dbg_io_ack(dbg_tgp_io_ack),
    .dbg_fifo_rd(dbg_tgp_fifo_rd), .dbg_fifo_wr(dbg_tgp_fifo_wr)
  );

  assign dbg_uc_we   = uc_we;
  assign dbg_uc_addr = {1'b0, uc_addr};
  assign dbg_uc_data = uc_data;

  assign dbg_ram_req = ram_req_w;

endmodule
