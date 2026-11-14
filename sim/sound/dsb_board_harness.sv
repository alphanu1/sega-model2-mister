// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// dsb_board as the core instantiates it, with its internals brought out for
// tb_dsb_board: the Z80's port accesses, the decoded samples, the T clock.
// From the Sega Model 1 core (sega-model1-mister 2657c46); the board's
// parameters come in from the Verilator line (-G), so the same harness runs
// the STCC configuration and a Star Wars one.
`timescale 1ns/1ps
module dsb_board_harness #(
  parameter int unsigned AW = 26,
  parameter logic [AW:1] ROM_BASE  = AW'(32'h3400000),
  parameter logic [AW:1] MPEG_BASE = AW'(32'h3000000),
  parameter logic [AW:1] RAM_BASE  = AW'(32'h3410000),
  parameter int unsigned MAW = 22,
  parameter logic [15:0] CODE_BASE = 16'h0380,
  parameter int unsigned CODE_LEN  = 768,
  parameter logic [15:0] VAR_BASE  = 16'h9000,
  parameter logic [15:0] STK_BASE  = 16'hff80,
  parameter bit FIFO_MLAB = 1'b0,
  parameter bit WRAM_MLAB = 1'b0,
  parameter int unsigned T_DEN = 20,
  parameter int unsigned TICK_DEN = 10000
) (
  input  logic        clk, rst_n,
  input  logic        rx_tog,
  input  logic  [7:0] rx_byte,
  input  logic        vol_mame,
  output logic        s_req, s_we,
  output logic [AW:1] s_addr,
  output logic [15:0] s_din,
  output logic  [1:0] s_be,
  input  logic        s_ack,
  input  logic [15:0] s_dout,
  output logic signed [15:0] out_l, out_r,
  output logic        out_stb, trap,
  output logic        io_wr, io_rd, tick,
  output logic  [7:0] io_addr, io_data,
  output logic        smp_stb,
  output logic [31:0] smp_lr,
  output logic        out_src,
  output logic        z_req, z_chip,
  output logic [15:0] z_addr
);
  dsb_board #(.AW(AW), .ROM_BASE(ROM_BASE), .MPEG_BASE(MPEG_BASE), .RAM_BASE(RAM_BASE), .MAW(MAW),
              .CODE_BASE(CODE_BASE), .CODE_LEN(CODE_LEN), .VAR_BASE(VAR_BASE), .STK_BASE(STK_BASE),
              .FIFO_MLAB(FIFO_MLAB), .WRAM_MLAB(WRAM_MLAB), .T_DEN(T_DEN), .TICK_DEN(TICK_DEN)) u (
    .clk, .rst_n, .rx_tog, .rx_byte, .vol_mame, .s_req, .s_we, .s_addr, .s_din, .s_be,
    .s_ack, .s_dout, .out_l, .out_r, .out_stb, .dbg_trap(trap), .dbg_frames());
  assign io_wr = u.io_wr, io_rd = u.io_rd, tick = u.tick, io_addr = u.io_addr;
  assign io_data = u.io_wr ? u.io_wdata : u.io_rdata;
  assign smp_stb = u.u_mpeg.smp_stb, smp_lr = u.u_mpeg.smp_lr, out_src = u.u_mpeg.out_src;
  assign z_req = u.z_req && u.pre_done && !u.z_ack_r, z_chip = u.z_chip, z_addr = u.z_addr;
endmodule
