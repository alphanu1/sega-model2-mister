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
// THE MODEL 2A CABINET (study R862, R887): what the 315-5649 reads -- ports
// B / C / D (IN0, IN1, IN2, active low unless MAME says otherwise) and its
// analog channels 0-2 -- from MiSTer's joysticks, sticks and paddle, after
// MAME 0.289 model2.cpp's INPUT_PORTS.
//
// R887: PROFILES, chosen by the MRA's game ID, so that a new game adds an
// MRA and not mapping logic. Each profile wires MiSTer's joystick bits to
// the ports in ONE FIXED ORDER; an MRA's <buttons names> follows that order.
// The released games' orders are the profiles' orders, unchanged (Ben: their
// MRAs do not move); a new game takes whichever fits its INPUT_PORTS.
//
//   DIGITAL, three buttons (every ID not below) -- VF2's order, MAME's
//     model2 / model2crx ports:
//     J  4 B1  5 B2  6 B3  7 Start  8 Coin  9 Test  10 Service
//        (P2 the same on joystick 1; a pad's left stick ORs into the
//        directions past a dead zone, R879)
//     IN0 0 coin1 1 coin2 2 test 3 service 4 start1 5 start2
//     IN1 0 B1 1 B2 2 B3 3 - 4 down 5 up 6 right 7 left (P1); IN2 P2
//     VF2 (0x00, Punch / Kick / Guard) is this map bit for bit (R852's
//     expressions). Hanguk Pro Yagu (vf2's ports), Dynamite Cop (Punch Kick
//     Jump) and Dead or Alive (Hold Punch Kick) take it as it is.
//   DIGITAL, two buttons (0x12 Zero Gunner, 0x15 Pilot Kids) -- Zero
//     Gunner's order, as released (R862, R879): IN1 / IN2 0x0c unused:
//     J  4 B1  5 B2  6 Start  7 Coin  8 Test  9 Service
//   ANALOG (0x10 and 0x18-0x1B; behind ANALOG, the M2_2A_RALLY switch) --
//     Daytona's m2_cab_inputs (steering from the left stick / paddle / d-pad,
//     pedals from the right stick's Y or two buttons), its four OSD lines:
//     J  4 Coin 5 Start 6 Test 7 Service 8 View 9 Hand Brake 10 Accel
//        11 Brake 12 Gear Up 13 Gear Down
//     IN0 0 coin1 2 test 3 service 5 View (VR) 6 start1 -- every game here
//     0x10 Sega Rally (srallyc): IN1 6:4 the shifter (daytona_gearbox_r's
//          {0,2,1,6,5}, ACTIVE HIGH), IN2 the hand brake (0x00 / 0xFF);
//          AN0 steering, AN1 accelerator, AN2 brake. Unchanged (R862).
//     0x18 Sky Target (skytargt): IN1 4 Machine Gun (J12) 5 Missile (J13);
//          AN0 STICKY (the left stick's Y, 0x80 + y), AN1 unbound (0xFF),
//          AN2 STICKX = the steering REVERSED (PORT_REVERSE: 0xFF - v).
//     0x19 Manx TT, 0x1A Motor Raid (manxtt port set): IN1 4 Shift Up /
//          Punch (J12) 5 Shift Down / Kick (J13); AN0 THROTTLE (the
//          accelerator), AN1 BRAKE, AN2 BANK = the steering reversed.
//     IN1 / IN2's other bits 1 (unused / unknown, active low).
//     R892, MOTION: Manx TT's DX cabinet (0x19 only) -- its Active Motion
//          Slider's drive board on PE (command, written every frame) and PD
//          (status, IN2). The boot's check (program 0x5f530; RAM 0x514034
//          command, 0x514035 status) puts 0x3D on PE and waits for 0xCE, then
//          sends the bike's centre (0xFF - EEPROM 0x51406f) and waits for
//          0xCD; anything else and the DANGER screen stays until Test
//          (MAME, PD 0xFF). A working base is answered here: PD = 0xCE while
//          PE holds 0x3D, else 0xCD. Nothing else reads PD in a race (the
//          test menu's "DriveBoard Test" does, and still reports an error).
//          Off (MOTION 0): IN2 0xFF, the check stops as in MAME.
//     R928, OVER REV (0x1C, 2C builds: OREV): MAME's overrev ports (indy500's
//          with the pedals PORT_REVERSE): IN0 6 start1 and coin / test /
//          service as the block's (bit 5 unused, 1); IN1 0 View 1 (J8) 1
//          View 2 (J9) 4 Shift Up (J12) 5 Shift Down (J13), the rest 1;
//          IN2 0xFF. AN0 STEER, AN1 ACCEL, AN2 BRAKE, each the block's
//          0x20..0xE0 widened to MAME's 0x00..0xFF (x 85/64 about the rest
//          point), the pedals reversed (rest 0xFF, floored 0x00): the game's
//          default with no NVRAM (MAME's note).
//   GUN (0x11, Virtua Cop 2) -- R870: Virtua Cop's buttons (its driver,
//     m2_vcop_guns, reads the same bits) and, with GUN, IN1 from the driver:
//     J  4 Trigger 5 Reload 6 Start 7 Coin 8 Test 9 Service (P2: joystick 1)
//     IN0 model2's; IN1 0 P1 trigger 1 P2 trigger, rest unused; IN2 0xFF
// Analog channels a profile does not drive read 0xFF (MAME's unbound value).

