// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R1046: THE COLOUR PATH'S SHADOWS FROM THE GAME ID AND THE CPU'S WRITES, as a 2B
// build forms them: the MRA's index-4 byte through m2b_gameid (RTL), Model2.sv's
// decodes of it (a2_big, is_orev, is_sgt, is_zerogun at M2A = C2 = B2 = 1, copied
// from Model2.sv), m2_luma_map (RTL, LSB 5, OREV, B2L) and Model2.sv's g_r3d_lut
// snoop (copied verbatim), into the three shadow memories as m2_span_tex writes
// them (lr_mem, pal_mem, xr / xg / xb). tb_m2_lut_snoop.cpp drives MAME's own
// stream of CPU writes, mapped as the 2B bridge maps them, and compares the
// shadows with the tables tb_m2_raster3d fills from MAME's final dumps (R1041's
// bench). Only the bench's frame of reference is a copy; the luma map and the ID
// register are the RTL.

module tb_m2_lut_snoop_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        id_we,
  input  logic [7:0]  id_din,
  input  logic        cpu_sd_req, cpu_sd_we, ack,
  input  logic [25:1] cpu_sd_addr,
  input  logic [15:0] cpu_sd_din,
  input  logic [11:0] rd_lr,      // the bench's read-back ports
  input  logic [9:0]  rd_pal,
  input  logic [12:0] rd_x,
  output logic [7:0]  q_lr,
  output logic [14:0] q_pal,
  output logic [7:0]  q_x,
  output logic [7:0]  game_q
);
  localparam int SDR_AW = 25, R3D_LSB = 5;
  localparam bit M2A = 1'b1, C2 = 1'b1, B2 = 1'b1;
  localparam logic [SDR_AW:1] GAME_PAL3D  = SDR_AW'(32'h1730000);
  localparam logic [SDR_AW:1] GAME_XLAT3D = SDR_AW'(32'h1731000);
  localparam logic [SDR_AW:1] GAME_LUMA   = SDR_AW'(32'h1860000);
  logic [7:0] game_id;
  m2b_gameid u_gameid (.clk(clk), .rst_n(rst_n), .we(id_we), .din(id_din), .game_id(game_id));
  assign game_q = game_id;
  // Model2.sv's decodes (B2 = C2 = M2A = 1)
  wire is_zerogun = M2A && (game_id[6:0] == 7'h12);
  wire is_hotd    = C2 && !B2 && (game_id[6:0] == 7'h17);
  wire is_orev    = C2 && (game_id[6:0] == 7'h1C);
  wire is_stcc    = C2 && !B2 && (game_id[6:0] == 7'h1D);
  wire is_wave    = C2 && !B2 && (game_id[6:0] == 7'h1E);
  wire is_wski    = C2 && !B2 && (game_id[6:0] == 7'h1F);
  wire is_bel     = C2 && !B2 && (game_id[6:0] == 7'h20);
  wire is_gunb    = B2 && (game_id[6:0] == 7'h25);
  wire is_indy    = B2 && (game_id[6:0] == 7'h26);
  wire is_sgt     = B2 && (game_id[6:0] == 7'h27);
  wire is_von     = B2 && (game_id[6:0] == 7'h28);
  wire is_fvip    = B2 && (game_id[6:0] == 7'h2A);
  wire is_schp    = B2 && (game_id[6:0] == 7'h2B);
  wire is_dybb    = B2 && (game_id[6:0] == 7'h2D);
  wire is_skis    = C2 && !B2 && (game_id[6:0] == 7'h21);
  wire is_tops    = C2 && !B2 && (game_id[6:0] == 7'h22);
  wire is_dc2c    = C2 && !B2 && (game_id[6:0] == 7'h23);
  wire is_ra2     = C2 && !B2 && (game_id[6:0] == 7'h24);
  wire is_2a1x    = M2A && (game_id[6:4] == 3'b001);
  logic a2_big;
  always_ff @(posedge clk)
    a2_big <= is_2a1x && ((game_id[3:0] == 4'h3) || (game_id[3:0] == 4'h4) || (game_id[3:0] == 4'h5)
                      || (game_id[3:0] == 4'h6) || (game_id[3:0] == 4'h8) || (game_id[3:0] == 4'hA)
                      || is_hotd || is_stcc) || is_wave || is_wski || is_bel
            || is_skis || is_tops || is_dc2c || is_ra2
            || is_gunb || is_indy || is_von || is_fvip || is_schp || is_dybb;
  // Model2.sv g_r3d_lut, verbatim but for p_ack[1] (ack) and the polygon side
  /* verilator lint_off UNUSEDSIGNAL */
  wire [R3D_LSB:0] q_ls;
  /* verilator lint_on UNUSEDSIGNAL */
  wire [R3D_LSB:0] w_ls;
  wire [SDR_AW:1] w_luma = cpu_sd_addr - GAME_LUMA;
  m2_luma_map #(.LSB(R3D_LSB), .OREV(C2), .B2L(B2)) u_lmap (.clk(clk), .game_id({game_id[5], game_id[3:0]}),
                      .big(a2_big | is_orev), .zg(is_zerogun), .sgt(is_sgt), .orev(is_orev),
                      .q_row(8'd0), .q_ls(q_ls), .w_row(w_luma[15:8]), .w_ls(w_ls));
  wire [SDR_AW:1] w_pal  = cpu_sd_addr - GAME_PAL3D;
  wire [SDR_AW:1] w_xlat = cpu_sd_addr - GAME_XLAT3D;
  wire            sd_wr  = cpu_sd_req && cpu_sd_we && ack;
  logic        r3d_lut_we;
  logic [1:0]  r3d_lut_sel;
  logic [12:0] r3d_lut_addr;
  logic [15:0] r3d_lut_data;
  always_ff @(posedge clk) begin
    r3d_lut_we   <= 1'b0;
    r3d_lut_data <= cpu_sd_din;
    if (sd_wr && w_luma < SDR_AW'(32'h8000) && w_ls[R3D_LSB]) begin
      r3d_lut_we <= 1'b1; r3d_lut_sel <= 2'd0; r3d_lut_addr <= 13'({w_ls[R3D_LSB-1:0], w_luma[7:1]});
    end
    if (sd_wr && w_pal < SDR_AW'(32'h400)) begin
      r3d_lut_we <= 1'b1; r3d_lut_sel <= 2'd1; r3d_lut_addr <= 13'(w_pal[10:1]);
    end
    if (sd_wr && w_xlat < SDR_AW'(32'h6000) && w_xlat[8:7] == 2'd0) begin
      r3d_lut_we <= 1'b1; r3d_lut_sel <= 2'd2;
      r3d_lut_addr <= {w_xlat[15:14], w_xlat[13:9], w_xlat[6:1]};
    end
  end
  // m2_span_tex's shadow writes (LSB 5)
  logic [7:0]  lr_mem [4096];
  logic [14:0] pal_mem [1024];
  logic [7:0]  x_mem [3][2048];
  always_ff @(posedge clk) begin
    if (r3d_lut_we && r3d_lut_sel == 2'd0) lr_mem [r3d_lut_addr[11:0]] <= r3d_lut_data[7:0];
    if (r3d_lut_we && r3d_lut_sel == 2'd1) pal_mem[r3d_lut_addr[9:0]] <= r3d_lut_data[14:0];
    if (r3d_lut_we && r3d_lut_sel == 2'd2 && r3d_lut_addr[12:11] != 2'd3) x_mem[r3d_lut_addr[12:11]][r3d_lut_addr[10:0]] <= r3d_lut_data[7:0];
  end
  assign q_lr = lr_mem[rd_lr];
  assign q_pal = pal_mem[rd_pal];
  assign q_x = (rd_x[12:11] == 2'd3) ? 8'd0 : x_mem[rd_x[12:11]][rd_x[10:0]];
endmodule
