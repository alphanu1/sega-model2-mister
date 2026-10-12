// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// R817: THE INSTRUCTION-FETCH PATH, DRIVEN BY A RECORDED INSTRUCTION STREAM.
//
// The real CPU on the real memory path (m2_cpu_real_harness) can only run the
// boot: past it the game needs the TGP, the I/O board and the rest, and the
// full-system bench never leaves the settings screen (R733). The boot's loops
// fit any instruction cache, so it cannot say what game code costs.
//
// So this keeps every piece of the fetch path real -- i960_icache, i960_top's
// bus grant (copied below), m2_cpu_bridge with its clock crossing, the line
// buffer and the data cache, m2_sdram_cdc and m2_sdram on their own clocks --
// and replaces only the sequencer with tb_m2_ifetch_replay.cpp, which walks an
// instruction-address stream (MAME's trace of the game, or the real CPU's own
// retired stream) issuing fetches exactly as i960_top's front end does, and
// load/store traffic on the shared bus. The sequencer model is checked against
// the real i960_top on the boot (the same stream through both).

`timescale 1ns/1ps

module m2_ifetch_replay_harness #(
  parameter int unsigned LINES    = 512,
  parameter bit          HUF      = 1'b1,
  parameter bit          ER       = 1'b0,
  parameter int unsigned COL_BITS = 10,
  parameter int unsigned XMODE    = 2
) (
  input  logic        clk_cpu,
  input  logic        clk_mem,
  input  logic        clk_sd,
  input  logic        rst_n,          // memory side
  input  logic        cpu_rst_n,      // cache, grant and bridge

  // the front end, as i960_top drives the cache
  input  logic        ic_req,
  input  logic [31:2] ic_addr,
  output logic [31:0] ic_data,
  output logic [31:2] ic_vaddr,
  output logic        ic_valid,
  output logic        ic_busy,

  // load/store traffic, as i960_lsu drives the bus: held until acknowledged
  input  logic        lsu_req,
  input  logic        lsu_we,
  input  logic [31:0] lsu_addr,
  input  logic  [3:0] lsu_be,
  output logic        lsu_ack,

  // preload and competing traffic, as m2_cpu_sdram_harness has them
  input  logic        wr_req,
  input  logic [COL_BITS+14:1] wr_addr,
  input  logic [15:0] wr_din,
  output logic        wr_ack,
  output logic        mem_ready,
  input  logic        p2_req,
  input  logic [COL_BITS+14:1] p2_addr,
  output logic        p2_ack,
  input  logic        p3_req,
  input  logic [COL_BITS+14:1] p3_addr,
  output logic        p3_ack,

  output logic [2:0]  dbg_gsel,
  output logic        dbg_bus_ack
);

  logic        ic_breq, ic_back;
  logic [31:0] ic_baddr;
  logic        bus_req, bus_we, bus_ack, bus_ifetch;
  logic [31:0] bus_addr, bus_rdata;

  i960_icache #(.LINES(LINES), .HUF(HUF), .ER(ER)) u_icache (
    .clk(clk_cpu), .rst_n(cpu_rst_n), .inval(1'b0),
    .req(ic_req), .req_demand(1'b1), .addr(ic_addr), .data(ic_data),
    .valid(ic_valid), .vaddr(ic_vaddr), .busy(ic_busy),
    .bus_req(ic_breq), .bus_addr(ic_baddr),
    .bus_rdata(bus_rdata), .bus_ack(ic_back)
  );

  // i960_top's grant, verbatim for the two masters that matter here.
  localparam logic [2:0] G_NONE = 3'd0, G_LSU = 3'd3, G_IC = 3'd4;
  logic [2:0] sel_next, grant_q, gsel;
  always_comb begin
    if      (lsu_req) sel_next = G_LSU;
    else if (ic_breq) sel_next = G_IC;
    else              sel_next = G_NONE;
  end
  always_ff @(posedge clk_cpu or negedge cpu_rst_n) begin
    if (!cpu_rst_n)             grant_q <= G_NONE;
    else if (grant_q == G_NONE) grant_q <= bus_ack ? G_NONE : sel_next;
    else if (bus_ack)           grant_q <= G_NONE;
  end
  assign gsel       = (grant_q != G_NONE) ? grant_q : sel_next;
  assign bus_ifetch = (gsel == G_IC);
  assign bus_req    = (gsel != G_NONE);
  assign bus_we     = (gsel == G_LSU) && lsu_we;
  assign bus_addr   = (gsel == G_LSU) ? lsu_addr : (gsel == G_IC) ? ic_baddr : 32'd0;
  assign ic_back    = (gsel == G_IC)  && bus_ack;
  assign lsu_ack    = (gsel == G_LSU) && bus_ack;
  assign dbg_gsel   = gsel;
  assign dbg_bus_ack = bus_ack;

  m2_cpu_sdram_harness #(.COL_BITS(COL_BITS), .DCACHE_EN_TOP(1'b1),
                         .BR_OWN_RST(1'b1), .XMODE(XMODE), .CPU_ASYNC(1'b0)) u_mem (
    .clk_cpu(clk_cpu), .clk_mem(clk_mem), .clk_sd(clk_sd), .rst_n(rst_n), .br_rst_n(cpu_rst_n),
    .bus_req(bus_req), .bus_ifetch(bus_ifetch), .bus_we(bus_we), .bus_addr(bus_addr), .bus_be((gsel == G_LSU) ? lsu_be : 4'b1111),
    .bus_wdata(32'h0), .bus_rdata(bus_rdata), .bus_ack(bus_ack),
    .wr_req(wr_req), .wr_addr(wr_addr), .wr_din(wr_din), .wr_ack(wr_ack),
    .p2_req(p2_req), .p2_addr(p2_addr), .p2_ack(p2_ack), .p2_dout(),
    .p3_req(p3_req), .p3_addr(p3_addr), .p3_ack(p3_ack), .p3_dout(),
    .io_sel(), .io_we(), .io_addr(), .io_wdata(), .io_be(), .io_rdata(32'h0), .io_stall(1'b0),
    .mem_ready(mem_ready),
    .dbg_last_addr(), .dbg_last_dout(), .dbg_reads()
  );

endmodule