`timescale 1ns/1ps

module m2_2a_inputs #(
  parameter int unsigned SYS_MHZ = 80,
  parameter bit          ANALOG  = 1'b1,  // the analog profile's block (M2_2A_RALLY)
  parameter bit          GUN     = 1'b0,  // R870: Virtua Cop 2's IN1 from the guns (M2_2A_VCOP2_GUN)
  parameter bit          MOTION  = 1'b0,  // R892: Manx TT's motion base answered on PD (M2_2A_MANX_MOTION)
  parameter bit          OREV    = 1'b0   // R928: Over Rev's profile (0x1C; 2C builds)
) (
  input  logic        clk,          // clk_sys
  input  logic        rst_n,        // cpu_rst_n: the game reset
  input  logic  [6:0] game,         // R887: the MRA's game ID (index 4, bits 6:0)
  input  logic [31:0] joystick_0,
  input  logic [31:0] joystick_1,
  input  logic [15:0] joy_analog,   // left stick (registered by the caller)
  input  logic [15:0] joy_ranalog,  // right stick
  input  logic [15:0] joy_analog_1, // R879: player 2's left stick (registered by the caller)
  input  logic  [7:0] paddle,
  input  logic        st_pedswap,   // status[28]  Pedals
  input  logic  [1:0] st_ssens,     // status[30:29] Steering
  input  logic  [1:0] st_ssm,       // status[51:50] Steering smoothing
  input  logic        st_rsteer,    // status[54]  Right stick
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic  [7:0] gun_in1,      // R870 (GUN): m2_vcop_guns in1, the triggers
  input  logic  [7:0] pe,           // R892 (MOTION): the 315-5649's PE latch
  /* verilator lint_on UNUSEDSIGNAL */
  output logic  [7:0] in0,          // registered, as Model2.sv's were
  output logic  [7:0] in1,
  output logic  [7:0] in2,
  output logic  [7:0] an0,
  output logic  [7:0] an1,
  output logic  [7:0] an2
);

  wire [31:0] j0 = joystick_0;
  wire [31:0] j1 = joystick_1;

  // ---- the profile (quasi-static: the game ID is set once per load)
  wire p_gun    = (game == 7'h11);
  wire p_rally  = (game == 7'h10);
  wire p_an2    = (game[6:2] == 5'b00110);          // 0x18-0x1B
  wire p_sky    = p_an2 & (game[1:0] == 2'b00);     // 0x18
  wire p_dig2   = (game == 7'h12) | (game == 7'h15);  // Zero Gunner, Pilot Kids
  wire p_manx   = MOTION & (game == 7'h19);         // R892: Manx TT's motion base
  wire p_orev   = OREV & ANALOG & (game == 7'h1C);  // R928: Over Rev (2C)
  // (Model2.sv shows the analog OSD lines for 0x10 and 0x18-0x1B alike)

  // R879: a pad's left analogue stick drives the digital directions too, past
  // a dead zone of 48 of 127 either way (MiSTer's analogue word: X in 7:0, Y
  // in 15:8, signed; directions in joystick 3:0 are up, down, left, right).
  function automatic logic [3:0] adir(input logic [15:0] a);
    logic signed [7:0] x, y;
    x = a[7:0]; y = a[15:8];
    adir = {y < -8'sd48, y > 8'sd48, x < -8'sd48, x > 8'sd48};
  endfunction
  wire [31:0] d0 = {j0[31:4], j0[3:0] | adir(joy_analog)};
  wire [31:0] d1 = {j1[31:4], j1[3:0] | adir(joy_analog_1)};

  // ---- DIGITAL: exactly R852's VF2 expressions
  wire [7:0] dg_in0 = ~{2'b00, j1[7], j0[7], j0[10], j0[9], j1[8], j0[8]};
  wire [7:0] dg_in1 = ~{d0[1], d0[0], d0[3], d0[2], 1'b0, j0[6], j0[5], j0[4]};
  wire [7:0] dg_in2 = ~{d1[1], d1[0], d1[3], d1[2], 1'b0, j1[6], j1[5], j1[4]};

  // ---- DIGITAL, two buttons: Zero Gunner's map as released (R862, R879)
  wire [7:0] d2_in0 = ~{2'b00, j1[6], j0[6], j0[9], j0[8], j1[7], j0[7]};
  wire [7:0] d2_in1 = ~{d0[1], d0[0], d0[3], d0[2], 2'b00, j0[5], j0[4]};
  wire [7:0] d2_in2 = ~{d1[1], d1[0], d1[3], d1[2], 2'b00, j1[5], j1[4]};

  // ---- GUN: Virtua Cop 2 (R870)
  wire [7:0] gn_in0 = ~{2'b00, j1[6], j0[6], j0[9], j0[8], j1[7], j0[7]};
  wire [7:0] gn_in1 = GUN ? gun_in1 : ~{6'b000000, j1[4], j0[4]};

  // ---- ANALOG
  wire [7:0] an_in0 = ~{1'b0, j0[5], j0[8], 1'b0, j0[7], j0[6], 1'b0, j0[4]};
  wire [7:0] cab_in0, cab_in1, cab_steer, cab_accel, cab_brake;
  wire [7:0] sky_y;
  generate if (ANALOG) begin : g_analog
    // Daytona's block: its IN1 carries the shifter at 6:4 (daytona_gearbox_r,
    // Gear Up / Down on J 12 / 13) and its ADC values are 0x20..0xE0.
    m2_cab_inputs #(.SYS_MHZ(SYS_MHZ)) u_cab (
      .clk(clk), .rst_n(rst_n), .is_desert(1'b0),
      .joystick_0(joystick_0), .joy_analog(joy_analog), .joy_ranalog(joy_ranalog),
      .paddle(paddle),
      .st_pedswap(st_pedswap), .st_ssens(st_ssens), .st_ssm(st_ssm), .st_rsteer(st_rsteer),
      .in0(cab_in0), .in1(cab_in1), .steer(cab_steer), .accel(cab_accel), .brake(cab_brake)
    );
    // Sky Target's Y: the left stick's Y as offset binary, 0x80 + y (MAME's
    // STICKY 0x00..0xFF, up low -- as MiSTer's Y). No logic: the sign bit
    // inverted. A stick only (the d-pad steers X through the block's ramp).
    assign sky_y = {~joy_analog[15], joy_analog[14:8]};
  end else begin : g_noanalog
    assign cab_in0 = 8'hFF; assign cab_in1 = 8'h8F; assign cab_steer = 8'h80;
    assign cab_accel = 8'h20; assign cab_brake = 8'h20; assign sky_y = 8'h80;
  end endgenerate
  wire [7:0] an_in1 = p_rally ? {1'b1, cab_in1[6:4], 4'b1111}
                              : {2'b11, ~j0[13], ~j0[12], 4'b1111};
  wire [7:0] an_in2 = (p_rally & j0[9]) ? 8'hFF : p_rally ? 8'h00
                    : p_manx ? ((pe == 8'h3D) ? 8'hCE : 8'hCD)   // R892
                    : 8'hFF;
  wire [7:0] steer_rev = ~cab_steer;                  // PORT_REVERSE: 0xFF - v
  // R928: Over Rev -- the block's 0x20..0xE0 onto 0x00..0xFF: (v - 0x20) * 85 / 64
  // (0xC0 -> 0xFF exactly; a constant multiply, floor), the steering about
  // its centre 0x80 the same way (+-0x60 -> +-0x7F). ONE multiply, taken by
  // the three channels in turn (a channel every third clock: the block's
  // values move far slower) -- three in parallel mapped +155 ALUTs.
  // R934: TWO STAGES. The block's outputs are combinational from the stick
  // (pedal_an's adders), and stick -> clamp -> multiply -> or_str in one clock
  // was the worst clk_sys path of every 2C seed (-0.52 to -1.91 ns). The
  // clamped value is registered with its channel; the multiply is the next
  // clock. One clock more of latency on a value the game reads per frame.
  logic [1:0] or_ch, or_cq;
  logic [7:0] or_str, or_acc, or_brk;
  logic [7:0] or_dq;
  logic       or_uq;
  wire  [7:0] or_a   = (or_ch == 2'd0) ? cab_steer : (or_ch == 2'd1) ? cab_accel : cab_brake;
  wire        or_up  = (or_a >= 8'h80);
  wire  [7:0] or_d   = (or_ch != 2'd0) ? ((or_a < 8'h20) ? 8'd0 : (or_a > 8'hE0) ? 8'hC0 : or_a - 8'h20)
                     : or_up ? ((or_a > 8'hE0) ? 8'h60 : or_a - 8'h80)
                             : ((or_a < 8'h20) ? 8'h60 : 8'h80 - or_a);
  wire [13:0] or_p   = {or_dq, 6'd0} + {2'd0, or_dq, 4'd0} + {4'd0, or_dq, 2'd0} + {6'd0, or_dq};
  wire  [7:0] or_m   = or_p[13:6];                    // d * 85 / 64
  always_ff @(posedge clk) begin
    or_ch <= (or_ch == 2'd2) ? 2'd0 : or_ch + 2'd1;
    or_cq <= or_ch; or_dq <= or_d; or_uq <= or_up;
    case (or_cq)
      2'd0:    or_str <= or_uq ? 8'h80 + or_m : 8'h80 - or_m;
      2'd1:    or_acc <= ~or_m;                       // PORT_REVERSE
      default: or_brk <= ~or_m;
    endcase
  end
  wire [7:0] or_in0 = {an_in0[7:6], 1'b1, an_in0[4:0]};           // bit 5 unused
  wire [7:0] or_in1 = {2'b11, ~j0[13], ~j0[12], 2'b11, ~j0[9], ~j0[8]};

  always_ff @(posedge clk) begin
    if (p_orev) begin                                 // R928
      in0 <= or_in0; in1 <= or_in1; in2 <= 8'hFF;
      an0 <= or_str; an1 <= or_acc; an2 <= or_brk;
    end else if (p_rally | p_an2) begin
      in0 <= an_in0; in1 <= an_in1; in2 <= an_in2;
      an0 <= p_rally ? cab_steer : p_sky ? sky_y : cab_accel;
      an1 <= p_rally ? cab_accel : p_sky ? 8'hFF : cab_brake;
      an2 <= p_rally ? cab_brake : steer_rev;
    end else begin
      in0 <= p_gun ? gn_in0 : p_dig2 ? d2_in0 : dg_in0;
      in1 <= p_gun ? gn_in1 : p_dig2 ? d2_in1 : dg_in1;
      in2 <= p_gun ? 8'hFF  : p_dig2 ? d2_in2 : dg_in2;
      an0 <= 8'hFF; an1 <= 8'hFF; an2 <= 8'hFF;
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, j0[31:14], j1[31:9], cab_in0, cab_in1[7], cab_in1[3:0]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
