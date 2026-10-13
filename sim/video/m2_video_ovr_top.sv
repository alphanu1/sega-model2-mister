// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R823: TWO TILEMAP PATHS SIDE BY SIDE, each m2_video + m2_char_cache as
// Model2.sv wires them, each cache's port 3 served by the bench. `r` is the
// shipped configuration (two-bank swap, sibling fill); `d` takes LBR / SIB.
// Same tile RAM image, same clock, same pixel enable: when neither path
// overruns in a frame, every visible pixel's palette index must agree.
`timescale 1ns/1ps
module m2_video_ovr_top #(
  parameter bit LBR = 1'b1,      // d: m2_video LB_RING
  parameter bit SIB = 1'b1       // d: m2_char_cache SIBLING
) (
  input  logic        clk,
  input  logic        ce_pix,
  input  logic        rst_n,
  input  logic        interlace,
  input  logic        ntsc_lines,   // R824: 262.5-line fields when interlaced
  // tile RAM, one read port per path (registered by the bench)
  output logic [14:0] r_tram_addr, d_tram_addr,
  input  logic [15:0] r_tram_data, d_tram_data,
  // port 3, per path
  output logic        r_m_req,  d_m_req,
  output logic [17:0] r_m_addr, d_m_addr,
  input  logic        r_m_ack,  d_m_ack,
  input  logic [63:0] r_m_data, d_m_data,
  // observation
  output logic [11:0] r_pal, d_pal,
  output logic [15:0] r_ovr, d_ovr,
  output logic [9:0]  hcnt, vcnt,
  output logic        vblank_start,
  output logic        r_creq, d_creq,
  // the glyph each cache handed its renderer, for a reference check
  output logic        r_vack, d_vack,
  output logic [17:0] r_vaddr, d_vaddr,
  output logic [31:0] r_vdata, d_vdata
);
  logic        r_req, d_req, r_ack, d_ack;
  logic [17:0] r_ca, d_ca;
  logic [31:0] r_cd, d_cd;
  logic [9:0]  d_hcnt, d_vcnt;

  m2_video u_r (
    .clk(clk), .ce_pix(ce_pix), .rst_n(rst_n), .tile_mask(14'h3fff),
    .gamma_sel(2'd0), .xlat_clk(clk), .xlat_we(1'b0), .xlat_addr(7'd0), .xlat_din(8'd0),
    .tram_addr(r_tram_addr), .tram_data(r_tram_data),
    .char_req(r_req), .char_addr(r_ca), .char_data(r_cd), .char_ack(r_ack),
    .pal_addr(r_pal), .pal_data(16'd0),
    .vid_cat1(), .vid_r(), .vid_g(), .vid_b(), .vid_hs(), .vid_vs(), .vid_hb(), .vid_vb(),
    .vblank_irq(vblank_start), .dbg_fetches(), .dbg_overruns(r_ovr), .dbg_ovr_frame(),
    .dbg_layer_px(), .dbg_ctrl(), .dbg_hscr(), .dbg_vscr(), .dbg_layer_have(),
    .vid_x(hcnt), .vid_y(vcnt), .interlace(interlace), .ntsc_lines(ntsc_lines), .vid_field()
  );
  m2_char_cache #(.IDX_BITS(13)) u_rc (
    .clk(clk), .rst_n(rst_n),
    .v_req(r_req), .v_addr(r_ca), .v_ack(r_ack), .v_data(r_cd),
    .m_req(r_m_req), .m_addr(r_m_addr), .m_ack(r_m_ack), .m_data(r_m_data),
    .inval(1'b0), .inval_idx(13'd0),
    .dbg_hits(), .dbg_misses(), .dbg_fills()
  );

  m2_video #(.LB_RING(LBR)) u_d (
    .clk(clk), .ce_pix(ce_pix), .rst_n(rst_n), .tile_mask(14'h3fff),
    .gamma_sel(2'd0), .xlat_clk(clk), .xlat_we(1'b0), .xlat_addr(7'd0), .xlat_din(8'd0),
    .tram_addr(d_tram_addr), .tram_data(d_tram_data),
    .char_req(d_req), .char_addr(d_ca), .char_data(d_cd), .char_ack(d_ack),
    .pal_addr(d_pal), .pal_data(16'd0),
    .vid_cat1(), .vid_r(), .vid_g(), .vid_b(), .vid_hs(), .vid_vs(), .vid_hb(), .vid_vb(),
    .vblank_irq(), .dbg_fetches(), .dbg_overruns(d_ovr), .dbg_ovr_frame(),
    .dbg_layer_px(), .dbg_ctrl(), .dbg_hscr(), .dbg_vscr(), .dbg_layer_have(),
    .vid_x(d_hcnt), .vid_y(d_vcnt), .interlace(interlace), .ntsc_lines(ntsc_lines), .vid_field()
  );
  m2_char_cache #(.IDX_BITS(13), .SIBLING(SIB)) u_dc (
    .clk(clk), .rst_n(rst_n),
    .v_req(d_req), .v_addr(d_ca), .v_ack(d_ack), .v_data(d_cd),
    .m_req(d_m_req), .m_addr(d_m_addr), .m_ack(d_m_ack), .m_data(d_m_data),
    .inval(1'b0), .inval_idx(13'd0),
    .dbg_hits(), .dbg_misses(), .dbg_fills()
  );

  assign r_vack = r_ack; assign r_vaddr = r_ca; assign r_vdata = r_cd;
  assign d_vack = d_ack; assign d_vaddr = d_ca; assign d_vdata = d_cd;
  assign r_creq = r_req;
  assign d_creq = d_req;
  /* verilator lint_off UNUSEDSIGNAL */
  wire unused = ^{d_hcnt, d_vcnt};
  /* verilator lint_on UNUSEDSIGNAL */
endmodule
