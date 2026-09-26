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
  // R628: MISS SLOTS, ONE SDRAM PORT EACH -- 2 (m, m2) or 4 (m, m2, m3, m4).
  // Two lines in flight was the limit on the board (R627: D blocked with both
  // ports busy 97% of its stalls).
  parameter int unsigned NS = 2,
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
  input  logic             m3_en, m4_en,   // R628: slots 2 and 3 (NS = 4)
  output logic             m3_req, m4_req,
  output logic [AW:1]      m3_addr, m4_addr,
  input  logic             m3_ack, m4_ack,
  input  logic [63:0]      m3_data, m4_data,

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

  // one axis, in TWO HALVES (R627: whole, it missed clk_mem by 0.35 ns on
  // s398). The first -- mirror and the half-texel shift -- runs as a request
  // is written into the K queue, straight off m2_texel_cdc's registers; the
  // second -- mask, the next texel, the clamp -- in stage A.
  function automatic logic [19:0] axis_pre(input logic [19:0] c, input logic [2:0] code,
                                           input logic mir);
    logic [19:0] m;
    logic [11:0] w;
    begin
      w  = 12'(32 << code);
      m  = (mir && ((c & (20'(w) << 8)) != 20'd0)) ? ~c : c;
      axis_pre = m - 20'h80;
    end
  endfunction
  // Returns {i0, i1, frac(9)}.
  function automatic logic [32:0] axis(input logic [19:0] a, input logic [2:0] code,
                                       input logic wrap);
    logic [11:0] w, i0, i1;
    logic [8:0]  f;
    begin
      w  = 12'(32 << code);
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


  // ------------------------------------------------------------ pipeline
  // R625: RETIMED FOR clk_mem (s391 missed it by 2.75 ns). Every hand-off
  // decision now comes from registers:
  //   K  a two-entry queue, so `rdy` is a register and the crossing's load
  //      logic no longer waits on this module's lookup; its head is always
  //      k_d[0], so axis() reads a register with no select in front; it holds
  //      u and v already mirrored and shifted half a texel (axis_pre, R627)
  //   A  axis(), on the way in
  //   P  place() for the four texels
  //   B  the lookups, one or two lines a cycle; the texels' same-line
  //      relations are worked out as the request ENTERS B, and whether an
  //      access is the request's last is a flag set the cycle before
  //   C1 the RAM's answer: tags compared, joins found, nibbles cut out
  //   D  hits written, joins and new misses recorded -- the one stage that
  //      can stall, and it stalls from registers
  // A held C1 re-reads its own lines; the read address depends on D's stall,
  // which is a few gates from D's registers, not on a compare.

  // ---- K and A
  typedef struct packed { logic [31:0] tex; logic [19:0] u, v; logic bl; } k_t;   // u, v: axis_pre()
  // model2_v.cpp: "disable smooth wrapping if mirroring is enabled".
  // poly_tex carries texwrapx (bit 7) but not texwrapy -- bit 8 is
  // translucent (R326) -- so v wraps unless mirrored (R620).
  // (a variable and an assign: Quartus 17 rejects `wire k_t` -- a struct-typed net)
  k_t k_in;
  // R627: tex[31] set -- m2_raster3d's fill is running late -- point-samples
  // this request whatever the OSD says
  assign k_in = {tex, axis_pre(u, tex[3:1], tex[9]), axis_pre(v, tex[6:4], tex[10]), bilinear && !tex[31]};
  logic        k_v [2];
  k_t          k_d [2];
  logic        a_v;
  logic [31:0] a_tex;
  logic [32:0] a_ax, a_ay;   // axis(): {i0, i1, frac}
  logic        a_bl;

  // ---- P
  logic        p_v;
  tx_t         p_tx [4];
  logic [8:0]  p_uf, p_vf;
  logic        p_tl, p_bl;

  // ---- B
  logic          b_v;
  tx_t           b_tx [4];
  logic [3:0]    b_done;      // texels whose line has been looked up
  logic [RW-1:0] b_ent;
  logic [3:0]    b_bank;      // each texel's bank (row-pair parity)
  logic [5:0]    b_eq;        // same line: 01 02 03 12 13 23
  logic          b_first;     // no access issued yet
  logic          b_single;    // the whole request is one access
  logic          b_remone;    // what remains after the last access is one access

  function automatic logic eqm(input logic [5:0] e, input int i, input int j);
    if (i == j) eqm = 1'b1;
    else begin
      automatic int a = (i < j) ? i : j;
      automatic int b = (i < j) ? j : i;
      case ({a[1:0], b[1:0]})
        4'b0001: eqm = e[0];
        4'b0010: eqm = e[1];
        4'b0011: eqm = e[2];
        4'b0110: eqm = e[3];
        4'b0111: eqm = e[4];
        default: eqm = e[5];
      endcase
    end
  endfunction
  // the texels in m take one access: in each bank, one line
  function automatic logic one_acc(input logic [3:0] m, input logic [3:0] bk, input logic [5:0] e);
    one_acc = 1'b1;
    for (int i = 0; i < 4; i++)
      for (int j = i + 1; j < 4; j++)
        if (m[i] && m[j] && (bk[i] == bk[j]) && !eqm(e, i, j)) one_acc = 1'b0;
  endfunction

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
  localparam int unsigned SW = (NS > 2) ? 2 : 1;       // slot index width
  logic          ms_busy [NS], ms_done [NS], ms_filled [NS];
  tx_t           ms_line [NS];
  logic [63:0]   ms_dat  [NS];
  logic [9:0]    ms_to   [NS];
  // the ports, as arrays: slot s asks port s
  logic          mq_req  [NS];
  logic [AW:1]   mq_addr [NS];
  // (packed vectors and plain assigns: Quartus 17 is not trusted with '{...}
  // on an unpacked net)
  wire [3:0]     mq_en  = {m4_en, m3_en, m2_en, 1'b1};
  wire [3:0]     mq_ack = {m4_ack, m3_ack, m2_ack, m_ack};
  logic [63:0]   mq_data [4];
  assign mq_data[0] = m_data;  assign mq_data[1] = m2_data;
  assign mq_data[2] = m3_data; assign mq_data[3] = m4_data;
  assign m_req  = mq_req[0];   assign m_addr  = mq_addr[0];
  assign m2_req = mq_req[1];   assign m2_addr = mq_addr[1];
  generate if (NS > 2) begin : g_p34
    assign m3_req = mq_req[2]; assign m3_addr = mq_addr[2];
    assign m4_req = mq_req[3]; assign m4_addr = mq_addr[3];
  end else begin : g_no34
    assign m3_req = 1'b0; assign m3_addr = '0;
    assign m4_req = 1'b0; assign m4_addr = '0;
  end endgenerate
  logic          fill_now;          // a done miss is taken for writing this cycle
  // R627: THE FILL IS WRITTEN FROM REGISTERS, a cycle after it is taken
  // (standalone: ms_done -> the RAM's write address was the worst path left).
  // The line, index and tag are copied here, so the slot may be released
  // behind it; a lookup of the line in between misses and joins or refetches.
  logic          fl_v, fl_b;
  logic [SW-1:0] fl_s;               // the slot being written
  logic [IB-1:0] fl_i;
  logic [63:0]   fl_d;
  logic [TB:0]   fl_t;

  // ------------------------------------------------------------ responses
  logic          rs_used [RSP_D];
  logic [3:0]    rs_rdy  [RSP_D];
  logic [3:0]    rs_nib  [RSP_D][4];
  logic [3:0]    rs_pend [RSP_D];     // waiting on a miss
  logic [SW-1:0] rs_slot [RSP_D][4];  // which miss
  logic [3:0]    rs_sel  [RSP_D][4];  // sel_of() -- all the head needs
  logic [8:0]    rs_uf   [RSP_D], rs_vf [RSP_D];
  logic          rs_tl   [RSP_D], rs_bl [RSP_D];
  logic [RW:0]   rs_wp, rs_rp;
  wire           rs_full  = ((rs_wp - rs_rp) == (RW+1)'(RSP_D));
  wire           rs_empty = (rs_wp == rs_rp);
  wire [RW-1:0]  rs_hd    = rs_rp[RW-1:0];

  // ------------------------------------------------------------ blend
  // model2rd.ipp's LERP, per field: x + ((y - x) * a >> 8), a in 0..0x100.
  // FIVE STAGES, ACROSS THEN DOWN, as the reference blends (s391: two
  // stages missed clk_mem by 2.75 ns). Each LERP is split at its multiply:
  //   O  the head's four texels and weights, latched (the select only)
  //   H1 the transparent-texel rules on the nibbles, the across differences
  //      and their products; the across alphas (0 or 0x80 at the corners, so
  //      a halving, not a multiply)
  //   H2 the across sums
  //   V1 the row rules, the down differences and their products
  //   V2 the down sums, the alpha test -- the answer
  // x * 17 is a nibble widened by replication, so LERP(17a, 17b, f) is
  // 17a + ((17 (b - a) f) >>> 8): the product is taken on the nibble
  // difference and scaled after, and is exactly the reference's.
  typedef struct packed {
    logic       v;
    logic [3:0] t00, t01, t10, t11;
    logic [8:0] uf, vf;
    logic       tl, bl;
  } o_t;
  typedef struct packed {
    logic              v;
    logic [3:0]        n00, n10;            // the left texels, after the rules
    logic signed [13:0] p0, p1;             // (right - left) * uf
    logic [8:0]        a0x, a1x;            // the across alphas
    logic [8:0]        vf;
    logic              tl, bl;
    logic [3:0]        nn;                  // point mode: the nearest texel
    logic              z0, z1;              // a row wholly transparent
  } h1_t;
  typedef struct packed {
    logic       v;
    logic [8:0] l0x, l1x, a0x, a1x, vf;
    logic       tl, bl;
    logic [3:0] nn;
    logic       z0, z1;
  } h2_t;
  typedef struct packed {
    logic              v;
    logic [8:0]        l0x, a0x;
    logic signed [9:0] dl, da;              // bottom - top; the product is V2's
    logic [8:0]        vf;
    logic              tl, bl;
    logic [3:0]        nn;
  } v1_t;

  // an across alpha: corners 0x80 (opaque) or 0 (transparent), LERP by f
  function automatic logic [8:0] alpha_x(input logic tr0, input logic tr1, input logic [8:0] f);
    case ({tr0, tr1})
      2'b00:   alpha_x = 9'h80;
      2'b11:   alpha_x = 9'h00;
      2'b10:   alpha_x = {1'b0, f[8:1]};                       // 0 + (0x80 f >> 8)
      default: alpha_x = 9'h80 - 9'((10'(f) + 10'd1) >> 1);    // 0x80 + floor(-0x80 f / 256)
    endcase
  endfunction

  function automatic h1_t stage_h1(input o_t o);
    logic [3:0] n00, n01, n10, n11;
    logic       f00, f01, f10, f11;
    h1_t h;
    begin
      h.v = o.v; h.vf = o.vf; h.tl = o.tl; h.bl = o.bl;
      // the nearest of the four: this core's old point sample
      // f >= 0x80, and the clamp's 0x100 counts (bit 8)
      h.nn = (o.vf[8] | o.vf[7]) ? ((o.uf[8] | o.uf[7]) ? o.t11 : o.t10)
                                 : ((o.uf[8] | o.uf[7]) ? o.t01 : o.t00);
      f00 = o.tl && o.t00 == 4'hF; f01 = o.tl && o.t01 == 4'hF;
      f10 = o.tl && o.t10 == 4'hF; f11 = o.tl && o.t11 == 4'hF;
      n00 = o.t00; n01 = o.t01; n10 = o.t10; n11 = o.t11;
      // a transparent texel takes its neighbour's luma (in the reference's
      // order: the second test sees the first's replacement)
      if (f00) n00 = n01;
      if (f01) n01 = n00;
      if (f10) n10 = n11;
      if (f11) n11 = n10;
      h.n00 = n00; h.n10 = n10;
      h.p0  = 14'(signed'(5'({1'b0, n01}) - 5'({1'b0, n00}))) * 14'(signed'({1'b0, o.uf}));
      h.p1  = 14'(signed'(5'({1'b0, n11}) - 5'({1'b0, n10}))) * 14'(signed'({1'b0, o.uf}));
      h.a0x = alpha_x(f00, f01, o.uf);
      h.a1x = alpha_x(f10, f11, o.uf);
      // THE ROW RULE, DECIDED HERE: "alpha 0 and luma 0xFF" after the across
      // blend happens exactly when both texels of the row are transparent (one
      // transparent texel leaves the row's luma its opaque neighbour's, never
      // 0xFF, and its alpha 0 only at a weight that selects that neighbour)
      h.z0 = f00 && f01;
      h.z1 = f10 && f11;
      stage_h1 = h;
    end
  endfunction

  function automatic logic [8:0] sum_x(input logic [3:0] n, input logic signed [13:0] p);
    logic signed [18:0] q;
    begin
      q = 19'(p) * 19'sd17;                                   // 17 (b - a) f
      sum_x = 9'(signed'(19'({10'd0, n, n})) + (q >>> 8));   // both signed: >>> must be arithmetic
    end
  endfunction

  function automatic h2_t stage_h2(input h1_t h);
    h2_t r;
    begin
      r.v = h.v; r.vf = h.vf; r.tl = h.tl; r.bl = h.bl; r.nn = h.nn;
      r.z0 = h.z0; r.z1 = h.z1;
      r.l0x = sum_x(h.n00, h.p0); r.l1x = sum_x(h.n10, h.p1);
      r.a0x = h.a0x; r.a1x = h.a1x;
      stage_h2 = r;
    end
  endfunction

  function automatic v1_t stage_v1(input h2_t h);
    v1_t r;
    begin
      r.v = h.v; r.tl = h.tl; r.bl = h.bl; r.nn = h.nn;
      // "if (tex0x == 0x000000f0) tex0x = tex1x" and the same for tex1x, in
      // order, luma only: with the rule decided in H1 (z0, z1), either firing
      // leaves both rows equal, so the down difference is zero and the base
      // is the bottom row when the top was the transparent one
      r.l0x = h.z0 ? h.l1x : h.l0x; r.a0x = h.a0x; r.vf = h.vf;
      // R627: the difference registered here and multiplied in V2, so the
      // multiply's operands come straight from registers (s398's paths)
      r.dl  = (h.z0 || h.z1) ? 10'sd0 : (10'(signed'({1'b0, h.l1x})) - 10'(signed'({1'b0, h.l0x})));
      r.da  = 10'(signed'({1'b0, h.a1x})) - 10'(signed'({1'b0, h.a0x}));
      stage_v1 = r;
    end
  endfunction

  function automatic logic [8:0] stage_v2(input v1_t h);
    logic [8:0] lo, ao;
    begin
      lo = 9'(signed'(19'({10'd0, h.l0x})) + ((19'(h.dl) * 19'(signed'({1'b0, h.vf}))) >>> 8));
      ao = 9'(signed'(19'({10'd0, h.a0x})) + ((19'(h.da) * 19'(signed'({1'b0, h.vf}))) >>> 8));
      if (!h.bl) stage_v2 = {h.tl && (h.nn == 4'hF), {h.nn, h.nn}};
      else       stage_v2 = {h.tl && (ao < 9'h40), lo[7:0]};
    end
  endfunction

  // ------------------------------------------------------------ C1 and D
  logic          c_v;
  logic [3:0]    c_k0, c_k1;      // texels served by the bank-0 / bank-1 line
  logic          c_has0, c_has1;
  logic [RW-1:0] c_ent;
  tx_t           c_t0, c_t1;
  logic [3:0]    c_sel [4];
  logic [IB-1:0] ra0_d, ra1_d;    // what the RAM was asked for last cycle
  logic          fw_v, fw_b;      // ... and what it was written with
  logic [IB-1:0] fw_i;

  logic          d_v;
  logic [3:0]    d_k0, d_k1;
  logic          d_has0, d_has1;
  logic [RW-1:0] d_ent;
  tx_t           d_t0, d_t1;
  logic          d_hit0, d_hit1;
  logic [SW:0]   d_j0, d_j1;      // {joined, slot}
  logic [3:0]    d_nb0 [4], d_nb1 [4];

  // ------------------------------------------------------------ inval
  logic inval_d, inval_pend;

  // ------------------------------------------------------------ D's decision
  logic [NS-1:0] ms_free;
  always_comb for (int k = 0; k < NS; k++) ms_free[k] = mq_en[k] && !ms_busy[k];
  wire d_need0 = d_v && d_has0 && !d_hit0 && !d_j0[SW];   // a new miss
  wire d_need1 = d_v && d_has1 && !d_hit1 && !d_j1[SW];
  // the first free slot, and the first after it
  logic [SW-1:0] fs_a, fs_b;
  logic          fs_av, fs_bv;
  always_comb begin
    fs_a = '0; fs_b = '0; fs_av = 1'b0; fs_bv = 1'b0;
    for (int k = NS - 1; k >= 0; k--) if (ms_free[k]) begin fs_a = SW'(k); fs_av = 1'b1; end
    for (int k = NS - 1; k >= 0; k--) if (ms_free[k] && SW'(k) != fs_a) begin fs_b = SW'(k); fs_bv = 1'b1; end
  end
  wire [1:0] d_nfree = fs_bv ? 2'd2 : (fs_av ? 2'd1 : 2'd0);   // capped at two: D needs at most two
  // no free slot for a needed miss: hold. Two needed, one free: take the
  // bank-0 line now and hold for the bank-1 line (with the second port off,
  // m2_en low, two at once would never be free).
  wire d_block = d_v && (d_need0 || d_need1) && (d_nfree == 2'd0);
  wire d_split = d_v && d_need0 && d_need1 && (d_nfree == 2'd1);
  wire d_stall = d_block || d_split;
  // the slot each new miss takes: bank 0 the first free, bank 1 the other
  wire [SW-1:0] d_s0 = fs_a;
  wire [SW-1:0] d_s1 = d_need0 ? fs_b : fs_a;
  wire d_do1 = !d_split;
  wire fa0 = d_v && !d_block && d_need0;                  // allocations this cycle,
  wire fa1 = d_v && !d_block && d_need1 && d_do1;         // forwarded to C1's joins

  logic [SW-1:0] fill_s;
  logic          fill_any;
  always_comb begin
    fill_s = '0; fill_any = 1'b0;
    for (int k = NS - 1; k >= 0; k--)
      if (ms_busy[k] && ms_done[k] && !ms_filled[k]) begin fill_s = SW'(k); fill_any = 1'b1; end
  end
  assign fill_now = !sweeping && fill_any;
  // texels waiting on each slot
  logic [NS-1:0] ms_ref;
  always_comb begin
    ms_ref = '0;
    for (int e = 0; e < RSP_D; e++)
      for (int k = 0; k < 4; k++)
        if (rs_pend[e][k]) ms_ref[rs_slot[e][k]] = 1'b1;
  end

  // ------------------------------------------------------------ B's pick
  // One not-yet-looked-up line in each bank, and every texel sharing it.
  // R627: COMPUTED A CYCLE AHEAD -- as a request enters B, and after each
  // access for the next -- and held in registers, so the RAM's read address is
  // a two-way select of registers (standalone: the pick in front of it was
  // the worst path left).
  typedef struct packed { logic ph0, ph1; logic [3:0] pk0, pk1; logic [1:0] f0, f1; } pk_t;
  function automatic pk_t pick_of(input logic [3:0] done, input logic [3:0] bank, input logic [5:0] e);
    pk_t r;
    begin
      r = '0;
      for (int k = 3; k >= 0; k--) begin
        if (!done[k] && !bank[k]) begin r.ph0 = 1'b1; r.f0 = 2'(k); end
        if (!done[k] &&  bank[k]) begin r.ph1 = 1'b1; r.f1 = 2'(k); end
      end
      for (int k = 0; k < 4; k++) begin
        r.pk0[k] = r.ph0 && !done[k] && !bank[k] && eqm(e, int'(r.f0), k);
        r.pk1[k] = r.ph1 && !done[k] &&  bank[k] && eqm(e, int'(r.f1), k);
      end
      pick_of = r;
    end
  endfunction
  logic [3:0]  pick0, pick1;
  tx_t         pl0, pl1;
  logic        ph0, ph1;
  wire b_last  = b_first ? b_single : b_remone;           // registers only
  wire l_go    = b_v && !sweeping && !d_stall;
  wire b_adv   = l_go && b_last;

  // R627: point mode's one texel: {v >= half, u >= half}, as H1's nn
  wire [1:0] p_nk   = {p_vf[8] | p_vf[7], p_uf[8] | p_uf[7]};
  wire [3:0] p_near = 4'd1 << p_nk;

  // the hand-offs, back to front
  wire p_take = p_v && (!b_v || b_adv) && !rs_full && !sweeping;
  wire a_take = a_v && (!p_v || p_take);
  wire a_in   = !a_v || a_take;                           // A can load this cycle
  assign rdy  = !k_v[1] && !inval_pend && !sweeping;
  wire k_push = req && rdy;
  wire k_pop  = k_v[0] && a_in;

  // ------------------------------------------------------------ the RAMs
  always_comb begin
    // a held C1 re-reads its own lines, so its data is still its own
    ra0 = d_stall ? idx_of(c_t0) : idx_of(pl0);
    ra1 = d_stall ? idx_of(c_t1) : idx_of(pl1);
    re0 = ph0; re1 = ph1;
    wr0 = 1'b0; wr1 = 1'b0; wa = '0; wd = '0; wt = '0;
    if (sweeping) begin
      wr0 = 1'b1; wr1 = 1'b1; wa = sweep; wd = '0; wt = '0;
    end else if (fl_v) begin
      wa = fl_i; wd = fl_d; wt = fl_t;
      if (fl_b) wr1 = 1'b1; else wr0 = 1'b1;
    end
  end

  // ------------------------------------------------------------ C1's compare
  // A READ AND A FILL OF THE SAME LINE ON THE SAME EDGE: the M10K's answer is
  // not defined, so it is taken as a miss (which then joins the held slot).
  wire rdw0 = fw_v && !fw_b && (fw_i == ra0_d);
  wire rdw1 = fw_v &&  fw_b && (fw_i == ra1_d);
  wire c_hit0 = ct0_q[TB] && (ct0_q[TB-1:0] == tag_of(c_t0)) && !rdw0;
  wire c_hit1 = ct1_q[TB] && (ct1_q[TB-1:0] == tag_of(c_t1)) && !rdw1;
  function automatic logic [SW:0] join_of(input tx_t t);
    // {found, slot}: a slot fetching this line, or one D allocates for it now
    join_of = '0;
    if      (fa0 && same_line(d_t0, t)) join_of = {1'b1, d_s0};
    else if (fa1 && same_line(d_t1, t)) join_of = {1'b1, d_s1};
    for (int k = NS - 1; k >= 0; k--)
      if (ms_busy[k] && same_line(ms_line[k], t)) join_of = {1'b1, SW'(k)};
  endfunction
  wire [SW:0] c_j0 = join_of(c_t0), c_j1 = join_of(c_t1);
  // slots that must not be released this cycle: named by C1 as it moves to
  // D, or by D as it writes. A STAGE THAT IS HELD NAMES NOTHING -- a blocked D
  // waiting for a free slot must not keep its own joined slot from being
  // freed (that wedged the first retimed version); instead, a slot released
  // under a held D's join drops the join, and D fetches the line afresh.
  logic [NS-1:0] names;
  always_comb begin
    names = '0;
    if (c_v && !d_stall && c_has0 && c_j0[SW]) names[c_j0[SW-1:0]] = 1'b1;
    if (c_v && !d_stall && c_has1 && c_j1[SW]) names[c_j1[SW-1:0]] = 1'b1;
    if (d_v && !d_block && d_has0 && d_j0[SW]) names[d_j0[SW-1:0]] = 1'b1;
    if (d_v && !d_block && d_has1 && d_j1[SW] && d_do1) names[d_j1[SW-1:0]] = 1'b1;
  end

  logic ms_busy_any;
  always_comb begin
    ms_busy_any = 1'b0;
    for (int k = 0; k < NS; k++) ms_busy_any = ms_busy_any | ms_busy[k];
  end

  // the head's answer, registered once all four texels are in
  wire hd_ready = !rs_empty && (rs_rdy[rs_hd] == 4'hF);
  o_t  o_q;
  h1_t h1_q;
  h2_t h2_q;
  v1_t v1_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      k_v[0] <= 1'b0; k_v[1] <= 1'b0; k_d[0] <= '0; k_d[1] <= '0;
      a_v <= 1'b0; a_tex <= '0; a_ax <= '0; a_ay <= '0; a_bl <= 1'b0;
      p_v <= 1'b0; p_uf <= '0; p_vf <= '0; p_tl <= 1'b0; p_bl <= 1'b0;
      for (int k = 0; k < 4; k++) begin p_tx[k] <= '0; b_tx[k] <= '0; end
      b_v <= 1'b0; b_done <= '0; b_ent <= '0; b_bank <= '0; b_eq <= '0;
      b_first <= 1'b0; b_single <= 1'b0; b_remone <= 1'b0;
      pick0 <= '0; pick1 <= '0; ph0 <= 1'b0; ph1 <= 1'b0; pl0 <= '0; pl1 <= '0;
      c_v <= 1'b0; c_k0 <= '0; c_k1 <= '0; c_has0 <= 1'b0; c_has1 <= 1'b0;
      c_ent <= '0; c_t0 <= '0; c_t1 <= '0;
      for (int k = 0; k < 4; k++) c_sel[k] <= '0;
      ra0_d <= '0; ra1_d <= '0; fw_v <= 1'b0; fw_b <= 1'b0; fw_i <= '0;
      fl_v <= 1'b0; fl_b <= 1'b0; fl_s <= '0; fl_i <= '0; fl_d <= '0; fl_t <= '0;
      d_v <= 1'b0; d_k0 <= '0; d_k1 <= '0; d_has0 <= 1'b0; d_has1 <= 1'b0;
      d_ent <= '0; d_t0 <= '0; d_t1 <= '0; d_hit0 <= 1'b0; d_hit1 <= 1'b0;
      d_j0 <= '0; d_j1 <= '0;
      for (int k = 0; k < 4; k++) begin d_nb0[k] <= '0; d_nb1[k] <= '0; end
      for (int k = 0; k < NS; k++) begin
        ms_busy[k] <= 1'b0; ms_done[k] <= 1'b0; ms_filled[k] <= 1'b0; ms_line[k] <= '0;
        ms_dat[k] <= '0; ms_to[k] <= '0; mq_req[k] <= 1'b0; mq_addr[k] <= '0;
      end
      rs_wp <= '0; rs_rp <= '0;
      for (int e = 0; e < RSP_D; e++) begin
        rs_used[e] <= 1'b0; rs_rdy[e] <= '0; rs_pend[e] <= '0;
        rs_uf[e] <= '0; rs_vf[e] <= '0; rs_tl[e] <= 1'b0; rs_bl[e] <= 1'b0;
        for (int k = 0; k < 4; k++) begin rs_nib[e][k] <= '0; rs_slot[e][k] <= '0; rs_sel[e][k] <= '0; end
      end
      ack <= 1'b0; texel <= '0; o_q <= '0; h1_q <= '0; h2_q <= '0; v1_q <= '0;
      sweep <= '0; sweeping <= 1'b1; inval_d <= 1'b0; inval_pend <= 1'b0;
      dbg_hits <= '0; dbg_misses <= '0; dbg_lost <= '0; dbg_sweeps <= '0;
    end else begin
      inval_d <= inval;
      if (inval && !inval_d) inval_pend <= 1'b1;

      // ---- the tag sweep: out of reset, and on an invalidate once idle
      if (sweeping) begin
        sweep <= sweep + 1'd1;
        if (sweep == IB'(LINES - 1)) begin sweeping <= 1'b0; inval_pend <= 1'b0; end
      end else if (inval_pend && !k_v[0] && !a_v && !p_v && !b_v && !c_v && !d_v && rs_empty
                   && !ms_busy_any) begin
        sweep <= '0; sweeping <= 1'b1;
        if (!(&dbg_sweeps)) dbg_sweeps <= dbg_sweeps + 1'd1;
      end

      // ---- K and A: the request, and its axes
      // model2_v.cpp: "disable smooth wrapping if mirroring is enabled".
      // poly_tex carries texwrapx (bit 7) but not texwrapy -- bit 8 is
      // translucent (R326) -- so v wraps unless mirrored (R620).
      // K: packed from the head down
      case ({k_push, k_pop})
        2'b01: begin k_d[0] <= k_d[1]; k_v[0] <= k_v[1]; k_v[1] <= 1'b0; end
        2'b10: if (!k_v[0]) begin k_d[0] <= k_in; k_v[0] <= 1'b1; end
               else         begin k_d[1] <= k_in; k_v[1] <= 1'b1; end
        2'b11: if (k_v[1]) begin k_d[0] <= k_d[1]; k_d[1] <= k_in; end
               else        begin k_d[0] <= k_in; end
        default: ;
      endcase
      // A: the axes
      if (k_pop) begin
        a_v <= 1'b1; a_tex <= k_d[0].tex; a_bl <= k_d[0].bl;
        a_ax <= axis(k_d[0].u, k_d[0].tex[3:1], k_d[0].tex[7] && !k_d[0].tex[9]);
        a_ay <= axis(k_d[0].v, k_d[0].tex[6:4], !k_d[0].tex[10]);
      end else if (a_take) a_v <= 1'b0;

      // ---- P: the four texels placed
      if (a_take) begin
        p_v <= 1'b1;
        p_tx[0] <= place(a_tex, a_ax[32:21], a_ay[32:21]);
        p_tx[1] <= place(a_tex, a_ax[20:9],  a_ay[32:21]);
        p_tx[2] <= place(a_tex, a_ax[32:21], a_ay[20:9]);
        p_tx[3] <= place(a_tex, a_ax[20:9],  a_ay[20:9]);
        p_uf <= a_ax[8:0]; p_vf <= a_ay[8:0]; p_tl <= a_tex[8]; p_bl <= a_bl;
      end else if (p_take) p_v <= 1'b0;

      // ---- B: the lookups; a response entry claimed as the request enters
      if (p_take) begin
        automatic logic [5:0] e;
        automatic logic [3:0] bk;
        e = {same_line(p_tx[2], p_tx[3]), same_line(p_tx[1], p_tx[3]), same_line(p_tx[1], p_tx[2]),
             same_line(p_tx[0], p_tx[3]), same_line(p_tx[0], p_tx[2]), same_line(p_tx[0], p_tx[1])};
        bk = {p_tx[3].rp[0], p_tx[2].rp[0], p_tx[1].rp[0], p_tx[0].rp[0]};
        b_v <= 1'b1;
        for (int k = 0; k < 4; k++) b_tx[k] <= p_tx[k];
        b_eq <= e; b_bank <= bk;
        begin
          automatic pk_t pk = pick_of(p_bl ? 4'd0 : ~p_near, bk, e);
          pick0 <= pk.pk0; pick1 <= pk.pk1; ph0 <= pk.ph0; ph1 <= pk.ph1;
          pl0 <= p_tx[pk.f0]; pl1 <= p_tx[pk.f1];
        end
        // R627: POINT MODE LOOKS UP ONE TEXEL. The nearest of the four is
        // known here (H1's nn picks it from the same fractions), so the
        // other three are marked looked-up and ready: a point-sampled request
        // is one line again, as m2_texel's was, not up to four.
        b_first <= 1'b1;
        b_single <= p_bl ? one_acc(4'hF, bk, e) : 1'b1;
        b_done <= p_bl ? 4'd0 : ~p_near;
        b_ent  <= rs_wp[RW-1:0];
        rs_used[rs_wp[RW-1:0]] <= 1'b1;
        rs_rdy [rs_wp[RW-1:0]] <= p_bl ? 4'd0 : ~p_near;   // R627: the rest unused
        rs_pend[rs_wp[RW-1:0]] <= 4'd0;
        rs_uf  [rs_wp[RW-1:0]] <= p_uf; rs_vf[rs_wp[RW-1:0]] <= p_vf;
        rs_tl  [rs_wp[RW-1:0]] <= p_tl; rs_bl[rs_wp[RW-1:0]] <= p_bl;
        for (int k = 0; k < 4; k++) rs_sel[rs_wp[RW-1:0]][k] <= sel_of(p_tx[k]);
        rs_wp  <= rs_wp + 1'd1;
      end else if (b_adv) begin
        b_v <= 1'b0;
      end
      if (l_go && !b_last) begin
        // not on the request's LAST access: then B empties or takes the next
        // request, whose b_done <= 0 this would overwrite
        b_done   <= b_done | pick0 | pick1;
        b_first  <= 1'b0;
        b_remone <= one_acc(~(b_done | pick0 | pick1), b_bank, b_eq);
        begin
          automatic pk_t pk = pick_of(b_done | pick0 | pick1, b_bank, b_eq);
          pick0 <= pk.pk0; pick1 <= pk.pk1; ph0 <= pk.ph0; ph1 <= pk.ph1;
          pl0 <= b_tx[pk.f0]; pl1 <= b_tx[pk.f1];
        end
      end

      // ---- L -> C1 (the RAM is read this cycle; C1 sees it next)
      ra0_d <= ra0; ra1_d <= ra1;
      fw_v  <= fl_v && !sweeping; fw_b <= wr1; fw_i <= wa;   // what was written
      fl_v  <= fill_now;
      if (fill_now) begin
        fl_b <= ms_line[fill_s].rp[0];
        fl_s <= fill_s;
        fl_i <= idx_of(ms_line[fill_s]);
        fl_d <= ms_dat[fill_s];
        fl_t <= {1'b1, tag_of(ms_line[fill_s])};
      end
      if (!d_stall) begin
        c_v <= l_go;
        if (l_go) begin
          c_k0 <= pick0; c_k1 <= pick1; c_has0 <= ph0; c_has1 <= ph1;
          c_ent <= b_ent; c_t0 <= pl0; c_t1 <= pl1;
          for (int k = 0; k < 4; k++) c_sel[k] <= sel_of(b_tx[k]);
        end
      end

      // ---- C1 -> D: compared, joined, cut out
      if (!d_stall) begin
        d_v <= c_v;
        if (c_v) begin
          d_k0 <= c_k0; d_k1 <= c_k1; d_has0 <= c_has0; d_has1 <= c_has1;
          d_ent <= c_ent; d_t0 <= c_t0; d_t1 <= c_t1;
          d_hit0 <= c_hit0; d_hit1 <= c_hit1; d_j0 <= c_j0; d_j1 <= c_j1;
          for (int k = 0; k < 4; k++) begin
            d_nb0[k] <= nib(cd0_q, c_sel[k]);
            d_nb1[k] <= nib(cd1_q, c_sel[k]);
          end
        end
      end

      // ---- D: hits written, texels waiting, new misses
      if (d_v && !d_block) begin
        for (int k = 0; k < 4; k++) begin
          if (d_k0[k]) begin
            if (d_hit0) begin
              rs_nib[d_ent][k] <= d_nb0[k]; rs_rdy[d_ent][k] <= 1'b1;
            end else begin
              rs_pend[d_ent][k] <= 1'b1; rs_slot[d_ent][k] <= d_j0[SW] ? d_j0[SW-1:0] : d_s0;
            end
          end
          if (d_k1[k] && d_do1) begin
            if (d_hit1) begin
              rs_nib[d_ent][k] <= d_nb1[k]; rs_rdy[d_ent][k] <= 1'b1;
            end else begin
              rs_pend[d_ent][k] <= 1'b1; rs_slot[d_ent][k] <= d_j1[SW] ? d_j1[SW-1:0] : d_s1;
            end
          end
        end
        if (d_need0) begin
          ms_busy[d_s0] <= 1'b1; ms_done[d_s0] <= 1'b0; ms_filled[d_s0] <= 1'b0; ms_to[d_s0] <= '0; ms_line[d_s0] <= d_t0;
          mq_req[d_s0] <= 1'b1; mq_addr[d_s0] <= (d_t0.sheet ? base_s1 : base_s0) + AW'({d_t0.rp, d_t0.cg, 2'b00});
        end
        if (d_need1 && d_do1) begin
          ms_busy[d_s1] <= 1'b1; ms_done[d_s1] <= 1'b0; ms_filled[d_s1] <= 1'b0; ms_to[d_s1] <= '0; ms_line[d_s1] <= d_t1;
          mq_req[d_s1] <= 1'b1; mq_addr[d_s1] <= (d_t1.sheet ? base_s1 : base_s0) + AW'({d_t1.rp, d_t1.cg, 2'b00});
        end
        if (d_need0 || (d_need1 && d_do1)) begin if (!(&dbg_misses)) dbg_misses <= dbg_misses + 1'd1; end
        else if (!(&dbg_hits)) dbg_hits <= dbg_hits + 1'd1;
        if (d_split) begin d_has0 <= 1'b0; d_k0 <= 4'd0; end   // bank 0 done; hold for bank 1
      end

      // ---- the misses: data in, timeout, fill
      for (int s = 0; s < NS; s++) begin
        if (ms_busy[s] && !ms_done[s]) begin
          ms_to[s] <= ms_to[s] + 1'd1;
          if (&ms_to[s]) begin
            // the memory never answered: answer with what is in hand (zeros)
            ms_done[s] <= 1'b1; ms_dat[s] <= '0;
            mq_req[s] <= 1'b0;
            if (!(&dbg_lost)) dbg_lost <= dbg_lost + 1'd1;
          end
        end
      end
      for (int s = 0; s < NS; s++)
        if (mq_ack[s] && ms_busy[s] && !ms_done[s]) begin
          ms_dat[s] <= mq_data[s]; ms_done[s] <= 1'b1; mq_req[s] <= 1'b0;
        end
      // the head's waiting texels take their nibble once their miss is done
      if (!rs_empty)
        for (int k = 0; k < 4; k++)
          if (rs_pend[rs_hd][k] && ms_done[rs_slot[rs_hd][k]]) begin
            rs_nib[rs_hd][k] <= nib(ms_dat[rs_slot[rs_hd][k]], rs_sel[rs_hd][k]);
            rs_rdy[rs_hd][k] <= 1'b1; rs_pend[rs_hd][k] <= 1'b0;
          end
      if (fill_now) ms_filled[fill_s] <= 1'b1;   // written this cycle
      // released once filled and no texel waits on it -- nor is about to
      // (named by C1's or D's join)
      for (int s = 0; s < NS; s++)
        // ... and not before its line is IN the RAM (the write lands a cycle
        // after the fill is taken): a lookup in that gap joins the slot
        if (ms_busy[s] && ms_filled[s] && !ms_ref[s] && !names[s] && !(fl_v && fl_s == SW'(s))) begin
          ms_busy[s] <= 1'b0;
          if (d_j0 == {1'b1, SW'(s)}) d_j0 <= '0;   // only a held D can still name it
          if (d_j1 == {1'b1, SW'(s)}) d_j1 <= '0;
        end

      // ---- answer the head
      o_q.v <= hd_ready;
      if (hd_ready) begin
        o_q.t00 <= rs_nib[rs_hd][0]; o_q.t01 <= rs_nib[rs_hd][1];
        o_q.t10 <= rs_nib[rs_hd][2]; o_q.t11 <= rs_nib[rs_hd][3];
        o_q.uf  <= rs_uf[rs_hd]; o_q.vf <= rs_vf[rs_hd];
        o_q.tl  <= rs_tl[rs_hd]; o_q.bl <= rs_bl[rs_hd];
        rs_used[rs_hd] <= 1'b0; rs_rdy[rs_hd] <= '0;
        rs_rp <= rs_rp + 1'd1;
      end
      h1_q  <= stage_h1(o_q);
      h2_q  <= stage_h2(h1_q);
      v1_q  <= stage_v1(h2_q);
      ack   <= v1_q.v;
      texel <= stage_v2(v1_q);
    end
  end
endmodule
