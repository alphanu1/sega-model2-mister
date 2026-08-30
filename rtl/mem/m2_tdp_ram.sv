// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// One write port and two read ports, in ONE set of M10K blocks.
//
// THE PROBLEM THIS SOLVES, MEASURED. Written as an inferred array --
//
//     logic [15:0] tram [32768];
//     always_ff @(posedge clk) begin
//       tram_data  <= tram[tram_addr];        // video reads
//       cpu_tram_q <= tram[ocb_addr];         // CPU reads
//       if (ocb_tram_we) tram[ocb_addr] <= ocb_din;
//     end
//
// -- Quartus 17.0 does not infer a true dual-port memory. It silently
// REPLICATES the array, once per read port, and the fitter report shows it
// plainly: `tram_rtl_0` at 64 blocks and `tram_rtl_1` at another 64, for a
// 512 Kbit memory whose floor is 52. The palette does the same at 15 + 16.
// Seventy-nine blocks of a 553-block device spent on holding two copies of
// something that changes on one port.
//
// The Model 1 project measured the identical thing on the identical idiom and
// found no inference template that avoids it: Quartus refuses the true
// dual-port template outright with Error 276001. So the saving needs an
// EXPLICIT altsyncram, which is what this is.
//
// M10K blocks in Cyclone V are true dual-port silicon: each port reads and
// writes independently. The condition for a single copy is that both ports be
// the SAME WIDTH -- mixed-width true dual-port is what forces replication --
// and both of ours are 16 bits, so this fits in one block set with port B's
// write enable simply tied off.
//
// READ-DURING-WRITE IS "DONT_CARE", AND THAT IS A REAL DIFFERENCE FROM THE
// INFERRED VERSION -- stated rather than glossed.
//
// The inferred array was non-blocking, so a read on the same cycle as a write
// to the same address returned the value from BEFORE the write. "OLD_DATA" is
// the altsyncram name for that and Cyclone V M10K DOES NOT SUPPORT IT in
// bidirectional dual-port mode; Quartus rejects it outright with Error 14000,
// "uses an unsupported value for parameter port_a_read_during_write_mode". The
// silicon cannot do read-first on a true dual-port. That was found by building
// it, which is the only place this is knowable.
//
// So the value read from a cell being written on the same edge is now
// undefined. Where that can happen and why it is acceptable:
//
//   * PORT A reads and writes the same address every write cycle, because the
//     read is unconditional. Nothing consumes it -- the CPU's reads and writes
//     are separate bus transactions and a write cycle's read data is discarded.
//   * PORT B is the renderer, reading a cell the CPU writes on the same edge.
//     One read of one cell takes either the old or the new tile number, for one
//     cycle. The real S24TILE arbitrates this in silicon and we do not know
//     which it would give either.
//
// The alternative is 64 blocks of a 553-block device spent on a second copy.
//
// SIMULATION USES THE INFERRED FORM. Verilator has no altsyncram, and the
// standing caveat applies either way: simulation cannot see memory inference,
// and only a Quartus build can say whether an array landed in M10K or in
// flip-flops. The two paths are written to the same semantics and the fitter
// report is the check.

`timescale 1ns/1ps

module m2_tdp_ram #(
  parameter int unsigned DW = 16,
  parameter int unsigned AW = 15
) (
  input  logic          clk,

  // Port A: the CPU's, read and write.
  input  logic [AW-1:0] a_addr,
  input  logic [DW-1:0] a_din,
  input  logic          a_we,
  output logic [DW-1:0] a_q,

  // Port B: the renderer's, read only.
  input  logic [AW-1:0] b_addr,
  output logic [DW-1:0] b_q
);

`ifdef VERILATOR
  (* ramstyle = "M10K" *) logic [DW-1:0] mem [1 << AW];
  always_ff @(posedge clk) begin
    a_q <= mem[a_addr];
    b_q <= mem[b_addr];
    if (a_we) mem[a_addr] <= a_din;
  end
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
    .indata_reg_b                    ("CLOCK0"),
    .address_reg_b                   ("CLOCK0"),
    .wrcontrol_wraddress_reg_b       ("CLOCK0"),
    .byteena_reg_b                   ("CLOCK0"),
    .read_during_write_mode_port_a   ("DONT_CARE"),
    .read_during_write_mode_port_b   ("DONT_CARE"),
    .read_during_write_mode_mixed_ports ("DONT_CARE"),
    .power_up_uninitialized          ("FALSE"),
    .lpm_type                        ("altsyncram")
  ) u_ram (
    .clock0    (clk),
    .clocken0  (1'b1),
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
    .clock1(1'b1), .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1),
    .eccstatus(), .rden_a(1'b1), .rden_b(1'b1)
  );
`endif

endmodule
