// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// The Z80 I/O board, standing alone: m2_ioz80 plus a bare 2 KB dual-port RAM
// with a spy port. What this exists to answer is not "does it work" but WHAT
// DOES THE FIRMWARE ACTUALLY DO -- every behaviour R37-R41 inferred from
// symptoms is now observable directly: when the status byte goes 0x40, what
// the flag does, whether the board writes the identity block (R41 said the
// CPU does -- now the firmware itself testifies), and what it computes into
// the credit fields.

`timescale 1ns/1ps

module m2_ioz80_harness #(
  // 25/50 = a 25 MHz Z80, the fast pacing tb_m2_ioz80 wants so the firmware's
  // multi-second delay loops finish inside a simulation.
  parameter int unsigned TICK_NUM = 25,
  parameter int unsigned TICK_DEN = 50
) (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        fw_we,
  input  logic [12:0] fw_addr,
  input  logic [15:0] fw_data,

  input  logic  [7:0] in0, in1, in2,
  // The board's own DIP banks, exposed so the multiplex can be tested rather
  // than assumed: the firmware selects between these and the cabinet inputs
  // with PA bit 0, and getting that backwards is what wrote the input-scan
  // pattern over the settings block.
  input  logic  [7:0] dsw1, dsw2, dsw3,
  input  logic  [7:0] adc0, adc1, adc2, adc3,

  // Game-side access (the tb plays the i960's role).
  input  logic        g_we,
  input  logic [10:0] g_addr,
  input  logic  [7:0] g_wdata,
  output logic  [7:0] g_rdata,

  // Spy: every Z80-side write, one cycle each.
  output logic  [7:0] spy_ee,
  output logic [15:0] spy_wrcnt,
  output logic        spy_wr,
  output logic  [7:0] spy_dout,
  output logic  [7:0] spy_di,
  output logic        spy_rd_end,
  output logic [15:0] spy_ra,
  output logic  [7:0] spy_rdat,
  output logic        spy_m1_n,
  output logic [15:0] spy_a,
  output logic        spy_we,
  output logic [10:0] spy_addr,
  output logic  [7:0] spy_data
);

  logic        z_we;
  logic [10:0] z_addr;
  logic  [7:0] z_wdata, z_rdata;

  logic [7:0] dp [2048];
  always_ff @(posedge clk) begin
    if (z_we) dp[z_addr] <= z_wdata;
    else if (g_we) dp[g_addr] <= g_wdata;   // Z80 wins ties, as in the core
    z_rdata <= dp[z_addr];
    g_rdata <= dp[g_addr];
  end

  assign spy_we   = z_we;
  assign spy_addr = z_addr;
  assign spy_data = z_wdata;

  m2_ioz80 #(.TICK_NUM(TICK_NUM), .TICK_DEN(TICK_DEN)) u_board (
    .clk(clk), .rst_n(rst_n),
    .fw_we(fw_we), .fw_addr(fw_addr), .fw_data(fw_data),
    .in0(in0), .in1(in1), .in2(in2), .dp_busy(1'b0),
    .dsw1(dsw1), .dsw2(dsw2), .dsw3(dsw3),
    .adc0(adc0), .adc1(adc1), .adc2(adc2), .adc3(adc3),
    .z_we(z_we), .z_addr(z_addr), .z_wdata(z_wdata), .z_rdata(z_rdata),
    .dbg_ee(spy_ee), .dbg_wrcnt(spy_wrcnt), .dbg_wr_stb(spy_wr), .dbg_dout(spy_dout), .dbg_di(spy_di),
    .dbg_rd_end(spy_rd_end), .dbg_ra(spy_ra), .dbg_rdat(spy_rdat), .dbg_m1_n(spy_m1_n), .dbg_a(spy_a),
    .dbg_last_wr(), .dbg_pf(), .dbg_pa(), .dbg_seccnt()
  );

endmodule
