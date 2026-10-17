// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// THE SCSP's COMMON REGISTERS (0x400-0x42f), TIMERS, INTERRUPTS AND MIDI
// (study R856-R858). Written against MAME 0.289's scsp.cpp (BSD-3-Clause,
// ElSemi, R. Belmont; notice in THIRD_PARTY.md): UpdateReg / UpdateRegR,
// CheckPendingIRQ, ResetInterrupts, the timer callbacks, the MIDI stacks.
//
// The registers as the 68000 wrote them live in a 24-word MLAB, MAME's
// udata; only the bits something reads live are flops. An access is two
// clocks: the old word is read (rd_a held), then a write merges into it
// (MAME's write(): r16, COMBINE_DATA, w16, UpdateReg). The timers count
// drained samples ((255 - count) << prescale, MAME's period, R856); this
// clock's events go in MAME's order: a 68000 write, a MIBUF read, a MIDI
// byte, the timers, then CheckPendingIRQ.

`timescale 1ns/1ps

module m2_scsp_regs #(
  parameter bit MIDI_OUT = 1'b1
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic  [5:1] a,                 // the register (held through an access)
  input  logic        we,                // the write's second clock: merge and write
  input  logic [15:0] d,
  input  logic  [1:0] be,
  output logic [15:0] q,                 // MAME's r16 of a (valid the clock after a settles)
  input  logic        mi_pop,            // a read of MIBUF
  input  logic [15:0] mon,               // the 0x408 monitor
  input  logic        tick44,
  // MIDI
  input  logic  [7:0] midi_data,
  input  logic        midi_valid,
  output logic        midi_ack,
  output logic  [7:0] mout_data,
  output logic        mout_valid,
  input  logic        mout_ack,
  // what the rest of the SCSP reads
  output logic  [2:0] ipl,
  output logic  [3:0] mvol,
  output logic        dac18,
  output logic  [1:0] rbl,
  output logic  [5:0] rbp,
  output logic  [4:0] mslc
);

  // ---- MAME's udata, as written
  (* ramstyle = "MLAB" *) logic [15:0] ud [32];
  logic [15:0] ud_q;
  logic [15:0] mrg;
  always_ff @(posedge clk) begin
    if (we) ud[a] <= mrg;
    ud_q <= ud[a];
  end

  // ---- live state
  logic  [2:0] lv_ta, lv_tb, lv_mi;       // the three interrupt levels (SCILV bits 6, 7, 3)
  logic  [3:0] eb;                        // SCIEB bits 8, 7, 6, 3
  logic [10:0] scipd, mcipd;
  logic  [7:1] lines;
  logic [2:0][14:0] tcd;
  logic  [2:0] tarm, texp, fired;
  (* ramstyle = "MLAB" *) logic [7:0] mfifo [32];
  logic  [7:0] mf_head;
  logic  [4:0] mw, mr;

  always_ff @(posedge clk) begin
    if (midi_valid && !midi_ack) mfifo[mw] <= midi_data;
    mf_head <= mfifo[mr];                 // (a read comes clocks after mr moves)
  end

  // r16: the word, with what MAME's UpdateRegR and its hardware bits put there
  always_comb begin
    q = ud_q;
    case (a)
      5'h02: q = {ud_q[15:8], mf_head};                          // MIBUF
      5'h04: q = mon;                                            // 0x408
      5'h0c: if (fired[0]) q[7:0] = 8'hff;                       // a timer's callback: count 0xff
      5'h0d: if (fired[1]) q[7:0] = 8'hff;
      5'h0e: if (fired[2]) q[7:0] = 8'hff;
      5'h10: q = {ud_q[15:11], scipd};
      5'h16: q = {5'd0, mcipd};
      default: if (a >= 5'h18) q = 16'd0;                         // past 0x42f: MAME reads 0
    endcase
  end
  assign mrg = {be[1] ? d[15:8] : q[15:8], be[0] ? d[7:0] : q[7:0]};

  wire [14:0] tload = 15'(({7'd0, ~mrg[7:0]} << mrg[10:8]) - 15'd1);   // (255 - count) << prescale, less one
  logic [10:0] scipd_n, scipd_c, mcipd_n;
  logic  [4:0] mw_n, mr_n;
  logic  [2:0] arm_n, ex_n, fired_n, rep, clr;   // clr: {MIDI, timer B / C, timer A}
  logic [2:0][14:0] tcd_n;
  logic        chk;
  always_comb begin
    logic [1:0] tw;
    tw = (a == 5'h0c) ? 2'd0 : (a == 5'h0d) ? 2'd1 : 2'd2;
    scipd_n = scipd; mcipd_n = mcipd; mw_n = mw; mr_n = mr;
    arm_n = tarm; ex_n = texp; fired_n = fired; tcd_n = tcd;
    chk = 1'b0; rep = 3'b000; clr = 3'b000;
    if (we) begin
      case (a)
        5'h02: begin                       // MIBUF: r16 pops it first
          if (mw_n != mr_n) mr_n = mr_n + 5'd1;
          if (mw_n == mr_n) begin clr[2] = 1'b1; scipd_n[3] = 1'b0; end
        end
        5'h0c, 5'h0d, 5'h0e: begin
          ex_n[tw] = 1'b0; fired_n[tw] = 1'b0;
          if (mrg[7:0] != 8'hff) begin arm_n[tw] = 1'b1; tcd_n[tw] = tload; end   // MAME re-arms below 255
        end
        5'h0f: chk = 1'b1;                 // SCIEB
        5'h10: scipd_n = mrg[10:0];
        5'h11: begin                       // SCIRE: clear, ResetInterrupts, check, re-pend
          scipd_n = scipd_n & ~mrg[10:0];
          clr = {mrg[3], mrg[7] | mrg[8], mrg[6]};
          chk = 1'b1; rep = 3'b111;
        end
        5'h16: if (mrg[5]) mcipd_n[5] = 1'b1;
        5'h17: mcipd_n = mcipd_n & ~mrg[10:0];
        default: ;
      endcase
    end
    if (mi_pop) begin
      if (mw_n != mr_n) mr_n = mr_n + 5'd1;
      if (mw_n == mr_n) begin clr[2] = 1'b1; scipd_n[3] = 1'b0; end
    end
    if (midi_valid && !midi_ack) begin mw_n = mw_n + 5'd1; chk = 1'b1; end
    if (tick44) begin
      for (int t = 0; t < 3; t++) begin
        if (arm_n[t]) begin
          if (tcd_n[t] != 15'd0) tcd_n[t] = tcd_n[t] - 15'd1;
          else begin
            arm_n[t] = 1'b0; ex_n[t] = 1'b1; fired_n[t] = 1'b1; scipd_n[6 + t] = 1'b1; chk = 1'b1;
            if (t == 0) mcipd_n[6] = 1'b1;
          end
        end
      end
    end
    if (chk && mw_n != mr_n) scipd_n[3] = 1'b1;
    scipd_c = scipd_n;
    for (int t = 0; t < 3; t++) if (rep[t] && ex_n[t]) scipd_n[6 + t] = 1'b1;
  end

  // the lines: CheckPendingIRQ sets one level after all of this clock's clears
  wire  [2:0] lv_ta_n = (we && a == 5'h12) ? {lv_ta[2:1], mrg[6]} : (we && a == 5'h13) ? {lv_ta[2], mrg[6], lv_ta[0]} :
                        (we && a == 5'h14) ? {mrg[6], lv_ta[1:0]} : lv_ta;
  wire  [2:0] lv_tb_n = (we && a == 5'h12) ? {lv_tb[2:1], mrg[7]} : (we && a == 5'h13) ? {lv_tb[2], mrg[7], lv_tb[0]} :
                        (we && a == 5'h14) ? {mrg[7], lv_tb[1:0]} : lv_tb;
  wire  [2:0] lv_mi_n = (we && a == 5'h12) ? {lv_mi[2:1], mrg[3]} : (we && a == 5'h13) ? {lv_mi[2], mrg[3], lv_mi[0]} :
                        (we && a == 5'h14) ? {mrg[3], lv_mi[1:0]} : lv_mi;
  wire  [3:0] eb_n    = (we && a == 5'h0f) ? {mrg[8:6], mrg[3]} : eb;
  wire  [7:0] dec_ta  = 8'(1) << lv_ta;
  wire  [7:0] dec_tb  = 8'(1) << lv_tb;
  wire  [7:0] dec_mi  = 8'(1) << lv_mi;
  logic [7:0] irq_set;
  always_comb begin
    irq_set = 8'd0;
    if (chk) begin
      if (scipd_c[6] && eb_n[1])      irq_set = dec_ta;
      else if (scipd_c[7] && eb_n[2]) irq_set = dec_tb;
      else if (scipd_c[8] && eb_n[3]) irq_set = dec_tb;
      else if (scipd_c[3] && eb_n[0]) irq_set = dec_mi;
    end
  end
  wire [7:0] irq_clr = ({8{clr[0]}} & dec_ta) | ({8{clr[1]}} & dec_tb) | ({8{clr[2]}} & dec_mi);
  wire [7:0] ln_n    = ({lines, 1'b0} & ~irq_clr) | irq_set;

  always_comb begin
    ipl = 3'd0;
    for (int l = 1; l < 8; l++) if (lines[l]) ipl = 3'(l);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lv_ta <= '0; lv_tb <= '0; lv_mi <= '0; eb <= '0; scipd <= '0; mcipd <= '0; lines <= '0;
      mw <= '0; mr <= '0; midi_ack <= 1'b0; tarm <= '0; texp <= 3'b111;   // MAME init(): TimCnt = 0xffff
      fired <= '0; tcd <= '0; mvol <= '0; dac18 <= 1'b0; rbl <= '0; rbp <= '0; mslc <= '0;
    end else begin
      lv_ta <= lv_ta_n; lv_tb <= lv_tb_n; lv_mi <= lv_mi_n; eb <= eb_n;
      scipd <= scipd_n; mcipd <= mcipd_n; lines <= ln_n[7:1]; mw <= mw_n; mr <= mr_n;
      tarm <= arm_n; texp <= ex_n; fired <= fired_n; tcd <= tcd_n;
      midi_ack <= midi_valid && !midi_ack;
      if (we && a == 5'h00) begin mvol <= mrg[3:0]; dac18 <= mrg[8]; end
      if (we && a == 5'h01) begin rbl <= mrg[8:7]; rbp <= mrg[5:0]; end
      if (we && a == 5'h04) mslc <= mrg[15:11];
    end
  end

  // ---- MIDI out (MOBUF): MAME's 32-byte stack, sent in order (any write to
  // 0x406 sends the low byte it leaves there)
  generate if (MIDI_OUT) begin : g_mout
    (* ramstyle = "MLAB" *) logic [7:0] mo_fifo [32];
    logic [4:0] mo_w, mo_wd, mo_r;
    wire mo_push = we && a == 5'h03;
    wire mo_pop  = mout_valid && mout_ack;
    always_ff @(posedge clk) begin
      if (mo_push) mo_fifo[mo_w] <= mrg[7:0];
      mout_data <= mo_fifo[mo_pop ? mo_r + 5'd1 : mo_r];
    end
    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin mo_w <= '0; mo_wd <= '0; mo_r <= '0; end
      else begin
        if (mo_push) mo_w <= mo_w + 5'd1;
        mo_wd <= mo_w;
        if (mo_pop) mo_r <= mo_r + 5'd1;
      end
    end
    assign mout_valid = mo_wd != mo_r;
  end else begin : g_nomout
    assign mout_valid = 1'b0;
    assign mout_data  = 8'd0;
  end endgenerate

endmodule
