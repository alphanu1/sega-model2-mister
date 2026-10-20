// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// R907: the colour translation table split into three MLAB arrays, against
// m2_video as it was at 2cebd70 (one 96-entry array, renamed m2_video_ref by
// the Makefile from git). Both get the same clocks, the same tile, glyph and
// palette memories (each answering its own instance's addresses) and the same
// table writes on their own clock; tb_m2_video_xlat.cpp compares the picture.
`timescale 1ns/1ps
module m2_video_xlat_miter (
  input  logic        clk,
  input  logic        xlat_clk,
  input  logic        ce_pix,
  input  logic        rst_n,
  input  logic  [1:0] gamma_sel,
  input  logic        xlat_we,
  input  logic  [6:0] xlat_addr,
  input  logic  [7:0] xlat_din,
  input  logic [31:0] seed,
  output logic [31:0] px_new,
  output logic [31:0] px_ref,
  output logic [11:0] pal_new,
  output logic [11:0] pal_ref
);
  function automatic logic [31:0] h(input logic [31:0] x);
    logic [31:0] v;
    v = (x ^ seed) * 32'h9E3779B1;
    return v ^ (v >> 15);
  endfunction

  logic [14:0] ta_n, ta_r;
  logic [17:0] ca_n, ca_r;
  logic        cr_n, cr_r;
  logic [11:0] pa_n, pa_r;
  logic [15:0] td_n, td_r, pd_n, pd_r;
  logic [31:0] cd_n, cd_r;
  logic        ck_n, ck_r;
  logic  [7:0] r_n, g_n, b_n, r_r, g_r, b_r;
  logic        hs_n, vs_n, hb_n, vb_n, hs_r, vs_r, hb_r, vb_r;

  // Registered reads, as Model2.sv's memories; the glyph answers a cycle on.
  always_ff @(posedge clk) begin
    td_n <= h({17'd1, ta_n}) [15:0];  td_r <= h({17'd1, ta_r}) [15:0];
    pd_n <= h({20'd2, pa_n}) [15:0];  pd_r <= h({20'd2, pa_r}) [15:0];
    cd_n <= h({14'd3, ca_n});         cd_r <= h({14'd3, ca_r});
    ck_n <= cr_n && !ck_n;            ck_r <= cr_r && !ck_r;
  end

  m2_video #(.LB_RING(1'b1), .HSCR_FIX(1'b0), .SCR_SYNC(1'b1), .SCR_STEP(1'b1), .SCR_DEPTH(2)) u_new (
    .clk(clk), .ce_pix(ce_pix), .rst_n(rst_n), .tile_mask(14'h3fff), .gamma_sel(gamma_sel),
    .xlat_clk(xlat_clk), .xlat_we(xlat_we), .xlat_addr(xlat_addr), .xlat_din(xlat_din),
    .tram_addr(ta_n), .tram_data(td_n), .char_req(cr_n), .char_addr(ca_n), .char_data(cd_n), .char_ack(ck_n),
    .pal_addr(pa_n), .pal_data(pd_n), .vid_cat1(), .vid_r(r_n), .vid_g(g_n), .vid_b(b_n),
    .vid_hs(hs_n), .vid_vs(vs_n), .vid_hb(hb_n), .vid_vb(vb_n), .vblank_irq(),
    .dbg_fetches(), .dbg_overruns(), .dbg_ovr_frame(), .dbg_layer_px(), .dbg_ctrl(), .dbg_hscr(), .dbg_vscr(),
    .dbg_layer_have(), .vid_x(), .vid_y(), .interlace(1'b0), .scr_flip(1'b0), .scr_tag(4'd0), .scr_vtgl(1'b0),
    .scr_ttag(4'd0), .ntsc_lines(1'b0), .mid_lines(1'b0), .narrow(1'b0), .vid_field());
  m2_video_ref #(.LB_RING(1'b1), .HSCR_FIX(1'b0), .SCR_SYNC(1'b1), .SCR_STEP(1'b1), .SCR_DEPTH(2)) u_ref (
    .clk(clk), .ce_pix(ce_pix), .rst_n(rst_n), .tile_mask(14'h3fff), .gamma_sel(gamma_sel),
    .xlat_clk(xlat_clk), .xlat_we(xlat_we), .xlat_addr(xlat_addr), .xlat_din(xlat_din),
    .tram_addr(ta_r), .tram_data(td_r), .char_req(cr_r), .char_addr(ca_r), .char_data(cd_r), .char_ack(ck_r),
    .pal_addr(pa_r), .pal_data(pd_r), .vid_cat1(), .vid_r(r_r), .vid_g(g_r), .vid_b(b_r),
    .vid_hs(hs_r), .vid_vs(vs_r), .vid_hb(hb_r), .vid_vb(vb_r), .vblank_irq(),
    .dbg_fetches(), .dbg_overruns(), .dbg_ovr_frame(), .dbg_layer_px(), .dbg_ctrl(), .dbg_hscr(), .dbg_vscr(),
    .dbg_layer_have(), .vid_x(), .vid_y(), .interlace(1'b0), .scr_flip(1'b0), .scr_tag(4'd0), .scr_vtgl(1'b0),
    .scr_ttag(4'd0), .ntsc_lines(1'b0), .mid_lines(1'b0), .narrow(1'b0), .vid_field());

  assign px_new  = {4'd0, hs_n, vs_n, hb_n, vb_n, r_n, g_n, b_n};
  assign px_ref  = {4'd0, hs_r, vs_r, hb_r, vb_r, r_r, g_r, b_r};
  assign pal_new = pa_n;
  assign pal_ref = pa_r;
endmodule
