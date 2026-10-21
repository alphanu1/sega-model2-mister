// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// m2_geo_view -- THE PROJECTION, FROM THE GAME'S OWN WINDOW COMMAND (R642).
//
// R174 fixed the projection at "a 496x384 screen centred at (248,192)". The
// game says otherwise (R641): geo_window_data carries the viewport and the
// projection centre, Daytona's centre is (248,270) most of the time, and its
// attract cameras move it 270 -> 312 -> 270. MAME (model2_v.cpp):
//
//   model2_3d_project:  x = crtc_xoffset + center[0] + x/z
//                       y = (384 - center[1]) + crtc_yoffset - y/z
//   window command 3:   left   = center[0] - viewport[0]
//                       right  = viewport[2] - center[0]
//                       top    = viewport[3] - center[1]
//                       bottom = center[1] - viewport[1]
//
// and m2_geo_project / m2_geo_clip take s = (xc + x/z, yc - y/z) with the
// frustum as four slopes (R174: Model 1's a_bottom is MAME's TOP plane):
//
//   xc = crtc_xoffset + cx          yc = 384 - cy + crtc_yoffset
//   a_left = -left   a_right = right   a_bottom = top   a_top = -bottom
//
// The CRTC offsets are parameters: MAME logs 0 and 128 for Daytona on every
// frame (p13c), set from CRTC registers this core does not decode.
//
// The window changes at most once a list and the geometry is idle between
// objects, so the conversion takes two registered stages and no hurry.
//
// R907: AND SO ONE CONVERTER, NOT SIX. The six values took six integer-to-
// float units in parallel (575 ALUT, 290 ALM placed in s1250) to answer in 3
// cycles something that changes once an object. One unit now visits the six
// slots in turn: an output is rewritten every 6 cycles and is right at most
// 8 cycles after its inputs change (up to 6 to reach its slot, then 2). The
// first use of any of them is a projection or a clip test after the object's
// first vertex has been fetched and transformed -- tens of cycles at the
// least -- and geodiff's pool hash (every FP operand, every cycle) is
// unchanged by the swap. The values are bit for bit the same.

