// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE for the full text.
//
// BENCH FIXTURE, NOT RTL. The cabinet-input block exactly as it stood in
// Model2.sv at 0f3cbc4 (before R835 moved it into rtl/io/m2_cab_inputs.sv and
// added Desert Tank), wrapped in a module with the same ports; only the status
// bits, the clock and the reset are renamed. tb_m2_cab_inputs holds the new
// module to this one with is_desert = 0.

`timescale 1ns/1ps

module m2_cab_inputs_ref #(
  parameter int unsigned SYS_MHZ = 80
) (
  input  logic        clk,          // clk_sys
  input  logic        rst_n,        // cpu_rst_n: the game reset
  input  logic [31:0] joystick_0,
  input  logic [15:0] joy_analog,   // left stick
  input  logic [15:0] joy_ranalog,  // right stick
  input  logic  [7:0] paddle,
  input  logic        st_pedswap,   // status[28]  Pedals
  input  logic  [1:0] st_ssens,     // status[30:29] Steering
  input  logic  [1:0] st_ssm,       // status[51:50] Steering smoothing
  input  logic        st_rsteer,    // status[54]  Right stick
  output logic  [7:0] in0,          // the I/O board's IN0 / IN1, active low
  output logic  [7:0] in1,
  output logic  [7:0] steer,        // its ADC channels 0..2
  output logic  [7:0] accel,
  output logic  [7:0] brake
);

// ---------------------------------------------------------- cabinet inputs
//
// model2.cpp's `daytona` port map, which is `model2` plus `gears` with IN0 and
// IN1 modified. Four buttons were wired and the rest -- the four VR buttons,
// the gearbox and every analog axis -- were not connected at all.
//
//   IN0  0x01 COIN1   0x02 COIN2   0x04 TEST    0x08 SERVICE
//        0x10 START1  0x20 VR1 Red 0x40 VR2 Blue 0x80 VR3 Yellow    all active low
//   IN1  0x01 VR4 Green (active low)   0x0e unused
//        0x70 GEARBOX -- ACTIVE HIGH, and the one field here that is not
//        0x80 unused
//   IN2  unused, 0xff
//
// Analog goes through the I/O board's ADC: channel 0 steering with 0x80 at
// centre, 1 accelerator and 2 brake both idling at 0x20. MAME's own limits are
// PORT_MINMAX(0x20, 0xe0) on all three.
assign in0 = ~{joystick_0[15], joystick_0[14], joystick_0[8],
                       joystick_0[5], joystick_0[7], joystick_0[6],
                       1'b0, joystick_0[4]};

// THE GEARBOX IS A STATE, NOT A BUTTON. The cabinet has a five-position shifter
// and MAME models it as five buttons feeding daytona_gearbox_r, which returns
// gearvalue[] = {0, 2, 1, 6, 5} for N,1,2,3,4 -- deliberately NOT a binary
// count, because the real shifter is a set of microswitches and the game reads
// their pattern. A gamepad has no shifter, so Gear Up and Gear Down step
// through the five positions and the same table converts.
logic [2:0] gear;                    // 0=N, 1..4
wire        gup   = joystick_0[12];
wire        gdn   = joystick_0[13];
logic       gup_d, gdn_d;
always_ff @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		gear <= 3'd0; gup_d <= 1'b0; gdn_d <= 1'b0;
	end else begin
		gup_d <= gup; gdn_d <= gdn;
		if (gup && !gup_d && gear != 3'd4) gear <= gear + 3'd1;
		if (gdn && !gdn_d && gear != 3'd0) gear <= gear - 3'd1;
	end
end
logic [2:0] gearval;
always_comb begin
	case (gear)
		3'd1:    gearval = 3'd2;
		3'd2:    gearval = 3'd1;
		3'd3:    gearval = 3'd6;
		3'd4:    gearval = 3'd5;
		default: gearval = 3'd0;     // neutral
	endcase
end

assign in1 = {1'b1, gearval, 3'b111, ~joystick_0[9]};

// STEERING: the analog stick, with the D-pad as a ramp for anyone without one.
//
// MAME's range is 0x20..0xe0, so +-96 about 0x80. The stick is signed +-127, so
// three quarters of it lands exactly on that range. The digital ramp exists
// because a menu that needs left and right is unusable on a d-pad otherwise,
// and it is a RAMP rather than a jump to the rail so the wheel sweeps as a real
// one would.
// R816: OR THE RIGHT STICK'S LEFT/RIGHT. MiSTer maps a wheel there -- steering
// on the right stick's X with the pedals on its Y (Ben, from a tester's wheel)
// -- and this core read only the left stick, so a wheel did not steer. Both
// sticks steer: the left when it is pushed past the dead zone, otherwise the
// right. A pad is unchanged; a wheel needs no setting.
wire signed [7:0] ax_l  = joy_analog[7:0];
wire signed [7:0] ax_r  = joy_ranalog[7:0];
wire              use_l = (ax_l > 8'sd12) || (ax_l < -8'sd12);
// R831: ONLY WHEN THE OSD SAYS SO. "Right stick: Pedals only" (the default)
// ignores the right stick's left/right, so a pad's pedal stick cannot steer;
// "Steering" is R816's behaviour, for a wheel MiSTer maps onto that stick.
reg  [2:0]        rsteer_s;
always_ff @(posedge clk) rsteer_s <= {rsteer_s[1:0], st_rsteer};
wire              use_r = rsteer_s[2] && ((ax_r > 8'sd12) || (ax_r < -8'sd12));
wire signed [7:0] ax    = use_l ? ax_l : ax_r;

// STEERING SENSITIVITY, because three quarters is a choice and not a law.
//
// The 3/4 above exists because the stick is +-127 and the ADC's range is +-96
// about 0x80, so three quarters lands exactly on the rails: full stick equals
// full lock. That is the RIGHT default and it stays entry zero -- but a wheel
// is not a stick, and how much lock a player wants for a given thumb movement
// is taste, not arithmetic. More sensitive than 3/4 reaches full lock before
// the stick's edge and CLAMPS there; less sensitive never reaches it.
//
// Written as shifts and adds: 1/2, 3/4, 1, and 5/4 of the axis.
reg [2:0] ssens0_s, ssens1_s;    // three flops, like every other OSD bit here
always_ff @(posedge clk) begin
	ssens0_s <= {ssens0_s[1:0], st_ssens[0]};
	ssens1_s <= {ssens1_s[1:0], st_ssens[1]};
end
wire [1:0] ssens = {ssens1_s[2], ssens0_s[2]};
wire signed [9:0] ax_x  = {{2{ax[7]}}, ax};                 // sign-extended
wire signed [9:0] ax_h  = {{3{ax[7]}}, ax[7:1]};            // x/2
wire signed [9:0] ax_q  = {{4{ax[7]}}, ax[7:2]};            // x/4
wire signed [9:0] ax_sc = (ssens == 2'd0) ? (ax_x - ax_q)   // 3/4, the default
                        : (ssens == 2'd1) ? ax_x            // 1
                        : (ssens == 2'd2) ? (ax_x + ax_q)   // 5/4
                        :                   ax_h;           // 1/2
// The ADC's own rails: past them the wheel is already at full lock.
wire signed [10:0] ax_sum = 11'sh080 + {ax_sc[9], ax_sc};
// NAMED FOR WHAT IT IS NOW. It was `ax34`, an OFFSET from centre that the
// consumer added 0x80 to; it is now the finished ADC value, centre and clamp
// included, and calling it the old name is how the offset gets added twice.
wire        [7:0]  steer_an = (ax_sum > 11'sh0e0) ? 8'he0
                            : (ax_sum < 11'sh020) ? 8'h20 : ax_sum[7:0];
logic [7:0] steer_dig;
logic [9:0] steer_div;
always_ff @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		steer_dig <= 8'h80; steer_div <= 10'd0;
	end else begin
		steer_div <= steer_div + 10'd1;
		if (steer_div == 10'd0) begin
			if (joystick_0[1]) begin                       // left
				if (steer_dig > 8'h21) steer_dig <= steer_dig - 8'd1;
			end else if (joystick_0[0]) begin              // right
				if (steer_dig < 8'hdf) steer_dig <= steer_dig + 8'd1;
			end else if (steer_dig > 8'h80) steer_dig <= steer_dig - 8'd1;
			else if (steer_dig < 8'h80) steer_dig <= steer_dig + 8'd1;
		end
	end
end
wire use_stick = use_l || use_r;   // R816
wire [7:0] steer_raw = |paddle ? paddle
                 : use_stick ? steer_an
                 : steer_dig;

// R830: STEERING SMOOTHING (OSD, default Off). The game turns its camera on
// how FAST the steering changes as well as where it is (a turning-centre
// term recomputed a step late), so a pad flicked lock to lock in a frame or
// two snaps the view; a cabinet wheel, with travel, a spring and the force
// motor, cannot move that fast and sweeps. This limits how fast the value the
// I/O board's ADC reads may move: Light ~22 counts a frame (~9 frames lock to
// lock, 0x20..0xE0), Wheel ~11 (~17 frames, ~0.3 s -- R830 measured a sweep at
// 16). Off is the raw value, unregistered, exactly as before.
reg [2:0] ssm0_s, ssm1_s;
always_ff @(posedge clk) begin ssm0_s <= {ssm0_s[1:0], st_ssm[0]}; ssm1_s <= {ssm1_s[1:0], st_ssm[1]}; end
wire [1:0] ssm = {ssm1_s[2], ssm0_s[2]};
localparam int unsigned STEER_FRAME = SYS_MHZ * 17391;          // clk_sys cycles in a 57.5 Hz frame
localparam int unsigned STEER_K_LT  = STEER_FRAME / 22;
localparam int unsigned STEER_K_WH  = STEER_FRAME / 11;
reg  [7:0]  steer_lim;
reg  [17:0] steer_slew;
always_ff @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		steer_lim <= 8'h80; steer_slew <= '0;
	end else if (ssm == 2'd0) begin
		steer_lim <= steer_raw; steer_slew <= '0;
	end else if (steer_slew == 18'd0) begin
		steer_slew <= (ssm == 2'd1) ? 18'(STEER_K_LT - 1) : 18'(STEER_K_WH - 1);
		if (steer_lim < steer_raw)      steer_lim <= steer_lim + 8'd1;
		else if (steer_lim > steer_raw) steer_lim <= steer_lim - 8'd1;
	end else
		steer_slew <= steer_slew - 18'd1;
end
assign steer = (ssm == 2'd0) ? steer_raw : steer_lim;

// PEDALS ARE ANALOGUE, ON THE RIGHT STICK'S Y AXIS -- Model 1's arrangement,
// tools/model1-ref/Model1.sv, and its reasoning transfers whole.
//
// MiSTer has no dedicated trigger signal: hps_io offers the two sticks, the
// paddles and the spinners, and a pad's triggers arrive as an analog axis. One
// axis per pedal was tried there and put the accelerator on the LEFT stick,
// which moves while steering. BOTH PEDALS ON ONE AXIS, SPLIT BY SIGN, leaves
// the left stick to steering alone.
//
// WHICH HALF IS WHICH DEPENDS ON THE PAD, and axis polarity is not
// standardised, so `Pedals` swaps them rather than making it a rebuild.
//
// THE RANGE IS MODEL 2'S, NOT MODEL 1'S. This board's ADC idles at 0x20 and
// tops at 0xe0 -- MAME's PORT_MINMAX(0x20,0xe0) on all three channels -- where
// Model 1 runs 0x01..0xff. The magnitude is seven bits, so three halves of it
// spans 0..190 and lands on 0x20..0xde; full travel saturates to 0xe0 so the
// rail is reachable. The buttons stay live and give full travel.
wire signed [7:0] pedal_ax  = joy_ranalog[15:8];        // right stick Y
// -128 HAS NO SEVEN-BIT MAGNITUDE: negating it gives zero, so a pad at full
// deflection would read as a pedal at rest. Clamped to 127.
wire        [6:0] pedal_mag = (pedal_ax == -8'sd128) ? 7'd127
                            : pedal_ax[7] ? (~pedal_ax[6:0] + 7'd1) : pedal_ax[6:0];
wire        [8:0] pedal_scl = {2'd0, pedal_mag} + {3'd0, pedal_mag[6:1]};   // mag * 3/2
wire        [7:0] pedal_an  = (pedal_scl >= 9'd192) ? 8'he0 : (8'h20 + pedal_scl[7:0]);
wire              pedal_up  = st_pedswap ? ~pedal_ax[7] : pedal_ax[7];
wire        [7:0] accel_an  = pedal_up ? pedal_an : 8'h20;
wire        [7:0] brake_an  = pedal_up ? 8'h20    : pedal_an;
assign accel = joystick_0[10] ? 8'he0 : accel_an;
assign brake = joystick_0[11] ? 8'he0 : brake_an;

endmodule
