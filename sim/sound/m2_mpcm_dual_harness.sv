// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// THE SHARED MULTIPCM BESIDE THE TWO IT REPLACES, for tb_m2_mpcm_dual (R821).
//
// Two m2_multipcm (the reference) and one m2_multipcm_dual on one 68000 bus,
// each chip behind its own m2_pcm_fetch (the board's cached path), so the
// testbench sees four memory ports -- reference chip 0 and 1, shared chip 0
// and 1 -- and answers each with its own latency. Each engine has its own
// enable, so the testbench can stop each at the end of its own pass, write
// the registers due there, and start them again independently.

module m2_mpcm_dual_harness (
  input  logic        clk,
  input  logic        rst,

  input  logic        ce_r0, ce_r1, ce_d,
  input  logic        cs_r0, cs_r1, cs_d0, cs_d1,
  input  logic  [1:0] addr,
  input  logic  [7:0] wdata,
  input  logic  [1:0] bank0, bank1,

  // memory ports: 0 = ref chip 0, 1 = ref chip 1, 2 = dual chip 0, 3 = dual chip 1
  output logic  [3:0] m_req,
  output logic [21:3] m_addr0, m_addr1, m_addr2, m_addr3,
  input  logic [63:0] m_data0, m_data1, m_data2, m_data3,
  input  logic  [3:0] m_ack,

  output logic        stb_r0, stb_r1, stb_d,
  output logic signed [15:0] r0_l, r0_r, r1_l, r1_r,
  output logic signed [15:0] d0_l, d0_r, d1_l, d1_r,
  // the chip side of each fetcher, for the byte check
  output logic  [3:0] c_req, c_ack,
  output logic [21:0] c_addr0, c_addr1, c_addr2, c_addr3,
  output logic  [7:0] c_data0, c_data1, c_data2, c_data3,
  // Where each engine is, so the testbench can stop them at the same slot
  // for writes in the middle of a pass.
  output logic  [5:0] d_v,
  output logic  [2:0] d_tick,
  output logic  [1:0] d_busy,          // per chip: fetch, step issue or multiply in flight
  output logic        d_pm,
  output logic  [4:0] r0_slot, r1_slot,
  output logic  [2:0] r0_tick, r1_tick
);

  assign d_v     = u_d.v;
  assign d_tick  = u_d.tick;
  assign d_busy  = {u_d.rom_req1 | u_d.ac_v1 | (u_d.pv_we &  u_d.pv_v[0]),
                    u_d.rom_req0 | u_d.ac_v0 | (u_d.pv_we & ~u_d.pv_v[0])};
  assign d_pm    = u_d.pm_v;
  assign r0_slot = u_r0.slot;
  assign r1_slot = u_r1.slot;
  assign r0_tick = u_r0.tick;
  assign r1_tick = u_r1.tick;

  wire [4:0] sl0, sl1, sl2, sl3;
  wire [7:0] rd_nc0, rd_nc1;

  m2_multipcm u_r0 (
    .clk(clk), .ce(ce_r0), .rst(rst),
    .cs(cs_r0), .we(1'b1), .addr(addr), .wdata(wdata), .rdata(rd_nc0),
    .rom_req(c_req[0]), .rom_slot(sl0), .rom_addr(c_addr0),
    .rom_data(c_data0), .rom_ack(c_ack[0]),
    .bank_sel(bank0), .sample_stb(stb_r0), .out_l(r0_l), .out_r(r0_r)
  );
  m2_multipcm u_r1 (
    .clk(clk), .ce(ce_r1), .rst(rst),
    .cs(cs_r1), .we(1'b1), .addr(addr), .wdata(wdata), .rdata(rd_nc1),
    .rom_req(c_req[1]), .rom_slot(sl1), .rom_addr(c_addr1),
    .rom_data(c_data1), .rom_ack(c_ack[1]),
    .bank_sel(bank1), .sample_stb(stb_r1), .out_l(r1_l), .out_r(r1_r)
  );
  m2_multipcm_dual u_d (
    .clk(clk), .ce(ce_d), .rst(rst),
    .cs0(cs_d0), .cs1(cs_d1), .we(1'b1), .addr(addr), .wdata(wdata),
    .rom_req0(c_req[2]), .rom_slot0(sl2), .rom_addr0(c_addr2),
    .rom_data0(c_data2), .rom_ack0(c_ack[2]),
    .rom_req1(c_req[3]), .rom_slot1(sl3), .rom_addr1(c_addr3),
    .rom_data1(c_data3), .rom_ack1(c_ack[3]),
    .bank_sel0(bank0), .bank_sel1(bank1),
    .sample_stb(stb_d), .out0_l(d0_l), .out0_r(d0_r), .out1_l(d1_l), .out1_r(d1_r)
  );

  m2_pcm_fetch #(.BYPASS(1'b0)) u_f0 (.clk(clk), .rst_n(!rst),
    .c_req(c_req[0]), .c_slot(sl0), .c_addr(c_addr0), .c_ack(c_ack[0]), .c_data(c_data0),
    .m_req(m_req[0]), .m_addr(m_addr0), .m_ack(m_ack[0]), .m_data(m_data0),
    .dbg_mean_lat(), .dbg_miss_1k());
  m2_pcm_fetch #(.BYPASS(1'b0)) u_f1 (.clk(clk), .rst_n(!rst),
    .c_req(c_req[1]), .c_slot(sl1), .c_addr(c_addr1), .c_ack(c_ack[1]), .c_data(c_data1),
    .m_req(m_req[1]), .m_addr(m_addr1), .m_ack(m_ack[1]), .m_data(m_data1),
    .dbg_mean_lat(), .dbg_miss_1k());
  m2_pcm_fetch #(.BYPASS(1'b0)) u_f2 (.clk(clk), .rst_n(!rst),
    .c_req(c_req[2]), .c_slot(sl2), .c_addr(c_addr2), .c_ack(c_ack[2]), .c_data(c_data2),
    .m_req(m_req[2]), .m_addr(m_addr2), .m_ack(m_ack[2]), .m_data(m_data2),
    .dbg_mean_lat(), .dbg_miss_1k());
  m2_pcm_fetch #(.BYPASS(1'b0)) u_f3 (.clk(clk), .rst_n(!rst),
    .c_req(c_req[3]), .c_slot(sl3), .c_addr(c_addr3), .c_ack(c_ack[3]), .c_data(c_data3),
    .m_req(m_req[3]), .m_addr(m_addr3), .m_ack(m_ack[3]), .m_data(m_data3),
    .dbg_mean_lat(), .dbg_miss_1k());

  wire _unused = &{1'b0, rd_nc0, rd_nc1};

endmodule
