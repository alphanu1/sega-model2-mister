// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- R1039: the framework's hps_io with its configuration
// string in logic (CONF_STR_BRAM 0, as every build before) against the same string in a ROM
// (CONF_STR_BRAM 1, the 2B build's), side by side on one HPS bus, io_dout compared every
// clock. The bus is driven as sys_top.v drives it: io_strobe = ~rack & io_clk, so two strobes
// are at least two clk_sys apart (GAP 2, the protocol's least); the HPS reads the string with
// command 0x14 (io_enable high, the command word, then a strobe per byte) at random spacings,
// between random other commands. GAP 1 (not a spacing sys_top can make) and PLANT (one byte of
// the ROM's string changed) are the two planted faults: each must differ.
`timescale 1ns/1ps
module tb_hps_cfgstr #(parameter int GAP = 2, parameter bit PLANT = 1'b0);
	`include "cfgstr_test.svh"   // localparam CS (the string), CS_P (the planted copy), N (its bytes)
	logic clk = 0;
	always #5 clk = ~clk;
	wire [45:0] bus_a, bus_b;
	logic        io_clk = 0, io_en = 0;
	logic [15:0] io_din = 0;
	logic        rack = 0;
	wire         io_strobe = (GAP == 1) ? io_clk : (~rack & io_clk);   // GAP 1: a strobe every clock
	always_ff @(posedge clk) rack <= io_clk;
	assign bus_a[35:33] = {1'b0, io_en, io_strobe};
	assign bus_a[31:16] = io_din;
	assign bus_a[45:38] = '0;
	assign bus_b[35:33] = {1'b0, io_en, io_strobe};
	assign bus_b[31:16] = io_din;
	assign bus_b[45:38] = '0;
	hps_io #(.CONF_STR(CS), .WIDE(1)) u_a (.clk_sys(clk), .HPS_BUS(bus_a));
	hps_io #(.CONF_STR(PLANT ? CS_P : CS), .CONF_STR_BRAM(1), .WIDE(1)) u_b (.clk_sys(clk), .HPS_BUS(bus_b));
	longint cyc = 0, diffs = 0, reads = 0;
	always_ff @(posedge clk) begin
		cyc <= cyc + 1;
		if (bus_a[15:0] !== bus_b[15:0]) begin
			diffs <= diffs + 1;
			if (diffs < 5) $display("DIFF at %0d: %h %h", cyc, bus_a[15:0], bus_b[15:0]);
		end
	end
	task automatic strobe(input logic [15:0] d);
		@(negedge clk); io_din = d; io_clk = 1;      // the word and the clock together
		@(posedge clk); #1;                           // the strobe is taken
		if (GAP != 1) begin
			@(negedge clk); io_clk = 0;
			repeat ($urandom % 4) @(negedge clk);
		end
	endtask
	initial begin
		repeat (4) @(negedge clk);
		for (int r = 0; r < 60; r++) begin
			io_en = 1;
			if ($urandom % 3 == 0) begin                  // another command between reads
				strobe(16'h001e); repeat (8) strobe(16'($urandom));
			end else begin
				strobe(16'h0014);
				for (int k = 0; k < N + 3; k++) begin strobe(16'h0000); reads++; end
			end
			@(negedge clk); io_en = 0; io_clk = 0;
			repeat (1 + $urandom % 4) @(negedge clk);
		end
		repeat (8) @(negedge clk);
		$display("hps_io CONF_STR_BRAM 0 vs 1 (GAP %0d, PLANT %0d): %0d string bytes, %0d byte reads, %0d clocks, %0d differ",
		         GAP, PLANT, N, reads, cyc, diffs);
		if (diffs) $display("FAIL"); else $display("PASS");
		$finish;
	end
endmodule
