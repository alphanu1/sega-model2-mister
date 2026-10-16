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
// THE MODEL 2A SOUND SIDE, SILENT (R852). On the 2A-CRX board the i960's
// i8251 (0x01c80000) is wired to the SCSP's MIDI port: TXD to MIDI in, MIDI
// out to RXD (MAME model2_scsp). The SCSP's 68000 runs the sound program and
// answers over MIDI. Until the SCSP and its 68000 are in the core, this sits
// on the far end of m2_sound_link: it takes every byte the i960 sends and
// sends nothing back.
//
// Why nothing is enough is the measurement in R852 (MAME 0.289, vf2 with the
// sound 68000 suspended from power-on): see the study entry.

`timescale 1ns/1ps

module m2_2a_snd_stub (
  input  logic        clk,
  input  logic        rst_n,
  // from the i960 (the SCSP's MIDI in)
  input  logic  [7:0] rx_data,
  input  logic        rx_valid,
  output logic        rx_ack,
  // to the i960 (the SCSP's MIDI out)
  output logic  [7:0] tx_data,
  output logic        tx_valid,
  input  logic        tx_ack,
  output logic [31:0] dbg_rx_bytes,
  output logic [31:0] dbg_tx_bytes
);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_ack <= 1'b0; dbg_rx_bytes <= 32'd0;
    end else begin
      rx_ack <= rx_valid && !rx_ack;
      if (rx_valid && !rx_ack && !(&dbg_rx_bytes)) dbg_rx_bytes <= dbg_rx_bytes + 32'd1;
    end
  end

  assign tx_data      = 8'd0;
  assign tx_valid     = 1'b0;
  assign dbg_tx_bytes = 32'd0;

  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, rx_data, tx_ack};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
