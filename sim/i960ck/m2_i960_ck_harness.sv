// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// R1011: THE i960 FROM A MAME CHECKPOINT, ON THE BOARD'S CPU PATH.
//
// i960_top as Model2.sv builds it for the 2A / 2C board (the ring of eight,
// the CPU-side data cache, the FP forms), m2_waitst when the game has it
// (Sega Rally), and m2_cpu_bridge with its two clocks (clk_cpu = clk_mem / 2,
// as clk_i960 = clk_sys / 2, R744). The bench (tb_i960_ck.cpp) answers the
// bridge's SDRAM port from a memory image taken from MAME at the checkpoint,
// its I/O port from MAME's own reads in order, and holds the tile RAM and
// palette here. Nothing else of the core is present: the i960's time here is
// its own, with every device answering at once.
//
// The SDRAM bases are the bench's own (one flat image), not Model2.sv's: the
// bridge's address arithmetic is base + offset, so only the decode matters.

`timescale 1ns/1ps

module m2_i960_ck_harness #(
  parameter bit          A2      = 1'b1,
  parameter bit          C2      = 1'b1,
  parameter bit          VC      = 1'b1,
  parameter bit          FR      = 1'b1,
  parameter bit          F2A     = 1'b1,
  parameter bit          RING    = 1'b1,
  parameter int unsigned FRAMES  = 8,
  parameter int unsigned DCL     = 64,
  parameter int unsigned ICL     = 512,
  parameter bit          WAITST  = 1'b0,
  // R1011's three timing changes, so one bench builds before and after
  parameter bit          IC_PAIR = 1'b1,
  parameter bit          LSU_ST1 = 1'b1,
  parameter bit          DC_ROMS = 1'b1,
  parameter bit          LSU_POST = 1'b1,
  parameter int unsigned AW      = 26
) (
  input  logic        clk_cpu,
  input  logic        clk_mem,
  input  logic        rst_n,
  input  logic        ws_en,
  input  logic  [3:0] irq,

  output logic        sd_req,
  output logic        sd_we,
  output logic [AW:1] sd_addr,
  output logic [15:0] sd_din,
  output logic  [1:0] sd_be,
  input  logic [63:0] sd_dout,
  input  logic        sd_ack,

  output logic        io_sel,
  output logic        io_we,
  output logic [31:0] io_addr,
  output logic [31:0] io_wdata,
  output logic  [3:0] io_be,
  input  logic [31:0] io_rdata,

  output logic [31:0] dbg_ip,
  output logic [31:0] dbg_acc_cnt,
  output logic [31:0] dbg_intr_cnt,
  output logic  [4:0] dbg_ts,
  output logic        trap,
  output logic  [7:0] trap_op,
  output logic        halted,
  output logic [31:0] dbg_icr,
  output logic        bus_req,
  output logic        bus_ifetch,
  output logic        bus_we,
  output logic        bus_ack,
  output logic [31:0] bus_addr
);

  logic        cpu_req, cpu_ack, b_req, b_ack;
  logic  [3:0] bus_be;
  logic [31:0] bus_wdata, cpu_rdata, b_rdata;

  i960_top #(.VC(VC), .FR(FR), .F2A(F2A), .C2(C2), .IC_LINES(ICL),
             .RC_RING(RING), .RC_FRAMES(FRAMES),
             .DC_LINES(DCL), .DC_2A(A2), .DC_LANES(1'b0),
             .IC_PAIR(IC_PAIR), .LSU_ST1(LSU_ST1), .DC_ROMS(DC_ROMS), .LSU_POST(LSU_POST)) u_cpu (
    .clk(clk_cpu), .rst_n(rst_n), .vc_en(VC || F2A || FR),
    .bus_req(cpu_req), .bus_ifetch(bus_ifetch), .bus_we(bus_we), .bus_addr(bus_addr), .bus_be(bus_be),
    .bus_wdata(bus_wdata), .bus_rdata(cpu_rdata), .bus_ack(cpu_ack),
    .irq(irq),
    .dbg_pc(), .dbg_sat(), .dbg_prcb(), .dbg_icr(dbg_icr),
    .dbg_intr_cnt(dbg_intr_cnt), .dbg_intr_work(), .dbg_acc_cnt(dbg_acc_cnt),
    .dbg_ip(dbg_ip), .dbg_insn(), .dbg_ts(dbg_ts),
    .trap(trap), .trap_op(trap_op), .halted(halted),
    .dbg_rip(), .dbg_pfp(), .dbg_rcache_pos(), .dbg_to_memory(),
    .dbg_rf_req(), .dbg_rf_ack(), .dbg_rf_addr(), .dbg_rf_we(), .dbg_rf_wdata()
  );
  assign bus_req = cpu_req;
  assign bus_ack = cpu_ack;

  generate if (WAITST) begin : g_ws
    m2_waitst u_waitst (
      .clk(clk_cpu), .rst_n(rst_n), .en(ws_en),
      .c_req(cpu_req), .c_we(bus_we), .c_addr(bus_addr), .c_be(bus_be), .c_wdata(bus_wdata),
      .c_rdata(cpu_rdata), .c_ack(cpu_ack),
      .b_req(b_req), .b_rdata(b_rdata), .b_ack(b_ack),
      .dbg_region(), .dbg_n()
    );
  end else begin : g_nows
    assign b_req = cpu_req; assign cpu_rdata = b_rdata; assign cpu_ack = b_ack;
  end endgenerate

  logic        oc_tram_we, oc_pal_we;
  logic [14:0] oc_addr;
  logic [15:0] oc_din, oc_tram_q, oc_pal_q;
  // The tile RAM and palette as M10K with a registered read (Model2.sv's).
  logic [15:0] tram [0:32767] /*verilator public*/;
  logic [15:0] pal  [0:32767] /*verilator public*/;
  always_ff @(posedge clk_mem) begin
    if (oc_tram_we) tram[oc_addr] <= oc_din;
    if (oc_pal_we)  pal[oc_addr]  <= oc_din;
    oc_tram_q <= tram[oc_addr];
    oc_pal_q  <= pal[oc_addr];
  end

  m2_cpu_bridge #(.AW(AW), .BOARD_2A(A2), .BOARD_2C(C2), .BUFFERRAM(1'b1), .BUFFERRAM_WRONLY(1'b0),
                  .DCACHE_EN(1'b1)) u_bridge (
    .dbg_dc_hits(), .dbg_dc_miss(),
    .char_wr(), .char_wr_addr(),
    .clk_cpu(clk_cpu), .rst_n_cpu(rst_n),
    .bus_req(b_req), .bus_ifetch(bus_ifetch), .bus_we(bus_we), .bus_addr(bus_addr), .bus_be(bus_be),
    .bus_wdata(bus_wdata), .bus_rdata(b_rdata), .bus_ack(b_ack),
    .clk_mem(clk_mem), .rst_n_mem(rst_n),
    .base_prog(AW'(32'h0000000)), .base_data(AW'(32'h1000000)), .base_work(AW'(32'h0200000)),
    .prog_ext(1'b0), .base_progx('0),
    .base_board(AW'(32'h0100000)), .base_char(AW'(32'h0300000)), .base_buffer(AW'(32'h0380000)),
    .base_pal3d(AW'(32'h03a0000)), .base_xlat3d(AW'(32'h03b0000)),
    .base_texs0(AW'(32'h0400000)), .base_texs1(AW'(32'h0480000)), .base_luma(AW'(32'h0500000)),
    .col_inval(), .buf_inval(), .tex_inval(),
    .sd_req(sd_req), .sd_we(sd_we), .sd_addr(sd_addr), .sd_din(sd_din), .sd_be(sd_be),
    .sd_dout(sd_dout), .sd_ack(sd_ack),
    .oc_tram_we(oc_tram_we), .oc_pal_we(oc_pal_we), .oc_addr(oc_addr), .oc_din(oc_din),
    .oc_tram_q(oc_tram_q), .oc_pal_q(oc_pal_q),
    .oc_xlat_we(), .oc_xlat_addr(), .oc_xlat_din(),
    .io_rdata(io_rdata), .io_sel(io_sel), .io_we(io_we), .io_stall(1'b0), .buf_wr_stall(1'b0),
    .io_addr(io_addr), .io_wdata(io_wdata), .io_be(io_be),
    .dbg_cpu_reads(), .dbg_cpu_writes(), .dbg_unmapped(),
    .dbg_last_addr(), .dbg_last_dout(), .dbg_probe6(), .dbg_probe2(),
    .dbg_tram_wr(), .dbg_pal_wr(), .dbg_mstate(), .dbg_sample()
  );

endmodule
