// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// R908: m2_geo_view with R907's shared converter against the 2A branch's own
// m2_geo_view before it (75ee3a2: six converters, R852's LIVE offsets), both
// with LIVE as the 2A core builds them (Model2.sv u_geo_view). The Makefile
// takes the reference from git and renames it m2_geo_view_ref;
// tb_m2_geo_view_live.cpp drives both with the same inputs and compares.
`timescale 1ns/1ps
module m2_geo_view_live_miter (
  input  logic        clk,
  input  logic        rst_n,
  input  logic signed [15:0] crtc_x,
  input  logic signed [15:0] crtc_y,
  input  logic [31:0] win_vp_s,
  input  logic [31:0] win_vp_e,
  input  logic [31:0] win_c0,
  output logic [191:0] o_new,
  output logic [191:0] o_ref
);
  m2_geo_view #(.CRTC_X(0), .CRTC_Y(128), .LIVE(1'b1)) u_new (
    .clk(clk), .rst_n(rst_n), .crtc_x(crtc_x), .crtc_y(crtc_y),
    .win_vp_s(win_vp_s), .win_vp_e(win_vp_e), .win_c0(win_c0),
    .xc(o_new[31:0]), .yc(o_new[63:32]), .a_left(o_new[95:64]), .a_right(o_new[127:96]),
    .a_bottom(o_new[159:128]), .a_top(o_new[191:160]));
  m2_geo_view_ref #(.CRTC_X(0), .CRTC_Y(128), .LIVE(1'b1)) u_ref (
    .clk(clk), .rst_n(rst_n), .crtc_x(crtc_x), .crtc_y(crtc_y),
    .win_vp_s(win_vp_s), .win_vp_e(win_vp_e), .win_c0(win_c0),
    .xc(o_ref[31:0]), .yc(o_ref[63:32]), .a_left(o_ref[95:64]), .a_right(o_ref[127:96]),
    .a_bottom(o_ref[159:128]), .a_top(o_ref[191:160]));
endmodule
