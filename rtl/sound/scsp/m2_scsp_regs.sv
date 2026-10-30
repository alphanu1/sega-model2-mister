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
// drained samples ((255 - count) << prescale, MAME's period, R856) on one
// shared counter, each timer holding the count its callback falls due at; this
// clock's events go in MAME's order: a 68000 write, a MIBUF read, a MIDI
// byte, the timers, then CheckPendingIRQ.
//
// A TIMER STARTS WHEN IT IS WRITTEN, NOT AT THE SAMPLE (R883). MAME's timer is
// a scheduler timer adjusted from the writing CPU's local time, so it falls
// due (255 - count) << prescale samples after the write itself, mid-sample.
// Counting from the sample the write lands in dropped the part of a sample
// between the tick and the write -- for VF2's driver, which re-arms timer A
// (49 samples) in its handler ~0.9 sample after the interrupt, that made the
// timer 1.3% fast and the music with it. So with `exact` each timer keeps
// the write's phase (tph: the drained sample's progress, in 1/49 to 1/64 of
// a sample, from the 44.1 kHz accumulator) and, once its count is due, fires
// when the phase reaches it. The replay benches (step_mode) apply their
// writes at sample boundaries: exact is 0 there and a timer fires on the
// tick, as before.
//
// THE ARCADE'S PERIOD (R976, TIMER / tarc). MAME's period is matched to MAME,
// not to the chip: a real Sega Rally cabinet's music runs 2.18% slower than
// MAME's (an arcade recording against MAME 0.289, pitch equal to 0.03%), so
// its timer A (TIMA 0xCE, prescale 0, re-armed ~0.9 sample after each
// interrupt) is 49.874 x 1.0218 = 50.96 samples, not MAME's 49 + latency.
// Arcade mode counts as the chip's documented counter does -- 8 bits, up,
// on the prescaled sample clock of a free-running prescaler (manual 4.2.11;
// srg320's and Mednafen's SCSPs) -- and is fitted, by one sample, to that
// recording: the value written is taken at the next sample boundary and the
// interrupt comes on the (256 - count)-th prescaled tick after it. That is
// 51 samples for Rally's timer A and 512 for its timer B (the emulators' 512
// too). Every timer fires on a sample boundary; the write's phase is not
// kept. TIMER: 0 MAME only, 1 arcade only, 2 both (tarc selects, an OSD A/B).

