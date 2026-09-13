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

  typedef enum logic [1:0] { T_IDLE, T_FETCH, T_EMIT, T_DRAIN } st_t;
  st_t st;

  logic signed [31:0] y_r, x_r, x1_r;
  logic [23:0]        col_r;
  logic               moire_r;
  logic signed [31:0] u_r, v_r, du_r, dv_r;
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

  assign tx_tex = {8'd0, tex_r};
  assign tx_u   = to_tx(u_r);
  assign tx_v   = to_tx(v_r);
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
      e_valid <= 1'b0; e_col <= '0; e_x <= '0; e_x1 <= '0; to_cnt <= '0;
      dbg_texpix <= '0; dbg_texnz <= '0;
    end else begin
      if (e_valid && out_ready) e_valid <= 1'b0;

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
          tex_r   <= in_tex;
          st      <= T_FETCH;
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

        T_EMIT: if (!e_valid || out_ready) begin
          e_valid <= 1'b1;
          e_x     <= x_r;
          e_x1    <= ((x_r + 32'(PIXSTEP) - 32'sd1) > x1_r)
                       ? x1_r : (x_r + 32'(PIXSTEP) - 32'sd1);
          e_col   <= {scale(col_r[23:16], inten),
                      scale(col_r[15:8],  inten),
                      scale(col_r[7:0],   inten)};
          if (!(&dbg_texpix)) dbg_texpix <= dbg_texpix + 32'(PIXSTEP);
          if (x_r + 32'(PIXSTEP) - 32'sd1 >= x1_r) begin
            st <= T_DRAIN;
          end else begin
            x_r <= x_r + 32'(PIXSTEP);
            u_r <= u_r + (du_r <<< (PIXSTEP == 2 ? 1 : 0));
            v_r <= v_r + (dv_r <<< (PIXSTEP == 2 ? 1 : 0));
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
