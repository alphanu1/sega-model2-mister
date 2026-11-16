// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R1029: THE 2C TILEMAP PATH, OLD AGAINST NEW. Each side is m2_video, its
// glyph cache, its palette and its tile RAM wired as Model2.sv wires them
// (u_tilemap, u_char_cache, u_pal, u_tram, at the 2C build's parameters); the
// old side is the tree before R1029 (m2_video_old, m2_char_cache_old, one
// m2_tdp_ram2c for the palette), the new side R1029's (PAL_COPIES 4 into
// m2_tdp_ram2c_lanes, LANES 4). Both take the same inputs -- the CPU's
// writes to tile RAM and palette on clk_sys, the glyph port's answers, the
// invalidates, the pixel enable -- and the bench (tb_m2_vid2c_miter.cpp)
// compares every output of the two on every clk_mem edge, and the palette's
// CPU read data on every clk_sys edge.
`timescale 1ns/1ps
module m2_vid2c_miter #(
  parameter bit SIB = 1'b0     // both caches' SIBLING (the 2C build: 0)
) (
  input  logic        clk_mem,
  input  logic        clk_sys,
  input  logic        rst_n,
  input  logic        cc_rst_n,
  input  logic        ce_pix,
  input  logic  [1:0] gamma_sel,
  input  logic        interlace,
  input  logic        scr_flip,
  input  logic  [3:0] scr_tag,
  input  logic        scr_vtgl,
  input  logic  [3:0] scr_ttag,
  // CPU port (clk_sys): tile RAM, palette, xlat
  input  logic [14:0] oc_addr,
  input  logic [15:0] oc_din,
  input  logic        oc_tram_we,
  input  logic        oc_pal_we,
  input  logic        xlat_we,
  input  logic  [6:0] xlat_addr,
  input  logic  [7:0] xlat_din,
  // the glyph cache's invalidate (clk_mem)
  input  logic        inval,
  input  logic [12:0] inval_idx,
  // port 3, one model per side (the bench answers each)
  output logic        o_m_req,  n_m_req,
  output logic [17:0] o_m_addr, n_m_addr,
  input  logic        o_m_ack,  n_m_ack,
  input  logic [63:0] o_m_data, n_m_data,
  // observation
  output logic [129:0] o_obs, n_obs,
  output logic [15:0]  o_pal_cpu, n_pal_cpu,
  output logic         n_copies_ok
);
  // ------------------------------------------------------------------ old
  logic [14:0] o_tram_addr; logic [15:0] o_tram_q, o_tram_cpu;
  logic        o_creq, o_cack; logic [17:0] o_caddr; logic [31:0] o_cdata;
  logic [11:0] o_pal_addr; logic [15:0] o_pal_q;
  logic        o_cat1, o_hs, o_vs, o_hb, o_vb, o_irq, o_field;
  logic [7:0]  o_r, o_g, o_b, o_fetch;
  logic [15:0] o_ovr, o_ovrf;
  logic [9:0]  o_x, o_y;
  logic [31:0] o_hits, o_miss, o_fills;

  m2_tdp_ram2c #(.DW(16), .AW(15)) o_tram (
    .a_clk(clk_sys), .a_addr(oc_addr), .a_din(oc_din), .a_we(oc_tram_we), .a_q(o_tram_cpu),
    .b_clk(clk_mem), .b_addr(o_tram_addr), .b_q(o_tram_q));
  m2_tdp_ram2c #(.DW(16), .AW(13)) o_pal (
    .a_clk(clk_sys), .a_addr(oc_addr[12:0]), .a_din(oc_din), .a_we(oc_pal_we), .a_q(o_pal_cpu),
    .b_clk(clk_mem), .b_addr({1'b0, o_pal_addr}), .b_q(o_pal_q));
  m2_video_old #(.LB_RING(1'b1), .HSCR_FIX(1'b0), .SCR_SYNC(1'b1),
                 .SCR_STEP(1'b1), .SCR_DEPTH(2), .MASK_SKIP(1'b1)) o_vid (
    .clk(clk_mem), .ce_pix(ce_pix), .rst_n(rst_n), .gamma_sel(gamma_sel), .tile_mask(14'h3FFF),
    .xlat_clk(clk_sys), .xlat_we(xlat_we), .xlat_addr(xlat_addr), .xlat_din(xlat_din),
    .tram_addr(o_tram_addr), .tram_data(o_tram_q),
    .char_req(o_creq), .char_addr(o_caddr), .char_data(o_cdata), .char_ack(o_cack),
    .pal_addr(o_pal_addr), .pal_data(o_pal_q),
    .vid_cat1(o_cat1), .vid_r(o_r), .vid_g(o_g), .vid_b(o_b),
    .vid_hs(o_hs), .vid_vs(o_vs), .vid_hb(o_hb), .vid_vb(o_vb),
    .vblank_irq(o_irq), .dbg_fetches(o_fetch), .dbg_overruns(o_ovr),
    .dbg_hscr(), .dbg_vscr(), .dbg_ovr_frame(o_ovrf), .vid_x(o_x), .vid_y(o_y),
    .interlace(interlace), .ntsc_lines(1'b0), .vid_field(o_field),
    .mid_lines(1'b0), .narrow(1'b0), .dbg_layer_px(), .dbg_ctrl(), .dbg_layer_have(),
    .scr_flip(scr_flip), .scr_tag(scr_tag), .scr_vtgl(scr_vtgl), .scr_ttag(scr_ttag));
  m2_char_cache_old #(.IDX_BITS(13), .SIBLING(SIB)) o_cc (
    .clk(clk_mem), .rst_n(cc_rst_n), .v_req(o_creq), .v_addr(o_caddr),
    .v_ack(o_cack), .v_data(o_cdata), .m_req(o_m_req), .m_addr(o_m_addr),
    .m_ack(o_m_ack), .m_data(o_m_data), .inval(inval), .inval_idx(inval_idx),
    .dbg_hits(o_hits), .dbg_misses(o_miss), .dbg_fills(o_fills));

  // ------------------------------------------------------------------ new
  localparam int unsigned PL = 4;
  logic [14:0] n_tram_addr; logic [15:0] n_tram_q, n_tram_cpu;
  logic        n_creq, n_cack; logic [17:0] n_caddr; logic [31:0] n_cdata;
  logic [11:0] n_pal_addr; logic [PL*12-1:0] n_pal_c; logic [PL*13-1:0] n_pal_b; logic [15:0] n_pal_q;
  logic        n_cat1, n_hs, n_vs, n_hb, n_vb, n_irq, n_field;
  logic [7:0]  n_r, n_g, n_b, n_fetch;
  logic [15:0] n_ovr, n_ovrf;
  logic [9:0]  n_x, n_y;
  logic [31:0] n_hits, n_miss, n_fills;

  always_comb for (int l = 0; l < PL; l++) n_pal_b[l*13 +: 13] = {1'b0, n_pal_c[l*12 +: 12]};
  always_comb begin
    n_copies_ok = 1'b1;
    for (int l = 0; l < PL; l++) if (n_pal_c[l*12 +: 12] != n_pal_addr) n_copies_ok = 1'b0;
  end
  m2_tdp_ram2c #(.DW(16), .AW(15)) n_tram (
    .a_clk(clk_sys), .a_addr(oc_addr), .a_din(oc_din), .a_we(oc_tram_we), .a_q(n_tram_cpu),
    .b_clk(clk_mem), .b_addr(n_tram_addr), .b_q(n_tram_q));
  m2_tdp_ram2c_lanes #(.DW(16), .AW(13), .B_LANES(PL)) n_pal (
    .a_clk(clk_sys), .a_addr(oc_addr[12:0]), .a_din(oc_din), .a_we(oc_pal_we), .a_q(n_pal_cpu),
    .b_clk(clk_mem), .b_addr(n_pal_b), .b_q(n_pal_q));
  m2_video #(.LB_RING(1'b1), .HSCR_FIX(1'b0), .SCR_SYNC(1'b1),
             .SCR_STEP(1'b1), .SCR_DEPTH(2), .MASK_SKIP(1'b1), .PAL_COPIES(PL)) n_vid (
    .clk(clk_mem), .ce_pix(ce_pix), .rst_n(rst_n), .gamma_sel(gamma_sel), .tile_mask(14'h3FFF),
    .xlat_clk(clk_sys), .xlat_we(xlat_we), .xlat_addr(xlat_addr), .xlat_din(xlat_din),
    .tram_addr(n_tram_addr), .tram_data(n_tram_q),
    .char_req(n_creq), .char_addr(n_caddr), .char_data(n_cdata), .char_ack(n_cack),
    .pal_addr(n_pal_addr), .pal_addr_c(n_pal_c), .pal_data(n_pal_q),
    .vid_cat1(n_cat1), .vid_r(n_r), .vid_g(n_g), .vid_b(n_b),
    .vid_hs(n_hs), .vid_vs(n_vs), .vid_hb(n_hb), .vid_vb(n_vb),
    .vblank_irq(n_irq), .dbg_fetches(n_fetch), .dbg_overruns(n_ovr),
    .dbg_hscr(), .dbg_vscr(), .dbg_ovr_frame(n_ovrf), .vid_x(n_x), .vid_y(n_y),
    .interlace(interlace), .ntsc_lines(1'b0), .vid_field(n_field),
    .mid_lines(1'b0), .narrow(1'b0), .dbg_layer_px(), .dbg_ctrl(), .dbg_layer_have(),
    .scr_flip(scr_flip), .scr_tag(scr_tag), .scr_vtgl(scr_vtgl), .scr_ttag(scr_ttag));
  m2_char_cache #(.IDX_BITS(13), .SIBLING(SIB), .LANES(4)) n_cc (
    .clk(clk_mem), .rst_n(cc_rst_n), .v_req(n_creq), .v_addr(n_caddr),
    .v_ack(n_cack), .v_data(n_cdata), .m_req(n_m_req), .m_addr(n_m_addr),
    .m_ack(n_m_ack), .m_data(n_m_data), .inval(inval), .inval_idx(inval_idx),
    .dbg_hits(n_hits), .dbg_misses(n_miss), .dbg_fills(n_fills));

  // Everything either side shows, packed the same way. The palette's video
  // read data and its address are in it as well as the colour.
  assign o_obs = {o_r, o_g, o_b, o_cat1, o_hs, o_vs, o_hb, o_vb, o_irq, o_field,
                  o_pal_addr, o_pal_q, o_tram_addr, o_creq, o_cack, o_caddr,
                  o_cdata[15:0] ^ o_cdata[31:16], o_x, o_y};
  assign n_obs = {n_r, n_g, n_b, n_cat1, n_hs, n_vs, n_hb, n_vb, n_irq, n_field,
                  n_pal_addr, n_pal_q, n_tram_addr, n_creq, n_cack, n_caddr,
                  n_cdata[15:0] ^ n_cdata[31:16], n_x, n_y};

  // The rest compared here, on every clk_mem edge, and counted.
  logic [63:0] cyc, bad;
  always_ff @(posedge clk_mem) begin
    cyc <= cyc + 64'd1;
    if (rst_n && (o_cdata != n_cdata || o_ovr != n_ovr || o_ovrf != n_ovrf || o_fetch != n_fetch ||
                  o_hits != n_hits || o_miss != n_miss || o_fills != n_fills || o_tram_cpu != n_tram_cpu)) begin
      if (bad < 10) $display("m2_vid2c_miter: counters/data differ at clk_mem %0d", cyc);
      bad <= bad + 64'd1;
    end
  end
  initial begin cyc = 0; bad = 0; end
  final $display("m2_vid2c_miter: %0d clk_mem cycles, %0d internal differences", cyc, bad);

  /* verilator lint_off UNUSEDSIGNAL */
  wire unused = ^{o_irq, n_irq};
  /* verilator lint_on UNUSEDSIGNAL */
endmodule
