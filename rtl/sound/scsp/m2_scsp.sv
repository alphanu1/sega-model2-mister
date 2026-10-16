// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// THE SCSP (Yamaha YMF292-F) OF THE MODEL 2A SOUND BOARD (study R856).
//
// Written for this core against MAME 0.289's src/devices/sound/scsp.cpp and
// scspdsp.cpp (BSD-3-Clause, copyright-holders ElSemi, R. Belmont; thanks-to
// kingshriek -- the notice and conditions are in THIRD_PARTY.md), whose
// arithmetic, tables and order of operations it follows, so that MAME's own
// register stream replayed into it gives MAME's own mix, sample for sample
// (tb_m2_scsp, against sim/sound/scsp_ref.h, itself bit-exact to MAME).
//
// ONE ENGINE, TIME-MULTIPLEXED: a sample is the 32 slots in order, then the
// DSP, then the 16 effect returns -- MAME's DoMasterSamples. A slot's
// registers come from a 512 x 16 M10K (two words a clock), its state from a
// 64 x 80 M10K (two rows a slot), its level words from m2_scsp_level, its
// sample bytes from m2_scsp_cache; one multiplier serves the pitch LFO, the
// interpolation, the amplitude LFO, the envelope and the three level
// products. 18 clocks an active slot, 1 an idle one.
//
// SOUND RAM HAS NO FIXED LATENCY (it is SDRAM), so the engine keeps no real
// time itself: it makes a sample when the output FIFO outside has room
// (out_ready), stalls on a cache miss, and the FIFO drains at 44,100 Hz.
// The timers count drained samples (tick44).
//
// THE 68000's ACCESSES are queued and applied in order at a slot boundary,
// between samples, or while the DSP runs (not DSP writes, then). MAME applies
// them between samples; here a write can land between two slots of a sample
// -- the one departure, R821's. A read waits for the queue to empty.
//
// NOT BUILT (no 2A game measured uses them, R856): FM (MDL / MDXSL / MDYSL
// and the ring buffer), reverse and ping-pong loops (LPCTL 2 / 3 play as 1),
// noise (SSCTL 1 and LFO waveform 3 give 0), DMA, MIDI out, the main-CPU
// interrupt (MCIEB / MCIPD stored, not wired -- as on Model 2), reads of the
// DSP's registers (0 -- no game reads them).

