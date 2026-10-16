// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// One m2_multipcm, alone, for tb_m2_mpcm_level (R819). The chip's register
// port and its sample-ROM port come straight out; the testbench is the 68000
// and the ROM. The enable is held high: the level of a voice does not depend
// on the rate the chip is clocked at, and a free-running chip gets through a
// level sweep and a MAME replay in minutes rather than hours.

module m2_mpcm_level_harness (
  input  logic        clk,
  input  logic        rst,
  input  logic        cs,
  input  logic  [1:0] addr,
  input  logic  [7:0] wdata,
  input  logic  [1:0] bank_sel,
  output logic        rom_req,
  output logic [21:0] rom_addr,
  input  logic  [7:0] rom_data,
  input  logic        rom_ack,
  output logic        sample_stb,
  output logic signed [15:0] out_l,
  output logic signed [15:0] out_r
);

  wire [7:0] rdata_nc;
  wire [4:0] slot_nc;

  m2_multipcm u_pcm (
    .clk(clk), .ce(1'b1), .rst(rst),
    .cs(cs), .we(1'b1), .addr(addr), .wdata(wdata), .rdata(rdata_nc),
    .rom_req(rom_req), .rom_slot(slot_nc), .rom_addr(rom_addr),
    .rom_data(rom_data), .rom_ack(rom_ack),
    .bank_sel(bank_sel), .sample_stb(sample_stb),
    .out_l(out_l), .out_r(out_r)
  );

  wire _unused = &{1'b0, rdata_nc, slot_nc};

endmodule
