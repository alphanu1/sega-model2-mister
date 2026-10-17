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
// THE MODEL 2A CABINET (study R862): what the 315-5649 reads -- ports B / C /
// D (IN0, IN1, IN2, active low unless MAME says otherwise) and its analog
// channels 0-2 -- for each 2A game, from MiSTer's joysticks, sticks and
// paddle, after MAME 0.289 model2.cpp's INPUT_PORTS. The game is the MRA's
// game ID (Model2.sv); each MRA's <buttons names> fixes which joystick bit is
// which button (bit 4 the first name), so the maps below follow the MRAs.
//
//   VF2 (game 0)  model2crx + vf2. Moved here from Model2.sv (R852) and
//                 unchanged: tb_m2_2a_inputs compares it bit for bit against
//                 the expressions as they stood.
//     J  4 Punch 5 Kick 6 Guard 7 Start 8 Coin 9 Test 10 Service
//     IN0 0 coin1 1 coin2 2 test 3 service 4 start1 5 start2
//     IN1 0 punch 1 kick 2 guard 3 - 4 down 5 up 6 right 7 left (P1)
//     IN2 the same for P2 (joystick 1)
//   Sega Rally (RALLY) srallyc + gears. The analog side is m2_cab_inputs,
//                 Daytona's block, unchanged (its OSD options: Pedals,
//                 Steering, Steering smoothing, Right stick): MAME 0.289
//                 measured (R862) -- the game reads steering 0x20 as 0x00
//                 and 0xE0 as 0xFF, the accelerator 0x00..0x30 as rest and
//                 0xC0..0xFF as full, the brake at 0x20 / 0x30 as at 0x00 --
//                 so its 0x20..0xE0 is full travel here as on Daytona.
//     J  (Daytona's order) 4 Coin 5 Start 6 Test 7 Service 8 View
//        9 Hand Brake 10 Accel 11 Brake 12 Gear Up 13 Gear Down
//     IN0 0 coin1 1 coin2 2 test 3 service 4 - 5 VR (view) 6 start1 7 -
//     IN1 6:4 the shifter, ACTIVE HIGH: daytona_gearbox_r's {N,1,2,3,4} ->
//         {0,2,1,6,5}; 3:0 and 7 unused (1)
//     IN2 the hand brake, MAME's PEDAL3: 0x00 at rest -- a button: 0xFF held
//     AN0 steering (0x80 centre), AN1 accelerator, AN2 brake
//   Virtua Cop 2 (vcop2). The guns' POSITION is not here: R870 reads it
//                 through the 315-5649's serial channel 2 (m2_315_5649 GUN),
//                 from Virtua Cop's driver m2_vcop_guns (V2). R870: the
//                 buttons are Virtua Cop's (its MRA's order, so the same
//                 driver reads them), and with GUN the triggers come from
//                 the driver (the mouse's button, Reload's shot off-screen).
//     J  4 Trigger 5 Reload 6 Start 7 Coin 8 Test 9 Service (P2: joystick 1)
//     IN0 model2's; IN1 0 P1 trigger 1 P2 trigger, rest unused; IN2 0xFF
//   Zero Gunner (zeroguna). model2crx with IN1 / IN2 0x0c unused.
//     J  4 Button 1 5 Button 2 6 Start 7 Coin 8 Test 9 Service
//     IN0 model2's; IN1 0 b1 1 b2 4 down 5 up 6 right 7 left; IN2 P2
//     SW  SW3, 0xFF (bit 0 low would enable the debug menu)
// Analog channels the game has none on read 0xFF (MAME's unbound default).

