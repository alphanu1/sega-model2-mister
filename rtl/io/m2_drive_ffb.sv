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
// R966: DAYTONA USA'S DRIVE BOARD, AS A FORCE FEEDBACK REQUEST FOR MAIN.
//
// WHAT. The cabinet's drive board (838-10646, EPR-16488A) takes one byte from
// the I/O board's 315-5338A port E and turns the wheel motor. MAME runs that
// board's Z80 but leaves its motor output unconnected (model2.cpp,
// driveio_port_w: "TODO: hook up to the main CPU"), so MAME has no reference
// for the force. This module does not run EPR-16488A either: it models the
// board's command handling and hands the effect to MiSTer Main through
// hps_io's joystick_0_ffb word (UIO_GET_FFB, 0x45), and Main plays it on the
// player's force feedback wheel through evdev.
//
// THE BYTE IS A LEVEL, NOT AN EVENT. The game writes DPRAM 0x11 only when the
// command changes; the I/O board's firmware copies it to port E once per pass
// of its loop, about once a frame (measured in MAME 0.289, 9,038 PE writes in
// 9,038 frames). A byte written twice inside one pass never leaves the I/O
// board (race start: the game wrote 07 27 71 07 10 3B, PE carried 07 71 07 3B).
//
// ACCEPTANCE, AS THE DRIVE BOARD DOES IT. Its Z80 samples the bus in its
// interrupt and acts on a byte only after reading the same value twice in a
// row (EPR-16488A 0x0520-0x052A: compare with E141, store and return on a
// mismatch). Here the sample is taken once per video frame (the core's own
// vblank, `frame`) and a byte is taken when it equals the previous sample, so
// a byte held for less than one frame is never taken and one held for two
// always is. Nothing is sampled until the firmware has written port E at
// least once after reset: the latch's reset value is not a command.
//
// THE DECODE is rt::DriveBoard from daytona-arcade-recomp
// (github.com/alphanu1/daytona-arcade-recomp, src/runtime/drive_board.h at
// f32c48ff9b, BSD-3-Clause), command for command; strength n = cmd[2:0]:
//   0x0-  motor on when cmd == 0x0A or n >= 5, off otherwise
//   0x1-  no force                  0x2-  resistance (0x28-2F: no force)
//   0x3-  centring (0x38-3F: the same, with a dead zone)
//   0x4-  uncentring: away from the centre (0x48-4F: no force)
//   0x5- / 0x6-  constant force, opposite ways (0x58-5F / 0x68-6F: no force)
//   0x7- and 0x80-0xFF  the effect is unchanged (a spring parameter, queries)
// Levels, of the board's strongest command: (7 + 2n) / 31 for the springs and
// resistance, (17 + 2n) / 31 for uncentring and the constant force; 0 when
// the motor is off or another effect runs.
//
// TO MAIN'S WORD (sys/hps_io.sv, joystick_N_ffb):
//   [55:48] flags   bit 0 ACTIVE: Main drives the wheel from this word;
//                   bit 1 CENTRE: the core supplies the centring (= ACTIVE).
//                   ACTIVE = built for this game, the OSD on, and a byte taken.
//   [47:32] constant, signed, positive pushes the wheel RIGHT
//                   0x5-: LEFT by default (SailorSat's notes, written driving
//                   real boards; FFBArcadePlugin; sm2-emu; BackForceFeeder for
//                   the related EPR-18261 -- recomp and m2-hle2 say right).
//                   Not checked on a cabinet: `invert` flips it, and the
//                   uncentring push with it.
//                   Uncentring: level * 32767 away from the centre by the
//                   steering value the I/O board's ADC reads (0x80 centre,
//                   higher = right -- the game's own mapping, MAME daytona
//                   with STEER 0xE0 drives into the right-hand wall), 0 within
//                   DEAD counts of the centre.
//   [31:24] spring  centring level * 255, both kinds. THE DEAD ZONE OF
//                   0x38-0x3F IS NOT EXPRESSIBLE: the word has no deadband.
//                   With no motor force (motor off, or a no-force command)
//                   IDLE_SPRING, ~20%, for the cabinet's mechanical return
//                   spring a USB wheel does not have (sm2-emu's figure).
//   [23:16] damper  0
//   [15:8]  friction  resistance level * 255
//   [7:0]   vibration  0 (the board has no vibration command)
//
// NOT MODELLED: the board's power ramp (one step per interrupt), its start-up
// calibration and DIP switches, the 0x7- slope, and the dead zones (above).
// Other wheel games use other boards (Sega Rally 838-11661, EPR-18261 for
// Indy 500 / STCC / Over Rev / Super GT) with other protocols; `en` is low
// for them.

