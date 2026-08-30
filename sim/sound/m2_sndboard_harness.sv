// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// The sound board with its ROM answered by the testbench, so the 68000 can be
// run against MAME's own instruction stream before the SDRAM arbiter grows a
// sixth port. The ROM port is exposed rather than filled in here: a harness
// that answered instantly would hide every DTACK stall the real fetch has.

`timescale 1ns/1ps

module m2_sndboard_harness #(
  parameter int unsigned ROM_LAT = 6      // clk_sys cycles, ~ an SDRAM burst
) (
  input  logic        clk,
  input  logic        rst_n,

  // The testbench's view of the ROM port.
  output logic        rom_req,
  output logic [17:1] rom_addr,
  input  logic        rom_ack,
  input  logic [15:0] rom_data,

  // The link, so the board can be talked to.
  input  logic  [7:0] rx_data,
  input  logic        rx_valid,
  output logic        rx_ack,
  output logic  [7:0] tx_data,
  output logic        tx_valid,
  input  logic        tx_ack,

  output logic [31:0] dbg_pc,
  output logic [31:0] dbg_insns,
  output logic [15:0] dbg_ym_writes,
  output logic [15:0] dbg_pcm_writes,

  // Bus observation, so the testbench can follow instruction fetches without
  // reaching inside the CPU.
  output logic        pcm1_req, output logic [21:0] pcm1_addr,
  input  logic  [7:0] pcm1_data, input  logic        pcm1_ack,
  output logic        pcm2_req, output logic [21:0] pcm2_addr,
  input  logic  [7:0] pcm2_data, input  logic        pcm2_ack,

  output logic signed [15:0] snd_l,
  output logic signed [15:0] snd_r,

  output logic        obs_as,
  output logic [23:0] obs_addr,
  output logic        obs_we
);

  m2_sound_board u_board (
    .clk(clk), .rst_n(rst_n),
    .rx_data(rx_data), .rx_valid(rx_valid), .rx_ack(rx_ack),
    .tx_data(tx_data), .tx_valid(tx_valid), .tx_ack(tx_ack),
    .rom_req(rom_req), .rom_addr(rom_addr),
    .rom_ack(rom_ack), .rom_data(rom_data),
    .pcm1_rom_req(pcm1_req), .pcm1_rom_addr(pcm1_addr),
    .pcm1_rom_data(pcm1_data), .pcm1_rom_ack(pcm1_ack),
    .pcm2_rom_req(pcm2_req), .pcm2_rom_addr(pcm2_addr),
    .pcm2_rom_data(pcm2_data), .pcm2_rom_ack(pcm2_ack),
    .snd_l(snd_l), .snd_r(snd_r),
    .dbg_pc(dbg_pc), .dbg_insns(dbg_insns),
    .dbg_ym_writes(dbg_ym_writes), .dbg_pcm_writes(dbg_pcm_writes)
  );

  assign obs_as   = u_board.as;
  assign obs_addr = u_board.addr;
  assign obs_we   = u_board.we;

  wire _unused = &{1'b0, ROM_LAT, 1'b0};

endmodule
