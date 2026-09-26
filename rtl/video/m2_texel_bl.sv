// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE for the full text.
//
// R620: THE BILINEAR TEXEL FETCH. One (u, v) in, one filtered 8-bit texel out,
// from the texture sheets in SDRAM -- the successor of m2_texel, which answered
// one point-sampled nibble.
//
// Behavioural contract is model2rd.ipp's fetch_bilinear_texel (BSD-3-Clause):
//
//     if (mirror && (u & (w << 8))) u = ~u;          // same for v
//     u -= 0x80;                                     // half a texel
//     ufrac = u & 0xff;  u0 = (u >> 8) & (w - 1);  u1 = (u0 + 1) & (w - 1);
//     if (!wrap && u1 == 0)                          // the texture's edge
//        ufrac >= 0x80 ? column 0 : column w - 1, unblended
//     four texels, blended across then down with LERP(x, y, a) = x + ((y - x) * a >> 8)
//
// and, translucent: each texel carries an alpha (none for 0xF), a transparent
// texel takes its neighbour's value, the alphas blend the same way and the
// pixel is discarded below half. The answer is {discard, t}: t is 8 bits.
//
// ONE DEPARTURE, DELIBERATE: a texel is widened by REPLICATION (x * 0x11,
// 0x0 .. 0xFF) where the reference shifts (x << 4, 0x00 .. 0xF0). The reference
// then goes through its luma table; this core scales the polygon's colour by t
// instead (m2_span_tex), and replication keeps full-scale texels full-scale as
// the point-sampled path always had. The blend weights are the reference's.
//
// POINT MODE (bilinear = 0): the nearest of the same four texels -- with the
// half-texel shift that is column (ufrac >= 0x80 ? u1 : u0), which is exactly
// the (u >> 8) sample m2_texel took. So the OSD switch toggles between this
// core's old picture and the filtered one on the same fetch.
//
// THE CACHE IS TWO BANKS, BY ROW-PAIR PARITY. A 64-bit line is four 16-bit
// words, eight texels across by two down (R293), so a 2x2 block needs the NEXT
// row pair half the time (v0 odd). Row pairs alternate between the banks, so
// both rows come back in ONE access nearly always; a block that also crosses an
// eight-texel column (one in eight) or wraps at the texture's edge takes a
// second. Measured on MAME's frame (study R620): 1.125 accesses a pixel.
// 2^IB lines a bank (IB = 11: 2,048, so the pair holds the 4,096 lines, 32 KB,
// m2_texel held at IDX_BITS 12 -- R453), split on the low bit of the row pair.
// Two 2048 x 64 RAMs pack into fewer M10K than one 4096 x 64.
//
// Two misses in flight, one per SDRAM port, as m2_texel had; a miss on a line
// already being fetched JOINS that fetch (neighbouring pixels miss on the same
// line). Answers leave in request order.

