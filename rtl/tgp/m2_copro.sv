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
  input  logic        sel_fifoctl,  // 0x00980004, fifo_control
  input  logic        we,
  input  logic [31:0] wdata,
  output logic [31:0] rdata,

  // ---- for the debug channel
  output logic [31:0] dbg_ctl,
  output logic [15:0] dbg_prog_words,   // how much program was uploaded
  output logic [15:0] dbg_in_pushed,
  output logic [15:0] dbg_out_popped,
  output logic        dbg_ram_req       // the tie-off above, made visible
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
  // Eight deep each, as model2.cpp sets them up.
  localparam int unsigned FD = 8;
  logic [31:0] fin  [FD], fout [FD];
  logic  [3:0] fin_wp, fin_rp, fout_wp, fout_rp;
  wire   [3:0] fin_cnt  = fin_wp  - fin_rp;
  wire   [3:0] fout_cnt = fout_wp - fout_rp;
  wire         fin_full  = (fin_cnt  >= 4'(FD));
  wire         fin_empty = (fin_cnt  == 4'd0);
  wire         fout_full = (fout_cnt >= 4'(FD));
  wire         fout_empty= (fout_cnt == 4'd0);

  // ---- the TGP's own handshakes
  wire        tgp_in_pop;
  wire [31:0] tgp_out_data;
  wire        tgp_out_push;

  // A read of the FIFO port pops; a write pushes, or uploads.
  wire fifo_rd = sel_fifo && !we;
  wire fifo_wr = sel_fifo &&  we;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      coproctl <= 32'd0; coprocnt <= 12'd0; halted <= 1'b1;
      uc_we <= 1'b0; uc_addr <= 11'd0; uc_data <= 32'd0;
      fin_wp <= 4'd0; fin_rp <= 4'd0; fout_wp <= 4'd0; fout_rp <= 4'd0;
      dbg_prog_words <= 16'd0; dbg_in_pushed <= 16'd0; dbg_out_popped <= 16'd0;
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
          fin[fin_wp[2:0]] <= wdata;
          fin_wp <= fin_wp + 4'd1;
          if (!(&dbg_in_pushed)) dbg_in_pushed <= dbg_in_pushed + 16'd1;
        end
      end

      // ---- the i960 popping the output FIFO
      if (fifo_rd && !fout_empty) begin
        fout_rp <= fout_rp + 4'd1;
        if (!(&dbg_out_popped)) dbg_out_popped <= dbg_out_popped + 16'd1;
      end

      // ---- the TGP's own ends
      if (tgp_in_pop && !fin_empty)   fin_rp  <= fin_rp  + 4'd1;
      if (tgp_out_push && !fout_full) begin
        fout[fout_wp[2:0]] <= tgp_out_data;
        fout_wp <= fout_wp + 4'd1;
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
  m2_tgp u_tgp (
    .clk(clk), .rst_n(rst_n & ~halted),
    .dbg_ucode_ram_csum(), .dbg_ucode_ram_ok(),
    .ucode_clk(clk), .ucode_we(uc_we), .ucode_addr(uc_addr), .ucode_data(uc_data),
    // The RAM window is not traced yet -- see the header. Acknowledged
    // immediately with zero so the TGP cannot hang on it, and the request is
    // brought out so a design that starts depending on it is visible.
    .ram_req(ram_req_w), .ram_we(), .ram_addr(), .ram_wdata(),
    .ram_rdata(32'd0), .ram_ack(ram_req_w),
    .fifo_in_data(fin[fin_rp[2:0]]), .fifo_in_valid(!fin_empty),
    .fifo_in_pop(tgp_in_pop),
    .fifo_out_data(tgp_out_data), .fifo_out_push(tgp_out_push),
    .fifo_out_full(fout_full)
  );

  assign dbg_ram_req = ram_req_w;

endmodule
