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
  // R424: the third plane. in_u/in_v are u/z and v/z now, and this is 1/z; the
  // walk divides one by the other to get back a texture coordinate.
  input  logic signed [31:0] in_o,
  input  logic signed [15:0] in_dodx,
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
  output logic [31:0]        dbg_texnz
);

  typedef enum logic [2:0] { T_IDLE, T_WARM, T_FETCH, T_EMIT, T_DRAIN } st_t;
  st_t st;

  logic signed [31:0] y_r, x_r, x1_r;
  logic [23:0]        col_r;
  logic               moire_r;
  logic signed [31:0] u_r, v_r, du_r, dv_r;
  logic signed [31:0] o_r, do_r;        // R424: 1/z and its gradient
  logic [31:0]        rcp_r;            // R424: 2^30 / o_r, held for the group
  logic [1:0]         rcp_age;          // cycles since the divider was given o
  logic [1:0]         warm_cnt;
  logic [23:0]        tex_r;
  logic [3:0]         texel_r;
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

  // R424: THE PERSPECTIVE DIVIDE, ONE RECIPROCAL PER PIXSTEP GROUP.
  //
  // u/z, v/z and 1/z are linear in screen space and the plane fit is exact for
  // them; u and v are not, which is the whole of the affine error R331
  // measured at 36 texels for a 4:1 depth ratio and 1,408 for 100:1. Dividing
  // per PIXEL is what the reference does and is not affordable here. Dividing
  // once per group of PIXSTEP leaves only the error WITHIN four pixels, which
  // is what consoles of this generation did.
  //
  // FED A GROUP AHEAD RATHER THAN STALLING. m2_persp_recip answers in two
  // cycles. o_nxt is stable throughout T_FETCH, so handing it over on entry
  // means the answer is waiting when the group advances, and the walk pays
  // nothing on any fetch that took two cycles or more -- which is most of
  // them. rcp_age is the guard for the ones that did not.
  wire signed [31:0] o_nxt = o_r + (do_r <<< $clog2(PIXSTEP));
  wire [15:0] rcp_d = (st == T_WARM) ? (o_r[31]   ? 16'd1 : {1'b0, o_r[30:16]})
                                     : (o_nxt[31] ? 16'd1 : {1'b0, o_nxt[30:16]});
  wire [31:0] rcp_q;
  m2_persp_recip u_rcp (.clk(clk), .rst_n(rst_n), .in_d(rcp_d), .out_q(rcp_q));

  // u = (u/z) / (1/z). u_r is u/z in 16.16 and rcp_r is 2^30/o, so the product
  // is u/z * 2^29 / o and the shift brings it back to 16.16. Saturating,
  // because a vertex whose 1/z interpolated to near zero is a vertex at the
  // horizon and the quotient there is unbounded.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic signed [31:0] persp(input logic signed [31:0] c,
                                               input logic [31:0] r);
    logic [54:0] p;
    begin
      if (c[31]) persp = 32'sd0;                 // to_tx clamps these anyway
      else begin
        p = 55'({1'b0, c[30:8]}) * 55'(r);
        persp = (p[54:9] > 46'h3fff_ffff) ? 32'sh3fff_ffff : 32'(p >> 9);
      end
    end
  endfunction

  /* verilator lint_on UNUSEDSIGNAL */

  wire signed [31:0] u_px = persp(u_r, rcp_r);
  wire signed [31:0] v_px = persp(v_r, rcp_r);

  assign tx_tex = {8'd0, tex_r};
  assign tx_u   = to_tx(u_px);
  assign tx_v   = to_tx(v_px);
  assign tx_req = (st == T_FETCH);

  // The texel as an intensity: 0x0 -> 0, 0xF -> 0xFF, evenly spaced.
  wire [7:0] inten = {texel_r, texel_r};
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
  wire tx_skip = tex_r[8] && (texel_r == 4'hf);
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

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= T_IDLE;
      y_r <= '0; x_r <= '0; x1_r <= '0; col_r <= '0; moire_r <= 1'b0;
      u_r <= '0; v_r <= '0; du_r <= '0; dv_r <= '0; tex_r <= '0; texel_r <= '0;
      o_r <= '0; do_r <= '0; rcp_r <= 32'd0; rcp_age <= 2'd0; warm_cnt <= 2'd0;
      e_valid <= 1'b0; e_col <= '0; e_x <= '0; e_x1 <= '0; to_cnt <= '0;
      dbg_texpix <= '0; dbg_texnz <= '0;
    end else begin
      if (e_valid && out_ready) e_valid <= 1'b0;

      // R424: THE AGE COUNTS UNCONDITIONALLY. It was inside the T_EMIT branch
      // that waits on it, so a texel that came back in one cycle left rcp_age
      // at 1 with nothing able to advance it -- the walk deadlocked and took
      // the band with it. A guard must never be gated by the thing it guards.
      if ((st == T_FETCH || st == T_EMIT) && rcp_age != 2'd3)
        rcp_age <= rcp_age + 2'd1;

      case (st)
        T_IDLE: if (in_valid && tex_now) begin
          y_r     <= in_y;
          x_r     <= in_x0;
          x1_r    <= in_x1;
          col_r   <= in_col;
          moire_r <= in_moire;
          u_r     <= in_u;
          v_r     <= in_v;
          du_r    <= 32'(in_dudx) <<< 8;
          dv_r    <= 32'(in_dvdx) <<< 8;
          o_r     <= in_o;                       // R424
          do_r    <= 32'(in_dodx) <<< 12;        // R424: 12.4, not 8.8
          tex_r   <= in_tex;
          warm_cnt <= 2'd2;
          st      <= T_WARM;
        end

        // R424: the span's FIRST group has nothing in flight to inherit, so it
        // is the one place the divider is waited on. Two cycles once a span,
        // not two cycles once a group.
        T_WARM: begin
          if (warm_cnt == 2'd0) begin
            rcp_r   <= rcp_q;
            rcp_age <= 2'd0;
            st      <= T_FETCH;
          end else warm_cnt <= warm_cnt - 2'd1;
        end

        T_FETCH: begin
          to_cnt <= to_cnt + 1'd1;
          if (tx_ack) begin
            texel_r <= tx_texel;
            if (tx_texel != 4'hf && !(&dbg_texnz)) dbg_texnz <= dbg_texnz + 1'd1;
            to_cnt  <= '0;
            st      <= T_EMIT;
          end else if (&to_cnt) begin
            texel_r <= 4'hf;
            to_cnt  <= '0;
            st      <= T_EMIT;
          end
        end

        // R424: the group cannot advance until the divider has answered for the
        // one after it. rcp_age counts from the cycle o_nxt was handed over, so
        // this only ever waits when the texel came back in under two cycles.
        T_EMIT: if ((!e_valid || out_ready) && rcp_age >= 2'd2) begin
          e_valid <= !tx_skip;                  // R326: transparent texel
          e_x     <= x_r;
          e_x1    <= ((x_r + 32'(PIXSTEP) - 32'sd1) > x1_r)
                       ? x1_r : (x_r + 32'(PIXSTEP) - 32'sd1);
          e_col   <= {scale(col_r[23:16], inten),
                      scale(col_r[15:8],  inten),
                      scale(col_r[7:0],   inten)};
          if (!tx_skip && !(&dbg_texpix)) dbg_texpix <= dbg_texpix + 32'(PIXSTEP);
          if (x_r + 32'(PIXSTEP) - 32'sd1 >= x1_r) begin
            st <= T_DRAIN;
          end else begin
            x_r <= x_r + 32'(PIXSTEP);
            // R323: THE TEXTURE STEP MUST MATCH PIXSTEP, and this only ever
            // handled 1 and 2. It read `<<< (PIXSTEP == 2 ? 1 : 0)`, so at any
            // PIXSTEP above two `x` advanced by PIXSTEP while u and v advanced
            // by ONE texel -- the texture magnified by PIXSTEP/2 along every
            // span, which on the board looks like texels at the wrong scale and
            // orientation. R322 set PIXSTEP to 4 and shipped that before this
            // was noticed.
            //
            // NEITHER BENCH COULD CATCH IT. tb_m2_raster3d counts pixels
            // painted, which is unchanged by a wrong texture coordinate, and
            // tb_m2_span_tex has 28 checks and no assertion on u or v at all.
            // A span walk needs a test that says WHICH TEXEL each pixel took.
            //
            // $clog2 is correct for any POWER OF TWO. A non-power-of-two step
            // (6) would need a real multiply on this path, for nothing that 8
            // does not already give.
            u_r <= u_r + (du_r <<< $clog2(PIXSTEP));
            v_r <= v_r + (dv_r <<< $clog2(PIXSTEP));
            o_r     <= o_nxt;                    // R424
            rcp_r   <= rcp_q;
            rcp_age <= 2'd0;
            st  <= T_FETCH;
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
