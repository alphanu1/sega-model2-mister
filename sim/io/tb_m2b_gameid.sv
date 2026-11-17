// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- R1039: m2b_gameid against the plain 8-bit register
// it replaces in a 2B build (Model2.sv's game_id before R1039), cycle by cycle. For an ID a
// 2B MRA sends (+IDS=<hex>, from sim/io/m2b_mra_ids.py) the two must be equal on every
// cycle; for any other ID the new register reads {crt, 0x00}. Random writes of all 256
// bytes, write strobes on random cycles, asynchronous resets.
`timescale 1ns/1ps
module tb_m2b_gameid;
	logic clk = 0, rst_n = 0, we = 0;
	logic [7:0] din = 0, ref_q, got;
	logic is2b [0:127];
	m2b_gameid dut (.clk(clk), .rst_n(rst_n), .we(we), .din(din), .game_id(got));
	always_ff @(posedge clk or negedge rst_n)
		if (!rst_n) ref_q <= 8'd0; else if (we) ref_q <= din;
	always #5 clk = ~clk;
	integer i, cyc = 0, bad = 0, eq = 0, other = 0, n2b = 0, nvc = 0;
	bit seen [0:255];
	string f;
	initial begin
		if (!$value$plusargs("IDS=%s", f)) begin $display("FAIL: no +IDS"); $finish; end
		$readmemh(f, is2b);
		for (i = 0; i < 128; i++) if (is2b[i]) n2b++;
		for (i = 0; i < 256; i++) seen[i] = 0;
		#12 rst_n = 1;
		for (cyc = 0; cyc < 2000000; cyc++) begin
			@(negedge clk);
			// check the settled value of the previous edge
			if (is2b[ref_q[6:0]]) begin
				eq++;
				// R1039: Model2.sv's is_2ax (M2A, C2) for every 2B ID but 0x00 -- vc_en's source
				if (ref_q[6:0] != 7'h00) begin
					nvc++;
					if (!((got[6:4] == 3'b001) || (got[6:4] == 3'b010))) begin bad++; $display("is_2ax 0 for %02x", got); end
				end
				if (got !== ref_q) begin bad++; if (bad < 10) $display("DIFF cyc %0d ref %02x got %02x", cyc, ref_q, got); end
			end else begin
				other++;
				if (got !== {ref_q[7], 7'h00}) begin bad++; if (bad < 10) $display("DIFF(other) cyc %0d ref %02x got %02x", cyc, ref_q, got); end
			end
			we  = ($urandom % 4) == 0;
			din = $urandom;
			if (we) seen[din] = 1;
			if (($urandom % 5000) == 0) begin #1 rst_n = 0; #2 rst_n = 1; end
		end
		for (i = 0; i < 256; i++) if (!seen[i]) begin bad++; $display("byte %02x never written", i); end
		$display("m2b_gameid: %0d IDs kept (incl. 0x00), %0d cycles with a 2B ID checked equal (%0d of them nonzero, is_2ax 1), %0d with another ID checked {crt,00}; %0d differ",
		         n2b, eq, nvc, other, bad);
		if (bad) $display("FAIL"); else $display("PASS");
		$finish;
	end
endmodule
