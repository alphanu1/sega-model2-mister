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
  output logic [19:0] dat_addr,
  output logic        dat_we,
  output logic [15:0] dat_wdata,
  output logic        dat_is_buf,
  output logic        dat_half,
  output logic        bufw_req,
  output logic [18:0] bufw_addr,
  output logic [15:0] bufw_data,
  input  logic        bufw_ack,
  input  logic [31:0] dat_rdata,
  input  logic        dat_ack,

  // ---- for the debug channel
  output logic [31:0] dbg_ctl,
  output logic [15:0] dbg_prog_words,   // how much program was uploaded
  output logic [15:0] dbg_in_pushed,
  output logic [15:0] dbg_out_popped,
  output logic [31:0] dbg_out_pushed,
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
  output logic [31:0] dbg_out_data,    // and what the TGP produced
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
  output logic [15:0] dbg_ff_math, dbg_ff_rom, dbg_ff_buf, dbg_rd_total,
  output logic        dbg_tgp_fifo_rd,
  output logic        dbg_tgp_fifo_wr,
  output logic [31:0] dbg_tgp_bank
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
  // 128, NOT 512, AND THE LIMIT IS FLIP-FLOPS RATHER THAN JUDGEMENT.
  //
  // `fifo_in_data` is read ASYNCHRONOUSLY -- the TGP sees the head combinationally
  // -- and an asynchronously read array is not an M10K on this part, it is
  // registers. At 512 entries that is 16 Kbit of flops and the design went to
  // 45,005 ALM of 41,910: 107%, no fit. The same rule is already written down
  // for the i960's arrays and it applies here.
  //
  // 128 is sixteen times the hardware's own depth and costs about 4 Kbit. The
  // depth only has to be enough that `dbg_in_dropped` never moves, because
  // nothing stalls any more: a full queue drops rather than halting the CPU,
  // and the counter makes that visible.
  localparam int unsigned FD_IN  = 128;
  // OUTBOUND IS 128 NOW, NOT THE REFERENCE'S 8, AND THE DEPTH IS A DEADLOCK
  // FIX RATHER THAN A GUESS AT THE HARDWARE.
  //
  // `m2_tgp` withholds the ack while `fifo_out_full` (see its line 369), so a
  // full outbound FIFO HOLDS THE TGP mid-instruction. Measured on the board:
  // the TGP pushed 121 results, the i960 stopped popping, and the core froze
  // at pc 0x0481 with `fin` then overflowing behind it -- exactly the halt
  // this file's header predicted. `gen_fifo.cpp` never blocks a push like
  // that; it queues into an unbounded overflow instead. 128 is that overflow,
  // bounded, and `dbg_out_dropped` says if it was ever not enough.
  //
  // It costs nothing. Both FIFOs are now M10K blocks rather than flip-flops,
  // so 8 -> 128 is the same one block, and `fin` GIVES BACK about 1,500 ALM
  // it was spending on 4,096 registers.
  localparam int unsigned FD_OUT = 128;

  wire [31:0] fin_q, fout_q;
  wire        fin_valid, fout_valid, fin_full, fout_full;
  wire [15:0] fin_count, fout_count;
  wire        fin_empty  = !fin_valid;
  wire        fout_empty = !fout_valid;

  // ---- the TGP's own handshakes
  wire        tgp_in_pop;
  wire [31:0] tgp_out_data;
  wire        tgp_out_push;

  // THE STALL LINE, AND WHICH DIRECTION IT RUNS IN. It is a READ of an empty
  // output FIFO that holds the i960, never a write.
  //
  // model2.cpp:202-205 sets up copro_fifo_out with `m_maincpu->i960_stall()`
  // as its on-empty callback, and gen_fifo.cpp:109-115 fires that callback
  // BEFORE returning T(): the zero is returned to an instruction that has
  // already been cancelled. i960.h:71-75 is the whole of i960_stall() --
  // `m_stalled = true; m_IP = m_PIP;` -- and i960.cpp:2053 refuses to write
  // the destination register while stalled. The `ld` is replayed until a
  // word is there. The program never sees the zero.
  //
  // The game depends on that. 0x115a0, 0x115d0, 0x11558 and every routine
  // like them push a command and READ THE RESULT IN THE NEXT INSTRUCTION --
  // `st r6,(g11)[g12]; st r5,(g11)[g12]; ld (g11)[g12],g1` is push, push,
  // pop. The protocol is synchronous and the FIFO read is the wait. Handing
  // back a zero instead is not an approximation of the reference, it is a
  // different machine: the i960 stores 0 as a height or a collision result
  // and carries on, and the words that later arrive in `fout` are read as
  // answers to questions asked long after.
  //
  // WRITES ARE A DIFFERENT MATTER AND STAY UNSTALLED. gen_fifo's push() always
  // completes; a full FIFO halts the source at a scheduler sync, not inside
  // the bus cycle. The earlier `stall` on a full push (removed in 41199bf)
  // froze the board because the coprocessor of that era could not drain the
  // queue at all (R133, an invented memory map). The queue is 128 deep for
  // that case and `dbg_in_dropped` says if it was ever too small.
  //
  // The bridge holds the access exactly as it would for a slow bus: io_sel
  // stays asserted, no acknowledge, and the read completes on the first cycle
  // `fout` has a word. `fout_pop` is gated on `fout_valid`, so a held read
  // pops once, on that cycle, and never before.
  // AND IT MUST NOT STALL ON A COPROCESSOR THAT CANNOT ANSWER (R158).
  //
  // MEASURED ON THE BOARD. With the bare `fifo_rd && !fout_valid` the core came
  // up dead -- no tilemap at all, stuck on the first screen -- and the UART said
  // why: 3,769 consecutive samples of `tgp_pc = 0000` with rd_total = 0 and
  // out_pushed = 0. The TGP had never left reset.
  //
  // The loop is closed and cannot break itself. `m2_tgp` is instantiated with
  // `.rst_n(rst_n & ~halted)`, and `halted` is 1 out of reset until the i960
  // writes coproctl with bit 31 falling. So a read of the FIFO port BEFORE that
  // write waits on `fout`, which only the TGP can fill, which only that write
  // can start -- and the stall is what stops the CPU reaching it. The one thing
  // that would release the stall is the one thing the stall prevents.
  //
  // The reference has no such state: MAME's TGP is a scheduled device that is
  // always able to run, so `on_fifo_unempty` can always arrive. Gating here
  // restores that PRECONDITION rather than departing from the behaviour -- while
  // the coprocessor is halted or taking a microcode upload it cannot answer, so
  // a read completes instead of hanging the machine. Once it is running, the
  // synchronous protocol of R151 applies unchanged.
  assign stall = fifo_rd && !fout_valid && !halted && !uploading;

  // A read of the FIFO port pops; a write pushes, or uploads.
  wire fifo_rd = sel_fifo && !we;
  wire fifo_wr = sel_fifo &&  we;
  // A function-port write is an ordinary FIFO push with the code folded in.
  wire fn_wr   = sel_fn   &&  we;
  wire [31:0] fn_word = (wdata & 32'h800f_ffff) | {1'b0, fn_code, 23'd0};

  // Both write ports land in the same queue: the FIFO port carries payloads and
  // the function port carries a command whose code is its address (R120). They
  // decode different regions and cannot assert together.
  wire        fin_push = (fifo_wr && !uploading) || fn_wr;
  wire [31:0] fin_din  = fn_wr ? fn_word : wdata;
  wire        fout_pop = fifo_rd && fout_valid;

  m2_fifo_m10k #(.DW(32), .DEPTH(FD_IN)) u_fin (
    .clk(clk), .rst_n(rst_n),
    .push(fin_push), .din(fin_din),
    .pop(tgp_in_pop), .q(fin_q), .q_valid(fin_valid),
    .full(fin_full), .count(fin_count), .dropped(dbg_in_dropped)
  );

  m2_fifo_m10k #(.DW(32), .DEPTH(FD_OUT)) u_fout (
    .clk(clk), .rst_n(rst_n),
    .push(tgp_out_push), .din(tgp_out_data),
    .pop(fout_pop), .q(fout_q), .q_valid(fout_valid),
    .full(fout_full), .count(fout_count), .dropped(dbg_out_dropped)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      coproctl <= 32'd0; coprocnt <= 12'd0; halted <= 1'b1;
      uc_we <= 1'b0; uc_addr <= 11'd0; uc_data <= 32'd0;
      dbg_prog_words <= 16'd0; dbg_in_pushed <= 16'd0; dbg_out_popped <= 16'd0;
      dbg_fctl_reads <= 32'd0;
      dbg_in_popped <= 32'd0; dbg_pop_data <= 32'd0; dbg_push_data <= 32'd0;
      dbg_out_data <= 32'd0; dbg_out_pushed <= 32'd0;
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
          // u_fin takes the word; this is only the count.
          dbg_push_data <= wdata;
          if (!(&dbg_in_pushed)) dbg_in_pushed <= dbg_in_pushed + 16'd1;
        end
      end

      if (sel_fifoctl && !we && !(&dbg_fctl_reads)) dbg_fctl_reads <= dbg_fctl_reads + 32'd1;

      // ---- the function port: a command push, never a program upload
      if (fn_wr && !fin_full) begin
        dbg_push_data <= fn_word;
        if (!(&dbg_in_pushed)) dbg_in_pushed <= dbg_in_pushed + 16'd1;
      end

      // ---- the i960 popping the output FIFO
      if (fout_pop) begin
        if (!(&dbg_out_popped)) dbg_out_popped <= dbg_out_popped + 16'd1;
      end

      // ---- the TGP's own ends
      if (tgp_in_pop && fin_valid) begin
        dbg_pop_data <= fin_q;
        if (!(&dbg_in_popped)) dbg_in_popped <= dbg_in_popped + 32'd1;
      end
      // `dbg_out_dropped` is u_fout's now. The old else-branch here could never
      // fire -- m2_tgp gates fifo_out_push on !fifo_out_full -- so a blocked
      // push counted as nothing and the counter read zero while the TGP was
      // held. That is why the board showed out_drop=00 during the freeze.
      if (tgp_out_push && !fout_full) begin
        dbg_out_data <= tgp_out_data;
        if (!(&dbg_out_pushed)) dbg_out_pushed <= dbg_out_pushed + 32'd1;
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
    // The empty case is unreachable by the CPU: `stall` holds the read until
    // fout_valid, so the 0 is only what the bus shows while nobody samples it.
    else if (sel_fifo)    rdata = fout_valid ? fout_q : 32'd0;
  end

  assign dbg_ctl = coproctl;

  // ---- the processor itself
  wire        ram_req_w;
  // AN EMPTY COMMAND FIFO STALLS THE TGP. THAT IS THE REFERENCE, READ AS FAR
  // AS THE CALLBACK RATHER THAN STOPPING AT THE RETURN VALUE.
  //
  // model2.cpp:193-196 sets up copro_fifo_in with `m_copro_tgp->stall()` on
  // empty, then HALT at the sync; gen_fifo.cpp:109-115 fires it before
  // returning T(); mb86233.cpp:1225-1227 (`do_stall: m_pc = m_ppc`) replays
  // the instruction. MAME's TGP parks at 004c with the FIFO empty -- it does
  // NOT fall through `0053 brif !zrd` into the idle handler. It never reaches
  // 00b5/00b6 unless a genuine zero word was pushed.
  //
  // R146 set this to 1 on the reading "pop() returns T() and never stalls",
  // which is what the function's last line says and not what the function
  // does. The cost of that was measured (R148/R149): the free-running loop
  // reads rf1 THREE times an iteration, only the first is the dispatch, and
  // at ~272,000 iterations a second every command the i960 sent was consumed
  // as an idle-handler operand at 00b5/00b6 instead. 109 arrived, none
  // dispatched. With the pop held, the only read that can consume a command
  // is the dispatch at 004c, exactly as in MAME.
  //
  // The stale-head defect R146 found in the same place was real and its fix
  // stays: `fifo_rdata` reads `fifo_in_valid ? fifo_in_data : 0`.
  //
  // The fin-full / fout-full deadlock Model 1 records (520cf6a) arms only if
  // the consumer stops draining results. Ours drains synchronously -- see the
  // `stall` line above -- so it cannot; and if it ever does, the signature is
  // everything freezing at once, not the frame-1 hang this replaces.
  m2_tgp #(.EMPTY_FIFO_READS_ZERO(1'b0)) u_tgp (
    .clk(clk), .rst_n(rst_n & ~halted),
    .dbg_ucode_ram_csum(), .dbg_ucode_ram_ok(),
    .ucode_clk(clk), .ucode_we(uc_we), .ucode_addr(uc_addr), .ucode_data(uc_data),
    // The RAM window is not traced yet -- see the header. Acknowledged
    // immediately with zero so the TGP cannot hang on it, and the request is
    // brought out so a design that starts depending on it is visible.
    .ram_req(ram_req_w), .ram_we(), .ram_addr(), .ram_wdata(),
    .ram_rdata(32'd0), .ram_ack(ram_req_w),
    .fifo_in_data(fin_q), .fifo_in_valid(fin_valid),
    .fifo_in_pop(tgp_in_pop),
    .fifo_out_data(tgp_out_data), .fifo_out_push(tgp_out_push),
    .fifo_out_full(fout_full),
    .tbl_req(tbl_req), .tbl_addr(tbl_addr),
    .tbl_rdata(tbl_rdata), .tbl_ack(tbl_ack),
    .dat_req(dat_req), .dat_addr(dat_addr),
    .dat_we(dat_we), .dat_wdata(dat_wdata), .dat_is_buf(dat_is_buf),
    .dat_half(dat_half),
    .bufw_req(bufw_req), .bufw_addr(bufw_addr), .bufw_data(bufw_data),
    .bufw_ack(bufw_ack),
    .dat_rdata(dat_rdata), .dat_ack(dat_ack),
    .dbg_retires(dbg_tgp_retires), .dbg_pc(dbg_tgp_pc), .dbg_op(dbg_tgp_op),
    .dbg_fifo_hold(dbg_tgp_hold), .dbg_wr_n(dbg_tgp_wr_n), .dbg_wr_addr(dbg_tgp_wr_addr), .dbg_wr_data(dbg_tgp_wr_data),
    .dbg_st(dbg_tgp_st), .dbg_a(dbg_tgp_a), .dbg_b(dbg_tgp_b), .dbg_d(dbg_tgp_d),
    .dbg_unimplemented(dbg_tgp_unimpl),
    .dbg_io_addr(dbg_tgp_io_addr), .dbg_io_rd(dbg_tgp_io_rd),
    .dbg_io_wr(dbg_tgp_io_wr), .dbg_io_ack(dbg_tgp_io_ack),
    .dbg_ff_math(dbg_ff_math), .dbg_ff_rom(dbg_ff_rom), .dbg_ff_buf(dbg_ff_buf), .dbg_rd_total(dbg_rd_total),
    .dbg_fifo_rd(dbg_tgp_fifo_rd), .dbg_fifo_wr(dbg_tgp_fifo_wr), .dbg_bank(dbg_tgp_bank)
  );

  assign dbg_uc_we   = uc_we;
  assign dbg_uc_addr = {1'b0, uc_addr};
  assign dbg_uc_data = uc_data;

  assign dbg_ram_req = ram_req_w;

endmodule
