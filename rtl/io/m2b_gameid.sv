// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// m2b_gameid -- the game ID register of a 2B build (R1039).
//
// Model2.sv's game_id is the byte the MRA sends on download index 4 (R726):
// bit 7 the CRT MRA's flag (R795), bits 6:0 the game. Everything that differs
// by game decodes it, and a decode against an ID no 2B set has (Daytona's
// cabinet, Sega Rally's wait states, Sky Target's filter, the 2A analog
// profiles, the luma ranges of 2A / 2C games ...) is logic the 2B build carries
// for a game it cannot run.
//
// A 2B build runs only the MRAs whose <rbf> is Model2B. This register holds
// which of THEIR IDs was sent -- four bits for the game, one for the CRT flag --
// and gives back the byte itself, so every decode downstream sees exactly the
// value it saw before for every 2B set, on the same cycle (it is still one
// register written by the same strobe; the decode is combinational, as the
// compares behind it were), and synthesis sees that game_id takes only these
// values: every compare against another ID folds to 0.
//
// An ID outside the list reads back as 0x00 (Daytona, the value before any
// download) with its CRT bit -- such an MRA is not a 2B set and does not run on
// the 2B board anyway (no TGP).
//
// THE LIST MUST FOLLOW THE 2B MRAs: a new 2B set on a new ID goes in here, or
// it runs as Daytona. make test_m2b_gameid reads every mra/*.mra with
// <rbf>Model2B</rbf> and fails if one sends an ID this register does not keep.
module m2b_gameid (
	input  logic       clk,
	input  logic       rst_n,      // the PLL-lock reset game_id has always had
	input  logic       we,         // ioctl_download && ioctl_wr && index 4
	input  logic [7:0] din,
	output logic [7:0] game_id
);
	// 0x00 (no ID yet), then each 2B set's ID (R887 / R1031 / R1037):
	//   0x12 Zero Gunner (2B)       0x13 Dynamite Baseball / '97
	//   0x14 Dynamite Cop / Deka 2  0x15 Pilot Kids (2B)
	//   0x16 Dead or Alive (2B)     0x17 Last Bronx, Virtua Striker
	//   0x1A Fighting Vipers, Sonic Championship / the Fighters
	//   0x1C Over Rev (2B)          0x25 Gunblade NY   0x26 INDY 500
	//   0x27 Super GT 24h           0x28 Virtual-On    0x29 Rail Chase 2
	function automatic logic [3:0] enc(input logic [6:0] g);
		case (g)
			7'h12: enc = 4'd1;   7'h13: enc = 4'd2;   7'h14: enc = 4'd3;
			7'h15: enc = 4'd4;   7'h16: enc = 4'd5;   7'h17: enc = 4'd6;
			7'h1A: enc = 4'd7;   7'h1C: enc = 4'd8;   7'h25: enc = 4'd9;
			7'h26: enc = 4'd10;  7'h27: enc = 4'd11;  7'h28: enc = 4'd12;
			7'h29: enc = 4'd13;
			default: enc = 4'd0;
		endcase
	endfunction
	function automatic logic [6:0] dec(input logic [3:0] i);
		case (i)
			4'd1:  dec = 7'h12;  4'd2:  dec = 7'h13;  4'd3:  dec = 7'h14;
			4'd4:  dec = 7'h15;  4'd5:  dec = 7'h16;  4'd6:  dec = 7'h17;
			4'd7:  dec = 7'h1A;  4'd8:  dec = 7'h1C;  4'd9:  dec = 7'h25;
			4'd10: dec = 7'h26;  4'd11: dec = 7'h27;  4'd12: dec = 7'h28;
			4'd13: dec = 7'h29;
			default: dec = 7'h00;
		endcase
	endfunction

	logic [4:0] q;   // {CRT flag, game index}
	always_ff @(posedge clk or negedge rst_n)
		if (!rst_n)  q <= 5'd0;
		else if (we) q <= {din[7], enc(din[6:0])};
	assign game_id = {q[4], dec(q[3:0])};
endmodule
