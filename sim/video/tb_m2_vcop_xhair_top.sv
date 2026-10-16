// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// m2_vcop_xhair in the video path as Model2.sv has it (R846): clk_mem,
// ce_pix from the same accumulator and constants, the real m2_video_timing,
// vid_x_d held on ce_pix (R779). The picture fed in is the column / row /
// field it shows, so the C++ side can tell, at every ce_pix (where the
// framework samples), which pixel the colour belongs to and whether the cross
// is drawn on it.

`timescale 1ns/1ps

module tb_m2_vcop_xhair_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        il,             // 15 kHz interlaced (273/274, CEI) or 24 kHz
  input  logic  [1:0] on,
  input  logic  [1:0] size,
  input  logic  [8:0] c1x, c1y, c2x, c2y,
  output logic        ce,             // the framework samples here
  output logic  [7:0] r, g, b,        // what it samples
  output logic  [9:0] px,             // the picture's column, row and field at that sample
  output logic  [9:0] prow,
  output logic        pfield
);
  localparam int unsigned CE_NUM = 16,  CE_DEN = 100;    // Model2.sv
  localparam int unsigned CEI_NUM = 547, CEI_DEN = 5300;
  logic [19:0] ce_acc;
  logic        ce_pix;
  wire [19:0] ce_num = il ? 20'(CEI_NUM) : 20'(CE_NUM);
  wire [19:0] ce_den = il ? 20'(CEI_DEN) : 20'(CE_DEN);
  always_ff @(posedge clk) begin
    if (ce_acc >= ce_den) ce_acc <= 20'd0;   // as Model2.sv: no reset
    else if (ce_acc + ce_num >= ce_den) begin ce_acc <= ce_acc + ce_num - ce_den; ce_pix <= 1'b1; end
    else begin ce_acc <= ce_acc + ce_num; ce_pix <= 1'b0; end
  end

  logic [9:0] hcnt, vcnt;
  logic       field;
  /* verilator lint_off PINCONNECTEMPTY */
  m2_video_timing u_t (
    .clk(clk), .ce_pix(ce_pix), .rst_n(rst_n),
    .interlace(il), .ntsc_lines(1'b0), .mid_lines(1'b0), .narrow(1'b0),
    .hcnt(hcnt), .vcnt(vcnt), .hblank(), .vblank(), .hsync(), .vsync(), .visible(),
    .line_start(), .line_number(), .vblank_start(), .field(field), .ypos(), .vtotal()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  logic [9:0] vid_x_d;
  always_ff @(posedge clk) if (ce_pix) vid_x_d <= hcnt;   // Model2.sv R779

  // the picture: its own coordinates as the colour (column low byte; column
  // high bits and row low bits; row high bits and the field)
  wire [7:0] pr = vid_x_d[7:0];
  wire [7:0] pg = {vid_x_d[9:8], vcnt[5:0]};
  wire [7:0] pb = {3'd0, field, vcnt[9:6]};

  m2_vcop_xhair u_x (
    .clk(clk), .on(on), .size(size),
    .c1x(c1x), .c1y(c1y), .c2x(c2x), .c2y(c2y),
    .il(il), .vx(vid_x_d), .vy(vcnt),
    .in_r(pr), .in_g(pg), .in_b(pb),
    .out_r(r), .out_g(g), .out_b(b)
  );

  // the pixel the output register holds: the picture, registered alongside
  logic [9:0] qx, qrow;
  logic       qf;
  always_ff @(posedge clk) begin qx <= vid_x_d; qrow <= vcnt; qf <= field; end
  assign ce = ce_pix;
  assign px = qx; assign prow = qrow; assign pfield = qf;
endmodule
