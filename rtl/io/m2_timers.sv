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
// THE FOUR MAIN-BOARD TIMERS at 0x00f00000-0x00f0000f (R852), after MAME
// 0.289 model2.cpp timers_r / timers_w / model2_timer_cb:
//   write   the timer's value (byte enables combine), it starts counting
//           down at 25 MHz from there
//   read    the value now (start - elapsed) while running, else the value
//           last left in it
//   zero    the timer stops, its value becomes 0xFFFFF, and `expire` pulses
//           (the board raises interrupt request bit timer + 2 if enabled)
// A write of 0 expires at once. The 25 MHz count is a fractional enable on
// clk (TICK_NUM / TICK_DEN per clock, 25 / SYS_MHZ).
//
// Virtua Fighter 2 needs them (R852, MAME): timer 3 is its interrupt source
// beside the vblank (enable 0x21) -- the sound UART's bytes are sent from the
// chain it starts -- and timers 0-2 are stopwatches it busy-waits on. The
// original board's Daytona never touches them and Desert Tank only reads one
// as a profiler (R835), so the original core does not build this.

`timescale 1ns/1ps

module m2_timers #(
  parameter int unsigned TICK_NUM = 5,     // 25 MHz from 80 MHz
  parameter int unsigned TICK_DEN = 16
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        sel,       // one cycle per access to 0x00f00000-0x00f0000f
  input  logic        we,
  input  logic  [1:0] idx,       // addr[3:2]
  input  logic  [3:0] be,
  input  logic [31:0] wdata,
  output logic [31:0] rdata,
  output logic  [3:0] expire
);

  localparam int unsigned AW = $clog2(TICK_DEN + TICK_NUM + 1);
  logic [AW-1:0] acc;
  logic          tick;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin acc <= '0; tick <= 1'b0; end
    else if (acc + AW'(TICK_NUM) >= AW'(TICK_DEN)) begin
      acc <= acc + AW'(TICK_NUM) - AW'(TICK_DEN); tick <= 1'b1;
    end else begin
      acc <= acc + AW'(TICK_NUM); tick <= 1'b0;
    end
  end

  logic [31:0] val [4];
  logic  [3:0] run;

  assign rdata = val[idx];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 4; i++) val[i] <= 32'h000fffff;
      run <= 4'd0; expire <= 4'd0;
    end else begin
      expire <= 4'd0;
      for (int i = 0; i < 4; i++) begin
        if (run[i] && val[i] == 32'd0) begin
          run[i] <= 1'b0; val[i] <= 32'h000fffff; expire[i] <= 1'b1;
        end else if (run[i] && tick)
          val[i] <= val[i] - 32'd1;
      end
      if (sel && we) begin
        val[idx] <= { be[3] ? wdata[31:24] : val[idx][31:24],
                      be[2] ? wdata[23:16] : val[idx][23:16],
                      be[1] ? wdata[15: 8] : val[idx][15: 8],
                      be[0] ? wdata[ 7: 0] : val[idx][ 7: 0] };
        run[idx] <= 1'b1;
      end
    end
  end

endmodule
