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
// TEXTURING A SPAN, one pixel at a time, between the quad filler and the band
// buffer.
//
// WHY IT SITS HERE AND NOT IN THE BAND. A band buffer writes FOUR pixels a
// cycle because a flat span is one colour repeated, and that is most of what
// makes the 3D fit its beam slot. A textured span is a different colour per
// pixel, so it cannot use that path -- but it does not have to CHANGE it
// either: a one-pixel span is a perfectly good span, and the band already
// takes one per handshake. So this unit expands a textured span into a run of
// single-pixel spans and the band is untouched, stipple and clipping included.
//
// AN UNTEXTURED SPAN PASSES STRAIGHT THROUGH, COMBINATIONALLY, AND THAT IS NOT
// AN OPTIMISATION -- IT IS A CORRECTNESS PROPERTY. Registering it instead costs
// one cycle a span, and tb_m2_raster3d caught exactly that: the reference's own
// frame painted 6,396 pixels where the frame before it painted 5,945, because
// the fill no longer finished inside its beam slot and the band went up with
// part of the picture missing. The bands are beam-paced, so latency in this
// path is not free and a flat span must cost what it always did.
//
// THE COLOUR IS THE POLYGON'S, SCALED BY THE TEXEL. The reference maps the
// texel through the luma table and then through the colour table:
//
//     luma = lumaram[lumabase + (t >> 1)] * object.luma / 256;
//     colour = gamma(colortable_{r,g,b}[(colorbase_ch << 8) | luma])
//
// which is the SAME colour ramp the flat path uses, read at an index the
// texture supplies instead of one the lighting supplies. Scaling the polygon's
// finished colour by the texel is that ramp approximated as linear. It puts
// the texture's detail and its shape on the screen with the polygon's own hue
// and lighting; what it does not reproduce is the curve of the ramp or a luma
// table that is not the identity. The exact path needs sixteen colours
// resolved per polygon -- a four-bit texel can only take sixteen values -- and
// that is a table and an allocator, not a change to this walk.

