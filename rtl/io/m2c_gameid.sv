// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// m2c_gameid -- the game ID register of a 2C build (R1043; R1039's m2b_gameid
// is the 2B one, and this is the same idea with the 2C list).
//
// Model2.sv's game_id is the byte the MRA sends on download index 4 (R726):
// bit 7 the CRT MRA's flag (R795), bits 6:0 the game. A 2C build carries every
// 2A decode as well (M2A is 1 on 2C): Daytona's cabinet, Desert Tank, Sega
// Rally, Virtua Cop 2, Zero Gunner, Sky Target, the 2A analog profiles of
// m2_2a_inputs, the 2A luma rows -- logic for games the 2C board does not run.
//
// A 2C build runs only the MRAs whose <rbf> is Model2C. This register holds
// which of THEIR IDs was sent -- four bits for the game, one for the CRT flag --
// and gives back the byte itself, so every decode downstream sees exactly the
// value it saw before for every 2C set, on the same cycle (one register written
// by the same strobe, the decode combinational, as the compares behind it
// were), and synthesis sees that game_id takes only these values: every
// compare against another ID folds to 0.
//
// An ID outside the list reads back as 0x00 (the value before any download)
// with its CRT bit -- such an MRA is not a 2C set and does not name this rbf.
//
// THE LIST MUST FOLLOW THE 2C MRAs: a new 2C set on a new ID goes in here, or
// it runs as game 0. make test_m2c_gameid reads every mra/*.mra with
// <rbf>Model2C</rbf> and fails if one sends an ID this register does not keep.
//
// q is named so Model2.sdc's R842 false path (game_id, written only during
// the download, every master it steers held in reset) still finds it.
module m2c_gameid (
	input  logic       clk,
	input  logic       rst_n,      // the PLL-lock reset game_id has always had
	input  logic       we,         // ioctl_download && ioctl_wr && index 4
	input  logic [7:0] din,
	output logic [7:0] game_id
);
	// 0x00 (no ID yet), then each 2C set's ID (R924 / R928 / R933 / R1010):
	//   0x17 The House of the Dead   0x1C Over Rev (2C)
	//   0x1D Sega Touring Car Ch.    0x1E Wave Runner
	//   0x1F Sega Water Ski          0x20 Behind Enemy Lines
	//   0x21 Sega Ski Super G        0x22 Top Skater
	//   0x23 Dynamite Cop (2C)       0x24 Royal Ascot II
	function automatic logic [3:0] enc(input logic [6:0] g);
		case (g)
			7'h17: enc = 4'd1;   7'h1C: enc = 4'd2;   7'h1D: enc = 4'd3;
			7'h1E: enc = 4'd4;   7'h1F: enc = 4'd5;   7'h20: enc = 4'd6;
			7'h21: enc = 4'd7;   7'h22: enc = 4'd8;   7'h23: enc = 4'd9;
			7'h24: enc = 4'd10;
			default: enc = 4'd0;
		endcase
	endfunction
	function automatic logic [6:0] dec(input logic [3:0] i);
		case (i)
			4'd1:  dec = 7'h17;  4'd2:  dec = 7'h1C;  4'd3:  dec = 7'h1D;
			4'd4:  dec = 7'h1E;  4'd5:  dec = 7'h1F;  4'd6:  dec = 7'h20;
			4'd7:  dec = 7'h21;  4'd8:  dec = 7'h22;  4'd9:  dec = 7'h23;
			4'd10: dec = 7'h24;
			default: dec = 7'h00;
		endcase
	endfunction

	logic [4:0] gid_q;   // {CRT flag, game index}
	always_ff @(posedge clk or negedge rst_n)
		if (!rst_n)  gid_q <= 5'd0;
		else if (we) gid_q <= {din[7], enc(din[6:0])};
	assign game_id = {gid_q[4], dec(gid_q[3:0])};
endmodule
