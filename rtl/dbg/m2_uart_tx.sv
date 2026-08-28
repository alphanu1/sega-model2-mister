// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// A GENUINE PRINTF. 8N1 transmitter onto the HPS UART, which sys_top.v wires
// to cyclonev_hps_interface_peripheral_uart -- the same port the Linux console
// uses, reachable with `debug=1` in mister.ini and a USB cable.
//
// WHY THIS EXISTS, AND WHY IT SHOULD HAVE EXISTED SOONER.
//
// The overlay renders 24 words of hex over the picture, and it has been the
// only instrument this core had. Reading it costs a photograph and a squint,
// it shows eight digits at a time, and it has now produced four wrong
// conclusions in one session: two values attributed to the wrong probe because
// a row was shared, and two read at a moment when the value was legitimately
// something else. None of those were failures of the probe. They were failures
// of a channel that can only show a handful of numbers, only right now, and
// only if someone is looking.
//
// docs/mister-integration.md said as much and was not acted on: "assume the
// screen is the core's only output channel, but know that it is not the only
// one available... A minimal transmitter is tens of LUTs, and that is a
// genuine printf." CLAUDE.md's summary flattened that into "No serial", which
// is what actually governed, and the cost was a session of hex-squinting.
//
// 8N1, LSB first, one stop bit. DIVISOR is clk cycles per bit: at 48 MHz,
// 115200 baud is 416.67, and 417 is 0.08% off -- far inside the 2% a UART
// tolerates over ten bits.

`timescale 1ns/1ps

module m2_uart_tx #(
  parameter int unsigned DIVISOR = 417
) (
  input  logic       clk,
  input  logic       rst_n,

  input  logic [7:0] data,
  input  logic       valid,      // one cycle; ignored unless ready
  output logic       ready,      // idle and able to take a byte

  output logic       tx
);

  localparam int unsigned CW = $clog2(DIVISOR);

  logic [CW-1:0] cnt;
  logic [3:0]    bit_i;
  logic [9:0]    shifter;        // {stop, data[7:0], start}
  logic          busy;

  assign ready = !busy;
  assign tx    = busy ? shifter[0] : 1'b1;   // line idles high

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt <= '0; bit_i <= '0; shifter <= 10'h3FF; busy <= 1'b0;
    end else if (!busy) begin
      if (valid) begin
        shifter <= {1'b1, data, 1'b0};   // stop, payload, start
        bit_i   <= 4'd0;
        cnt     <= '0;
        busy    <= 1'b1;
      end
    end else begin
      if (cnt == CW'(DIVISOR - 1)) begin
        cnt     <= '0;
        shifter <= {1'b1, shifter[9:1]};
        bit_i   <= bit_i + 4'd1;
        if (bit_i == 4'd9) busy <= 1'b0;   // start + 8 + stop sent
      end else begin
        cnt <= cnt + CW'(1);
      end
    end
  end

endmodule
