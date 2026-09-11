// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// The CPU bridge against the REAL SDRAM controller and a device model.
//
// WHY THIS EXISTS. m2_cpu_bridge passes its own testbench and m2_sdram passes
// its own, and on hardware the CPU reads zero from a ROM that is demonstrably
// loaded. The two have never been tested TOGETHER: the bridge's testbench talks
// to a hand-written model of the controller, and a hand-written model is a
// second opinion about the controller written by whoever wrote the code that
// talks to it. It agreed with the bridge, twice, about things the controller
// does differently -- a one-cycle acknowledge (study R32) and now something
// else.
//
// The composition is the thing that ships, so the composition is what this
// tests. Both clocks are real: 25 MHz for the CPU side, 40 MHz for memory.

`timescale 1ns/1ps

module m2_cpu_sdram_harness #(
  parameter int unsigned COL_BITS = 10,
  // The capture depth the controller uses. Model2.sv drives this from the
  // OSD and its DEFAULT IS 0, which maps to CL+1. m2_sdram's own harness
  // hardcodes 3 -- CL+3 -- so the setting the core actually ships with has
  // never been tested by the controller's own suite.
  // Defaults to 3 so the suite runs at the depth m2_sdram's own harness uses.
  // Sweep it with -GRD_LAT_SEL: in THIS MODEL only 3 works, and the core
  // ships with 0. That disagreement is a finding about the model as much as
  // about the core -- on hardware, changing the OSD setting does NOT fix the
  // CPU's reads, so the model and the board do not agree here and the
  // simulation must not be trusted to pick the value.
  parameter logic [2:0] RD_LAT_SEL = 3'd3,
  // Passed through so the composition can be run with the cache OUT of the
  // path. With it in, every SDRAM read takes the cached route and the plain
  // read path is dead code -- which is how it bit-rotted unnoticed until a
  // hardware build ran it (black screen, boot record read as FFFFFFFF).
  parameter bit DCACHE_EN_TOP = 1'b1
) (
  input  logic        clk_cpu,
  input  logic        clk_mem,
  input  logic        rst_n,

  // The CPU side, driven exactly as i960_top drives it.
  input  logic        bus_req,
  input  logic        bus_we,
  input  logic [31:0] bus_addr,
  input  logic  [3:0] bus_be,
  input  logic [31:0] bus_wdata,
  output logic [31:0] bus_rdata,
  output logic        bus_ack,

  // Preload path, so the ROM can be put in the device model the way the loader
  // puts it there rather than by poking arrays.
  input  logic        wr_req,
  input  logic [COL_BITS+14:1] wr_addr,
  input  logic [15:0] wr_din,
  output logic        wr_ack,

  // COMPETING TRAFFIC. On the board ports 2 and 3 are never idle: the SDRAM
  // self-test loops forever and the character fetch runs every line. The CPU is
  // the only port this harness drove, and tb_m2_sdram.cpp's own header says why
  // that is not enough -- "a controller that delivers p2's data to p1 passes
  // every single-port test".
  input  logic        p2_req,
  input  logic [COL_BITS+14:1] p2_addr,
  output logic        p2_ack,
  output logic [63:0] p2_dout,
  input  logic        p3_req,
  input  logic [COL_BITS+14:1] p3_addr,
  output logic        p3_ack,
  output logic [63:0] p3_dout,

  output logic        mem_ready,
  output logic [31:0] dbg_last_addr,
  output logic [31:0] dbg_last_dout,
  output logic [31:0] dbg_reads
);

  localparam int unsigned AW = 2 + 13 + COL_BITS;

  logic [4:0]         p_req, p_we, p_ack;
  logic [4:0][AW:1]   p_addr;
  logic [4:0][15:0]   p_din;
  logic [4:0][1:0]    p_be;
  logic [4:0][63:0]   p_dout;

  logic        sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n, sd_dq_oe;
  logic [1:0]  sd_ba, sd_dqm;
  logic [12:0] sd_a;
  logic [15:0] sd_dq_o, sd_dq_i;

  logic        b_req, b_we;
  logic [AW:1] b_addr;
  logic [15:0] b_din;
  logic  [1:0] b_be;

  m2_cpu_bridge #(.AW(AW), .BOARD_2A(1'b0), .DCACHE_EN(DCACHE_EN_TOP)) u_bridge (
    .io_stall(1'b0),   // no stalling peripheral in this harness
    .dbg_dc_hits(), .dbg_dc_miss(),
    .char_wr(), .char_wr_addr(),
    .clk_cpu(clk_cpu), .rst_n_cpu(rst_n),
    .bus_req(bus_req), .bus_we(bus_we), .bus_addr(bus_addr), .bus_be(bus_be),
    .bus_wdata(bus_wdata), .bus_rdata(bus_rdata), .bus_ack(bus_ack),

    .clk_mem(clk_mem), .rst_n_mem(rst_n),
    // The game map, same bases Model2.sv uses.
    .base_prog(AW'(32'h0000000)), .base_data(AW'(32'h0020000)),
    .base_work(AW'(32'h1600000)), .base_board(AW'(32'h1680000)),
    .base_char(AW'(32'h1690000)),
    .base_pal3d(AW'(32'h1730000)), .base_xlat3d(AW'(32'h1731000)), .col_inval(),

    .sd_req(b_req), .sd_we(b_we), .sd_addr(b_addr), .sd_din(b_din), .sd_be(b_be),
    .sd_dout(p_dout[0]), .sd_ack(p_ack[0]),

    .oc_tram_we(), .oc_pal_we(), .oc_addr(), .oc_din(),
    .oc_tram_q(16'd0), .oc_pal_q(16'd0),
    .oc_xlat_we(), .oc_xlat_addr(), .oc_xlat_din(),
    .io_rdata(32'd0), .io_sel(), .io_we(), .io_addr(), .io_wdata(),
    .dbg_cpu_reads(dbg_reads), .dbg_cpu_writes(), .dbg_unmapped(),
    .dbg_last_addr(dbg_last_addr), .dbg_last_dout(dbg_last_dout)
  );

  // PORT 0, exactly as Model2.sv wires it.
  always_comb begin
    p_req = '0; p_we = '0; p_addr = '0; p_din = '0; p_be = '1;
    p_req[0]  = b_req;
    p_we[0]   = b_we;
    p_addr[0] = b_addr;
    p_din[0]  = b_din;
    p_be[0]   = b_be;
    p_req[2]  = p2_req;
    p_addr[2] = AW'(p2_addr);
    p_req[3]  = p3_req;
    p_addr[3] = AW'(p3_addr);
  end
  assign p2_ack = p_ack[2];
  assign p2_dout = p_dout[2];
  assign p3_ack = p_ack[3];
  assign p3_dout = p_dout[3];

  m2_sdram #(.COL_BITS(COL_BITS), .NP(5), .T_REFI(300)) u_sdram (
    .clk(clk_mem), .rst_n(rst_n), .ready(mem_ready),
    .rd_lat_sel(RD_LAT_SEL),
    .sd_cke(sd_cke), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n),
    .sd_we_n(sd_we_n), .sd_ba(sd_ba), .sd_a(sd_a), .sd_dqm(sd_dqm),
    .sd_dq_o(sd_dq_o), .sd_dq_oe(sd_dq_oe), .sd_dq_i(sd_dq_i),
    .wr_req(wr_req), .wr_addr(AW'(wr_addr)), .wr_din(wr_din), .wr_be(2'b11),
    .wr_ack(wr_ack),
    .p_req(p_req), .p_we(p_we), .p_addr(p_addr), .p_din(p_din), .p_be(p_be),
    .p_dout(p_dout), .p_ack(p_ack)
  );

  sdram_model #(.COL_BITS(COL_BITS)) u_model (
    .clk(clk_mem),
    .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n), .cas_n(sd_cas_n),
    .we_n(sd_we_n), .ba(sd_ba), .a(sd_a), .dqm(sd_dqm),
    .dq_i(sd_dq_o), .dq_oe_i(sd_dq_oe), .dq_o(sd_dq_i), .dq_oe_o(),
    .violations(), .v_flags(), .reads_served(), .writes_served()
  );

endmodule
