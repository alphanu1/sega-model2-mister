// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// m2_scsp as the core will use it, for quartus_map's area figure (study
// R856): the bench-only outputs (raw mix, per-slot samples, counters) left
// unconnected so they are pruned, as they are in the core.
`timescale 1ns/1ps
module scsp_area_top (
  input  logic        clk, rst_n,
  input  logic        cpu_req, cpu_we,
  input  logic [11:1] cpu_addr,
  input  logic [15:0] cpu_din,
  input  logic  [1:0] cpu_be,
  output logic        cpu_ack,
  output logic [15:0] cpu_dout,
  output logic  [2:0] ipl,
  input  logic  [7:0] midi_data,
  input  logic        midi_valid,
  output logic        midi_ack,
  output logic  [7:0] mout_data,
  output logic        mout_valid,
  input  logic        mout_ack,
  output logic        sm_req,
  output logic [15:0] sm_line,
  input  logic        sm_ack,
  input  logic [63:0] sm_data,
  output logic        dm_req, dm_we,
  output logic [18:1] dm_addr,
  output logic [15:0] dm_wdata,
  input  logic        dm_ack,
  input  logic [63:0] dm_data,
  input  logic        snp,
  input  logic [18:1] snp_addr,
  input  logic        out_ready,
  output logic        out_valid,
  output logic signed [15:0] out_l, out_r,
  input  logic        tick44,
  input  logic  [5:0] tph,
  input  logic        cpu_tick,
  input  logic  [1:0] boost              // R894: the OSD's Direct boost (a live input, as in the core)
);
  m2_scsp u (
    .clk(clk), .rst_n(rst_n),
    .cpu_req(cpu_req), .cpu_we(cpu_we), .cpu_addr(cpu_addr), .cpu_din(cpu_din), .cpu_be(cpu_be),
    .cpu_ack(cpu_ack), .cpu_dout(cpu_dout), .ipl(ipl),
    .midi_data(midi_data), .midi_valid(midi_valid), .midi_ack(midi_ack),
    .mout_data(mout_data), .mout_valid(mout_valid), .mout_ack(mout_ack),
    .sm_req(sm_req), .sm_line(sm_line), .sm_ack(sm_ack), .sm_data(sm_data),
    .dm_req(dm_req), .dm_we(dm_we), .dm_addr(dm_addr), .dm_wdata(dm_wdata), .dm_ack(dm_ack), .dm_data(dm_data),
    .snp(snp), .snp_addr(snp_addr),
    .out_ready(out_ready), .out_valid(out_valid), .out_l_raw(), .out_r_raw(), .out_l(out_l), .out_r(out_r),
    .tick44(tick44), .tph(tph), .cpu_tick(cpu_tick), .tarc(1'b0), .boost(boost), .step_mode(1'b0), .step_go(1'b0), .quiet(),
    .dbg_slot_valid(), .dbg_slot(), .dbg_slot_smp(), .dbg_samples(), .dbg_miss()
  );
endmodule
