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

`timescale 1ns/1ps

module m2b_lutram #(
    parameter int AW = 4,
    parameter int DW = 32,
    parameter bit INIT1 = 1'b0
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
    assign rd = mem[ra];
endmodule