`timescale 1ns/1ps

module m2_scsp_regs #(
  parameter bit MIDI_OUT = 1'b1,
  parameter int TIMER    = 0             // R976: 0 MAME's timers, 1 the arcade's, 2 tarc selects
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
  input  logic        exact,             // a timer falls due at its write's phase (R883)
  input  logic  [5:0] tph,               // the phase within the drained sample (0 at its tick)
  input  logic        tarc,              // R976: with TIMER 2, 1 = the arcade's timers (quasi-static)
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

  // ---- the register, a clock after it settles (R859, timing): an access
  // reads the old word at its first clock and merges at its second, and a is
  // held through it, so everything but the old word's read takes this copy
  logic  [5:1] ar;
  always_ff @(posedge clk) ar <= a;

  // ---- MAME's udata, as written
  (* ramstyle = "MLAB" *) logic [15:0] ud [32];
  logic [15:0] ud_q;
  logic [15:0] mrg;
  always_ff @(posedge clk) begin
    if (we) ud[ar] <= mrg;
    ud_q <= ud[a];
  end

  // ---- live state
  logic  [2:0] lv_ta, lv_tb, lv_mi;       // the three interrupt levels (SCILV bits 6, 7, 3)
  logic  [3:0] eb;                        // SCIEB bits 8, 7, 6, 3
  logic [10:0] scipd, mcipd;
  logic  [7:1] lines;
  logic [14:0] gcnt;                     // drained samples, mod 2^15
  logic [2:0][14:0] due;                  // when each timer's callback falls due
  logic  [2:0] tarm, texp, fired;
  logic [2:0][5:0] dph;                   // each timer's write phase (0: on the tick)
  logic  [2:0] late;                      // the count is due, the phase not yet reached
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
    case (ar)
      5'h02: q = {ud_q[15:8], mf_head};                          // MIBUF
      5'h04: q = mon;                                            // 0x408
      5'h0c: if (fired[0]) q[7:0] = 8'hff;                       // a timer's callback: count 0xff
      5'h0d: if (fired[1]) q[7:0] = 8'hff;
      5'h0e: if (fired[2]) q[7:0] = 8'hff;
      5'h10: q = {ud_q[15:11], scipd};
      5'h16: q = {5'd0, mcipd};
      default: if (ar >= 5'h18) q = 16'd0;                         // past 0x42f: MAME reads 0
    endcase
  end
  assign mrg = {be[1] ? d[15:8] : q[15:8], be[0] ? d[7:0] : q[7:0]};

  wire [14:0] gnext = gcnt + 15'd1;
  wire [14:0] tdue  = gcnt + 15'({7'd0, ~mrg[7:0]} << mrg[10:8]);    // now + (255 - count) << prescale
  // (a timer written this clock falls due at the next sample, tdue == gnext,
  // only for count 254 at prescale 0: tested directly, not through the adder
  // -- R859, timing)
  wire        tone  = mrg[10:0] == 11'h0fe;
  // R976: the arcade's -- the (256 - count)-th prescaled tick after the next
  // sample boundary, ticks where the free-running sample count is a multiple
  // of 2^prescale (mod 2^15, as gcnt)
  wire        arc   = (TIMER == 1) || (TIMER == 2 && tarc);
  wire [14:0] tdue_a = 15'((15'(gnext >> mrg[10:8]) + 15'(9'd256 - {1'b0, mrg[7:0]})) << mrg[10:8]);
  logic [10:0] scipd_n, scipd_c, mcipd_n;
  logic  [4:0] mw_n, mr_n;
  logic  [2:0] arm_n, ex_n, fired_n, rep, clr;   // clr: {MIDI, timer B / C, timer A}
  logic  [2:0] late_n;
  logic [2:0][14:0] due_n;
  logic [2:0][5:0] dph_n;
  wire   [5:0] wph = (exact && !tick44) ? tph : 6'd0;   // a write in the tick's clock counts as on it
  logic        chk;
  logic  [2:0] wrt;                              // the timer written this clock
  always_comb begin
    logic [1:0] tw;
    logic [2:0] go;                              // a timer fires this clock
    tw = (ar == 5'h0c) ? 2'd0 : (ar == 5'h0d) ? 2'd1 : 2'd2;
    scipd_n = scipd; mcipd_n = mcipd; mw_n = mw; mr_n = mr;
    arm_n = tarm; ex_n = texp; fired_n = fired; due_n = due; late_n = late; dph_n = dph;
    chk = 1'b0; rep = 3'b000; clr = 3'b000; wrt = 3'b000;
    if (we) begin
      case (ar)
        5'h02: begin                       // MIBUF: r16 pops it first
          if (mw_n != mr_n) mr_n = mr_n + 5'd1;
          if (mw_n == mr_n) begin clr[2] = 1'b1; scipd_n[3] = 1'b0; end
        end
        5'h0c, 5'h0d, 5'h0e: begin
          ex_n[tw] = 1'b0; fired_n[tw] = 1'b0; late_n[tw] = 1'b0;
          if (arc) begin arm_n[tw] = 1'b1; due_n[tw] = tdue_a; dph_n[tw] = 6'd0; wrt[tw] = 1'b1; end   // R976: every count
          else if (mrg[7:0] != 8'hff) begin arm_n[tw] = 1'b1; due_n[tw] = tdue; dph_n[tw] = wph; wrt[tw] = 1'b1; end   // MAME re-arms below 255
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
    go = 3'b000;
    for (int t = 0; t < 3; t++) begin
      // the count due at this tick: now if written on a tick, else once the
      // phase reaches the write's (a phase past this sample's last clock fires
      // at the next tick)
      if (tick44 && arm_n[t] && (wrt[t] ? tone && !arc : due[t] == gnext)) begin
        if (wrt[t] || dph[t] == 6'd0) go[t] = 1'b1; else late_n[t] = 1'b1;
      end else if (late[t] && !wrt[t] && (tick44 || tph >= dph[t])) begin
        go[t] = 1'b1; late_n[t] = 1'b0;
      end
      if (go[t]) begin
        arm_n[t] = 1'b0; ex_n[t] = 1'b1; fired_n[t] = 1'b1; scipd_n[6 + t] = 1'b1; chk = 1'b1;
        if (t == 0) mcipd_n[6] = 1'b1;
      end
    end
    if (chk && mw_n != mr_n) scipd_n[3] = 1'b1;
    scipd_c = scipd_n;
    for (int t = 0; t < 3; t++) if (rep[t] && ex_n[t]) scipd_n[6 + t] = 1'b1;
  end

  // the lines: CheckPendingIRQ sets one level after all of this clock's clears
  wire  [2:0] lv_ta_n = (we && ar == 5'h12) ? {lv_ta[2:1], mrg[6]} : (we && ar == 5'h13) ? {lv_ta[2], mrg[6], lv_ta[0]} :
                        (we && ar == 5'h14) ? {mrg[6], lv_ta[1:0]} : lv_ta;
  wire  [2:0] lv_tb_n = (we && ar == 5'h12) ? {lv_tb[2:1], mrg[7]} : (we && ar == 5'h13) ? {lv_tb[2], mrg[7], lv_tb[0]} :
                        (we && ar == 5'h14) ? {mrg[7], lv_tb[1:0]} : lv_tb;
  wire  [2:0] lv_mi_n = (we && ar == 5'h12) ? {lv_mi[2:1], mrg[3]} : (we && ar == 5'h13) ? {lv_mi[2], mrg[3], lv_mi[0]} :
                        (we && ar == 5'h14) ? {mrg[3], lv_mi[1:0]} : lv_mi;
  wire  [3:0] eb_n    = (we && ar == 5'h0f) ? {mrg[8:6], mrg[3]} : eb;
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
      fired <= '0; due <= '0; gcnt <= '0; mvol <= '0; late <= '0; dph <= '0; dac18 <= 1'b0; rbl <= '0; rbp <= '0; mslc <= '0;
    end else begin
      lv_ta <= lv_ta_n; lv_tb <= lv_tb_n; lv_mi <= lv_mi_n; eb <= eb_n;
      scipd <= scipd_n; mcipd <= mcipd_n; lines <= ln_n[7:1]; mw <= mw_n; mr <= mr_n;
      tarm <= arm_n; texp <= ex_n; fired <= fired_n; due <= due_n; late <= late_n; dph <= dph_n;
      if (tick44) gcnt <= gnext;
      midi_ack <= midi_valid && !midi_ack;
      if (we && ar == 5'h00) begin mvol <= mrg[3:0]; dac18 <= mrg[8]; end
      if (we && ar == 5'h01) begin rbl <= mrg[8:7]; rbp <= mrg[5:0]; end
      if (we && ar == 5'h04) mslc <= mrg[15:11];
    end
  end

  // ---- MIDI out (MOBUF): MAME's 32-byte stack, sent in order (any write to
  // 0x406 sends the low byte it leaves there)
  generate if (MIDI_OUT) begin : g_mout
    (* ramstyle = "MLAB" *) logic [7:0] mo_fifo [32];
    logic [4:0] mo_w, mo_wd, mo_r;
    wire mo_push = we && ar == 5'h03;
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