`timescale 1ns/1ps

module m2_span_tex #(
  // TWO PIXELS PER TEXEL FETCH (R279). A textured span costs a fetch and a
  // handshake per pixel, and the bands are beam-paced: at four cycles a pixel
  // a busy frame does not finish. One texel covering two pixels halves both
  // costs, and on this screen it is barely visible -- Daytona's textures are
  // magnified far more often than minified, so adjacent pixels usually share a
  // texel anyway. Set to 1 to fetch per pixel.
  parameter int unsigned PIXSTEP = 2
) (
  input  logic               clk,
  input  logic               rst_n,

  // ---- span in, from m2_raster_fill
  input  logic               in_valid,
  output logic               in_ready,
  input  logic signed [31:0] in_y, in_x0, in_x1,
  input  logic [23:0]        in_col,
  input  logic               in_moire,
  input  logic signed [31:0] in_u, in_v,          // quarter-texels, 16 fractional bits
  // 8.8 texels a pixel (R286), shifted up to this unit's 16.16 on the way in.
  input  logic signed [15:0] in_dudx, in_dvdx,
  // R339: 1/z at the span's start and its gradient along x. u and v above are
  // u/z and v/z, and the texel coordinate is u = (uoz << 15) / ooz -- the
  // perspective divide, done once per PIXSTEP group.
  input  logic signed [31:0] in_ooz,
  input  logic signed [15:0] in_doozdx,
  input  logic [23:0]        in_tex,
  input  logic               in_tex_en,

  // ---- span out, to the band buffers
  // R310: A SPAN IS STILL INSIDE THIS UNIT. With a FIFO in front, the quad
  // store running dry no longer means the spans have been painted -- they can
  // still be queued or mid-fetch, and a span that outlives its band is painted
  // into the NEXT one. The band sequencer waits on this.
  output logic               busy,
  output logic               out_valid,
  input  logic               out_ready,
  output logic signed [31:0] out_y, out_x0, out_x1,
  output logic [23:0]        out_col,
  output logic               out_moire,

  // ---- the texel fetch
  output logic               tx_req,
  input  logic               tx_ack,
  output logic [31:0]        tx_tex,
  output logic [19:0]        tx_u, tx_v,
  input  logic [3:0]         tx_texel,

  output logic [31:0]        dbg_texpix,      // textured pixels emitted
  // TEXELS THAT ARE NOT 0xF, which is the question "did the game upload its
  // textures at all". Unwritten memory reads 0xFFFF by this project's standing
  // rule, so an empty sheet returns 0xF for every texel and a textured polygon
  // comes out FLAT AND FULL BRIGHTNESS -- indistinguishable, by eye, from a
  // texture path that does nothing. tb_m2_boot sees no CPU write to either
  // sheet in 20 M instructions, so this is not a hypothetical.
  output logic [31:0]        dbg_texnz,
  // R446: kept so m2_raster3d and Model2.sv stay byte-identical to the build
  // this is being tested against. The current state costs nothing to expose;
  // the dwell counter that used to sit behind it is gone (R443).
  output logic [2:0]         dbg_hot,
  output logic [15:0]        dbg_hotcyc
);

  typedef enum logic [2:0] { T_IDLE, T_RUN, T_DRAIN } st_t;   // R476
  st_t st;

  logic signed [31:0] y_r, x1_r;   // R476: x_r is iss_x/fq_x now
  logic [23:0]        col_r;
  logic               moire_r;
  // R476: u_r/v_r/ooz_r are gone -- the issue pointer walks the span and the
  // gradients are all the consumer needs.
  logic signed [31:0] du_r, dv_r;
  // R339: 1/z walks the span exactly as u and v do.
  logic signed [31:0] doz_r;
  // The divided coordinates, in the same quarter-texel.16 the affine path used,
  // so to_tx() and everything downstream are unchanged.
  logic signed [31:0] uq_r, vq_r;
  // R433: the Newton step and the coordinate multiply, split across cycles.
  // R446: THE DIVIDE MOVES BESIDE THE FETCH INSTEAD OF IN FRONT OF IT.
  //
  // As four FSM states the walk ran T_RCP1..4 -> T_FETCH -> T_EMIT for EVERY
  // PIXSTEP group: four cycles of divide serialised ahead of every texel fetch,
  // on spans ~125 groups wide. Before orientation a group was T_FETCH ->
  // T_EMIT. That serialisation is why bands fell from 41-85% to one or two.
  //
  // 1/z is linear, so the NEXT group's value is known as soon as this one
  // starts: u_nxt/ooz_nxt below. The four stages become a pipeline clocked
  // every cycle on those, so group N+1's coordinates are computed WHILE group
  // N's texel is in flight, and the fetch never waits for a divide again.
  // Only the first group of a span pays, once, in T_WARM.

  // Clamp to a positive 32-bit value: a vertex far enough away makes the
  // coordinate enormous, and to_tx would read a wrapped one as a small texel.
  function automatic logic signed [31:0] sat32(input logic [63:0] v);
    sat32 = (v[63:31] != 33'd0) ? 32'sh7FFFFFFF : 32'(v);
  endfunction

  // R339: THE RECIPROCAL SEED, 128 ENTRIES ON THE TOP 8 BITS.
  //
  // A plain table accurate enough for half a texel needs ~12 index bits --
  // 4,096 entries, about 1,000 ALM in MLAB, and there is no M10K left at
  // 553/553. ONE NEWTON STEP buys those bits in DSP instead, which is the
  // resource with 49 blocks idle:
  //
  //     seed alone       7.8e-3   ->  2.0     texels on a 256-texel coordinate
  //     + one Newton     6.1e-5   ->  0.016   texels
  //
  // which is an order of magnitude under what the plane fit's own quantisation
  // contributes (0.02 to 0.59 texels, R338), so the divide is not the limit.
  (* ramstyle = "MLAB" *) logic [24:0] rcp_tab [128];
  initial begin
    for (int i = 0; i < 128; i++)
      rcp_tab[i] = 25'((64'd1 <<< 47) / (64'(128 + i) <<< 16));
  end

  // Where the leading one of ooz sits, so it can be normalised to [2^23, 2^24).
  function automatic logic [5:0] top_bit(input logic [31:0] v);
    logic [5:0] n;
    begin
      n = 6'd0;
      for (int i = 31; i >= 0; i--) if (v[i] && n == 6'd0) n = 6'(i);
      top_bit = n;
    end
  endfunction
  logic [23:0]        tex_r;
  // R476: no registered texel -- the emit uses the one that has just arrived.
  // A FETCH THAT NEVER ANSWERS MUST NOT STOP THE BAND. m2_texel has its own
  // timeout on the memory, but it also goes deaf while it sweeps its tags, and
  // this walk is inside the band fill -- a wait here is a band that never
  // completes and a picture that stops. On expiry the texel is taken as 0xF,
  // which is what unwritten memory reads anyway.
  logic [8:0]         to_cnt;

  // The stored coordinate is quarter-texels with sixteen fractional bits; the
  // fetch wants texels with eight, which is ten bits to the right. Negative
  // coordinates clamp to zero rather than wrapping into the top of the sheet:
  // a plane fitted through a clipped quad can step slightly outside it.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [19:0] to_tx(input logic signed [31:0] q);
    to_tx = q[31] ? 20'd0 : q[29:10];      // the fraction below bit 10 is dropped
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  assign tx_tex = {8'd0, tex_r};
  // R339: the DIVIDED coordinates, not u/z and v/z themselves.
  assign tx_u   = to_tx(uq_r);
  assign tx_v   = to_tx(vq_r);
  assign tx_req = fq_valid;   // R476

  // The texel as an intensity: 0x0 -> 0, 0xF -> 0xFF, evenly spaced.
  // R476: the emit computes its own intensity from the texel that has just
  // arrived, so there is no registered copy to derive one from.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [7:0] scale(input logic [7:0] c, input logic [7:0] i);
    logic [15:0] p;
    begin
      // (c * i + c) >> 8, so a full texel -- i = 255 -- returns c EXACTLY
      // rather than c * 255/256. Without the +c, turning textures on darkens
      // every pixel by a step even where the texture is solid.
      p = 16'(c) * 16'(i) + 16'(c);
      scale = p[15:8];
    end
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  wire tex_now = in_tex_en && in_tex[0];

  // R326: THE TRANSLUCENT TEXEL TEST, WHICH IS THE WHOLE OF MAME'S ALPHA.
  //
  // model2rd.ipp's fetch_bilinear_texel<Translucent> sets 0x00800000 on every
  // texel EXCEPT 0xf0, and draw_scanline_tex<Translucent> then does
  // `if (t < 0x00400000) continue;`. With point sampling that reduces exactly
  // to: on a translucent polygon a texel of 0xF is transparent and every other
  // value draws normally. On a NON-translucent polygon 0xF is a legitimate
  // full-brightness texel and must not be skipped -- which is why this is
  // gated on the header bit rather than applied to every span.
  //
  // Bit 8 of the packed texture word is the translucent flag (see the packing
  // in m2_geo_engine); it used to be texwrapy, which nothing read.
  //
  // Skipping costs nothing but the pixel: the walk advances identically, so a
  // fully transparent span still terminates on its own x1.

  wire idle    = (st == T_IDLE);
  assign busy  = !idle || e_valid;

  // The registered half, used only while a textured span is being walked.
  logic               e_valid;
  logic [23:0]        e_col;
  // THE PIXEL'S OWN x, LATCHED WITH ITS COLOUR. Taking it from the walking
  // register instead puts every pixel one to the right of where its texel came
  // from: the walk advances in the same cycle the pixel is offered, so the
  // combinational read sees the NEXT x.
  logic signed [31:0] e_x;
  // AND THE GROUP'S LAST PIXEL, REGISTERED WITH IT. Computing `min(x + PIXSTEP
  // - 1, x1)` on the way OUT puts a 32-bit add, a compare and a mux between a
  // register and the band buffer's write decode -- combinational the whole
  // way, because a flat span passes through this unit as wires. It is latched
  // here instead.
  logic signed [31:0] e_x1;

  // Flat spans go through as wires; textured pixels come from the registers.
  assign out_valid = idle ? (in_valid && !tex_now) : e_valid;
  assign out_y     = idle ? in_y     : y_r;
  assign out_x0    = idle ? in_x0    : e_x;
  // PIXSTEP wide, clipped at the span's end -- computed when the pixel is
  // formed, not when it is offered.
  assign out_x1    = idle ? in_x1 : e_x1;
  assign out_col   = idle ? in_col   : e_col;
  assign out_moire = idle ? in_moire : moire_r;

  // A flat span is accepted only when the band takes it, which is the handshake
  // the fill saw before this unit existed. A textured one is accepted at once
  // and walked from the registers.
  assign in_ready  = idle && (tex_now || out_ready);
  assign dbg_hot    = st;          // R446: free, no counter behind it
  assign dbg_hotcyc = 16'd0;

  // R446: the group after this one. Stable for as long as the FSM sits in
  // T_FETCH/T_EMIT, which is what lets the pipeline below settle on it.
  // R476: THE PIPELINE CARRIES SUCCESSIVE GROUPS NOW, NOT ONE HELD STILL.
  //
  // It used to be fed dv_u/dv_o = u_nxt/ooz_nxt -- the SAME next-group value,
  // recomputed every cycle while the walk sat on the current one -- and the FSM
  // waited `dv_age >= 6` for it to settle, then advanced and waited again. A
  // fixed-latency pipeline fed a constant, so nothing overlapped.
  //
  // R475 measured what that costs, with the bench answering every texel in ONE
  // cycle: **7.41 cycles per group**, which is 45,835 groups x 7.41 x 20 ns =
  // 6.8 ms of a 16.7 ms frame before any texel latency at all -- twice the
  // 3.3 ms the misses cost. The divide was the bottleneck, not the fetch, and
  // it is why R470's 60 MHz renderer bought nothing: a faster clock shortens a
  // fixed wait proportionally while the crossing it added got longer.
  //
  // So an ISSUE pointer walks the span a group per cycle into the pipeline, a
  // shadow carries each group's x alongside, and the consumer takes results as
  // they emerge. The divide's six cycles are paid once per SPAN instead of once
  // per group.
  logic signed [31:0] iss_u, iss_v, iss_ooz;
  logic signed [31:0] iss_x;
  logic               iss_run;      // still issuing groups for this span
  wire                iss_last  = (iss_x + 32'(PIXSTEP) - 32'sd1) >= x1_r;

  wire signed [31:0] dv_o    = iss_ooz;
  wire signed [31:0] dv_u    = iss_u;
  wire signed [31:0] dv_v    = iss_v;

  // THE SHADOW. Six deep, matching d0..d4b, so the x that arrives with a
  // result is the x that was issued with its operands. Getting this depth
  // wrong pairs a group's coordinates with another group's position, which
  // draws a span whose texture slides along it -- and every arithmetic check
  // still passes.
  localparam int unsigned PIPE_D = 6;
  logic                    sh_v    [PIPE_D];
  logic signed [31:0]      sh_x    [PIPE_D];
  logic                    sh_last [PIPE_D];

  logic [2:0]  dv_age;            // kept: the span's first result still warms

  // R476: the result standing at the end of the pipeline, and the fetch slot.
  wire                res_valid = sh_v[PIPE_D-1];
  wire signed [31:0]  res_x     = sh_x[PIPE_D-1];
  wire                res_last  = sh_last[PIPE_D-1];

  logic               fq_valid;   // a texel fetch is outstanding
  // R478: THE RETIRE STAGE. R476 computed e_col straight from the arriving
  // texel, which put m2_texel's `hold` register, the nibble select, the
  // adapter and scale() in ONE cycle:
  //
  //   m2_texel|hold[12] -> m2_span_tex|e_col[22]   9.570 ns
  //
  // and cost about 0.6 ns of clk_sys across three seeds. The old walk
  // registered the texel first and coloured it the cycle after; streaming the
  // walk removed that stage by accident. Putting it back costs a stage but not
  // a cycle per group, because the next fetch is issued on the same edge.
  logic               rt_valid;
  logic [3:0]         rt_texel;
  logic signed [31:0] rt_x;
  logic               rt_last;
  logic signed [31:0] fq_x;
  logic               fq_last;

  // Take a result when there is one, no fetch is outstanding, and the emit
  // slot will be free. The pipeline runs whenever the output is not being held.
  // The span load, seen by the pipeline block so the issue pointer starts with
  // the span. The FSM loads du_r/dv_r/doz_r on the same edge; the first advance
  // happens a cycle later, by which time they are valid.
  wire ld_span   = (st == T_IDLE) && in_valid && tex_now;
  // R478: the retire slot only has to be free by the NEXT edge, not this one.
  // Requiring !rt_valid outright cost a whole cycle a group (2.36 -> 3.36):
  // the emit that frees it happens on the same edge the fetch would start.
  wire rt_frees  = rt_valid && (!e_valid || out_ready);
  wire cons_take = res_valid && !fq_valid && (!rt_valid || rt_frees) && (st == T_RUN);
  wire pipe_en   = !res_valid || cons_take;
  logic signed [31:0] d0_o;   logic [5:0] d0_e;   // R448: stage 1a
  logic [5:0]  d1_e;   logic [31:0] d1_m;  logic [24:0] d1_r;
  logic [31:0] d2_nd;  logic [5:0]  d2_e;  logic [24:0] d2_r;
  logic [24:0] d3_r1;  logic [5:0]  d3_e;
  logic signed [31:0] d4_u, d4_v;
  logic        [63:0] d4a_pu, d4a_pv;   // R468: the product, before the shift
  logic         [4:0] d4a_sh;
  // The coordinate that entered the pipeline with the 1/z now emerging from it,
  // delayed three cycles to match. Getting this wrong pairs a texel coordinate
  // with the wrong pixel's depth, which is the whole fault this change exists
  // to avoid introducing.
  logic signed [31:0] u_h1, v_h1, u_h2, v_h2, u_h3, v_h3, u_h4, v_h4;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      d0_o <= '0; d0_e <= '0;
      d1_e <= '0; d1_m <= '0; d1_r <= '0;
      d2_nd <= '0; d2_e <= '0; d2_r <= '0;
      d3_r1 <= '0; d3_e <= '0; d4_u <= '0; d4_v <= '0;
      d4a_pu <= '0; d4a_pv <= '0; d4a_sh <= '0;   // R468
      u_h1 <= '0; v_h1 <= '0; u_h2 <= '0; v_h2 <= '0; u_h3 <= '0; v_h3 <= '0;
      u_h4 <= '0; v_h4 <= '0;
      iss_u <= '0; iss_v <= '0; iss_ooz <= '0; iss_x <= '0; iss_run <= 1'b0;
      for (int k = 0; k < PIPE_D; k++) begin
        sh_v[k] <= 1'b0; sh_x[k] <= '0; sh_last[k] <= 1'b0;
      end
    end else if (ld_span) begin
      // R476: START OF SPAN. The shadow is cleared so a stale valid from the
      // previous span cannot emerge as a group of this one -- which would draw
      // one span's texel at another span's x and pass every arithmetic check.
      iss_u   <= in_u;
      iss_v   <= in_v;
      iss_ooz <= in_ooz;
      iss_x   <= in_x0;
      iss_run <= 1'b1;
      for (int k = 0; k < PIPE_D; k++) begin
        sh_v[k] <= 1'b0; sh_x[k] <= '0; sh_last[k] <= 1'b0;
      end
    end else if (pipe_en) begin
      // R476: THE WHOLE PIPELINE STALLS TOGETHER. When the consumer cannot take
      // the result at the output, nothing moves -- issue, stages and shadow all
      // hold. Letting the stages advance while the output is held would drop
      // the result that is standing there.
      //
      // Issue one group per enabled cycle, and shift the shadow with it.
      if (iss_run) begin
        iss_u   <= iss_u   + (du_r  <<< $clog2(PIXSTEP));
        iss_v   <= iss_v   + (dv_r  <<< $clog2(PIXSTEP));
        iss_ooz <= iss_ooz + (doz_r <<< $clog2(PIXSTEP));
        iss_x   <= iss_x   + 32'(PIXSTEP);
        if (iss_last) iss_run <= 1'b0;
      end
      sh_v[0]    <= iss_run;
      sh_x[0]    <= iss_x;
      sh_last[0] <= iss_run && iss_last;
      for (int k = 1; k < PIPE_D; k++) begin
        sh_v[k]    <= sh_v[k-1];
        sh_x[k]    <= sh_x[k-1];
        sh_last[k] <= sh_last[k-1];
      end

      // R448: STAGE 1 SPLIT IN TWO. As one cycle it was the ooz_nxt add, then
      // top_bit's priority encode, then a variable shift, then the rcp_tab
      // read -- four operations, and report_timing named it:
      //   m2_span_tex|doz_r[17] -> m2_span_tex|d1_r[19]   -0.905 on clk_sys
      // A four-stage pipeline with four things in its first stage, written to
      // take a divide OUT of a critical path.
      //
      // 1a: the add and the encode. 1b: the shift and the table read.
      d0_o <= dv_o;
      d0_e <= top_bit(dv_o);
      begin
        automatic logic [31:0] m = (d0_e >= 6'd23) ? (d0_o >> (d0_e - 6'd23))
                                                   : (d0_o << (6'd23 - d0_e));
        d1_e <= d0_e; d1_m <= m; d1_r <= rcp_tab[m[22:16]];
      end
      // stage 2: the Newton residual
      d2_nd <= 32'((((64'd1 <<< 48) - (64'(d1_m) * 64'(d1_r))) >> 24));
      d2_e  <= d1_e; d2_r <= d1_r;
      // stage 3: the refined reciprocal
      d3_r1 <= 25'((64'(d2_r) * 64'(d2_nd)) >> 23);
      d3_e  <= d2_e;
      // stage 4a: the coordinate multiply. R468: THE SHIFT MOVED OFF IT.
      //
      //   m2_span_tex|Mult1~mult_hh_pl -> m2_span_tex|d4_v[26]   16.933 ns
      //
      // was the worst clk_3d path on s134 once R466 moved m2_persp_recip off
      // it. One cycle carried a 64-bit multiply, a VARIABLE shift by sh and
      // then sat32 -- a DSP output straight into a barrel shifter, the same
      // shape R457, R459, R461 and R466 each split.
      //
      // `sh` is not the offender: it comes off the registered d3_e and
      // computes beside the multiply. The multiply feeding the shifter is.
      //
      // COSTS LATENCY, NOT THROUGHPUT. d0..d4 is a pipeline (R446/R448), not a
      // state walk -- group N+1's coordinates are computed while group N's
      // texel is in flight -- so one more stage means dv_age reaches six
      // instead of five, and nothing issues any slower.
      d4a_pu <= 64'(u_h4) * 64'(d3_r1);
      d4a_pv <= 64'(v_h4) * 64'(d3_r1);
      d4a_sh <= (d3_e < 6'd23) ? 5'd16 : 5'(d3_e - 6'd7);

      // stage 4b: the un-normalise and the clamp, on the registered product.
      d4_u <= sat32(d4a_pu >> d4a_sh);
      d4_v <= sat32(d4a_pv >> d4a_sh);
      u_h1 <= dv_u;  v_h1 <= dv_v;
      u_h2 <= u_h1;  v_h2 <= v_h1;
      u_h3 <= u_h2;  v_h3 <= v_h2;
      u_h4 <= u_h3;  v_h4 <= v_h3;   // R448: one deeper, to match
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= T_IDLE; dv_age <= 3'd0; fq_valid <= 1'b0; fq_x <= '0; fq_last <= 1'b0;
      rt_valid <= 1'b0; rt_texel <= 4'd0; rt_x <= '0; rt_last <= 1'b0;   // R478
      y_r <= '0; x1_r <= '0; col_r <= '0; moire_r <= 1'b0;
      du_r <= '0; dv_r <= '0; tex_r <= '0;
      doz_r <= '0; uq_r <= '0; vq_r <= '0;
      // R433
      e_valid <= 1'b0; e_col <= '0; e_x <= '0; e_x1 <= '0; to_cnt <= '0;
      dbg_texpix <= '0; dbg_texnz <= '0;
    end else begin
      if (e_valid && out_ready) e_valid <= 1'b0;
      // R446: the pipeline is four deep; this says when its output matches the
      // operands currently presented. It must NOT be gated by the branch that
      // waits on it -- R424 made that mistake and deadlocked the walk.
      if (dv_age != 3'd7) dv_age <= dv_age + 3'd1;

      case (st)
        T_IDLE: if (in_valid && tex_now) begin
          y_r     <= in_y;
          x1_r    <= in_x1;
          col_r   <= in_col;
          moire_r <= in_moire;
          du_r    <= 32'(in_dudx) <<< 8;
          dv_r    <= 32'(in_dvdx) <<< 8;
          tex_r   <= in_tex;
          doz_r   <= 32'(in_doozdx) <<< 8;
          dv_age  <= 3'd0;
          fq_valid <= 1'b0;
          to_cnt  <= '0;
          st      <= T_RUN;
        end

        // R476: ONE STATE, NOT THREE. T_WARM waited for the first divide,
        // T_FETCH waited for a texel and T_EMIT waited for dv_age to reach six
        // again -- and that last wait was per GROUP, which R475 measured as
        // 7.41 cycles a group with a perfect cache. The pipeline now carries
        // successive groups, so the six cycles are paid once per span while it
        // fills, and after that a result is standing at the output every cycle
        // the consumer can take one.
        T_RUN: begin
          to_cnt <= to_cnt + 1'd1;

          // Take the next result and start its fetch.
          if (cons_take) begin
            uq_r   <= d4_u;
            vq_r   <= d4_v;
            fq_x    <= res_x;
            fq_last <= res_last;
            fq_valid <= 1'b1;
            to_cnt  <= '0;
          end

          // Retire the outstanding fetch into the colour stage. R478: the texel
          // is REGISTERED here and coloured on the next edge, so the cache's
          // output does not reach scale() combinationally.
          if (fq_valid && (tx_ack || (&to_cnt))) begin
            automatic logic [3:0] tnow = tx_ack ? tx_texel : 4'hf;
            rt_valid <= 1'b1;
            rt_texel <= tnow;
            rt_x     <= fq_x;
            rt_last  <= fq_last;
            fq_valid <= 1'b0;
            to_cnt   <= '0;
            // R484: WRAPS, DOES NOT SATURATE. The top level reads this as a
            // per-frame delta (`sat16d(now, prev)`, an unsigned 32-bit
            // subtract), and that subtraction is correct across a wrap but
            // reads ZERO forever once the counter sticks at all-ones. At
            // 180,080 textured groups a frame this saturated after ~6.6
            // minutes of attract mode -- so the instrument reported "no
            // non-transparent texels" while the screen was plainly showing
            // textures. m2_texel's and m2_char_cache's counters have always
            // wrapped and have never had this fault. Dropping the guard also
            // takes a 32-input AND out of the increment enable, which this
            // module has been bitten by before (see m2_texel's dbg_misses).
            if (tx_ack && tnow != 4'hf) dbg_texnz <= dbg_texnz + 1'd1;
          end

          // Colour and emit the retired group.
          if (rt_valid && (!e_valid || out_ready)) begin
            automatic logic       skip = tex_r[8] && (rt_texel == 4'hf);
            automatic logic [7:0] iv   = {rt_texel, rt_texel};
            rt_valid <= 1'b0;
            e_valid <= !skip;                     // R326: transparent texel
            e_x     <= rt_x;
            e_x1    <= ((rt_x + 32'(PIXSTEP) - 32'sd1) > x1_r)
                         ? x1_r : (rt_x + 32'(PIXSTEP) - 32'sd1);
            e_col   <= {scale(col_r[23:16], iv),
                        scale(col_r[15:8],  iv),
                        scale(col_r[7:0],   iv)};
            if (!skip) dbg_texpix <= dbg_texpix + 32'(PIXSTEP);   // R484: wraps
            if (rt_last) st <= T_DRAIN;
          end
        end

        // The last pixel has to be TAKEN before this unit goes back to passing
        // spans through, because the pass-through mux would overwrite it.
        T_DRAIN: if (!e_valid || out_ready) st <= T_IDLE;

        default: st <= T_IDLE;
      endcase
    end
  end

endmodule