`timescale 1ns/1ps

module m2_scsp (
  input  logic        clk,
  input  logic        rst_n,

  // ---- the 68000 (0x100000-0x100fff decoded outside), one access per req
  input  logic        cpu_req,          // pulse: an access starts
  input  logic        cpu_we,
  input  logic [11:1] cpu_addr,
  input  logic [15:0] cpu_din,
  input  logic  [1:0] cpu_be,           // {upper, lower}
  output logic        cpu_ack,          // pulse: done (read data valid)
  output logic [15:0] cpu_dout,
  output logic  [2:0] ipl,              // 0 = none

  // ---- MIDI in (the i960's UART, through m2_sound_link)
  input  logic  [7:0] midi_data,
  input  logic        midi_valid,
  output logic        midi_ack,

  // ---- sound RAM
  output logic        sm_req,           // the slots' line fills
  output logic [15:0] sm_line,          // byte address [18:3]
  input  logic        sm_ack,
  input  logic [63:0] sm_data,          // word i of the line in [16i+15:16i]
  output logic        dm_req,           // the DSP (word address)
  output logic        dm_we,
  output logic [18:1] dm_addr,
  output logic [15:0] dm_wdata,
  input  logic        dm_ack,
  input  logic [63:0] dm_data,
  input  logic        snp,              // a 68000 write to sound RAM has landed
  input  logic [18:1] snp_addr,

  // ---- output
  input  logic        out_ready,
  output logic        out_valid,        // pulse
  output logic signed [31:0] out_l_raw, out_r_raw,   // MAME's smpl / smpr
  output logic signed [15:0] out_l, out_r,           // after the DAC and MVOL
  input  logic        tick44,           // one per sample drained at 44.1 kHz

  // ---- benches
  input  logic        step_mode,        // one sample per step_go
  input  logic        step_go,
  output logic        quiet,            // between samples with nothing pending
  output logic        dbg_slot_valid,
  output logic  [4:0] dbg_slot,
  output logic signed [31:0] dbg_slot_smp,
  output logic [31:0] dbg_samples,
  output logic [31:0] dbg_miss
);

`include "scsp_tables.svh"

  localparam logic [1:0] ATT = 2'd0, DC1 = 2'd1, DC2 = 2'd2, REL = 2'd3;

  // =====================================================================
  // declarations
  // =====================================================================
  typedef enum logic [2:0] { E_IDLE, E_OP, E_SLOT, E_DSP, E_EFF, E_OUT } est_t;
  typedef enum logic [2:0] { L_WAIT, L_W1, L_F1, L_A2, L_W2, L_F2, L_DONE } lst_t;

  est_t        est, op_ret;
  logic  [4:0] slot;
  logic  [4:0] c;
  logic [31:0] active, kb;
  logic [31:0][1:0] egst;               // the envelope state of each slot

  // RAM ports
  logic  [8:0] ra_addr, rb_addr;
  logic [15:0] ra_q, rb_q, rb_d;
  logic  [1:0] rb_be;
  logic  [5:0] st_addr;
  logic        st_we;
  logic [79:0] st_d, st_q;
  logic  [9:0] st_be;                     // byte enables
  logic  [9:0] eg_a;
  logic [10:0] ps_a, as_a;
  logic [12:0] eg_q;
  logic  [8:0] ps_q, as_q;
  logic signed [26:0] mu_a;                // one 27 x 18 multiply
  logic signed [17:0] mu_b;
  logic signed [44:0] mu_p;

  // the 68000's queue
  logic [28:0] wq [4];                      // {be 2, addr 11, data 16}
  logic  [1:0] wq_rd, wq_wr;
  logic  [2:0] wq_n;
  logic        rd_pend;
  logic [11:1] rd_a;
  logic        wq_pop, rd_done;
  logic [15:0] rd_val;

  // ops
  logic        op_rd;
  logic [11:1] o_addr;
  logic [15:0] o_data;
  logic  [1:0] o_be;
  logic  [3:0] oc;
  logic  [4:0] sw;
  logic [15:0] sw_w4, sw_w5, sw_w8;
  logic  [3:0] mon_ca;

  // sub-blocks
  logic        lv_req, lv_busy;
  logic  [4:0] lv_slot;
  logic [15:0] lv_w6, lv_w10, lv_w11;
  logic  [7:0] lv_raddr;
  logic [14:0] lv_q;
  logic        lk_req, lk_hit, fill_req, fill_done;
  logic [15:0] lk_line, fill_line;
  logic [63:0] lk_data, fill_data;
  logic        dsp_wr_done;
  logic [18:1] dsp_wr_addr;
  logic        dsp_go, dsp_done, dsp_busy, dsp_started, dsp_fin;
  logic        mix_we;
  logic [19:0] mix_val;
  logic  [3:0] ef_idx;
  logic signed [15:0] ef_q;
  logic        dw_en;
  logic [11:1] dw_addr;
  logic [15:0] dw_data;
  logic  [1:0] dw_be;
  logic  [3:0] isel_r;

  // common registers, timers, interrupts, MIDI
  logic [15:0] c400, c402, c404, c418, c41a, c41c;
  logic  [7:0] scilv0, scilv1, scilv2;
  logic [10:0] scieb, scipd, mcieb, mcipd;
  logic  [4:0] mslc;
  logic  [7:1] lines;
  logic  [7:0] mfifo [32];
  logic  [4:0] mw, mr;
  logic [14:0] tcnt [3];
  logic  [2:0] tarm, texp;
  logic        cw_en, mi_pop;
  logic [11:1] cw_addr;
  logic [15:0] cw_d;
  logic  [1:0] cw_be;
  logic [15:0] mon;

  // the slot in flight
  logic [15:0] r0, r1, r2, r3, r4, r5, r6, r8, r9;
  logic [31:0] cur, nxt, cur_a;
  logic [15:0] pph, aph, pph_n, aph_n;
  logic signed [27:0] vol;
  logic  [5:0] ar_i, d1r_i, d2r_i, rr_i;
  logic  [4:0] dl;
  logic        hold;
  logic [31:0] step0, step;
  logic signed [16:0] p1, p2;
  lst_t        ls;
  logic [19:0] a1, a2;
  logic  [1:0] eg_pre;
  logic        stop_loop;
  logic [31:0] cur_n, nxt_n;
  logic signed [27:0] vol_n;
  logic  [1:0] eg_n;
  logic        stop_rel, eg_lin;
  logic [12:0] eg_lv;
  logic signed [27:0] vol_r;
  logic  [1:0] eg_r;
  logic        stop_r, lin_r;
  logic [12:0] lv_r;
  logic signed [31:0] s1, s2, s3;
  logic [14:0] v_d, v_l, v_r, v_el, v_er;
  logic signed [31:0] smpl, smpr;
  logic  [3:0] ei;
  logic  [2:0] ec;
  logic signed [15:0] ef_r;

  wire  [28:0] wq_h   = wq[wq_rd];
  wire  [11:1] h_addr = wq_h[26:16];
  wire   [4:0] o_slot = o_addr[9:5];
  wire   [3:0] o_word = o_addr[4:1];
  // the queue's count and the read flag settle a clock after a pop / an answer
  wire         op_ready = ((wq_n != 3'd0) || rd_pend) && !wq_pop && !rd_done;
  wire         head_dsp = (wq_n != 3'd0) && h_addr >= 11'h380 && h_addr < 11'h600;
  wire         op_ok    = op_ready && !(head_dsp && dsp_busy);

  // =====================================================================
  // RAMs and ROMs
  // =====================================================================
  // slot registers: port A reads, port B reads and writes (byte enables)
  (* ramstyle = "M10K" *) logic [1:0][7:0] sreg [512];
  always_ff @(posedge clk) ra_q <= sreg[ra_addr];
  always_ff @(posedge clk) begin
    if (rb_be[0]) sreg[rb_addr][0] <= rb_d[7:0];
    if (rb_be[1]) sreg[rb_addr][1] <= rb_d[15:8];
    rb_q <= sreg[rb_addr];
  end

  // slot state, byte-enabled so that no update needs a read first:
  //   row 0  [79:64] pph  [63:32] cur  [31:0] nxt
  //   row 1  [79:64] aph  [63:48] {rr 6, dl 5, 0}  [47:0] {vol 28, ar 6,
  //          d1r 6, d2r 6, hold 1, 0}
  (* ramstyle = "M10K" *) logic [9:0][7:0] st [64];
  always_ff @(posedge clk) begin
    for (int b = 0; b < 10; b++) if (st_we && st_be[b]) st[st_addr][b] <= st_d[8*b +: 8];
    st_q <= st[st_addr];
  end

  // MAME's EG_TABLE, PSCALES, ASCALES
  (* ramstyle = "M10K" *) logic [12:0] eg_rom [1024];
  (* ramstyle = "M10K" *) logic  [8:0] ps_rom [2048];
  (* ramstyle = "M10K" *) logic  [8:0] as_rom [2048];
  initial begin
    $readmemh("scsp_eg.hex", eg_rom);
    $readmemh("scsp_pscale.hex", ps_rom);
    $readmemh("scsp_ascale.hex", as_rom);
  end
  always_ff @(posedge clk) begin
    eg_q <= eg_rom[eg_a];
    ps_q <= ps_rom[ps_a];
    as_q <= as_rom[as_a];
  end

  // the multiplier: operands and product registered (a product is valid two
  // clocks after its operands are set)
  always_ff @(posedge clk) mu_p <= mu_a * mu_b;
  wire signed [31:0] mu_lo = mu_p[31:0];     // MAME's int product (wraps at 32 bits)

  // =====================================================================
  // the 68000's queue
  // =====================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wq_rd <= '0; wq_wr <= '0; wq_n <= '0; rd_pend <= 1'b0; cpu_ack <= 1'b0; cpu_dout <= '0;
      rd_a <= '0;
    end else begin
      cpu_ack <= 1'b0;
      if (cpu_req && cpu_we) begin
        wq[wq_wr] <= {cpu_be, cpu_addr, cpu_din};
        wq_wr <= wq_wr + 2'd1;
        cpu_ack <= 1'b1;
      end
      if (cpu_req && !cpu_we) begin rd_pend <= 1'b1; rd_a <= cpu_addr; end
      if (rd_done) begin rd_pend <= 1'b0; cpu_ack <= 1'b1; cpu_dout <= rd_val; end
      if (wq_pop) wq_rd <= wq_rd + 2'd1;
      wq_n <= wq_n + {2'd0, cpu_req && cpu_we} - {2'd0, wq_pop};
    end
  end

  // =====================================================================
  // the level words, the sample cache, the DSP
  // =====================================================================
  m2_scsp_level u_level (
    .clk(clk), .rst_n(rst_n),
    .req(lv_req), .req_slot(lv_slot), .req_w6(lv_w6), .req_w10(lv_w10), .req_w11(lv_w11),
    .busy(lv_busy), .rd_addr(lv_raddr), .rd_q(lv_q)
  );

  m2_scsp_cache #(.IDX(8)) u_cache (
    .clk(clk), .rst_n(rst_n),
    .lk_req(lk_req), .lk_line(lk_line), .lk_hit(lk_hit), .lk_data(lk_data),
    .fill_req(fill_req), .fill_line(fill_line), .fill_done(fill_done), .fill_data(fill_data),
    .m_req(sm_req), .m_line(sm_line), .m_ack(sm_ack), .m_data(sm_data),
    .snp(snp), .snp_line(snp_addr[18:3]), .snp2(dsp_wr_done), .snp2_line(dsp_wr_addr[18:3]),
    .dbg_fills(dbg_miss)
  );

  m2_scsp_dsp u_dsp (
    .clk(clk), .rst_n(rst_n),
    .go(dsp_go), .done(dsp_done), .busy(dsp_busy),
    .rbl(c402[8:7]), .rbp(c402[5:0]),
    .mix_sel(isel_r), .mix_we(mix_we), .mix_val(mix_val),
    .ef_idx(ef_idx), .ef_q(ef_q),
    .w_en(dw_en), .w_addr(dw_addr), .w_data(dw_data), .w_be(dw_be),
    .m_req(dm_req), .m_we(dm_we), .m_addr(dm_addr), .m_wdata(dm_wdata),
    .m_ack(dm_ack), .m_data(dm_data), .snp(snp), .snp_addr(snp_addr),
    .wr_done(dsp_wr_done), .wr_addr(dsp_wr_addr), .dbg_stall(), .dbg_on(1'b0)
  );

  // =====================================================================
  // helpers (MAME's formulas)
  // =====================================================================
  // PSCALES index: the pitch LFO's signed wave p, + 128 (LFO_Init)
  function automatic logic [7:0] plfo_idx(input logic [1:0] ws, input logic [7:0] i);
    logic signed [9:0] p;
    case (ws)
      2'd0: p = $signed({{2{i[7]}}, i});                           // i < 128 ? i : i - 256
      2'd1: p = i[7] ? -10'sd128 : 10'sd127;
      2'd2: begin
        if (i < 8'd64)       p = $signed({1'b0, i, 1'b0});
        else if (i < 8'd128) p = 10'sd255 - $signed({1'b0, i, 1'b0});
        else if (i < 8'd192) p = 10'sd256 - $signed({1'b0, i, 1'b0});
        else                 p = $signed({1'b0, i, 1'b0}) - 10'sd511;
      end
      default: p = 10'sd0;                                         // noise: not built
    endcase
    plfo_idx = 8'(p + 10'sd128);
  endfunction
  // the amplitude LFO's wave, 0..255
  function automatic logic [7:0] alfo_wave(input logic [1:0] ws, input logic [7:0] i);
    case (ws)
      2'd0: alfo_wave = 8'd255 - i;
      2'd1: alfo_wave = i[7] ? 8'd0 : 8'd255;
      2'd2: alfo_wave = i[7] ? {i[6:0], 1'b0} : 8'd255 - {i[6:0], 1'b0};
      default: alfo_wave = 8'd0;                                   // noise: not built
    endcase
  endfunction
  // Step(): (FNS + 1024) << (octave + 2), octave signed
  function automatic logic [31:0] pitch(input logic [3:0] o, input logic [9:0] f);
    logic signed [5:0] sh;
    logic [31:0] fn;
    sh = $signed({{2{o[3]}}, o}) + 6'sd2;
    fn = {21'd0, 1'b1, f};
    if (sh >= 0) pitch = fn << sh[3:0];
    else         pitch = fn >> 6'(-sh);
  endfunction
  // Get_AR / Get_DR's index, clamp(base + 2 R, 0, 63)
  function automatic logic [5:0] rate_i(input logic signed [7:0] base, input logic [4:0] r);
    logic signed [7:0] x;
    x = base + $signed({2'b00, r, 1'b0});
    if (x < 0)       rate_i = 6'd0;
    else if (x > 63) rate_i = 6'd63;
    else             rate_i = x[5:0];
  endfunction
  // Compute_EG's base: octave + 2 KRS + FNS[9], or 0 when KRS = 0xf
  function automatic logic signed [7:0] eg_base(input logic [15:0] w5, input logic [15:0] w8);
    if (w5[13:10] == 4'hf) eg_base = 8'sd0;
    else eg_base = $signed({{4{w8[14]}}, w8[14:11]}) + $signed({3'b000, w5[13:10], 1'b0}) + $signed({7'd0, w8[9]});
  endfunction
  // a byte (as int8 << 8) or a word of a line
  function automatic logic signed [16:0] pick(input logic [63:0] ln, input logic [19:0] a, input logic p8);
    logic [15:0] wd;
    wd = ln[{a[2:1], 4'b0} +: 16];
    if (p8) pick = a[0] ? $signed({wd[7], wd[7:0], 8'd0}) : $signed({wd[15], wd[15:8], 8'd0});
    else    pick = $signed({wd[15], wd});
  endfunction
  function automatic logic [15:0] merge(input logic [15:0] old, input logic [15:0] d, input logic [1:0] be);
    merge = {be[1] ? d[15:8] : old[15:8], be[0] ? d[7:0] : old[7:0]};
  endfunction

  // =====================================================================
  // common registers, timers, interrupts, MIDI (MAME UpdateReg & co.)
  // =====================================================================
  wire [2:0] lvl_ta = {scilv2[6], scilv1[6], scilv0[6]};
  wire [2:0] lvl_tb = {scilv2[7], scilv1[7], scilv0[7]};
  wire [2:0] lvl_mi = {scilv2[3], scilv1[3], scilv0[3]};

  always_comb begin
    ipl = 3'd0;
    for (int l = 1; l < 8; l++) if (lines[l]) ipl = 3'(l);
  end

  always_ff @(posedge clk) begin
    if (midi_valid && !midi_ack) mfifo[mw] <= midi_data;
  end
  wire [7:0] mf_head = mfifo[mr];          // the byte MIBUF reads

  // the next state of the registers below: this clock's events in MAME's
  // order (a 68000 write, a MIBUF read, a MIDI byte, the timers, then
  // CheckPendingIRQ) on working copies
  logic [15:0] c400_n, c402_n, c404_n, c418_n, c41a_n, c41c_n;
  logic  [7:0] scilv0_n, scilv1_n, scilv2_n;
  logic [10:0] scieb_n, scipd_n, mcieb_n, mcipd_n;
  logic  [4:0] mslc_n, mw_n, mr_n;
  logic  [7:0] ln_n;
  logic  [2:0] arm_n, ex_n;
  logic [14:0] cn0_n, cn1_n, cn2_n;
  logic [15:0] mrg;
  logic        chk;
  always_comb begin
    c400_n = c400; c402_n = c402; c404_n = c404; c418_n = c418; c41a_n = c41a; c41c_n = c41c;
    scilv0_n = scilv0; scilv1_n = scilv1; scilv2_n = scilv2;
    scieb_n = scieb; scipd_n = scipd; mcieb_n = mcieb; mcipd_n = mcipd; mslc_n = mslc;
    ln_n = {lines, 1'b0}; mw_n = mw; mr_n = mr; arm_n = tarm; ex_n = texp;
    cn0_n = tcnt[0]; cn1_n = tcnt[1]; cn2_n = tcnt[2];
    chk = 1'b0; mrg = 16'd0;

    // ---- a register write (MAME write(): r16, combine, w16, UpdateReg)
    if (cw_en) begin
      case (cw_addr[5:1])
        5'h00: c400_n = merge(c400, cw_d, cw_be);
        5'h01: c402_n = merge(c402, cw_d, cw_be);
        5'h02: begin                         // MIBUF: r16 pops it first
          c404_n = merge({c404[15:8], mf_head}, cw_d, cw_be);
          if (mw_n != mr_n) mr_n = mr_n + 5'd1;
          if (mw_n == mr_n) begin ln_n[lvl_mi] = 1'b0; scipd_n[3] = 1'b0; end
        end
        5'h04: begin mrg = merge(mon, cw_d, cw_be); mslc_n = mrg[15:11]; end
        5'h0c: begin
          mrg = merge(c418, cw_d, cw_be); c418_n = mrg; ex_n[0] = 1'b0;
          if (mrg[7:0] != 8'hff) begin arm_n[0] = 1'b1; cn0_n = 15'({7'd0, 8'hff - mrg[7:0]} << mrg[10:8]); end
        end
        5'h0d: begin
          mrg = merge(c41a, cw_d, cw_be); c41a_n = mrg; ex_n[1] = 1'b0;
          if (mrg[7:0] != 8'hff) begin arm_n[1] = 1'b1; cn1_n = 15'({7'd0, 8'hff - mrg[7:0]} << mrg[10:8]); end
        end
        5'h0e: begin
          mrg = merge(c41c, cw_d, cw_be); c41c_n = mrg; ex_n[2] = 1'b0;
          if (mrg[7:0] != 8'hff) begin arm_n[2] = 1'b1; cn2_n = 15'({7'd0, 8'hff - mrg[7:0]} << mrg[10:8]); end
        end
        5'h0f: begin mrg = merge({5'd0, scieb}, cw_d, cw_be); scieb_n = mrg[10:0]; chk = 1'b1; end
        5'h10: begin mrg = merge({5'd0, scipd}, cw_d, cw_be); scipd_n = mrg[10:0]; end
        5'h11: begin                         // SCIRE: clear, ResetInterrupts, re-pend expired timers
          mrg = merge(16'd0, cw_d, cw_be);
          scipd_n = scipd_n & ~mrg[10:0];
          if (mrg[6])           ln_n[lvl_ta] = 1'b0;
          if (mrg[7] || mrg[8]) ln_n[lvl_tb] = 1'b0;
          if (mrg[3])           ln_n[lvl_mi] = 1'b0;
          if (mw_n != mr_n) scipd_n[3] = 1'b1;
          if (scipd_n != 11'd0) begin
            if (scipd_n[6] && scieb_n[6])      ln_n[lvl_ta] = 1'b1;
            else if (scipd_n[7] && scieb_n[7]) ln_n[lvl_tb] = 1'b1;
            else if (scipd_n[8] && scieb_n[8]) ln_n[lvl_tb] = 1'b1;
            else if (scipd_n[3] && scieb_n[3]) ln_n[lvl_mi] = 1'b1;
          end
          if (ex_n[0]) scipd_n[6] = 1'b1;
          if (ex_n[1]) scipd_n[7] = 1'b1;
          if (ex_n[2]) scipd_n[8] = 1'b1;
        end
        5'h12: begin mrg = merge({8'd0, scilv0}, cw_d, cw_be); scilv0_n = mrg[7:0]; end
        5'h13: begin mrg = merge({8'd0, scilv1}, cw_d, cw_be); scilv1_n = mrg[7:0]; end
        5'h14: begin mrg = merge({8'd0, scilv2}, cw_d, cw_be); scilv2_n = mrg[7:0]; end
        5'h15: begin mrg = merge({5'd0, mcieb}, cw_d, cw_be); mcieb_n = mrg[10:0]; end
        5'h16: begin mrg = merge({5'd0, mcipd}, cw_d, cw_be); if (mrg[5]) mcipd_n[5] = 1'b1; end
        5'h17: begin mrg = merge(16'd0, cw_d, cw_be); mcipd_n = mcipd_n & ~mrg[10:0]; end
        default: ;
      endcase
    end

    // ---- a MIBUF read
    if (mi_pop) begin
      if (mw_n != mr_n) mr_n = mr_n + 5'd1;
      if (mw_n == mr_n) begin ln_n[lvl_mi] = 1'b0; scipd_n[3] = 1'b0; end
    end

    // ---- a MIDI byte arrives (rcv_complete: push, CheckPendingIRQ)
    if (midi_valid && !midi_ack) begin mw_n = mw_n + 5'd1; chk = 1'b1; end

    // ---- the timers count a drained sample
    if (tick44) begin
      if (arm_n[0]) begin
        cn0_n = cn0_n - 15'd1;
        if (cn0_n == 15'd0) begin arm_n[0] = 1'b0; ex_n[0] = 1'b1; scipd_n[6] = 1'b1; chk = 1'b1; c418_n[7:0] = 8'hff; mcipd_n[6] = 1'b1; end
      end
      if (arm_n[1]) begin
        cn1_n = cn1_n - 15'd1;
        if (cn1_n == 15'd0) begin arm_n[1] = 1'b0; ex_n[1] = 1'b1; scipd_n[7] = 1'b1; chk = 1'b1; c41a_n[7:0] = 8'hff; end
      end
      if (arm_n[2]) begin
        cn2_n = cn2_n - 15'd1;
        if (cn2_n == 15'd0) begin arm_n[2] = 1'b0; ex_n[2] = 1'b1; scipd_n[8] = 1'b1; chk = 1'b1; c41c_n[7:0] = 8'hff; end
      end
    end

    // ---- CheckPendingIRQ
    if (chk) begin
      if (mw_n != mr_n) scipd_n[3] = 1'b1;
      if (scipd_n != 11'd0) begin
        if (scipd_n[6] && scieb_n[6])      ln_n[lvl_ta] = 1'b1;
        else if (scipd_n[7] && scieb_n[7]) ln_n[lvl_tb] = 1'b1;
        else if (scipd_n[8] && scieb_n[8]) ln_n[lvl_tb] = 1'b1;
        else if (scipd_n[3] && scieb_n[3]) ln_n[lvl_mi] = 1'b1;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      c400 <= '0; c402 <= '0; c404 <= '0; c418 <= '0; c41a <= '0; c41c <= '0;
      scilv0 <= '0; scilv1 <= '0; scilv2 <= '0; scieb <= '0; scipd <= '0; mcieb <= '0; mcipd <= '0;
      mslc <= '0; lines <= '0; mw <= '0; mr <= '0; midi_ack <= 1'b0;
      tarm <= '0; texp <= 3'b111;            // MAME init(): TimCnt = 0xffff
      tcnt[0] <= '0; tcnt[1] <= '0; tcnt[2] <= '0;
    end else begin
      c400 <= c400_n; c402 <= c402_n; c404 <= c404_n; c418 <= c418_n; c41a <= c41a_n; c41c <= c41c_n;
      scilv0 <= scilv0_n; scilv1 <= scilv1_n; scilv2 <= scilv2_n;
      scieb <= scieb_n; scipd <= scipd_n; mcieb <= mcieb_n; mcipd <= mcipd_n; mslc <= mslc_n;
      lines <= ln_n[7:1]; mw <= mw_n; mr <= mr_n; tarm <= arm_n; texp <= ex_n;
      tcnt[0] <= cn0_n; tcnt[1] <= cn1_n; tcnt[2] <= cn2_n;
      midi_ack <= midi_valid && !midi_ack;
    end
  end

  // MAME's r16 of a common register
  function automatic logic [15:0] common_read(input logic [5:1] a);
    case (a)
      5'h00: common_read = c400;
      5'h01: common_read = c402;
      5'h02: common_read = {c404[15:8], mf_head};
      5'h0c: common_read = c418;
      5'h0d: common_read = c41a;
      5'h0e: common_read = c41c;
      5'h0f: common_read = {5'd0, scieb};
      5'h10: common_read = {5'd0, scipd};
      5'h12: common_read = {8'd0, scilv0};
      5'h13: common_read = {8'd0, scilv1};
      5'h14: common_read = {8'd0, scilv2};
      5'h15: common_read = {5'd0, mcieb};
      5'h16: common_read = {5'd0, mcipd};
      default: common_read = 16'd0;
    endcase
  endfunction

  // =====================================================================
  // the slot's combinational parts
  // =====================================================================
  wire        pcm8   = r0[4];
  wire  [1:0] lpctl  = r0[6:5];
  wire  [1:0] ssctl  = r0[8:7];
  wire  [1:0] sbctl  = r0[10:9];
  wire [19:0] sa     = {r0[3:0], r1};
  wire [15:0] lsa    = r2;
  wire [15:0] lea    = r3;
  wire  [4:0] d2r_r  = r4[15:11];
  wire        lpslnk = r5[14];
  wire        sdir   = r6[8];
  wire  [4:0] lfof   = r9[14:10];
  wire  [1:0] plfows = r9[9:8];
  wire  [2:0] plfos  = r9[7:5];
  wire  [1:0] alfows = r9[4:3];
  wire  [2:0] alfos  = r9[2:0];
  wire        live   = ssctl != 2'd3;      // MAME: SSCTL 3 returns 0, touching nothing
  wire        alfo_on = alfos != 3'd0 && !sdir && live;

  // the two sample addresses (bytes; MAME's read_byte masks to 20 bits)
  always_comb begin
    logic [31:0] o1, o2;
    o1 = pcm8 ? (cur >> 12) : ((cur >> 11) & ~32'd1);
    o2 = pcm8 ? (nxt >> 12) : ((nxt >> 11) & ~32'd1);
    a1 = sa + o1[19:0];
    a2 = sa + o2[19:0];
  end

  // the loop, after the step (LPCTL 2 / 3 play as 1: not built)
  always_comb begin
    logic [31:0] n_a, ad1, ad2;
    n_a = cur_a + 32'd4096;
    ad1 = cur_a >> 12;
    ad2 = n_a >> 12;
    eg_pre = egst[slot];
    if (ad1 >= {16'd0, lsa} && lpslnk && egst[slot] == ATT) eg_pre = DC1;
    cur_n = cur_a; nxt_n = n_a; stop_loop = 1'b0;
    if (lpctl == 2'd0) begin
      if ((ad1 >= {16'd0, lsa} && ad1 >= {16'd0, lea}) || (ad2 >= {16'd0, lsa} && ad2 >= {16'd0, lea})) stop_loop = 1'b1;
    end else begin
      if (ad1 >= {16'd0, lea}) cur_n = cur_a - {4'd0, lea, 12'd0} + {4'd0, lsa, 12'd0};
      if (ad2 >= {16'd0, lea}) nxt_n = n_a   - {4'd0, lea, 12'd0} + {4'd0, lsa, 12'd0};
    end
    if (!live) begin cur_n = cur; nxt_n = nxt; stop_loop = 1'b0; eg_pre = egst[slot]; end
  end

  // the envelope (MAME EG_Update), from eg_pre; SDIR leaves it alone
  // the one rate this state uses (MAME's AR / D1R / D2R / RR table value)
  logic  [5:0] dr_i;
  logic [18:0] dr_v;
  always_comb begin
    case (eg_pre)
      DC1:     dr_i = d1r_i;
      DC2:     dr_i = d2r_i;
      default: dr_i = rr_i;
    endcase
    dr_v = scsp_drtab(dr_i);
  end
  always_comb begin
    logic signed [28:0] v;
    v = {vol[27], vol};
    eg_n = eg_pre; stop_rel = 1'b0;
    case (eg_pre)
      ATT: begin
        v = v + $signed({2'b00, scsp_artab(ar_i)});
        if (v >= $signed({3'b000, 10'h3ff, 16'd0})) begin
          if (!lpslnk) eg_n = DC1;          // (D1R >= 1024 << 16 never holds with DRTABLE)
          v = {3'b000, 10'h3ff, 16'd0};
        end
      end
      DC1: begin
        v = v - $signed({10'd0, dr_v});
        if (v <= 0) v = '0;
        if (v[25:21] <= dl) eg_n = DC2;
      end
      DC2: begin
        if (d2r_r != 5'd0) begin
          v = v - $signed({10'd0, dr_v});
          if (v <= 0) v = '0;
        end
      end
      default: begin
        v = v - $signed({10'd0, dr_v});
        if (v <= 0) begin v = '0; stop_rel = 1'b1; end
      end
    endcase
    vol_n  = v[27:0];
    eg_lin = eg_pre == ATT;
    eg_lv  = hold ? 13'h0ffc : {1'b0, vol_n[25:16], 2'b00};
    if (sdir || !live) begin vol_n = vol; eg_n = eg_pre; stop_rel = 1'b0; end
  end

  // the interpolated, SBCTL'd sample (valid at c = 8, from the product)
  logic signed [31:0] s0, s1c;
  always_comb begin
    logic signed [31:0] s;
    s = ({{15{p1[16]}}, p1} <<< 12) + mu_lo;
    s0 = s >>> 12;
    if (ssctl != 2'd0) s0 = 32'sd0;
    s1c = s0;
    if (sbctl[0]) s1c = s1c ^ 32'sh7fff;
    if (sbctl[1]) s1c = {{16{~s1c[15]}}, ~s1c[15], s1c[14:0]};   // (s16)(sample ^ 0x8000)
  end

  // =====================================================================
  // address muxes
  // =====================================================================
  always_comb begin
    ra_addr = {slot, 4'd0}; rb_addr = {slot, 4'd1}; rb_d = o_data; rb_be = 2'b00;
    st_addr = {slot, 1'b0}; st_we = 1'b0; st_d = '0; st_be = '1;
    ps_a = {plfos, plfo_idx(plfows, pph_n[15:8])};
    as_a = {alfos, alfo_wave(alfows, aph_n[15:8])};
    eg_a = vol_r[25:16];
    lv_raddr = {slot, 3'd0};
    lk_req = 1'b0; lk_line = a1[18:3];
    fill_req = 1'b0; fill_line = a1[18:3];
    ef_idx = ei;
    mix_we = 1'b0; mix_val = mu_lo[29:10];
    case (est)
      E_OP: begin
        ra_addr = {o_slot, o_word}; rb_addr = {o_slot, o_word};
        if (op_rd) begin
          st_addr = {mslc, oc != 4'd0};
        end else begin
          case (oc)
            4'd0: if (o_addr < 11'h200) begin rb_be = o_be; rb_d = (o_word == 4'd0) ? (o_data & 16'hefff) : o_data; end
            4'd1: rb_addr = {o_slot, 4'd5};
            4'd2: begin st_addr = {o_slot, 1'b1}; st_we = 1'b1; st_be = 10'b0011000000;   // RR (base 0), DL
                        st_d[63:48] = {rate_i(8'sd0, rb_q[4:0]), 5'h1f - rb_q[9:5], 5'd0}; end
            4'd4: begin ra_addr = {o_slot, 4'd6}; rb_addr = {o_slot, 4'd10}; end
            4'd5: ra_addr = {o_slot, 4'd11};
            4'd8: begin ra_addr = {sw, 4'd4}; rb_addr = {sw, 4'd5}; end
            4'd9: ra_addr = {sw, 4'd8};
            // StartSlot: cur 0, nxt 4096, the LFO phases kept (bytes 9-8)
            4'd11: begin st_addr = {sw, 1'b0}; st_we = 1'b1; st_be = 10'b0011111111; st_d[63:0] = {32'd0, 32'd4096}; end
            4'd12: begin st_addr = {sw, 1'b1}; st_we = 1'b1; st_be = 10'b0011111111;
                         st_d[63:0] = {rate_i(eg_base(sw_w5, sw_w8), sw_w5[4:0]), 5'h1f - sw_w5[9:5], 5'd0,
                                       28'h17F0000,
                                       rate_i(eg_base(sw_w5, sw_w8), sw_w4[4:0]),
                                       rate_i(eg_base(sw_w5, sw_w8), sw_w4[10:6]),
                                       rate_i(eg_base(sw_w5, sw_w8), sw_w4[15:11]),
                                       sw_w4[5], 1'b0}; end
            default: ;
          endcase
        end
      end
      E_SLOT: begin
        case (c)
          5'd0: begin ra_addr = {slot, 4'd0}; rb_addr = {slot, 4'd1}; st_addr = {slot, 1'b0}; end
          5'd1: begin ra_addr = {slot, 4'd8}; rb_addr = {slot, 4'd9}; st_addr = {slot, 1'b1}; end
          5'd2: begin ra_addr = {slot, 4'd2}; rb_addr = {slot, 4'd3}; end
          5'd3: begin ra_addr = {slot, 4'd4}; rb_addr = {slot, 4'd5}; end
          5'd4: begin ra_addr = {slot, 4'd6}; rb_addr = {slot, 4'd10}; end
          5'd9: begin
            st_addr = {slot, 1'b0}; st_we = live;
            st_d = {(plfos != 3'd0 && live) ? pph_n : pph, cur_n, nxt_n};
            lv_raddr = {slot, 3'd2};
          end
          5'd10: begin
            st_addr = {slot, 1'b1}; st_we = live;
            st_d = {alfo_on ? aph_n : aph, rr_i, dl, 5'd0, vol_r, ar_i, d1r_i, d2r_i, hold, 1'b0};
            lv_raddr = {slot, 3'd0};
          end
          5'd11: lv_raddr = {slot, 3'd1};
          5'd17: begin   // MAME StopSlot clears KEYONB in the register
            rb_addr = {slot, 4'd0}; rb_be = {stop_r, 1'b0}; rb_d = {r0[15:12], 1'b0, r0[10:0]};
          end
          default: ;
        endcase
        if (c == 5'd15) mix_we = 1'b1;
        if (c >= 5'd2) begin
          case (ls)
            L_WAIT: begin lk_req = 1'b1; lk_line = a1[18:3]; end
            L_A2:   begin lk_req = 1'b1; lk_line = a2[18:3]; end
            L_F1:   begin fill_req = 1'b1; fill_line = a1[18:3]; end
            L_F2:   begin fill_req = 1'b1; fill_line = a2[18:3]; end
            default: ;
          endcase
        end
      end
      E_EFF: lv_raddr = {1'b0, ei, ec == 3'd0 ? 3'd3 : 3'd4};
      default: ;
    endcase
    // a lookup is skipped (no request) where the FSM below takes 0 directly
    if (est == E_SLOT && c >= 5'd2 && ls == L_WAIT && (ssctl != 2'd0 || a1 >= 20'h80000)) lk_req = 1'b0;
    if (est == E_SLOT && ls == L_A2 && a2 >= 20'h80000) lk_req = 1'b0;
  end


  assign quiet = est == E_IDLE && !op_ready && !wq_pop && !rd_done && !lv_busy && !lv_req && !dsp_busy;
  wire go_ok = step_mode ? (step_go && !lv_busy && !lv_req) : out_ready;

  // the output: MAME's DAC (smpl >> 2 clamped to 16 bits, or the 18-bit
  // range), then MVOL / 15 -- the speaker's gain, round(65536 x MVOL / 15)
  // through the engine's multiplier; 15 is unity
  function automatic logic signed [15:0] dac(input logic signed [31:0] s, input logic d18);
    logic signed [31:0] x;
    if (d18) begin
      x = s;
      if (x > 32'sd131071) x = 32'sd131071; else if (x < -32'sd131072) x = -32'sd131072;
      x = x >>> 2;
    end else begin
      x = s >>> 2;
      if (x > 32'sd32767) x = 32'sd32767; else if (x < -32'sd32768) x = -32'sd32768;
    end
    dac = x[15:0];
  endfunction
  function automatic logic [16:0] mvol_gain(input logic [3:0] mv);
    mvol_gain = 17'((({13'd0, mv} * 17'd65536) + 17'd7) / 17'd15);
  endfunction
  wire signed [15:0] dac_l = dac(smpl, c400[8]);
  wire signed [15:0] dac_r = dac(smpr, c400[8]);

`ifdef SCSP_DEBUG
  logic [4:0]  dbg_sel;
  logic [31:0] dbg_from, dbg_to;
  initial begin
    if (!$value$plusargs("dslot=%d", dbg_sel)) dbg_sel = 5'd0;
    if (!$value$plusargs("dfrom=%d", dbg_from)) dbg_from = 32'd0;
    if (!$value$plusargs("dto=%d", dbg_to)) dbg_to = 32'd0;
  end
`endif
  // =====================================================================
  // the engine
  // =====================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      est <= E_IDLE; op_ret <= E_IDLE; slot <= '0; c <= '0; oc <= '0; sw <= '0; op_rd <= 1'b0;
      o_addr <= '0; o_data <= '0; o_be <= '0;
      active <= '0; kb <= '0;
      egst <= {32{REL}};
      wq_pop <= 1'b0; rd_done <= 1'b0; lv_req <= 1'b0; dsp_go <= 1'b0; dw_en <= 1'b0;
      dsp_started <= 1'b0; dsp_fin <= 1'b0;
      cw_en <= 1'b0; mi_pop <= 1'b0;
      out_valid <= 1'b0; dbg_samples <= '0; dbg_slot_valid <= 1'b0;
      ls <= L_WAIT; smpl <= '0; smpr <= '0; mon <= '0;
    end else begin
      wq_pop <= 1'b0; rd_done <= 1'b0; dsp_go <= 1'b0; dw_en <= 1'b0; out_valid <= 1'b0;
      dbg_slot_valid <= 1'b0; cw_en <= 1'b0; mi_pop <= 1'b0;
      if (lv_req && !lv_busy) lv_req <= 1'b0;
      if (dsp_done) dsp_fin <= 1'b1;

      case (est)
        // ------------------------------------------------ between samples
        E_IDLE: begin
          if (op_ok) begin
            est <= E_OP; op_ret <= E_IDLE; oc <= '0; op_rd <= wq_n == 3'd0;
            o_addr <= (wq_n != 3'd0) ? h_addr : rd_a; o_data <= wq_h[15:0]; o_be <= wq_h[28:27];
          end else if (go_ok && !dsp_busy && !op_ready) begin
            est <= E_SLOT; slot <= 5'd0; c <= 5'd0; ls <= L_WAIT; smpl <= '0; smpr <= '0;
          end
        end

        // ------------------------------------------------ a queued access
        E_OP: begin
          if (!op_rd) begin
            if (o_addr < 11'h200) begin
              // a slot register: w16, then UpdateSlotReg
              case (oc)
                4'd0: begin
                  wq_pop <= 1'b1;
                  if (o_word == 4'd0 && o_be[1]) kb[o_slot] <= o_data[11];
                  if (o_word == 4'd0 && o_be[1] && o_data[12]) begin oc <= 4'd7; sw <= 5'd0; end
                  else if (o_word == 4'd5) oc <= 4'd1;
                  else if (o_word == 4'd6 || o_word == 4'd10 || o_word == 4'd11) oc <= 4'd4;
                  else est <= op_ret;
                end
                4'd1: oc <= 4'd2;                         // word 5 asked
                4'd2: est <= op_ret;                      // row 1's RR (base 0), DL written
                4'd4: oc <= 4'd5;                         // words 6, 10 asked
                4'd5: begin lv_w6 <= ra_q; lv_w10 <= rb_q; oc <= 4'd6; end
                4'd6: begin lv_w11 <= ra_q; lv_slot <= o_slot; oc <= 4'd13; end
                4'd13: if (!lv_busy && !lv_req) begin lv_req <= 1'b1; est <= op_ret; end
                // the KEYONEX sweep: start a released slot that is keyed,
                // release one that is not
                4'd7: begin
                  if (kb[sw] && egst[sw] == REL) oc <= 4'd8;
                  else begin
                    if (!kb[sw]) egst[sw] <= REL;
                    if (sw == 5'd31) est <= op_ret; else sw <= sw + 5'd1;
                  end
                end
                4'd8: oc <= 4'd9;                         // words 4, 5 and row 0 asked
                4'd9: begin sw_w4 <= ra_q; sw_w5 <= rb_q; oc <= 4'd10; end
                4'd10: begin sw_w8 <= ra_q; oc <= 4'd11; end
                4'd11: oc <= 4'd12;                       // row 0 written
                4'd12: begin                              // row 1 written
                  active[sw] <= 1'b1; egst[sw] <= ATT;
                  if (sw == 5'd31) est <= op_ret; else begin sw <= sw + 5'd1; oc <= 4'd7; end
                end
                default: est <= op_ret;
              endcase
            end else if (o_addr < 11'h218) begin
              wq_pop <= 1'b1; cw_en <= 1'b1; cw_addr <= o_addr; cw_d <= o_data; cw_be <= o_be;
              est <= op_ret;
            end else if (o_addr >= 11'h380 && o_addr < 11'h600) begin
              wq_pop <= 1'b1; dw_en <= 1'b1; dw_addr <= o_addr; dw_data <= o_data; dw_be <= o_be;
              est <= op_ret;
            end else begin
              wq_pop <= 1'b1; est <= op_ret;               // ring buffer, unmapped: nothing
            end
          end else begin
            // a read (MAME r16)
            case (oc)
              4'd0: oc <= 4'd1;
              4'd1: begin mon_ca <= st_q[59:56]; oc <= 4'd2; end
              default: begin
                if (o_addr < 11'h200) rd_val <= rb_q;
                else if (o_addr == 11'h204) begin
                  // 0x408: (CA << 7) | (SGC << 5) | EG of slot MSLC
                  rd_val <= {5'd0, mon_ca, egst[mslc], 5'h1f - st_q[45:41]};
                  mon    <= {5'd0, mon_ca, egst[mslc], 5'h1f - st_q[45:41]};
                end else rd_val <= common_read(o_addr[5:1]);
                if (o_addr == 11'h202) mi_pop <= 1'b1;
                rd_done <= 1'b1; est <= op_ret;
              end
            endcase
          end
        end

        // ------------------------------------------------ a slot
        E_SLOT: begin
          if (c == 5'd0 && op_ok) begin
            est <= E_OP; op_ret <= E_SLOT; oc <= '0; op_rd <= wq_n == 3'd0;
            o_addr <= (wq_n != 3'd0) ? h_addr : rd_a; o_data <= wq_h[15:0]; o_be <= wq_h[28:27];
          end else if (c == 5'd0 && !active[slot]) begin
            if (slot == 5'd31) begin est <= E_DSP; dsp_started <= 1'b0; dsp_fin <= 1'b0; end
            slot <= slot + 5'd1;
          end else begin
            c <= c + 5'd1;
            // ---- the sample bytes (from c = 2; p1 and p2 by c = 6)
            if (c >= 5'd2) begin
              case (ls)
                L_WAIT: begin
                  if (ssctl != 2'd0) begin p1 <= '0; p2 <= '0; ls <= L_DONE; end
                  else if (a1 >= 20'h80000) begin p1 <= '0; ls <= L_A2; end
                  else ls <= L_W1;
                end
                L_W1: begin
                  if (lk_hit) begin
                    p1 <= pick(lk_data, a1, pcm8);
                    if (a2[19:3] == a1[19:3]) begin p2 <= pick(lk_data, a2, pcm8); ls <= L_DONE; end
                    else ls <= L_A2;
                  end else ls <= L_F1;
                end
                L_F1: if (fill_done) begin
                  p1 <= pick(fill_data, a1, pcm8);
                  if (a2[19:3] == a1[19:3]) begin p2 <= pick(fill_data, a2, pcm8); ls <= L_DONE; end
                  else ls <= L_A2;
                end
                L_A2: begin
                  if (a2 >= 20'h80000) begin p2 <= '0; ls <= L_DONE; end
                  else ls <= L_W2;
                end
                L_W2: begin
                  if (lk_hit) begin p2 <= pick(lk_data, a2, pcm8); ls <= L_DONE; end
                  else ls <= L_F2;
                end
                L_F2: if (fill_done) begin p2 <= pick(fill_data, a2, pcm8); ls <= L_DONE; end
                default: ;
              endcase
            end
            case (c)
              5'd1: begin r0 <= ra_q; r1 <= rb_q; pph <= st_q[79:64]; cur <= st_q[63:32]; nxt <= st_q[31:0]; end
              5'd2: begin
                r8 <= ra_q; r9 <= rb_q;
                aph <= st_q[79:64]; rr_i <= st_q[63:58]; dl <= st_q[57:53];
                vol <= st_q[47:20]; ar_i <= st_q[19:14]; d1r_i <= st_q[13:8]; d2r_i <= st_q[7:2]; hold <= st_q[1];
              end
              5'd3: begin
                r2 <= ra_q; r3 <= rb_q;
                step0 <= pitch(r8[14:11], r8[9:0]);
                pph_n <= pph + {7'd0, scsp_lfostep(lfof)};
                aph_n <= aph + {7'd0, scsp_lfostep(lfof)};
              end
              5'd4: begin r4 <= ra_q; r5 <= rb_q; end      // ps_q / as_q asked
              5'd5: begin
                r6 <= ra_q; isel_r <= rb_q[6:3];
                mu_a <= step0[26:0]; mu_b <= {5'd0, ps_q, 4'd0}; // PLFO_Step returns p << 4 (step0 < 2^22)
              end
              5'd6: begin
                if (ls != L_DONE) c <= c;                  // the sample bytes are not in yet
                else begin
                  mu_a <= {{10{p2[16]}}, p2} - {{10{p1[16]}}, p1};
                  mu_b <= {6'd0, cur[11:0]};
                end
              end
              5'd7: step <= (plfos != 3'd0) ? (mu_lo >>> 12) : step0;
              5'd8: begin
                cur_a <= cur + step;
                s1 <= s1c;
                mu_a <= s1c[26:0]; mu_b <= {5'd0, as_q, 4'd0};     // ALFO_Step returns p << 4
              end
              5'd9: begin                                  // row 0 written; the envelope
                vol_r <= vol_n; eg_r <= eg_n; stop_r <= stop_loop | stop_rel; lin_r <= eg_lin; lv_r <= eg_lv;
              end
              5'd10: begin                                 // row 1 written; ALFO product
                s2 <= alfo_on ? (mu_lo >>> 12) : s1;
                v_d <= lv_q;
              end
              5'd11: begin                                 // EG_TABLE in; the EG product
                mu_a <= s2[26:0]; mu_b <= {5'd0, lin_r ? lv_r : eg_q};
                v_l <= lv_q;
              end
              5'd12: v_r <= lv_q;
              5'd13: begin
                s3 <= (!live) ? 32'sd0 : (sdir ? s2 : (mu_lo >>> 12));
                mu_a <= (!live) ? 27'sd0 : (sdir ? s2[26:0] : 27'(mu_lo >>> 12)); mu_b <= {3'd0, v_d};
              end
              5'd14: begin mu_a <= s3[26:0]; mu_b <= {3'd0, v_l}; end
              5'd15: begin mu_a <= s3[26:0]; mu_b <= {3'd0, v_r}; end   // the DSP send lands
              5'd16: smpl <= smpl + (mu_lo >>> 12);
              5'd17: begin
                smpr <= smpr + (mu_lo >>> 12);
                if (live) egst[slot] <= eg_r;
                if (stop_r) begin active[slot] <= 1'b0; kb[slot] <= 1'b0; end
                dbg_slot_valid <= 1'b1; dbg_slot <= slot; dbg_slot_smp <= s3;
`ifdef SCSP_DEBUG
                if (slot == dbg_sel && dbg_samples >= dbg_from && dbg_samples < dbg_to)
                  $display("n %0d slot %0d r0 %h sa %h lsa %h lea %h cur %h nxt %h step %h a1 %h a2 %h p1 %0d p2 %0d s1 %0d s2 %0d s3 %0d vol %h eg %0d",
                           dbg_samples, slot, r0, sa, lsa, lea, cur, nxt, step, a1, a2, p1, p2, s1, s2, s3, vol, egst[slot]);
`endif
                c <= 5'd0; ls <= L_WAIT;
                if (slot == 5'd31) begin est <= E_DSP; dsp_started <= 1'b0; dsp_fin <= 1'b0; end
                slot <= slot + 5'd1;
              end
              default: ;
            endcase
          end
        end

        // ------------------------------------------------ the DSP
        E_DSP: begin
          if (op_ok) begin
            est <= E_OP; op_ret <= E_DSP; oc <= '0; op_rd <= wq_n == 3'd0;
            o_addr <= (wq_n != 3'd0) ? h_addr : rd_a; o_data <= wq_h[15:0]; o_be <= wq_h[28:27];
          end else if (!dsp_started) begin
            if (!dsp_busy) begin dsp_go <= 1'b1; dsp_started <= 1'b1; end
          end else if (dsp_fin || dsp_done) begin
            est <= E_EFF; ei <= 4'd0; ec <= 3'd0;
          end
        end

        // ------------------------------------------------ effect returns
        E_EFF: begin
          ec <= ec + 3'd1;
          case (ec)
            3'd0: ;                                       // level 3, EFREG asked
            3'd1: begin v_el <= lv_q; ef_r <= ef_q; end   // level 4 asked
            3'd2: begin v_er <= lv_q; mu_a <= {{11{ef_r[15]}}, ef_r}; mu_b <= {3'd0, v_el}; end
            3'd3: begin mu_a <= {{11{ef_r[15]}}, ef_r}; mu_b <= {3'd0, v_er}; end
            3'd4: smpl <= smpl + (mu_lo >>> 12);
            default: begin
              smpr <= smpr + (mu_lo >>> 12);
              ec <= 3'd0;
              if (ei == 4'd15) est <= E_OUT;   // E_OUT counts on ec from 0
              ei <= ei + 4'd1;
            end
          endcase
        end

        // ------------------------------------------------ the sample
        default: begin
          ec <= ec + 3'd1;
          case (ec)
            3'd0: begin mu_a <= {{11{dac_l[15]}}, dac_l}; mu_b <= {1'b0, mvol_gain(c400[3:0])}; end
            3'd1: begin mu_a <= {{11{dac_r[15]}}, dac_r}; mu_b <= {1'b0, mvol_gain(c400[3:0])}; end
            3'd2: out_l <= (c400[3:0] == 4'hf) ? dac_l : mu_p[31:16];
            default: begin
              out_r <= (c400[3:0] == 4'hf) ? dac_r : mu_p[31:16];
              out_valid <= 1'b1;
              out_l_raw <= smpl; out_r_raw <= smpr;
              if (!(&dbg_samples)) dbg_samples <= dbg_samples + 32'd1;
              ec <= 3'd0;
              est <= E_IDLE;
            end
          endcase
        end
      endcase
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, r4[10:0], r5[13:0], r5[15], r6[15:9], r6[7:0], r8[15], r8[10], r9[15],
                   c404[7:0], mcieb, lk_line[0], st_q[52:48], st_q[0], mu_p[44:32], eg_r};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
