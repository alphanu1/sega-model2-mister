// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// m2_tdp_ram with each port on its OWN clock (study R561, step 1(b)).
//
// The tile and palette RAMs are written by the CPU on the core clock and read
// by the video on clk_mem once the video moves there, as Model 1's video does:
// "the video-side tilemap and palette copies ... are dual-clock RAMs and need
// no handshake because only the CPU writes them" (m1_integrated). An M10K is
// true dual-port silicon with a clock per port, so the crossing is the memory
// itself and there is nothing to synchronise.
//
// Everything m2_tdp_ram records still holds -- one block set because both
// ports are the same width, and read-during-write DONT_CARE because Cyclone V
// cannot do OLD_DATA on a true dual-port. With two clocks there is one more
// reason for the mixed-port case: the two ports' edges have no relationship,
// so "the same edge" is not even defined. A video read of a cell the CPU is
// writing returns the old or the new value, for one read, as before.
//
// m2_tdp_ram itself is left alone: the backup RAM uses it, and its power-up
// value is part of the game's contract.

`timescale 1ns/1ps

module m2_tdp_ram2c #(
  parameter int unsigned DW = 16,
  parameter int unsigned AW = 15
) (
  // Port A: the CPU's, read and write.
  input  logic          a_clk,
  input  logic [AW-1:0] a_addr,
  input  logic [DW-1:0] a_din,
  input  logic          a_we,
  output logic [DW-1:0] a_q,

  // Port B: the video's, read only.
  input  logic          b_clk,
  input  logic [AW-1:0] b_addr,
  output logic [DW-1:0] b_q
);

`ifdef VERILATOR
  (* ramstyle = "M10K" *) logic [DW-1:0] mem [1 << AW];
  always_ff @(posedge a_clk) begin
    a_q <= mem[a_addr];
    if (a_we) mem[a_addr] <= a_din;
  end
  always_ff @(posedge b_clk) b_q <= mem[b_addr];
`else
  altsyncram #(
    .operation_mode                  ("BIDIR_DUAL_PORT"),
    .ram_block_type                  ("M10K"),
    .width_a                         (DW),
    .widthad_a                       (AW),
    .numwords_a                      (1 << AW),
    .width_b                         (DW),
    .widthad_b                       (AW),
    .numwords_b                      (1 << AW),
    .width_byteena_a                 (1),
    .width_byteena_b                 (1),
    .outdata_reg_a                   ("UNREGISTERED"),
    .outdata_reg_b                   ("UNREGISTERED"),
    .indata_reg_b                    ("CLOCK1"),
    .address_reg_b                   ("CLOCK1"),
    .wrcontrol_wraddress_reg_b       ("CLOCK1"),
    .byteena_reg_b                   ("CLOCK1"),
    .read_during_write_mode_port_a   ("DONT_CARE"),
    .read_during_write_mode_port_b   ("DONT_CARE"),
    .read_during_write_mode_mixed_ports ("DONT_CARE"),
    .power_up_uninitialized          ("FALSE"),
    .lpm_type                        ("altsyncram")
  ) u_ram (
    .clock0    (a_clk),
    .clock1    (b_clk),
    .clocken0  (1'b1),
    .clocken1  (1'b1),
    .address_a (a_addr),
    .data_a    (a_din),
    .wren_a    (a_we),
    .q_a       (a_q),
    .address_b (b_addr),
    .data_b    ({DW{1'b0}}),
    .wren_b    (1'b0),
    .q_b       (b_q),
    // Everything this design does not use, tied off as the IP expects.
    .aclr0(1'b0), .aclr1(1'b0),
    .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_a(1'b1), .byteena_b(1'b1),
    .clocken2(1'b1), .clocken3(1'b1),
    .eccstatus(), .rden_a(1'b1), .rden_b(1'b1)
  );
`endif

endmodule

// R1030: THE SAME MEMORY AS B_LANES SIDE-BY-SIDE m2_tdp_ram2c's, each holding
// DW / B_LANES of the data bits, with port B's address taken PER LANE.
//
// The palette is 8,192 x 16 -- sixteen M10K, one data bit each (8K x 1) --
// and its video address came from one register, m2_video's pal_addr_q, which
// had to reach all sixteen blocks wherever the fitter put them: a route with
// no logic in it, 8.2-9.6 ns on most 2C seeds and 13.0 ns on s3076 (-3.824).
// Split by data bit, each lane's blocks have a b_addr of their own, so the
// video side can give each its own copy of the register, placed beside them.
//
// Nothing else changes: the same blocks (a lane of DW / B_LANES bits at
// 2^AW words is that many 8K x 1 blocks here), the same registered address
// on both ports, the same unregistered output, the same cycle. Port A is
// shared by every lane, as the CPU's single address always was. b_addr is
// lane-major: lane l's address is b_addr[l*AW +: AW].
module m2_tdp_ram2c_lanes #(
  parameter int unsigned DW = 16,
  parameter int unsigned AW = 13,
  parameter int unsigned B_LANES = 4
) (
  input  logic                  a_clk,
  input  logic [AW-1:0]         a_addr,
  input  logic [DW-1:0]         a_din,
  input  logic                  a_we,
  output logic [DW-1:0]         a_q,

  input  logic                  b_clk,
  input  logic [B_LANES*AW-1:0] b_addr,
  output logic [DW-1:0]         b_q
);
  localparam int unsigned LW = DW / B_LANES;

  genvar l;
  generate
    for (l = 0; l < B_LANES; l++) begin : g_lane
      m2_tdp_ram2c #(.DW(LW), .AW(AW)) u_ram (
        .a_clk(a_clk),
        .a_addr(a_addr), .a_din(a_din[l*LW +: LW]), .a_we(a_we), .a_q(a_q[l*LW +: LW]),
        .b_clk(b_clk),
        .b_addr(b_addr[l*AW +: AW]), .b_q(b_q[l*LW +: LW])
      );
    end
  endgenerate
endmodule
