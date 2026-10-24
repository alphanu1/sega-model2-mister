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
// The cabinet's inputs: the I/O board's IN0 / IN1 and its three ADC channels,
// from MiSTer's joystick, sticks and paddle. Moved out of Model2.sv (R835) so
// it can be benched; is_desert (game_id 2) selects Desert Tank's map, and with
// it clear this is Daytona's block exactly as before -- tb_m2_cab_inputs runs
// it beside sim/io/m2_cab_inputs_ref.sv (the block as it stood in Model2.sv at
// 0f3cbc4) and compares every output on every cycle.
// R958: st_wheel (status[71:70], "Analog control") adds two wheel layouts,
// GitHub #12; Standard (0, the default) is the block as before, bit for bit.

`timescale 1ns/1ps

module m2_cab_inputs #(
  parameter int unsigned SYS_MHZ = 80
) (
  input  logic        clk,          // clk_sys
  input  logic        rst_n,        // cpu_rst_n: the game reset
  input  logic        is_desert,    // game_id 2 (R835)
  input  logic [31:0] joystick_0,
  input  logic [15:0] joy_analog,   // left stick
  input  logic [15:0] joy_ranalog,  // right stick
  input  logic  [7:0] paddle,
  input  logic        st_pedswap,   // status[28]  Pedals
  input  logic  [1:0] st_ssens,     // status[30:29] Steering
  input  logic  [1:0] st_ssm,       // status[51:50] Steering smoothing
  input  logic        st_rsteer,    // status[54]  Right stick
  input  logic  [1:0] st_wheel,     // status[71:70] Analog control (R958): 0 Standard, 1 Wheel A, 2 Wheel B
  output logic  [7:0] in0,          // the I/O board's IN0 / IN1, active low
  output logic  [7:0] in1,
  output logic  [7:0] steer,        // its ADC channels 0..2 (Desert Tank:
                                    // HANDLE, ACCEL, TURRET -- R837)
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

// R835: DESERT TANK'S IN1 -- model2.cpp INPUT_PORTS_START(desert): 0x01
// Shift (PORT_TOGGLE), 0x10 Machine Gun, 0x20 Cannon, the rest unused; all
// active low. IN0 is Daytona's bit for bit (VR1/2/3 at 0x20/0x40/0x80), so
// it is shared. The buttons keep the J1 line's positions -- the Desert Tank
// MRA renames them (Model 1's <buttons names>, no CONF_STR change): VR4
// becomes Shift, Gear Up / Gear Down become Machine Gun / Cannon.
// SHIFT IS A LEVER, NOT A BUTTON: the cabinet's forward / reverse switch
// latches, and MAME models it as a toggle. Out of reset it reads 1
// (released), MAME's default -- forward. R837: the Forward / Reverse buttons
// now set it, and VR4 still flips it; the register is at the end of this
// file, beside the drive pedal it goes with.
// R838: THE BOARD SAYS THE OTHER WAY ROUND. With bit 0 low for reverse
// (R837, read off MAME's input test) Ben's Forward drove the tank backwards
// and Reverse forwards on s1107, so bit 0 is HIGH in reverse. Out of reset
// it is 0: forward.
logic dt_shift;                      // 1 = lever in reverse (IN1 bit 0 high, R838)
wire [7:0] iob_in1_dt = {2'b11, ~joystick_0[13], ~joystick_0[12], 3'b111, dt_shift};
assign in1 = is_desert ? iob_in1_dt : {1'b1, gearval, 3'b111, ~joystick_0[9]};

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
// R958: ANALOG CONTROL, Wheel A / Wheel B (GitHub #12). The wheel is the
// left stick's X, always, with no dead zone (a wheel's first degrees are
// steering, not noise), and the right stick never steers (Wheel B's brake
// is on its X). The d-pad still steers while its left or right is held.
// Standard (0, and the unused 3) is everything above, unchanged.
reg  [2:0]        wheel0_s, wheel1_s;
always_ff @(posedge clk) begin
	wheel0_s <= {wheel0_s[1:0], st_wheel[0]};
	wheel1_s <= {wheel1_s[1:0], st_wheel[1]};
end
wire              whl_a = wheel0_s[2] & ~wheel1_s[2];    // 1: Wheel A
wire              whl_b = wheel1_s[2] & ~wheel0_s[2];    // 2: Wheel B
wire              whl   = whl_a | whl_b;
wire signed [7:0] ax    = (use_l || whl) ? ax_l : ax_r;

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
wire use_stick = whl ? !(joystick_0[1] || joystick_0[0])   // R958: the wheel unless the d-pad steers
                    : (use_l || use_r);                    // R816
wire [7:0] steer_raw = |paddle ? paddle
                 : use_stick ? steer_an
                 : steer_dig;
// R843: steer_raw REGISTERED. The stick's path -- the dead zone's stick
// select, the sensitivity scale, the centre and the ADC clamp -- into the
// limiter's compare was one clk_sys cycle and failed it on every seed of
// b8b890c (s1117 -0.625, s1119 -1.885: joy_analog_q -> steer_lim). One
// cycle later from every source (paddle, stick, d-pad) alike; the limiter
// and the output read the register. The bench's reference carries the same
// register (sim/io/m2_cab_inputs_ref.sv), so the comparison still proves
// nothing else moved.
reg [7:0] steer_rq;
always_ff @(posedge clk) steer_rq <= steer_raw;

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
		steer_lim <= steer_rq; steer_slew <= '0;
	end else if (steer_slew == 18'd0) begin
		steer_slew <= (ssm == 2'd1) ? 18'(STEER_K_LT - 1) : 18'(STEER_K_WH - 1);
		if (steer_lim < steer_rq)       steer_lim <= steer_lim + 8'd1;
		else if (steer_lim > steer_rq)  steer_lim <= steer_lim - 8'd1;
	end else
		steer_slew <= steer_slew - 18'd1;
end
assign steer = (ssm == 2'd0) ? steer_rq : steer_lim;

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
// R835: DESERT TANK USES THESE RANGES AS THEY ARE. MAME gives its pedals
// 0x00..0xff and its wheel 0x00..0xff (no PORT_MINMAX), but the game itself
// clamps: in MAME 0.289 a race with the accelerator held at 0x20 is the same
// run, frame for frame, as one at 0x00 ("GAS PEDAL", the tank stands), 0xe0
// the same as 0xff, and the wheel held at 0x20 / 0xe0 the same as 0x00 /
// 0xff (sim/io/mame_m2_desert.lua, DT_ACCV / DT_STEERV; identical PNGs at
// every second, 60 s of play). So Daytona's 0x20..0xe0 is full travel there.
wire        [7:0] accel_an  = pedal_up ? pedal_an : 8'h20;
wire        [7:0] brake_an  = pedal_up ? 8'h20    : pedal_an;

// R958: THE WHEEL LAYOUTS' PEDALS, one axis each (GitHub #12, the request's
// own description of what MiSTer Main reports):
//   Wheel A (older wheels; the cathoderayblog guide) -- accelerator on the
//     left stick's Y, brake on the right stick's Y: centre released, full up
//     (0 .. -127) fully pressed; the lower half reads released.
//   Wheel B (direct-drive pedal sets, e.g. Logitech RS50) -- the whole axis:
//     accelerator on the left stick's Y, -127 (up) released .. +127 (down)
//     fully pressed; brake on the right stick's X, -127 (left) released ..
//     +127 (right) fully pressed. (v + 127) / 2 is the seven-bit magnitude,
//     -128 reading as released.
// Both feed the magnitude through the right-stick pedals' 3/2 scaling (0x20
// at rest, 0xde at full), so a pedal reaches what a pad's stick does.
// "Pedals: Swapped" exchanges the two pedals; the Accel / Brake buttons
// still give full travel. Registered: the stick's value moves at USB rates,
// and this keeps the new arithmetic off the paths R842 / R934 timed.
function automatic logic [6:0] whl_up(input logic [7:0] v);   // Wheel A: up half
	return (v == 8'h80) ? 7'd127 : v[7] ? (~v[6:0] + 7'd1) : 7'd0;
endfunction
/* verilator lint_off UNUSEDSIGNAL */
function automatic logic [6:0] whl_full(input logic [7:0] v);  // Wheel B: whole axis
	logic [7:0] u;                      // (u[0]: the half step dropped)
	u = v + 8'd127;                     // -127 -> 0, +127 -> 254; -128 wraps to 255
	return (v == 8'h80) ? 7'd0 : u[7:1];
endfunction
/* verilator lint_on UNUSEDSIGNAL */
function automatic logic [7:0] whl_an(input logic [6:0] m);    // pedal_an's scaling
	logic [8:0] s;
	s = {2'd0, m} + {3'd0, m[6:1]};
	return (s >= 9'd192) ? 8'he0 : (8'h20 + s[7:0]);
endfunction
wire        [6:0] whl_acc_c = whl_b ? whl_full(joy_analog[15:8])  : whl_up(joy_analog[15:8]);
wire        [6:0] whl_brk_c = whl_b ? whl_full(joy_ranalog[7:0])  : whl_up(joy_ranalog[15:8]);
reg         [6:0] whl_acc_m, whl_brk_m;     // after "Pedals"
reg         [7:0] whl_acc_an, whl_brk_an;
always_ff @(posedge clk) begin
	whl_acc_m  <= st_pedswap ? whl_brk_c : whl_acc_c;
	whl_brk_m  <= st_pedswap ? whl_acc_c : whl_brk_c;
	whl_acc_an <= whl_an(st_pedswap ? whl_brk_c : whl_acc_c);
	whl_brk_an <= whl_an(st_pedswap ? whl_acc_c : whl_brk_c);
end
wire        [7:0] dy_accel  = joystick_0[10] ? 8'he0 : whl ? whl_acc_an : accel_an;   // Daytona's, as before
wire        [7:0] dy_brake  = joystick_0[11] ? 8'he0 : whl ? whl_brk_an : brake_an;

// ------------------------------------------------- R837: Desert Tank's ADC
//
// THE GAME NAMES ITS CHANNELS (service mode, INPUT TEST, MAME 0.289):
// HANDLE (0), ACCEL (1), TURRET (2) -- three, and nothing on 3-7. There is
// no brake: channel 2 is the CANNON'S ELEVATION, an absolute position with
// 0x80 at centre (MAME's own default for it), lower = aim up (the crosshair
// at the top of the screen by 0x28), higher = aim down; the game slews the
// gun to it in about a second. Feeding it a pedal's idle 0x20 is what
// pinned the board's cannon straight up (s1104). ACCEL is the only drive
// pedal, and the shift lever (IN1 bit 0, low = reverse) chooses which way it
// drives; let go and the tank stops.
//
// So, for a pad: Forward / Reverse (the Accel / Brake buttons, which players
// put on the triggers) press the one drive pedal fully AND set the lever --
// Reverse wins if both are held. The right stick's Y aims the cannon,
// centred at rest; the d-pad's up / down move a held aim for anyone without
// a right stick. "Right stick: Pedals+steer" (a wheel: X steers, Y the
// pedals) keeps that meaning here: Y drives, its sign choosing the lever,
// and the cannon is the d-pad's. "Pedals: Swapped" flips the right stick's
// Y in both modes. VR4 still flips the lever, as a cabinet's would be.
// R958: Wheel A / B are a wheel too: the accelerator pedal drives forward
// and the brake pedal in reverse, whichever is pressed further (past the
// same dead zone), the lever following; the cannon is the d-pad's.
wire              dt_wheel  = rsteer_s[2] || whl;
wire              dt_fwd_b  = joystick_0[10];
wire              dt_rev_b  = joystick_0[11];
wire              dt_wfwd   = (whl_acc_m >= whl_brk_m);
wire        [6:0] dt_mag    = whl ? (dt_wfwd ? whl_acc_m : whl_brk_m) : pedal_mag;
wire              dt_up     = whl ? dt_wfwd : pedal_up;
wire              dt_ped_on = dt_wheel && (dt_mag > 7'd12);
wire              dt_go_rev = dt_rev_b || (!dt_fwd_b && dt_ped_on && !dt_up);
wire              dt_go_fwd = !dt_rev_b && (dt_fwd_b || (dt_ped_on && dt_up));
logic             dt_shf_d;
always_ff @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		dt_shift <= 1'b0; dt_shf_d <= 1'b0;
	end else begin
		dt_shf_d <= joystick_0[9];
		if (dt_go_rev)                         dt_shift <= 1'b1;
		else if (dt_go_fwd)                    dt_shift <= 1'b0;
		else if (joystick_0[9] && !dt_shf_d)   dt_shift <= ~dt_shift;
	end
end
// The drive pedal: a button is a full press; a wheel's pedal is analogue,
// Daytona's scaling, and held at rest inside the dead zone so the tank stands.
wire        [7:0] dt_accel  = (dt_fwd_b || dt_rev_b) ? 8'he0
                            : !dt_ped_on ? 8'h20
                            : !whl ? pedal_an
                            : dt_wfwd ? whl_acc_an : whl_brk_an;   // R958

// The turret. Three quarters of the stick is exactly +-96 about 0x80, the
// steering's arithmetic; -128 negated is +128, which ten bits hold.
wire signed [7:0] ry        = joy_ranalog[15:8];
wire signed [9:0] ry_x      = st_pedswap ? -{{2{ry[7]}}, ry} : {{2{ry[7]}}, ry};
wire signed [9:0] ry_sc     = ry_x - (ry_x >>> 2);
wire        [7:0] tur_an    = 8'h80 + ry_sc[7:0];
wire              tur_use   = !dt_wheel && ((ry > 8'sd12) || (ry < -8'sd12));
// The d-pad's aim HOLDS where it is left (a cannon has no spring), one count
// every ~7.8 ms: the full 0x20..0xe0 in 1.5 s.
localparam int unsigned TUR_K = SYS_MHZ * 7812;
logic [7:0]  tur_dig;
logic [19:0] tur_div;
always_ff @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		tur_dig <= 8'h80; tur_div <= '0;
	end else if (tur_div == 20'd0) begin
		tur_div <= 20'(TUR_K - 1);
		if (joystick_0[3] && !joystick_0[2]) begin           // up: aim up
			if (tur_dig > 8'h20) tur_dig <= tur_dig - 8'd1;
		end else if (joystick_0[2] && !joystick_0[3]) begin  // down
			if (tur_dig < 8'he0) tur_dig <= tur_dig + 8'd1;
		end
	end else
		tur_div <= tur_div - 20'd1;
end
wire        [7:0] tur_raw   = tur_use ? tur_an : tur_dig;
// A SLEW LIMIT, BECAUSE THE GAME'S GUN SERVO BREAKS ON A BIG DOWNWARD JUMP.
// MAME 0.289 (sim/io/mame_m2_desert_input.lua): with the gun fully up, a
// jump of the TURRET value to 0xc8 or beyond (0x20 -> 0xc8 / 0xd0 / 0xe0,
// 0x30 -> 0xe0) sends the gun the wrong way -- it stays pinned up, ignores
// the input for 10-20 s and comes back inverted for a while -- where 0x20 ->
// 0xc0 and 0x30 -> 0xb8 work, every upward jump works, and a ramp from 0x20
// to 0xe0 over 0.5 s or more works. A stick flicked from full up to full
// down does exactly the breaking thing. So the value moves one count each
// ~3.9 ms -- 0x20..0xe0 in 0.75 s, faster than the gun itself (~0x60 in
// 0.6 s), so nothing is lost but the jump.
localparam int unsigned TUR_S = SYS_MHZ * 3906;
logic [7:0]  dt_turret;
logic [18:0] tur_sdiv;
always_ff @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		dt_turret <= 8'h80; tur_sdiv <= '0;
	end else if (tur_sdiv == 19'd0) begin
		tur_sdiv <= 19'(TUR_S - 1);
		if (dt_turret < tur_raw)      dt_turret <= dt_turret + 8'd1;
		else if (dt_turret > tur_raw) dt_turret <= dt_turret - 8'd1;
	end else
		tur_sdiv <= tur_sdiv - 19'd1;
end

assign accel = is_desert ? dt_accel  : dy_accel;
assign brake = is_desert ? dt_turret : dy_brake;

endmodule
