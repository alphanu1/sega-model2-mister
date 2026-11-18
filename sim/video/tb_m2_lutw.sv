// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- R1044: the 3D tables' CPU write (Model2.sv g_r3d_lut),
// R1042's form against the 2B build's (the address and select loaded in every clock, chosen by
// the windows' ranges). Random CPU SDRAM writes biased into the three windows (3D palette,
// colour xlat, luma) and around their edges, random acks, the game settings changed every
// 50,000 clocks; m2_luma_map as Model2.sv builds it on 2B (LSB 5, OREV 1, B2L 1). Checked on
// every clock: r3d_lut_we and r3d_lut_data equal; where r3d_lut_we is set (the clock
// m2_span_tex writes a table), r3d_lut_sel and r3d_lut_addr equal. +n=<clocks> +seed=<n>.
`timescale 1ns/1ps
module tb_m2_lutw (input logic clk);
	localparam int SDR_AW = 25, LSB = 5;
	localparam logic [SDR_AW:1] GAME_PAL3D = SDR_AW'(32'h1730000), GAME_XLAT3D = SDR_AW'(32'h1731000),
	                            GAME_LUMA = SDR_AW'(32'h1860000);
	logic [SDR_AW:1] cpu_sd_addr;
	logic            cpu_sd_req, cpu_sd_we, ack;
	logic [15:0]     cpu_sd_din;
	logic [4:0]      gid;
	logic            big, zg, sgt, orev;
	wire [LSB:0]     w_ls, q_ls;
	wire [SDR_AW:1]  w_luma = cpu_sd_addr - GAME_LUMA, w_pal = cpu_sd_addr - GAME_PAL3D, w_xlat = cpu_sd_addr - GAME_XLAT3D;
	m2_luma_map #(.LSB(LSB), .OREV(1'b1), .B2L(1'b1)) u_lmap (.clk, .game_id(gid), .big, .zg, .sgt, .orev,
		.q_row(8'd0), .q_ls(q_ls), .w_row(w_luma[15:8]), .w_ls(w_ls));
	wire sd_wr = cpu_sd_req && cpu_sd_we && ack;
	// R1042's form (Model2.sv before R1044)
	logic o_we; logic [1:0] o_sel; logic [12:0] o_addr; logic [15:0] o_data;
	always_ff @(posedge clk) begin
		o_we <= 1'b0; o_data <= cpu_sd_din;
		if (sd_wr && w_luma < SDR_AW'(32'h8000) && w_ls[LSB]) begin o_we <= 1'b1; o_sel <= 2'd0; o_addr <= 13'({w_ls[LSB-1:0], w_luma[7:1]}); end
		if (sd_wr && w_pal < SDR_AW'(32'h400)) begin o_we <= 1'b1; o_sel <= 2'd1; o_addr <= 13'(w_pal[10:1]); end
		if (sd_wr && w_xlat < SDR_AW'(32'h6000) && w_xlat[8:7] == 2'd0) begin
			o_we <= 1'b1; o_sel <= 2'd2; o_addr <= {w_xlat[15:14], w_xlat[13:9], w_xlat[6:1]}; end
	end
	// the 2B build's (Model2.sv g_lutw_b2)
	logic n_we; logic [1:0] n_sel; logic [12:0] n_addr; logic [15:0] n_data;
	always_ff @(posedge clk) begin
		n_we <= (sd_wr && w_luma < SDR_AW'(32'h8000) && w_ls[LSB]) || (sd_wr && w_pal < SDR_AW'(32'h400)) ||
		        (sd_wr && w_xlat < SDR_AW'(32'h6000) && w_xlat[8:7] == 2'd0);
		n_data <= cpu_sd_din;
		if (w_xlat < SDR_AW'(32'h6000)) begin n_sel <= 2'd2; n_addr <= {w_xlat[15:14], w_xlat[13:9], w_xlat[6:1]}; end
		else if (w_pal < SDR_AW'(32'h400)) begin n_sel <= 2'd1; n_addr <= 13'(w_pal[10:1]); end
		else begin n_sel <= 2'd0; n_addr <= 13'({w_ls[LSB-1:0], w_luma[7:1]}); end
	end
	// stimulus
	int unsigned n, seed, cyc, writes, bad;
	initial begin
		if (!$value$plusargs("n=%d", n)) n = 10000000;
		if (!$value$plusargs("seed=%d", seed)) seed = 1;
		void'($urandom(seed));
		cyc = 0; writes = 0; bad = 0;
		cpu_sd_addr = '0; cpu_sd_req = 0; cpu_sd_we = 0; ack = 0; cpu_sd_din = 0;
		gid = 0; big = 0; zg = 0; sgt = 0; orev = 0;
	end
	always_ff @(posedge clk) begin
		int unsigned r, b;
		cyc <= cyc + 1;
		if (cyc % 50000 == 0) begin
			r = $urandom;
			gid <= 5'(r); big <= r[8]; zg <= r[9] && r[10]; sgt <= r[11] && r[12]; orev <= r[13] && r[14];
		end
		r = $urandom;
		b = r % 8;
		case (b)
			0, 1: cpu_sd_addr <= GAME_LUMA + SDR_AW'($urandom % 32'h8100);
			2:    cpu_sd_addr <= GAME_PAL3D + SDR_AW'($urandom % 32'h480);
			3, 4: cpu_sd_addr <= GAME_XLAT3D + SDR_AW'($urandom % 32'h6100);
			5:    cpu_sd_addr <= GAME_LUMA - SDR_AW'($urandom % 32'h100);
			6:    if (r[20]) cpu_sd_addr <= SDR_AW'($urandom);
			default: ;                                   // held
		endcase
		cpu_sd_req <= $urandom % 4 != 0; cpu_sd_we <= $urandom % 4 != 0; ack <= $urandom % 3 == 0;
		cpu_sd_din <= 16'($urandom);
		if (o_we) writes <= writes + 1;
		if (o_we != n_we || o_data != n_data || (o_we && (o_sel != n_sel || o_addr != n_addr))) begin
			if (bad < 5) $display("cycle %0d: old we %b sel %0d addr %h data %h, new we %b sel %0d addr %h data %h",
			                      cyc, o_we, o_sel, o_addr, o_data, n_we, n_sel, n_addr, n_data);
			bad <= bad + 1;
		end
		if (cyc == n) begin
			$display("tb_m2_lutw: %0d clocks, %0d table writes, %0d differ: %s", cyc, writes, bad, bad == 0 ? "PASS" : "FAIL");
			$finish;
		end
	end
endmodule
