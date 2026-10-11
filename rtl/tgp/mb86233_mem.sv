// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE for the full text.
//
// Behaviour transcribed from MAME's Model 1 driver:
//
//   src/mame/sega/model1_m.cpp   (copro_data_map)
//   BSD-3-Clause / GPL-2.0 mixed — see THIRD-PARTY.md
//
// Fujitsu MB86233 "TGP" — data-space memory subsystem
//
// Both internal RAM banks plus the decode that routes everything else off-chip.
//
// THE MAP IS NARROWER THAN THIS REPO'S DOCS SAID. copro_data_map is:
//
//   0x0000-0x00ff  RAM bank 0, 256 words
//   0x0100         copro_fifo_in,  READ only, ONE address
//   0x0200-0x03ff  RAM bank 1, 512 words
//   0x0400         copro_fifo_out, WRITE only, ONE address
//
// docs/m0-mb86233-spike.md described this as "accesses to 0x100-0x1ff and
// 0x400+ route externally", which implied two external windows of 256 and
// 64K words. There is exactly one address at each end, one direction each.
// Everything else in the space is unmapped and reads as zero.
//
// The distinction matters for the +0x200 adder: an EA of 0x200 landing on the
// output FIFO is the documented trick (x1 = 0x200 plus the adder), and it works
// precisely because 0x400 is a single decoded address rather than a window that
// a stray address could fall into unnoticed.

