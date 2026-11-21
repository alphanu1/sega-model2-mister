// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- the 2B SHARC's small register arrays (study R1028).
//
// m2b_lutram: one copy of a 2^AW x DW array in MLAB -- one write port (written at the clock
// edge), one asynchronous read port. Its own module, as tgpx4_rf (R920 / R1006): Quartus 17.0
// does not infer RAM from an array written inside a generate loop in a bigger module, and an
// asynchronous read is only inferred as MLAB with no_rw_check (R607). no_rw_check makes a read
// of the address being written in the same clock undefined: no user of these reads such a
// value (each says why at its instance). INIT1 (benches): the array starts all ones, so a read
// of a word never written shows (the standing rule); on the device an MLAB is configuration
// memory and starts as the bitstream sets it (zero).
//
// RAW (R1058): the read address comes straight from an inferred M10K's read data (the SHARC's
// fetched word, pm_q). Inferred, Quartus 17.0 takes that word into the MLAB as its read-address
// register and the M10K is left with an asynchronous read ("uninferred", PM's upper lane in
// flip-flops: R1029), so those reads were gated by a LUT. Here the MLAB is an explicit altdpram
// with the inferred one's settings (unregistered read address and data, mixed-port read during
// write DONT_CARE -- no_rw_check's), so nothing is absorbed and no gate is needed. Simulation
// (Verilator) uses the inferred form; the two are the same array.

`timescale 1ns/1ps

module m2b_lutram #(
    parameter int AW = 4,
    parameter int DW = 32,
    parameter bit INIT1 = 1'b0,
    parameter bit RAW = 1'b0
) (
    input  logic          clk,
    input  logic          we,
    input  logic [AW-1:0] wa,
    input  logic [DW-1:0] wd,
    input  logic [AW-1:0] ra,
    output logic [DW-1:0] rd
);
    (* ramstyle = "MLAB, no_rw_check" *) logic [DW-1:0] mem [0:(1 << AW) - 1];
    generate if (INIT1) begin : g_init
        initial for (int k = 0; k < (1 << AW); k++) mem[k] = '1;
    end endgenerate
    always_ff @(posedge clk) if (we) mem[wa] <= wd;
`ifdef VERILATOR
    assign rd = mem[ra];
`else
    // (RAW: mem is written and never read, so synthesis drops it; the altdpram is the array)
    generate if (RAW) begin : g_raw
        altdpram #(
            .width (DW), .widthad (AW), .numwords (1 << AW),
            .indata_reg ("INCLOCK"), .indata_aclr ("OFF"),
            .wraddress_reg ("INCLOCK"), .wraddress_aclr ("OFF"),
            .wrcontrol_reg ("INCLOCK"), .wrcontrol_aclr ("OFF"),
            .rdaddress_reg ("UNREGISTERED"), .rdaddress_aclr ("OFF"),
            .rdcontrol_reg ("UNREGISTERED"), .rdcontrol_aclr ("OFF"),
            .outdata_reg ("UNREGISTERED"), .outdata_aclr ("OFF"),
            .use_eab ("ON"), .intended_device_family ("Cyclone V"), .ram_block_type ("MLAB"),
            .read_during_write_mode_mixed_ports ("DONT_CARE"), .lpm_type ("altdpram")
        ) u_ram (
            .inclock (clk), .inclocken (1'b1), .wren (we), .wraddress (wa), .data (wd),
            .rdaddress (ra), .q (rd),
            .outclock (1'b1), .outclocken (1'b1), .rden (1'b1), .aclr (1'b0), .sclr (1'b0),
            .wraddressstall (1'b0), .rdaddressstall (1'b0), .byteena (1'b1)
        );
    end else begin : g_inf
        assign rd = mem[ra];
    end endgenerate
`endif
endmodule
