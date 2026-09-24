// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// THE REAL CPU ON THE REAL MEMORY PATH.
//
// R527. Two changes to this path have now been correct in every bench and
// wrong on the board: R490's span overlap (seven simulated regimes clean, four
// hardware failures) and R523's posted writes (129 checks clean, black then
// locked up before the first frame). They share one gap. m2_cpu_sdram_harness
// drives the CPU side with a MODEL, and tb_i960_rom drives the real i960_top
// against a MODEL of memory; nothing has ever put the real CPU on the real
// bridge on the real controller.
//
// The model in tb_m2_cpu_bridge drops bus_req after every acknowledge. The real
// CPU holds it across a run of accesses, moves the address ON the acknowledge,
// and -- the part no bench sees -- RELEASES ITS INTERNAL BUS GRANT on it, so
// another master (instruction fetch, register-frame spill) can take the bus in
// the next cycle. Posting moves that acknowledge ten cycles earlier. Whatever
// that does, this is the harness that can show it.
//
// It is a wrapper, not a rewrite: i960_top drives the bus_* ports that
// m2_cpu_sdram_harness already exposes, and everything that composition test
// established -- ROM mirror, competing traffic ports, the preload path -- is
// reused unchanged. The CPU has its OWN reset so it can be held while the
// controller initialises and the ROM is loaded through wr_*.

`timescale 1ns/1ps

module m2_cpu_real_harness #(
  parameter int unsigned COL_BITS      = 10,
  parameter bit          DCACHE_EN_TOP = 1'b1
) (
  input  logic        clk_cpu,
  input  logic        clk_mem,
  input  logic        rst_n,          // memory side
  input  logic        cpu_rst_n,      // the CPU, released after preload

  // Preload, as m2_cpu_sdram_harness has it: the ROM goes in the way the
  // loader puts it there.
  input  logic        wr_req,
  input  logic [COL_BITS+14:1] wr_addr,
  input  logic [15:0] wr_din,
  output logic        wr_ack,
  output logic        mem_ready,

  // What the bench watches. The CPU's own view of its progress, and the bus
  // it is driving -- so a wedge can be attributed to one side or the other.
  output logic [31:0] dbg_pc,
  output logic [31:0] dbg_ip,
  output logic [31:0] dbg_acc_cnt,
  output logic        trap,
  output logic        halted,
  output logic        bus_req,
  output logic        bus_we,
  output logic        bus_ack,
  output logic [31:0] bus_addr,
  output logic [31:0] bus_rdata,     // for the bench's bus trace
  output logic [31:0] bus_wdata,     // R532: for the copy checksum

  // R529: competing traffic on the controller's other ports, driven by the
  // bench the way tb_m2_cpu_sdram drives them.
  input  logic        p2_req,
  input  logic [COL_BITS+14:1] p2_addr,
  output logic        p2_ack,
  input  logic        p3_req,
  input  logic [COL_BITS+14:1] p3_addr,
  output logic        p3_ack,

  // R530: the bridge's I/O side and the CPU's interrupt lines, so the bench
  // can model the devices the boot code talks to.
  output logic        io_sel,
  output logic        io_we,
  output logic [31:0] io_addr,
  output logic [31:0] io_wdata,
  output logic  [3:0] io_be,
  input  logic [31:0] io_rdata,
  input  logic        io_stall,
  input  logic  [3:0] irq
);

  logic  [3:0] bus_be;

  i960_top u_cpu (
    .clk(clk_cpu), .rst_n(cpu_rst_n),
    .bus_req(bus_req), .bus_we(bus_we), .bus_addr(bus_addr), .bus_be(bus_be),
    .bus_wdata(bus_wdata), .bus_rdata(bus_rdata), .bus_ack(bus_ack),
    .irq(irq),
    .dbg_pc(dbg_pc), .dbg_ip(dbg_ip), .dbg_acc_cnt(dbg_acc_cnt),
    .trap(trap), .halted(halted),
    .dbg_sat(), .dbg_prcb(), .dbg_icr(), .dbg_intr_cnt(), .dbg_intr_work(),
    .dbg_insn(), .trap_op(), .dbg_rip(), .dbg_pfp(), .dbg_rcache_pos(),
    .dbg_to_memory(), .dbg_rf_req(), .dbg_rf_ack(), .dbg_rf_addr(),
    .dbg_rf_we(), .dbg_rf_wdata()
  );

  m2_cpu_sdram_harness #(.COL_BITS(COL_BITS), .DCACHE_EN_TOP(DCACHE_EN_TOP)) u_mem (
    .clk_cpu(clk_cpu), .clk_mem(clk_mem), .rst_n(rst_n),
    .bus_req(bus_req), .bus_we(bus_we), .bus_addr(bus_addr), .bus_be(bus_be),
    .bus_wdata(bus_wdata), .bus_rdata(bus_rdata), .bus_ack(bus_ack),
    .wr_req(wr_req), .wr_addr(wr_addr), .wr_din(wr_din), .wr_ack(wr_ack),
    .p2_req(p2_req), .p2_addr(p2_addr), .p2_ack(p2_ack), .p2_dout(),
    .p3_req(p3_req), .p3_addr(p3_addr), .p3_ack(p3_ack), .p3_dout(),
    .io_sel(io_sel), .io_we(io_we), .io_addr(io_addr), .io_wdata(io_wdata),
    .io_be(io_be), .io_rdata(io_rdata), .io_stall(io_stall),
    .mem_ready(mem_ready),
    .dbg_last_addr(), .dbg_last_dout(), .dbg_reads()
  );

endmodule