`timescale 1ns/1ps

module mb86233_mem #(
  // R602: writes from their own, registered, address. Off, the module is as
  // it always was (its unit bench runs that way); mb86233_core turns it on.
  parameter bit SPLIT_WR = 1'b0
) (
  input  logic        clk,
  input  logic        rst_n,

  // Data-space port. Single cycle for RAM; external accesses assert ext_req
  // and the caller must hold the access until ext_ack.
  input  logic        req,
  input  logic        we,
  input  logic [16:0] addr,        // 17 bits: the +0x200 adder can reach 0x101ff
  input  logic [31:0] wdata,
  input  logic        wreq,        // R602, SPLIT_WR only: write wdata at waddr
  input  logic [16:0] waddr,
  output logic [31:0] rdata,
  output logic        stall,       // external access not yet satisfied

  // Off-chip side.
  output logic        ext_rd,      // read  0x0100 (input FIFO)
  output logic        ext_wr,      // write 0x0400 (output FIFO)
  output logic [31:0] ext_wdata,
  input  logic [31:0] ext_rdata,
  input  logic        ext_ack,

  // Decode visibility, for the core and for assertions.
  output logic        sel_ram0,
  output logic        sel_ram1,
  output logic        sel_fifo_in,
  output logic        sel_fifo_out,
  output logic        unmapped,
  // Does the microcode ever STORE to data RAM? `lab` reloads B from
  // ea_pre_1(r2)+0x200, which is ordinary RAM on Model 2, so if nothing is
  // written there B can only ever read zero -- which is exactly what happens.
  output logic [31:0] dbg_wr_n,
  output logic [16:0] dbg_wr_addr,
  output logic [31:0] dbg_wr_data
);

  // --------------------------------------------------------------- decode

  assign sel_ram0     = (addr <= 17'h000ff);
  assign sel_ram1     = (addr >= 17'h00200) && (addr <= 17'h003ff);
  // Single addresses, and direction-specific: 0x0100 has only a read handler
  // and 0x0400 only a write handler in copro_data_map. A write to 0x0100 or a
  // read from 0x0400 hits no handler at all.
  assign sel_fifo_in  = (addr == 17'h00100) && !we;
  assign sel_fifo_out = (addr == 17'h00400) &&  we;
  assign unmapped     = !(sel_ram0 | sel_ram1 | sel_fifo_in | sel_fifo_out);

  // ------------------------------------------------------------------ RAM
  //
  // Kept as two separate arrays rather than one 0x000-0x3ff block with a hole:
  // the banks are physically distinct on the die (the 86233 has "two normal
  // independent ram banks, one of 256 dwords and one of 512" per MAME's header)
  // and inferring them separately is what gets two M10K blocks instead of one
  // oversized one with 256 words of dead space.

  logic [31:0] ram0 [0:255];
  logic [31:0] ram1 [0:511];

  // Power-on contents are ZERO, and that is not a simulation convenience.
  // Cyclone V M10K blocks take their contents from the FPGA configuration
  // bitstream, so on real hardware these come up initialised. Leaving them
  // undefined in RTL makes simulation disagree with the device it models.
  //
  // This was found by lockstep: a generated program read address 0x6a before
  // ever writing it, the reference returned 0 from a zeroed array and the DUT
  // returned 0x26000000 from uninitialised memory. It looked exactly like a
  // transfer bug for several rounds of narrowing — the store path, the read
  // addresses and the write streams were all correct, because nothing had
  // been stored at all.
  integer ri;
  initial begin
    for (ri = 0; ri < 256; ri = ri + 1) ram0[ri] = 32'd0;
    for (ri = 0; ri < 512; ri = ri + 1) ram1[ri] = 32'd0;
  end

  logic [7:0] a0;
  logic [8:0] a1;
  assign a0 = addr[7:0];
  assign a1 = addr[8:0];          // 0x200-0x3ff, so bit 9 distinguishes, [8:0] indexes

  logic [31:0] ram0_q, ram1_q;

  // R602: WITH SPLIT_WR THE WRITE ENABLE IS DECODED FROM waddr, NOT addr.
  // addr is live from the core's address generator -- it has to be, the read
  // is registered inside the RAM -- and decoding the write enable from it put
  // the AGU, the +0x200 add and the address mux in front of every M10K write
  // enable (s329: state.S_LABB_W -> ram1 porta_we, -1.301 ns at 70 MHz).
  // The core writes only in S_DST_W, where the address is already a
  // register, so the write port takes that and the read port keeps addr.
  wire        w_ram0 = SPLIT_WR ? (wreq && (waddr <= 17'h000ff))
                                : (req && we && sel_ram0);
  wire        w_ram1 = SPLIT_WR ? (wreq && (waddr >= 17'h00200) && (waddr <= 17'h003ff))
                                : (req && we && sel_ram1);
  wire [7:0]  w_a0   = SPLIT_WR ? waddr[7:0] : a0;
  wire [8:0]  w_a1   = SPLIT_WR ? waddr[8:0] : a1;
  wire [16:0] w_addr = SPLIT_WR ? waddr : addr;

  always_ff @(posedge clk) begin
    if (w_ram0) ram0[w_a0] <= wdata;
    ram0_q <= ram0[a0];
  end

  always_ff @(posedge clk) begin
    if (w_ram1) ram1[w_a1] <= wdata;
    ram1_q <= ram1[a1];
  end

  // --------------------------------------------------------- external side

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dbg_wr_n <= 32'd0; dbg_wr_addr <= 17'd0; dbg_wr_data <= 32'd0;
    end else if (w_ram0 || w_ram1) begin   // R602
      if (!(&dbg_wr_n)) dbg_wr_n <= dbg_wr_n + 32'd1;
      dbg_wr_addr <= w_addr;
      dbg_wr_data <= wdata;
    end
  end

  assign ext_rd    = req & sel_fifo_in;
  assign ext_wr    = req & sel_fifo_out;
  assign ext_wdata = wdata;

  // MAME models this as m_stall plus `goto do_stall`, which re-executes the
  // whole instruction. Here the access simply is not complete until ext_ack,
  // and the core holds the instruction.
  //
  // R731: THE SELECT IS REGISTERED -- Model 1's 9b72de7, ported. This was
  // `req & (sel_fifo_in | sel_fifo_out) & ~ext_ack`, which puts the
  // combinational address decode inside whatever next-state logic reads it:
  // the FSM drives an address, the address decodes to a bank select, the
  // select makes stall, and stall decides the next state, all in one cycle.
  // On Model 1 that was the whole clk_3d critical path at 57.143 MHz,
  //   state.S_DST_W -> u_mem|sel_ram1 -> u_mem|stall -> state.S_DST, -1.256 ns.
  //
  // Registering it is safe because of how the core holds an access: each _W
  // state presents the SAME request at the SAME address as its partner state,
  // and stall is only ever CHECKED in the _W states. So the select needed was
  // computed a cycle earlier. A first-cycle stall is behaviour nothing reads.
  // If a state ever issues an external access and tests stall in the same
  // cycle, this must go back to combinational.
  //
  // In this core the port is NOT CONNECTED to anything that reads it:
  // mb86233_core takes mem_stall from its own registered FIFO decode (R596,
  // R601) and leaves this output on mem_stall_c. So this changes no timing
  // path on Model 2 -- it keeps the module, and its bench's contract, the
  // same as the reference's.
  logic sel_ext_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) sel_ext_q <= 1'b0;
    else        sel_ext_q <= req & (sel_fifo_in | sel_fifo_out);
  end
  assign stall = sel_ext_q & ~ext_ack;

  // ------------------------------------------------------------- read mux
  //
  // RAM reads are registered, so the select must be too or the mux picks the
  // new address's bank while the data is still the old address's.
  //
  // R731: THE ADDRESS IS REGISTERED, AND THE SELECT DECODED AFTER IT. This
  // registered the three selects -- `sel_ram0_q <= req & sel_ram0` and so on
  // -- which hangs the bank compares off the end of the core's address
  // generator: x_src_bank -> AGU -> +0x200 -> address mux -> compare ->
  // sel_ram0_q / sel_ram1_q / sel_fifo_in_q, failing at 80 MHz. Registering
  // req, we and addr instead and decoding them on the far side of the flop is
  // the same function at every port, cycle for cycle (a select registered
  // from a decode equals the decode of the registered inputs), so the bench
  // is unchanged. The compares now run in parallel with the M10K's own
  // clock-to-out, and the AGU ends at a flop exactly as it already ends at
  // the RAM's address register.
  logic        req_q, we_q;
  logic [16:0] addr_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      req_q  <= 1'b0;
      we_q   <= 1'b0;
      addr_q <= 17'd0;
    end else begin
      req_q  <= req;
      we_q   <= we;
      addr_q <= addr;
    end
  end

  logic sel_ram0_q, sel_ram1_q, sel_fifo_in_q;
  assign sel_ram0_q    = req_q && (addr_q <= 17'h000ff);
  assign sel_ram1_q    = req_q && (addr_q >= 17'h00200) && (addr_q <= 17'h003ff);
  assign sel_fifo_in_q = req_q && (addr_q == 17'h00100) && !we_q;

  always_comb begin
    if      (sel_fifo_in_q) rdata = ext_rdata;
    else if (sel_ram0_q)    rdata = ram0_q;
    else if (sel_ram1_q)    rdata = ram1_q;
    else                    rdata = 32'd0;   // unmapped reads as zero
  end

endmodule