`timescale 1ns/1ps

module m2_geo_view #(
  parameter int CRTC_X = 0,
  parameter int CRTC_Y = 128,
  // R852: 1 = the offsets come from crtc_x / crtc_y, which the top level
  // latches from the game's writes to the tilemap chip's sync registers
  // (MAME horizontal_sync_w / vertical_sync_w: 84 + xhout, 130 + xvout).
  // Virtua Fighter 2 sets y to 127 where Daytona sets 128: with the constant
  // its whole 3D sat one line low (geodiff, walk 1500: 467 of 523 polygons
  // off by 1.0-1.1 px in y). 0 keeps the constants, as the original core.
  parameter bit LIVE = 1'b0
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic signed [15:0] crtc_x,
  input  logic signed [15:0] crtc_y,
  input  logic [31:0] win_vp_s,     // {x[27:16], y[11:0]}, 12-bit signed
  input  logic [31:0] win_vp_e,
  input  logic [31:0] win_c0,
  output logic [31:0] xc, yc,
  output logic [31:0] a_left, a_right, a_bottom, a_top
);

  function automatic logic signed [15:0] s12(input logic [11:0] v);
    s12 = 16'(signed'(v));
  endfunction

  // A small signed integer to IEEE-754 single, exactly (|v| < 2^15).
  function automatic logic [31:0] i2f(input logic signed [15:0] v);
    logic        sg;
    logic [15:0] m;
    int          e;
    logic [31:0] f;
    begin
      sg = v[15];
      m  = sg ? 16'(-v) : 16'(v);
      e  = 0;
      for (int i = 0; i < 16; i++) if (m[i]) e = i;
      if (m == 16'd0) f = 32'd0;
      else            f = {sg, 8'(127 + e), 23'({m, 23'd0} >> e)};
      i2f = f;
    end
  endfunction
  // R740: i2f in two halves a stage apart -- the sign and magnitude, then the
  // encode and the shift (s788 at 80 MHz: ib -> a_top -0.395). The same float.
  function automatic logic [16:0] i2f_sm(input logic signed [15:0] v);
    i2f_sm = {v[15], v[15] ? 16'(-v) : 16'(v)};
  endfunction
  function automatic logic [31:0] i2f_pk(input logic [16:0] sm);
    logic [15:0] m;
    int          e;
    begin
      m = sm[15:0];
      e = 0;
      for (int i = 0; i < 16; i++) if (m[i]) e = i;
      i2f_pk = (m == 16'd0) ? 32'd0 : {sm[16], 8'(127 + e), 23'({m, 23'd0} >> e)};
    end
  endfunction

  wire signed [15:0] vx0 = s12(win_vp_s[27:16]), vy0 = s12(win_vp_s[11:0]);
  wire signed [15:0] vx1 = s12(win_vp_e[27:16]), vy1 = s12(win_vp_e[11:0]);
  wire signed [15:0] cx  = s12(win_c0[27:16]),   cy  = s12(win_c0[11:0]);

  // Bits 31:28 and 15:12 are outside the two twelve-bit fields (MAME masks
  // them: x = (w & 0x0fff0000) >> 4, y = w & 0xfff).
  wire _unused = &{1'b0, win_vp_s[31:28], win_vp_s[15:12], win_vp_e[31:28],
                   win_vp_e[15:12], win_c0[31:28], win_c0[15:12]};

  // R907: the slot in turn, 0..5 = xc, yc, a_left, a_right, a_bottom, a_top.
  logic [2:0] sl;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) sl <= 3'd0;
    else        sl <= (sl == 3'd5) ? 3'd0 : sl + 3'd1;
  end

  // Stage 1: the slot's integer, one subtractor (iv = p - q) for all six:
  //   xc = CRTC_X + cx          = cx - (-CRTC_X)
  //   yc = 384 - cy + CRTC_Y    = (384 + CRTC_Y) - cy
  //   -left = vx0 - cx   right = vx1 - cx   top = vy1 - cy   -bottom = vy0 - cy
  // (R740: a_left and a_top stored negated). 16-bit wrap as before.
  // R852 with R907: LIVE takes the offsets from crtc_x / crtc_y in the same
  // two forms -- cx - (-crtc_x), (384 + crtc_y) - cy -- equal to the
  // per-value adders before R907 modulo 2^16, as the constants are.
  localparam logic signed [15:0] XN = 16'(0 - CRTC_X);      // -CRTC_X
  localparam logic signed [15:0] YP = 16'(384 + CRTC_Y);    // 384 + CRTC_Y
  wire  signed [15:0] xn = LIVE ? 16'sd0 - crtc_x  : XN;
  wire  signed [15:0] yp = LIVE ? 16'sd384 + crtc_y : YP;
  logic signed [15:0] p, q;
  always_comb begin
    case (sl)
      3'd0:    begin p = cx;                        q = xn;  end
      3'd1:    begin p = yp;                        q = cy;  end
      3'd2:    begin p = vx0;                       q = cx;  end
      3'd3:    begin p = vx1;                       q = cx;  end
      3'd4:    begin p = vy1;                       q = cy;  end
      default: begin p = vy0;                       q = cy;  end
    endcase
  end

  logic signed [15:0] iv;
  logic         [2:0] t1, t2;
  logic        [16:0] sm;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      iv <= 16'sd0; t1 <= 3'd7; sm <= 17'd0; t2 <= 3'd7;   // 7: no slot
    end else begin
      iv <= p - q;            t1 <= sl;
      sm <= i2f_sm(iv);       t2 <= t1;    // R740: stage 1b, sign and magnitude
    end
  end

  // Stage 2: to float, into the slot's own register. Reset to R174's
  // constants, which the power-up window (m2_geo's reset words) also produces.
  wire [31:0] fv = i2f_pk(sm);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      xc <= 32'h4378_0000; yc <= 32'h4340_0000;             // 248, 192
      a_left <= 32'hC378_0000; a_right <= 32'h4378_0000;    // -248, +248
      a_bottom <= 32'h4340_0000; a_top <= 32'hC340_0000;    // +192, -192
    end else begin
      case (t2)
        3'd0: xc       <= fv;
        3'd1: yc       <= fv;
        3'd2: a_left   <= fv;   // = i2f(-left)
        3'd3: a_right  <= fv;
        3'd4: a_bottom <= fv;
        3'd5: a_top    <= fv;   // = i2f(-bottom)
        default: ;
      endcase
    end
  end

endmodule