`timescale 1ns/1ps

module m2_drive_ffb #(
  parameter logic [7:0] DEAD        = 8'd2,    // uncentring: no push within +-DEAD of 0x80
  parameter logic [7:0] IDLE_SPRING = 8'd51    // 20% of 255
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        en,       // built, and the game is Daytona (quasi-static)
  input  logic        on,       // OSD: Force feedback On
  input  logic        invert,   // OSD: FFB direction Invert
  input  logic  [7:0] pe_cmd,   // the 315-5338A's port E latch
  input  logic        pe_stb,   // one clk per firmware write to port E
  input  logic        frame,    // one clk per video frame (vblank)
  input  logic  [7:0] steer,    // the steering value the I/O board's ADC reads
  output logic [55:0] ffb       // hps_io joystick_0_ffb
);

  localparam logic [2:0] E_NONE = 3'd0, E_RES = 3'd1, E_CEN = 3'd2, E_CDZ = 3'd3,
                         E_UNC  = 3'd4, E_FORCE = 3'd5;

  // ------------------------------------------------------------ acceptance
  logic       seen;      // port E written since reset
  logic       have;      // smp holds a sample
  logic [7:0] smp;       // the previous frame's sample
  logic       started;   // a byte has been taken
  // rt::DriveBoard's state
  logic       motor;
  logic [2:0] eff;
  logic [2:0] n;
  logic       dir5;      // the force is 0x5- (else 0x6-)

  wire take = frame && seen && have && (pe_cmd == smp);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      seen <= 1'b0; have <= 1'b0; smp <= 8'd0; started <= 1'b0;
      motor <= 1'b0; eff <= E_NONE; n <= 3'd0; dir5 <= 1'b0;
    end else begin
      if (pe_stb) seen <= 1'b1;
      if (frame && seen) begin smp <= pe_cmd; have <= 1'b1; end
      if (take) begin
        started <= 1'b1;
        case (pe_cmd[7:4])
          4'h0: motor <= (pe_cmd == 8'h0A) || (pe_cmd[2:0] >= 3'd5);
          4'h1: begin eff <= E_NONE; n <= 3'd0; end
          4'h2: begin eff <= pe_cmd[3] ? E_NONE : E_RES; n <= pe_cmd[2:0]; end
          4'h3: begin eff <= pe_cmd[3] ? E_CDZ  : E_CEN; n <= pe_cmd[2:0]; end
          4'h4: begin eff <= pe_cmd[3] ? E_NONE : E_UNC; n <= pe_cmd[2:0]; end
          4'h5, 4'h6: begin
            eff <= pe_cmd[3] ? E_NONE : E_FORCE; n <= pe_cmd[2:0];
            dir5 <= (pe_cmd[7:4] == 4'h5);
          end
          default: ;   // 0x7- and up: unchanged
        endcase
      end
    end
  end

  // ------------------------------------------------------------ the word
  // round((7 + 2n) * 255 / 31) and (17 + 2n) * 32767 / 31 = (17 + 2n) * 1057.
  logic  [7:0] lvl8;
  logic [15:0] lvl16;
  always_comb begin
    case (n)
      3'd0: begin lvl8 = 8'd58;  lvl16 = 16'd17969; end
      3'd1: begin lvl8 = 8'd74;  lvl16 = 16'd20083; end
      3'd2: begin lvl8 = 8'd90;  lvl16 = 16'd22197; end
      3'd3: begin lvl8 = 8'd107; lvl16 = 16'd24311; end
      3'd4: begin lvl8 = 8'd123; lvl16 = 16'd26425; end
      3'd5: begin lvl8 = 8'd140; lvl16 = 16'd28539; end
      3'd6: begin lvl8 = 8'd156; lvl16 = 16'd30653; end
      default: begin lvl8 = 8'd173; lvl16 = 16'd32767; end
    endcase
  end

  wire act    = en && on && started;
  wire idle   = !motor || (eff == E_NONE);
  wire right  = steer > (8'h80 + DEAD);
  wire left   = steer < (8'h80 - DEAD);
  wire push   = motor && ((eff == E_FORCE) || ((eff == E_UNC) && (right || left)));
  // negative = left: 0x5- is left; uncentring pushes the way the wheel is turned
  wire neg    = ((eff == E_FORCE) ? dir5 : left) ^ invert;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) ffb <= 56'd0;
    else if (!act) ffb <= 56'd0;
    else begin
      ffb[55:48] <= 8'h03;                                            // ACTIVE, CENTRE
      ffb[47:32] <= !push ? 16'd0 : neg ? (16'd0 - lvl16) : lvl16;
      ffb[31:24] <= idle ? IDLE_SPRING : ((eff == E_CEN) || (eff == E_CDZ)) ? lvl8 : 8'd0;
      ffb[23:16] <= 8'd0;
      ffb[15:8]  <= (motor && (eff == E_RES)) ? lvl8 : 8'd0;
      ffb[7:0]   <= 8'd0;
    end
  end

endmodule
