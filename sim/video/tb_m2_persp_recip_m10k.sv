// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- R1039: m2_persp_recip with its table in logic (M10K 0)
// against the M10K form (M10K 1), side by side, out_q compared on every clock: every 16-bit
// input (each held for a random 1-3 clocks, in a shuffled order), then random inputs, with
// asynchronous resets at random times. PLANT 1 reads the M10K one clock late (its address
// from sa_dn, not sa_dn's next value): it must differ.
`timescale 1ns/1ps
module tb_m2_persp_recip_m10k #(parameter bit PLANT = 1'b0);
	logic clk = 0, rst_n = 0;
	logic [15:0] d = 0;
	logic [31:0] qa, qb;
	always #5 clk = ~clk;
	m2_persp_recip #(.M10K(1'b0)) u_a (.clk(clk), .rst_n(rst_n), .in_d(d), .out_q(qa));
	m2_persp_recip #(.M10K(1'b1)) u_b (.clk(clk), .rst_n(rst_n), .in_d(d), .out_q(qb));
	generate if (PLANT) begin : g_plant
		// the planted fault: the M10K's address one clock late
		initial force u_b.g_m10k.m_a = u_b.sa_dn[14:8];
	end endgenerate
	longint cyc = 0, diffs = 0, checked = 0;
	always @(posedge clk) begin
		cyc <= cyc + 1;
		if (rst_n) begin
			checked <= checked + 1;
			if (qa !== qb) begin
				diffs <= diffs + 1;
				if (diffs < 5) $display("DIFF at %0d: d %h  logic %h  m10k %h", cyc, d, qa, qb);
			end
		end
	end
	int perm [65536];
	initial begin
		for (int i = 0; i < 65536; i++) perm[i] = i;
		for (int i = 65535; i > 0; i--) begin int j, t; j = $urandom % (i + 1); t = perm[i]; perm[i] = perm[j]; perm[j] = t; end
		repeat (3) @(negedge clk);
		rst_n = 1;
		for (int i = 0; i < 65536 + 400000; i++) begin
			@(negedge clk);
			d = (i < 65536) ? 16'(perm[i]) : 16'($urandom);
			repeat ($urandom % 3) @(negedge clk);
			if (($urandom % 20000) == 0) begin #2 rst_n = 0; #4 rst_n = 1; end
		end
		repeat (8) @(negedge clk);
		$display("m2_persp_recip logic vs M10K table (PLANT %0d): %0d clocks out of reset compared, %0d differ", PLANT, checked, diffs);
		if (diffs) $display("FAIL"); else $display("PASS");
		$finish;
	end
endmodule
