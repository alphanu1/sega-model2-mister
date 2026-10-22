// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R929: THE PICTURE PATH AROUND m2_gun_flash, as Model2.sv wires it: m2_video
// with the core's parameters, tile RAM's read gated by the flash's kill, a
// stand-in 3D layer under the category-1 tiles (mix_r = r3d_hit && !cat1 ?
// 3D : tile), the flash's white over both, and the register the framework
// samples. FLASH = 0 is the core before R929 (no module, gf_r = mix_r).
// Tile RAM, char RAM and the palette are the C++ bench's (tb_m2_gunflash.cpp).
`timescale 1ns/1ps
module tb_m2_gunflash_top #(
  parameter bit FLASH = 1'b1
) (
  input  logic        clk,
  input  logic        ce_pix,
  input  logic        rst_n,
  input  logic        xlat_we,
  input  logic  [6:0] xlat_addr,
  input  logic  [7:0] xlat_din,
  output logic [14:0] tram_addr,
  input  logic [15:0] tram_q,          // the RAM's registered output for last cycle's tram_addr
  output logic        char_req,
  output logic [17:0] char_addr,
  input  logic [31:0] char_data,
  input  logic        char_ack,
  output logic [11:0] pal_addr,
  input  logic [15:0] pal_data,
  // the CPU's tile-RAM writes (the bench also applies them to its array)
  input  logic        cpu_tram_we,
  input  logic [14:0] cpu_tram_addr,
  input  logic [15:0] cpu_tram_din,
  input  logic  [1:0] trig_n,
  input  logic  [1:0] mode,
  input  logic        en,
  output logic  [7:0] o_r, o_g, o_b,
  output logic        o_hb, o_vb,
  output logic        o_white,
  output logic  [1:0] trig_game_n
);
  logic        gf_kill, gf_white;
  wire  [15:0] tram_data = gf_kill ? 16'h0000 : tram_q;
  logic        cat1, hb, vb;
  logic  [7:0] tr, tg, tb;
  logic  [9:0] vx, vy;
  /* verilator lint_off PINCONNECTEMPTY */
  m2_video #(.LB_RING(1'b1), .HSCR_FIX(1'b0), .SCR_SYNC(1'b1), .SCR_STEP(1'b1), .SCR_DEPTH(2)) u_video (
    .clk(clk), .ce_pix(ce_pix), .rst_n(rst_n), .tile_mask(14'h3FFF), .gamma_sel(2'd0),
    .xlat_clk(clk), .xlat_we(xlat_we), .xlat_addr(xlat_addr), .xlat_din(xlat_din),
    .tram_addr(tram_addr), .tram_data(tram_data),
    .char_req(char_req), .char_addr(char_addr), .char_data(char_data), .char_ack(char_ack),
    .pal_addr(pal_addr), .pal_data(pal_data),
    .vid_cat1(cat1), .vid_r(tr), .vid_g(tg), .vid_b(tb),
    .vid_hs(), .vid_vs(), .vid_hb(hb), .vid_vb(vb), .vblank_irq(),
    .dbg_fetches(), .dbg_overruns(), .dbg_ovr_frame(), .dbg_layer_px(), .dbg_ctrl(),
    .dbg_hscr(), .dbg_vscr(), .dbg_layer_have(),
    .vid_x(vx), .vid_y(vy), .interlace(1'b0),
    .scr_flip(1'b0), .scr_tag(4'd0), .scr_vtgl(1'b0), .scr_ttag(4'd0),
    .ntsc_lines(1'b0), .mid_lines(1'b0), .narrow(1'b0), .vid_field()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  // A stand-in 3D layer: a pattern over a window of the screen, so the flash
  // is seen to cover polygons as well as tiles (the game's own flash does, being
  // category 1).
  logic       r3d_hit;
  logic [7:0] r3d_r, r3d_g, r3d_b;
  always_ff @(posedge clk) begin
    r3d_hit <= (vx >= 10'd40) && (vx < 10'd456) && (vy >= 10'd30) && (vy < 10'd354);
    r3d_r   <= vx[7:0];
    r3d_g   <= vy[7:0];
    r3d_b   <= vx[7:0] ^ vy[7:0];
  end
  wire [7:0] mix_r = (r3d_hit && !cat1) ? r3d_r : tr;
  wire [7:0] mix_g = (r3d_hit && !cat1) ? r3d_g : tg;
  wire [7:0] mix_b = (r3d_hit && !cat1) ? r3d_b : tb;

  logic [7:0] gf_r, gf_g, gf_b;
  generate if (FLASH) begin : g_flash
    m2_gun_flash u_flash (
      .clk_sys(clk), .rst_sys_n(rst_n), .en(en), .mode(mode),
      .cpu_tram_we(cpu_tram_we), .cpu_tram_addr(cpu_tram_addr), .cpu_tram_din(cpu_tram_din),
      .trig_n(trig_n), .trig_game_n(trig_game_n),
      .clk(clk), .rst_n(rst_n), .vb(vb), .tram_addr(tram_addr),
      .kill(gf_kill), .white(gf_white)
    );
    assign gf_r = gf_white ? 8'hFF : mix_r;
    assign gf_g = gf_white ? 8'hFF : mix_g;
    assign gf_b = gf_white ? 8'hFF : mix_b;
  end else begin : g_noflash
    assign gf_kill = 1'b0; assign gf_white = 1'b0; assign trig_game_n = trig_n;
    assign gf_r = mix_r; assign gf_g = mix_g; assign gf_b = mix_b;
  end endgenerate

  // the register before the framework (Model2.sv mix_r_q)
  always_ff @(posedge clk) begin
    o_r <= gf_r; o_g <= gf_g; o_b <= gf_b;
  end
  assign o_hb = hb;
  assign o_vb = vb;
  assign o_white = gf_white;

  /* verilator lint_off UNUSEDSIGNAL */
  wire unused = |{vx[9:8], vy[9:8], cpu_tram_addr[0] & 1'b0};
  /* verilator lint_on UNUSEDSIGNAL */
endmodule