`timescale 1ns/1ps

module m2_2a_inputs #(
  parameter int unsigned SYS_MHZ = 80,
  parameter bit          RALLY   = 1'b1,  // Sega Rally's analog block (M2_2A_RALLY)
  parameter bit          GUN     = 1'b0   // R870: Virtua Cop 2's IN1 from the guns (M2_2A_VCOP2_GUN)
) (
  input  logic        clk,          // clk_sys
  input  logic        rst_n,        // cpu_rst_n: the game reset
  input  logic        is_srally,    // game ID 0x10
  input  logic        is_vcop2,     // 0x11
  input  logic        is_zerogun,   // 0x12
  input  logic [31:0] joystick_0,
  input  logic [31:0] joystick_1,
  input  logic [15:0] joy_analog,   // left stick (registered by the caller)
  input  logic [15:0] joy_ranalog,  // right stick
  input  logic  [7:0] paddle,
  input  logic        st_pedswap,   // status[28]  Pedals
  input  logic  [1:0] st_ssens,     // status[30:29] Steering
  input  logic  [1:0] st_ssm,       // status[51:50] Steering smoothing
  input  logic        st_rsteer,    // status[54]  Right stick
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic  [7:0] gun_in1,      // R870 (GUN): m2_vcop_guns in1, the triggers
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

  // ---- VF2, exactly R852's expressions (Model2.sv at 9fb631d)
  wire [7:0] vf_in0 = ~{2'b00, j1[7], j0[7], j0[10], j0[9], j1[8], j0[8]};
  wire [7:0] vf_in1 = ~{j0[1], j0[0], j0[3], j0[2], 1'b0, j0[6], j0[5], j0[4]};
  wire [7:0] vf_in2 = ~{j1[1], j1[0], j1[3], j1[2], 1'b0, j1[6], j1[5], j1[4]};

  // ---- Zero Gunner: the stick, two buttons
  wire [7:0] zg_in0 = ~{2'b00, j1[6], j0[6], j0[9], j0[8], j1[7], j0[7]};
  wire [7:0] zg_in1 = ~{j0[1], j0[0], j0[3], j0[2], 2'b00, j0[5], j0[4]};
  wire [7:0] zg_in2 = ~{j1[1], j1[0], j1[3], j1[2], 2'b00, j1[5], j1[4]};

  // ---- Virtua Cop 2: the triggers (both on IN1), starts and coins; R870
  // Virtua Cop's button order (m2_vcop_guns' in0 is this same map)
  wire [7:0] v2_in0 = ~{2'b00, j1[6], j0[6], j0[9], j0[8], j1[7], j0[7]};
  wire [7:0] v2_in1 = GUN ? gun_in1 : ~{6'b000000, j1[4], j0[4]};

  // ---- Sega Rally
  wire [7:0] sr_in0 = ~{1'b0, j0[5], j0[8], 1'b0, j0[7], j0[6], 1'b0, j0[4]};
  wire [7:0] cab_in0, cab_in1, cab_steer, cab_accel, cab_brake;
  generate if (RALLY) begin : g_rally
    // Daytona's block: its IN1 carries the shifter at 6:4 (daytona_gearbox_r,
    // Gear Up / Down on J 12 / 13) and its ADC values are 0x20..0xE0.
    m2_cab_inputs #(.SYS_MHZ(SYS_MHZ)) u_cab (
      .clk(clk), .rst_n(rst_n), .is_desert(1'b0),
      .joystick_0(joystick_0), .joy_analog(joy_analog), .joy_ranalog(joy_ranalog),
      .paddle(paddle),
      .st_pedswap(st_pedswap), .st_ssens(st_ssens), .st_ssm(st_ssm), .st_rsteer(st_rsteer),
      .in0(cab_in0), .in1(cab_in1), .steer(cab_steer), .accel(cab_accel), .brake(cab_brake)
    );
  end else begin : g_norally
    assign cab_in0 = 8'hFF; assign cab_in1 = 8'h8F; assign cab_steer = 8'h80;
    assign cab_accel = 8'h20; assign cab_brake = 8'h20;
  end endgenerate
  wire [7:0] sr_in1 = {1'b1, cab_in1[6:4], 4'b1111};
  wire [7:0] sr_in2 = j0[9] ? 8'hFF : 8'h00;

  always_ff @(posedge clk) begin
    if (is_srally) begin
      in0 <= sr_in0; in1 <= sr_in1; in2 <= sr_in2;
      an0 <= cab_steer; an1 <= cab_accel; an2 <= cab_brake;
    end else begin
      in0 <= is_vcop2 ? v2_in0 : is_zerogun ? zg_in0 : vf_in0;
      in1 <= is_vcop2 ? v2_in1 : is_zerogun ? zg_in1 : vf_in1;
      in2 <= is_vcop2 ? 8'hFF  : is_zerogun ? zg_in2 : vf_in2;
      an0 <= 8'hFF; an1 <= 8'hFF; an2 <= 8'hFF;
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, j0[31:14], j1[31:9], cab_in0, cab_in1[7], cab_in1[3:0]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