`timescale 1ns/1ps

module m2_texel_bl #(
  parameter int unsigned AW = 25,
  parameter int unsigned RSP_D = 8,   // response entries; a power of two
  parameter int unsigned IB = 11      // index bits a bank, 8..11: 2048 lines is
                                      // m2_texel's IDX_BITS 12 (R453) in two halves
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic [AW:1]      base_s0,
  input  logic [AW:1]      base_s1,
  input  logic             bilinear,   // quasi-static (OSD); 0 = nearest texel

  input  logic             req,
  output logic             rdy,
  input  logic [31:0]      tex,        // m2_geo_engine's poly_tex
  input  logic [19:0]      u,          // texel coordinates, 12.8
  input  logic [19:0]      v,
  output logic             ack,        // one cycle, in request order
  output logic [8:0]       texel,      // {discard, t}

  output logic             m_req,
  output logic [AW:1]      m_addr,
  input  logic             m_ack,
  input  logic [63:0]      m_data,
  input  logic             m2_en,
  output logic             m2_req,
  output logic [AW:1]      m2_addr,
  input  logic             m2_ack,
  input  logic [63:0]      m2_data,

  input  logic             inval,
  output logic [31:0]      dbg_hits,
  output logic [31:0]      dbg_misses,
  output logic [15:0]      dbg_lost,
  output logic [15:0]      dbg_sweeps
);
  localparam int unsigned LINES = 1 << IB;
  localparam int unsigned RB = IB - 7;        // row-pair bits in the index, above the bank bit
  localparam int unsigned TB = 17 - IB;       // {sheet, rowpair[9:RB+1]}
  localparam int unsigned RW = $clog2(RSP_D);

  // ------------------------------------------------------------ stage A
  logic        a_v;
  logic [31:0] a_tex;
  logic [32:0] a_ax, a_ay;   // axis(): {i0, i1, frac}, taken as the request enters
  logic        a_bl;

  // ------------------------------------------------------------ the four texels
  // Per texel k (0: u0v0, 1: u1v0, 2: u0v1, 3: u1v1): its line and its nibble.
  typedef struct packed {
    logic        sheet;
    logic [9:0]  rp;      // row pair, y2 >> 1
    logic [6:0]  cg;      // column group, x2 >> 3
    logic [1:0]  wsel;    // word in the line, x2[2:1]
    logic        px, py;  // x2[0], y2[0]
  } tx_t;

  function automatic logic [11:0] fold_x(input logic [11:0] x2);
    fold_x = (x2 >= 12'd1024) ? {x2[11:10] - 2'd1, x2[9:0]} : x2;
  endfunction

  // texel coordinate (tu, tv inside the texture) to its place on the sheet
  function automatic tx_t place(input logic [31:0] t, input logic [11:0] tu, input logic [11:0] tv);
    logic [11:0] x0, y0, x2, y2;
    logic [18:0] wa;
    tx_t r;
    begin
      x0 = {1'b0, t[18:13], 5'd0} + tu;
      y0 = {2'd0, t[23:19], 5'd0} + tv;
      x2 = fold_x(x0);
      y2 = (x0 >= 12'd1024) ? (y0 ^ 12'd1024) : y0;
      // THE WORD ADDRESS AS A SUM, as get_texel forms it: one fold can leave
      // x2 at 1024 or more, and (y2 / 2) * 512 + x2 / 2 then carries into the
      // next row pair -- which a line id cut from x2 alone would miss.
      wa = {y2[10:1], 9'd0} + {8'd0, x2[11:1]};
      r.sheet = t[12];
      r.rp    = wa[18:9];
      r.cg    = wa[8:2];
      r.wsel  = wa[1:0];
      r.px    = x2[0];
      r.py    = y2[0];
      place   = r;
    end
  endfunction

  // one axis: mirror, half-texel, wrap, clamp. Returns {i0, i1, frac(9)}.
  function automatic logic [32:0] axis(input logic [19:0] c, input logic [2:0] code,
                                       input logic mir, input logic wrap);
    logic [19:0] m, a;
    logic [11:0] w, i0, i1;
    logic [8:0]  f;
    begin
      w  = 12'(32 << code);
      m  = (mir && ((c & (20'(w) << 8)) != 20'd0)) ? ~c : c;
      a  = m - 20'h80;
      f  = {1'b0, a[7:0]};
      i0 = a[19:8] & (w - 12'd1);
      i1 = (i0 + 12'd1) & (w - 12'd1);
      if (!wrap && i1 == 12'd0) begin
        // model2rd.ipp's edge clamp, EXACTLY: (0, 1) at weight 0 or (w-2, w-1)
        // at weight 0x100. Resolving it to one column is the same colour but
        // not the same translucency -- a transparent texel takes its
        // NEIGHBOUR's value first, and the neighbour is column 1 or w-2.
        if (f >= 9'h80) begin i0 = 12'd0;          i1 = 12'd1;          f = 9'd0;   end
        else            begin i0 = w - 12'd2;      i1 = w - 12'd1;      f = 9'h100; end
      end
      axis = {i0, i1, f};
    end
  endfunction

  // ------------------------------------------------------------ stage B
  // The request, placed: four texels, the fractions, the flags.
  logic        b_v;
  tx_t         b_tx [4];
  logic [3:0]  b_done;      // texels whose line has been looked up
  logic [RW-1:0] b_ent;

  // ------------------------------------------------------------ the banks
  (* ramstyle = "M10K" *) logic [63:0]  cdata0 [LINES];
  (* ramstyle = "M10K" *) logic [63:0]  cdata1 [LINES];
  (* ramstyle = "M10K" *) logic [TB:0]  ctag0  [LINES];   // {valid, tag}
  (* ramstyle = "M10K" *) logic [TB:0]  ctag1  [LINES];
  logic [IB-1:0] ra0, ra1;          // read index this cycle
  logic          re0, re1;          // a read is wanted in this bank
  logic [63:0]   cd0_q, cd1_q;
  logic [TB:0]   ct0_q, ct1_q;
  logic          wr0, wr1;
  logic [IB-1:0] wa;
  logic [63:0]   wd;
  logic [TB:0]   wt;
  logic [IB-1:0] sweep;
  logic          sweeping;
  always_ff @(posedge clk) begin
    cd0_q <= cdata0[ra0]; ct0_q <= ctag0[ra0];
    cd1_q <= cdata1[ra1]; ct1_q <= ctag1[ra1];
    if (wr0) begin cdata0[wa] <= wd; ctag0[wa] <= wt; end
    if (wr1) begin cdata1[wa] <= wd; ctag1[wa] <= wt; end
  end

  function automatic logic [IB-1:0] idx_of(input tx_t t);
    idx_of = {t.rp[RB:1], t.cg};
  endfunction
  function automatic logic [TB-1:0] tag_of(input tx_t t);
    tag_of = {t.sheet, t.rp[9:RB+1]};
  endfunction
  function automatic logic same_line(input tx_t a, input tx_t b);
    same_line = (a.sheet == b.sheet) && (a.rp == b.rp) && (a.cg == b.cg);
  endfunction
  // where a texel's nibble sits in its line: {wsel, px, py}
  function automatic logic [3:0] sel_of(input tx_t t);
    sel_of = {t.wsel, t.px, t.py};
  endfunction
  function automatic logic [3:0] nib(input logic [63:0] line, input logic [3:0] t);
    logic [15:0] w;
    begin
      case (t[3:2])
        2'd0: w = line[15:0];
        2'd1: w = line[31:16];
        2'd2: w = line[47:32];
        default: w = line[63:48];
      endcase
      nib = t[0] ? (t[1] ? w[3:0]  : w[7:4])
                 : (t[1] ? w[11:8] : w[15:12]);
    end
  endfunction

  // ------------------------------------------------------------ the misses
  // A SLOT IS HELD after its fill until no waiting texel names it: waiting
  // texels take their nibble from the slot at the HEAD of the response queue,
  // not wherever they wait -- four selectors, where one per waiting texel was
  // thirty-two, 64 bits wide, and most of this module's area (s387: 2,000 ALM).
  logic          ms_busy [2], ms_done [2], ms_filled [2];
  tx_t           ms_line [2];
  logic [63:0]   ms_dat  [2];
  logic [9:0]    ms_to   [2];
  logic          fill_now;          // a done miss is written this cycle
  logic          fill_sel;

  // ------------------------------------------------------------ responses
  logic          rs_used [RSP_D];
  logic [3:0]    rs_rdy  [RSP_D];
  logic [3:0]    rs_nib  [RSP_D][4];
  logic [3:0]    rs_pend [RSP_D];     // waiting on a miss
  logic          rs_slot [RSP_D][4];  // which miss
  logic [3:0]    rs_sel  [RSP_D][4];  // sel_of() -- all the head needs
  logic [8:0]    rs_uf   [RSP_D], rs_vf [RSP_D];
  logic          rs_tl   [RSP_D], rs_bl [RSP_D];
  logic [RW:0]   rs_wp, rs_rp;
  wire           rs_full  = ((rs_wp - rs_rp) == (RW+1)'(RSP_D));
  wire           rs_empty = (rs_wp == rs_rp);
  wire [RW-1:0]  rs_hd    = rs_rp[RW-1:0];

  // ------------------------------------------------------------ stage L/C
  // L: this cycle's access -- up to one texel line per bank, looked up.
  // C: next cycle, compare; hit -> nibble, miss -> join or allocate.
  logic          l_v;
  logic [3:0]    l_k0, l_k1;      // texels served by the bank-0 / bank-1 line
  logic          l_has0, l_has1;
  logic [RW-1:0] l_ent;
  tx_t           l_t0, l_t1;
  logic          c_v;
  logic [3:0]    c_k0, c_k1;
  logic          c_has0, c_has1;
  logic [RW-1:0] c_ent;
  tx_t           c_t0, c_t1;
  logic [3:0]    c_sel [4];

  // Pick, for this cycle, one not-yet-looked-up line in each bank, and every
  // texel of the request that shares it.
  logic [3:0]  pick0, pick1;
  tx_t         pl0, pl1;
  logic        ph0, ph1;
  always_comb begin
    pick0 = 4'd0; pick1 = 4'd0; ph0 = 1'b0; ph1 = 1'b0;
    pl0 = b_tx[0]; pl1 = b_tx[0];
    for (int k = 0; k < 4; k++) begin
      if (!b_done[k]) begin
        if (b_tx[k].rp[0] == 1'b0) begin
          if (!ph0) begin ph0 = 1'b1; pl0 = b_tx[k]; end
        end else begin
          if (!ph1) begin ph1 = 1'b1; pl1 = b_tx[k]; end
        end
      end
    end
    for (int k = 0; k < 4; k++) begin
      if (!b_done[k] && ph0 && same_line(b_tx[k], pl0)) pick0[k] = 1'b1;
      if (!b_done[k] && ph1 && same_line(b_tx[k], pl1)) pick1[k] = 1'b1;
    end
  end
  wire b_last  = ((b_done | pick0 | pick1) == 4'hF);
  wire l_go    = b_v && !fill_now && !sweeping && !c_stall;
  wire b_adv   = l_go && b_last;               // the request's last access issues

  always_comb begin
    // a held compare re-reads its own lines, so its data is still its own
    ra0 = c_stall ? idx_of(c_t0) : idx_of(pl0);
    ra1 = c_stall ? idx_of(c_t1) : idx_of(pl1);
    re0 = ph0; re1 = ph1;
    wr0 = 1'b0; wr1 = 1'b0; wa = '0; wd = '0; wt = '0;
    if (sweeping) begin
      wr0 = 1'b1; wr1 = 1'b1; wa = sweep; wd = '0; wt = '0;
    end else if (fill_now) begin
      wa = idx_of(ms_line[fill_sel]);
      wd = ms_dat[fill_sel];
      wt = {1'b1, tag_of(ms_line[fill_sel])};
      if (ms_line[fill_sel].rp[0]) wr1 = 1'b1; else wr0 = 1'b1;
    end
  end

  // ------------------------------------------------------------ blend
  // model2rd.ipp's LERP, per field: x + ((y - x) * a >> 8), a in 0..0x100.
  function automatic logic [8:0] lerp9(input logic [8:0] x, input logic [8:0] y, input logic [8:0] a);
    logic signed [19:0] d;
    begin
      d = (20'(signed'({1'b0, y})) - 20'(signed'({1'b0, x}))) * 20'(signed'({1'b0, a}));
      lerp9 = 9'(20'(signed'({1'b0, x})) + (d >>> 8));
    end
  endfunction
  // TWO STAGES, ACROSS THEN DOWN, as the reference blends: two LERPs in series
  // behind the head's 8:1 select do not fit one clk_mem cycle.
  typedef struct packed {
    logic [8:0] l0x, l1x, a0x, a1x;   // the rows blended across
    logic [8:0] vf;
    logic       tl, bl;
    logic [3:0] nn;                   // point mode: the nearest texel
  } hz_t;
  function automatic hz_t blend_h(input logic [3:0] t00, t01, t10, t11,
                                  input logic [8:0] uf, input logic [8:0] vf,
                                  input logic tl, input logic bl);
    logic [8:0] l00, l01, l10, l11, a00, a01, a10, a11;
    hz_t h;
    begin
      // the nearest of the four: this core's old point sample
      // f >= 0x80, and the clamp's 0x100 counts (bit 8)
      h.nn = (vf[8] | vf[7]) ? ((uf[8] | uf[7]) ? t11 : t10) : ((uf[8] | uf[7]) ? t01 : t00);
      h.vf = vf; h.tl = tl; h.bl = bl;
      l00 = {1'b0, t00, t00}; l01 = {1'b0, t01, t01};
      l10 = {1'b0, t10, t10}; l11 = {1'b0, t11, t11};
      a00 = (tl && t00 == 4'hF) ? 9'd0 : 9'h80;
      a01 = (tl && t01 == 4'hF) ? 9'd0 : 9'h80;
      a10 = (tl && t10 == 4'hF) ? 9'd0 : 9'h80;
      a11 = (tl && t11 == 4'hF) ? 9'd0 : 9'h80;
      if (tl) begin
        // a transparent texel takes its neighbour's luma (in the reference's
        // order: the second test sees the first's replacement)
        if (t00 == 4'hF) l00 = l01;
        if (t01 == 4'hF) l01 = l00;
        if (t10 == 4'hF) l10 = l11;
        if (t11 == 4'hF) l11 = l10;
      end
      h.l0x = lerp9(l00, l01, uf); h.a0x = lerp9(a00, a01, uf);
      h.l1x = lerp9(l10, l11, uf); h.a1x = lerp9(a10, a11, uf);
      blend_h = h;
    end
  endfunction
  function automatic logic [8:0] blend_v(input hz_t h);
    logic [8:0] l0x, l1x, lo, ao;
    begin
      if (!h.bl) blend_v = {h.tl && (h.nn == 4'hF), {h.nn, h.nn}};
      else begin
        l0x = h.l0x; l1x = h.l1x;
        if (h.tl) begin
          // "if (tex0x == 0x000000f0) tex0x = tex1x" -- alpha 0 and the
          // transparent luma; replication makes that luma 0xFF here
          // "& 0xff": the luma only -- the alpha stays 0; both tests, in order
          if (h.a0x == 9'd0 && l0x == 9'hFF) l0x = l1x;
          if (h.a1x == 9'd0 && l1x == 9'hFF) l1x = l0x;
        end
        lo = lerp9(l0x, l1x, h.vf);
        ao = lerp9(h.a0x, h.a1x, h.vf);
        blend_v = {h.tl && (ao < 9'h40), lo[7:0]};
      end
    end
  endfunction

  // the head's answer, registered once all four texels are in
  wire hd_ready = !rs_empty && (rs_rdy[rs_hd] == 4'hF);
  logic hz_v;
  hz_t  hz;

  // ------------------------------------------------------------ inval
  logic inval_d, inval_pend;

  // ------------------------------------------------------------ sequencing
  wire ms_free0 = !ms_busy[0];
  wire ms_free1 = m2_en && !ms_busy[1];
  wire ms_fill0 = ms_busy[0] && ms_done[0] && !ms_filled[0];
  wire ms_fill1 = ms_busy[1] && ms_done[1] && !ms_filled[1];
  assign fill_sel = ms_fill0 ? 1'b0 : 1'b1;
  assign fill_now = !sweeping && (ms_fill0 || ms_fill1);
  // texels waiting on each slot
  logic [1:0] ms_ref;
  always_comb begin
    ms_ref = 2'b00;
    for (int e = 0; e < RSP_D; e++)
      for (int k = 0; k < 4; k++)
        if (rs_pend[e][k]) ms_ref[rs_slot[e][k]] = 1'b1;
  end

  // Stage C's miss handling may need a miss slot; if none is free the whole
  // front stalls (C holds, and L behind it).
  function automatic logic [1:0] c_join(input tx_t t);
    // {found, slot}
    c_join = 2'b00;
    if (ms_busy[0] && same_line(ms_line[0], t)) c_join = 2'b10;
    else if (ms_busy[1] && same_line(ms_line[1], t)) c_join = 2'b11;
  endfunction
  wire c_hit0 = ct0_q[TB] && (ct0_q[TB-1:0] == tag_of(c_t0));
  wire c_hit1 = ct1_q[TB] && (ct1_q[TB-1:0] == tag_of(c_t1));
  wire [1:0] c_j0 = c_join(c_t0), c_j1 = c_join(c_t1);
  wire c_need0 = c_v && c_has0 && !c_hit0 && !c_j0[1];   // a new miss
  wire c_need1 = c_v && c_has1 && !c_hit1 && !c_j1[1];
  wire [1:0] c_nfree = 2'(ms_free0) + 2'(ms_free1);
  // no free slot for a needed miss: hold. Two needed, one free: take the
  // bank-0 line now and hold for the bank-1 line (with the second port off,
  // m2_en low, two at once would never be free).
  wire c_block = c_v && (c_need0 || c_need1) && (c_nfree == 2'd0);
  wire c_split = c_v && c_need0 && c_need1 && (c_nfree == 2'd1);
  wire c_stall = c_block || c_split;
  // the slots stage C names this cycle (joins; a new miss re-arms its slot anyway)
  logic [1:0] c_names;
  always_comb begin
    c_names = 2'b00;
    if (c_v && !c_block) begin
      if (c_has0 && !c_hit0 && c_j0[1]) c_names[c_j0[0]] = 1'b1;
      if (c_has1 && !c_hit1 && c_j1[1] && !c_split) c_names[c_j1[0]] = 1'b1;
    end
  end
  // the RAM output is only valid the cycle after the read: a held C re-reads
  logic c_reread;

  // B takes the next request as the current one issues its last access, and
  // claims its response entry as it enters -- one request a cycle when it hits.
  wire can_b  = (!b_v || b_adv) && !rs_full && !sweeping;
  wire b_take = a_v && can_b;
  assign rdy  = (!a_v || can_b) && !inval_pend && !sweeping;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_v <= 1'b0; a_tex <= '0; a_ax <= '0; a_ay <= '0; a_bl <= 1'b0;
      b_v <= 1'b0; b_done <= '0; b_ent <= '0;
      for (int k = 0; k < 4; k++) b_tx[k] <= '0;
      c_v <= 1'b0; c_k0 <= '0; c_k1 <= '0; c_has0 <= 1'b0; c_has1 <= 1'b0;
      c_ent <= '0; c_t0 <= '0; c_t1 <= '0; c_reread <= 1'b0;
      for (int k = 0; k < 4; k++) c_sel[k] <= '0;
      l_v <= 1'b0;
      for (int k = 0; k < 2; k++) begin
        ms_busy[k] <= 1'b0; ms_done[k] <= 1'b0; ms_filled[k] <= 1'b0; ms_line[k] <= '0;
        ms_dat[k] <= '0; ms_to[k] <= '0;
      end
      m_req <= 1'b0; m_addr <= '0; m2_req <= 1'b0; m2_addr <= '0;
      rs_wp <= '0; rs_rp <= '0;
      for (int e = 0; e < RSP_D; e++) begin
        rs_used[e] <= 1'b0; rs_rdy[e] <= '0; rs_pend[e] <= '0;
        rs_uf[e] <= '0; rs_vf[e] <= '0; rs_tl[e] <= 1'b0; rs_bl[e] <= 1'b0;
        for (int k = 0; k < 4; k++) begin rs_nib[e][k] <= '0; rs_slot[e][k] <= 1'b0; rs_sel[e][k] <= '0; end
      end
      ack <= 1'b0; texel <= '0; hz_v <= 1'b0; hz <= '0;
      sweep <= '0; sweeping <= 1'b1; inval_d <= 1'b0; inval_pend <= 1'b0;
      dbg_hits <= '0; dbg_misses <= '0; dbg_lost <= '0; dbg_sweeps <= '0;
    end else begin
      inval_d <= inval;
      if (inval && !inval_d) inval_pend <= 1'b1;

      // ---- the tag sweep: out of reset, and on an invalidate once idle
      if (sweeping) begin
        sweep <= sweep + 1'd1;
        if (sweep == IB'(LINES - 1)) begin sweeping <= 1'b0; inval_pend <= 1'b0; end
      end else if (inval_pend && !a_v && !b_v && !c_v && rs_empty && !ms_busy[0] && !ms_busy[1]) begin
        sweep <= '0; sweeping <= 1'b1;
        if (!(&dbg_sweeps)) dbg_sweeps <= dbg_sweeps + 1'd1;
      end

      // ---- stage A: the request
      // model2_v.cpp: "disable smooth wrapping if mirroring is enabled".
      // poly_tex carries texwrapx (bit 7) but not texwrapy -- bit 8 is
      // translucent (R326) -- so v wraps unless mirrored (R620).
      // THE AXES ARE WORKED HERE, NOT IN B: axis() then place() in one cycle
      // is two carry chains and a compare in series, too long for clk_mem.
      // u, v and tex come from m2_texel_cdc's registers.
      if (req && rdy && !inval_pend) begin
        a_v <= 1'b1; a_tex <= tex; a_bl <= bilinear;
        a_ax <= axis(u, tex[3:1], tex[9],  tex[7] && !tex[9]);
        a_ay <= axis(v, tex[6:4], tex[10], !tex[10]);
      end else if (b_take) a_v <= 1'b0;

      // ---- stage B: placed; a response entry claimed as it enters
      if (b_take) begin
        automatic logic [32:0] ax = a_ax;
        automatic logic [32:0] ay = a_ay;
        b_v    <= 1'b1;
        b_tx[0] <= place(a_tex, ax[32:21], ay[32:21]);
        b_tx[1] <= place(a_tex, ax[20:9],  ay[32:21]);
        b_tx[2] <= place(a_tex, ax[32:21], ay[20:9]);
        b_tx[3] <= place(a_tex, ax[20:9],  ay[20:9]);
        b_done <= 4'd0;
        b_ent  <= rs_wp[RW-1:0];
        rs_used[rs_wp[RW-1:0]] <= 1'b1;
        rs_rdy [rs_wp[RW-1:0]] <= 4'd0;
        rs_pend[rs_wp[RW-1:0]] <= 4'd0;
        rs_uf  [rs_wp[RW-1:0]] <= ax[8:0];  rs_vf[rs_wp[RW-1:0]] <= ay[8:0];
        rs_tl  [rs_wp[RW-1:0]] <= a_tex[8]; rs_bl[rs_wp[RW-1:0]] <= a_bl;
        rs_sel[rs_wp[RW-1:0]][0] <= sel_of(place(a_tex, ax[32:21], ay[32:21]));
        rs_sel[rs_wp[RW-1:0]][1] <= sel_of(place(a_tex, ax[20:9],  ay[32:21]));
        rs_sel[rs_wp[RW-1:0]][2] <= sel_of(place(a_tex, ax[32:21], ay[20:9]));
        rs_sel[rs_wp[RW-1:0]][3] <= sel_of(place(a_tex, ax[20:9],  ay[20:9]));
        rs_wp  <= rs_wp + 1'd1;
      end else if (b_adv) begin
        b_v <= 1'b0;
      end

      // ---- stage L: an access (both banks) this cycle; C compares next cycle
      if (!c_stall) begin
        c_v <= l_go;
        if (l_go) begin
          c_k0 <= pick0; c_k1 <= pick1; c_has0 <= ph0; c_has1 <= ph1;
          c_ent <= b_ent; c_t0 <= pl0; c_t1 <= pl1;
          for (int k = 0; k < 4; k++) c_sel[k] <= sel_of(b_tx[k]);
          // not on the request's LAST access: then B empties or takes the next
          // request, whose b_done <= 0 this would overwrite
          if (!b_last) b_done <= b_done | pick0 | pick1;
        end
      end

      // ---- stage C: hits, joins, new misses
      // A new miss takes a free slot: the bank-0 line the first free one, the
      // bank-1 line the other (c_stall guarantees enough are free).
      if (c_v && !c_block) begin
        automatic logic s0 = ms_free0 ? 1'b0 : 1'b1;             // slot for a new bank-0 miss
        automatic logic s1 = c_need0 ? ~s0 : (ms_free0 ? 1'b0 : 1'b1);
        automatic logic do1 = !c_split;                           // bank 1 this cycle too
        for (int k = 0; k < 4; k++) begin
          if (c_k0[k]) begin
            if (c_hit0) begin
              rs_nib[c_ent][k] <= nib(cd0_q, c_sel[k]); rs_rdy[c_ent][k] <= 1'b1;
            end else begin
              rs_pend[c_ent][k] <= 1'b1; rs_slot[c_ent][k] <= c_j0[1] ? c_j0[0] : s0;
            end
          end
          if (c_k1[k] && do1) begin
            if (c_hit1) begin
              rs_nib[c_ent][k] <= nib(cd1_q, c_sel[k]); rs_rdy[c_ent][k] <= 1'b1;
            end else begin
              rs_pend[c_ent][k] <= 1'b1; rs_slot[c_ent][k] <= c_j1[1] ? c_j1[0] : s1;
            end
          end
        end
        if (c_need0) begin
          ms_busy[s0] <= 1'b1; ms_done[s0] <= 1'b0; ms_filled[s0] <= 1'b0; ms_to[s0] <= '0; ms_line[s0] <= c_t0;
          if (!s0) begin m_req  <= 1'b1; m_addr  <= (c_t0.sheet ? base_s1 : base_s0) + AW'({c_t0.rp, c_t0.cg, 2'b00}); end
          else     begin m2_req <= 1'b1; m2_addr <= (c_t0.sheet ? base_s1 : base_s0) + AW'({c_t0.rp, c_t0.cg, 2'b00}); end
        end
        if (c_need1 && do1) begin
          ms_busy[s1] <= 1'b1; ms_done[s1] <= 1'b0; ms_filled[s1] <= 1'b0; ms_to[s1] <= '0; ms_line[s1] <= c_t1;
          if (!s1) begin m_req  <= 1'b1; m_addr  <= (c_t1.sheet ? base_s1 : base_s0) + AW'({c_t1.rp, c_t1.cg, 2'b00}); end
          else     begin m2_req <= 1'b1; m2_addr <= (c_t1.sheet ? base_s1 : base_s0) + AW'({c_t1.rp, c_t1.cg, 2'b00}); end
        end
        if (c_need0 || (c_need1 && do1)) begin if (!(&dbg_misses)) dbg_misses <= dbg_misses + 1'd1; end
        else if (!(&dbg_hits)) dbg_hits <= dbg_hits + 1'd1;
        if (c_split) begin c_has0 <= 1'b0; c_k0 <= 4'd0; end   // bank 0 done; hold for bank 1
      end

      // ---- the misses: data in, timeout, fill
      for (int s = 0; s < 2; s++) begin
        if (ms_busy[s] && !ms_done[s]) begin
          ms_to[s] <= ms_to[s] + 1'd1;
          if (&ms_to[s]) begin
            // the memory never answered: answer with what is in hand (zeros)
            ms_done[s] <= 1'b1; ms_dat[s] <= '0;
            if (s == 0) m_req <= 1'b0; else m2_req <= 1'b0;
            if (!(&dbg_lost)) dbg_lost <= dbg_lost + 1'd1;
          end
        end
      end
      if (m_ack && ms_busy[0] && !ms_done[0]) begin
        ms_dat[0] <= m_data; ms_done[0] <= 1'b1; m_req <= 1'b0;
      end
      if (m2_ack && ms_busy[1] && !ms_done[1]) begin
        ms_dat[1] <= m2_data; ms_done[1] <= 1'b1; m2_req <= 1'b0;
      end
      // the head's waiting texels take their nibble once their miss is done
      if (!rs_empty)
        for (int k = 0; k < 4; k++)
          if (rs_pend[rs_hd][k] && ms_done[rs_slot[rs_hd][k]]) begin
            rs_nib[rs_hd][k] <= nib(ms_dat[rs_slot[rs_hd][k]], rs_sel[rs_hd][k]);
            rs_rdy[rs_hd][k] <= 1'b1; rs_pend[rs_hd][k] <= 1'b0;
          end
      if (fill_now) ms_filled[fill_sel] <= 1'b1;   // written this cycle
      // released once filled and no texel waits on it -- nor is about to: stage
      // C names a slot as it marks a texel waiting (a join, or a new miss on a
      // slot this edge re-arms, which the free test cannot see)
      for (int s = 0; s < 2; s++)
        if (ms_busy[s] && ms_filled[s] && !ms_ref[s] && !c_names[s]) ms_busy[s] <= 1'b0;

      // ---- answer the head
      hz_v <= hd_ready;
      if (hd_ready) begin
        hz <= blend_h(rs_nib[rs_hd][0], rs_nib[rs_hd][1], rs_nib[rs_hd][2], rs_nib[rs_hd][3],
                      rs_uf[rs_hd], rs_vf[rs_hd], rs_tl[rs_hd], rs_bl[rs_hd]);
        rs_used[rs_hd] <= 1'b0; rs_rdy[rs_hd] <= '0;
        rs_rp <= rs_rp + 1'd1;
      end
      ack <= hz_v;
      if (hz_v) texel <= blend_v(hz);
    end
  end
endmodule
