// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// EVENT STREAMER. Turns tagged 64-bit records into hex lines on the UART, so
// the board can be read like a log instead of photographed like a dashboard.
//
// The record is deliberately dumb: a one-character tag, a 32-bit address and a
// 32-bit value, printed as
//
//     W 01690000 12345678
//
// Two channels, because the question that needs answering is a comparison
// between them -- what the CPU WRITES into a region against what the renderer
// READS out of it. Feeding both down one wire timestamps them against each
// other for free, which is the thing the overlay could never do.
//
// FLOW CONTROL IS "DROP", NOT "STALL", AND THAT IS DELIBERATE. At 115200 baud a
// 20-character line takes 1.7 ms; the events being watched can arrive millions
// of times a second. A streamer that backpressured would change the timing of
// the thing it is measuring -- the classic instrument that destroys its own
// subject. Instead it takes what it can and COUNTS WHAT IT DROPPED, and the
// drop count is printed in the periodic summary so the log never quietly
// implies it saw everything.
//
// BUDGET: one line per BUDGET_CYC clocks, so the stream stays readable and the
// UART stays ahead of it. Bursts of interest still get through -- the first
// events after reset are exactly when nothing else is competing.

`timescale 1ns/1ps

module m2_dbg_stream #(
  parameter int unsigned DIVISOR    = 417,      // 48 MHz / 115200
  parameter int unsigned BUDGET_CYC = 100_000   // ~2 ms between lines
) (
  input  logic        clk,
  input  logic        rst_n,

  // Channel A and B: assert ev_*_valid for one cycle with the payload.
  input  logic        a_valid,
  input  logic [31:0] a_addr,
  input  logic [31:0] a_data,
  input  logic        b_valid,
  input  logic [31:0] b_addr,
  input  logic [31:0] b_data,

  // Tag characters, so the top level names its own channels.
  input  logic  [7:0] a_tag,
  input  logic  [7:0] b_tag,

  input  logic        enable,

  output logic        tx,
  output logic [31:0] dbg_dropped
);

  // ---------------------------------------------------------------- capture
  logic        pend;
  logic [7:0]  p_tag;
  logic [31:0] p_addr, p_data;
  // SEPARATE BUDGETS, AND CHANNEL A HAS PRIORITY.
  //
  // One shared budget starved the channel that mattered. Channel B (character
  // fetches) fires thousands of times a second and channel A (tilemap writes)
  // comparatively rarely, so with a single ~4 ms window B took essentially
  // every slot and A was counted as a drop and never printed. The log showed
  // ZERO tilemap writes across a full boot, which read as "the tilemap is
  // never written" and was in fact "the instrument never got to say so".
  //
  // A is the rare, interesting channel: it gets its own, much shorter budget
  // and wins arbitration. B keeps the long one and fills the gaps.
  logic [31:0] budget_a, budget_b;

  wire allow_a = (budget_a == 32'd0);
  wire allow_b = (budget_b == 32'd0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pend <= 1'b0; p_tag <= 8'h3F; p_addr <= '0; p_data <= '0;
      budget_a <= '0; budget_b <= '0; dbg_dropped <= '0;
    end else begin
      if (budget_a != 32'd0) budget_a <= budget_a - 32'd1;
      if (budget_b != 32'd0) budget_b <= budget_b - 32'd1;

      if (a_valid || b_valid) begin
        if (!pend && enable && ((a_valid && allow_a) || (b_valid && allow_b))) begin
          pend <= 1'b1;
          if (a_valid && allow_a) begin
            p_tag <= a_tag; p_addr <= a_addr; p_data <= a_data;
            budget_a <= 32'(BUDGET_CYC / 16);   // the rare channel, sampled finer
          end else begin
            p_tag <= b_tag; p_addr <= b_addr; p_data <= b_data;
            budget_b <= 32'(BUDGET_CYC);
          end
        end else if (enable) begin
          // Counted, not stalled: an instrument must not change what it
          // measures. The summary prints this so the log cannot imply
          // completeness it does not have.
          if (!(&dbg_dropped)) dbg_dropped <= dbg_dropped + 32'd1;
        end
      end

      if (pend && done) pend <= 1'b0;
    end
  end

  // ------------------------------------------------------------- formatting
  // 20 characters: tag, space, 8 hex, space, 8 hex, CR, LF.
  localparam int unsigned NCHAR = 20;

  logic [4:0] ci;         // character index
  logic       sending, done;
  logic [7:0] ch;
  logic       ch_valid;
  logic       ub_ready;

  function automatic [7:0] hex(input logic [3:0] n);
    hex = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h41 + {4'd0, n} - 8'd10);
  endfunction

  always_comb begin
    ch = 8'h20;
    case (ci)
      5'd0:  ch = p_tag;
      5'd1:  ch = 8'h20;
      5'd2:  ch = hex(p_addr[31:28]);  5'd3:  ch = hex(p_addr[27:24]);
      5'd4:  ch = hex(p_addr[23:20]);  5'd5:  ch = hex(p_addr[19:16]);
      5'd6:  ch = hex(p_addr[15:12]);  5'd7:  ch = hex(p_addr[11:8]);
      5'd8:  ch = hex(p_addr[7:4]);    5'd9:  ch = hex(p_addr[3:0]);
      5'd10: ch = 8'h20;
      5'd11: ch = hex(p_data[31:28]);  5'd12: ch = hex(p_data[27:24]);
      5'd13: ch = hex(p_data[23:20]);  5'd14: ch = hex(p_data[19:16]);
      5'd15: ch = hex(p_data[15:12]);  5'd16: ch = hex(p_data[11:8]);
      5'd17: ch = hex(p_data[7:4]);    5'd18: ch = hex(p_data[3:0]);
      5'd19: ch = 8'h0A;               // newline; CR omitted, the console adds it
      default: ch = 8'h20;
    endcase
  end

  assign ch_valid = sending && ub_ready;
  assign done     = sending && ub_ready && (ci == 5'(NCHAR - 1));

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sending <= 1'b0; ci <= '0;
    end else if (!sending) begin
      if (pend) begin sending <= 1'b1; ci <= '0; end
    end else if (ub_ready) begin
      if (ci == 5'(NCHAR - 1)) sending <= 1'b0;
      else                     ci <= ci + 5'd1;
    end
  end

  m2_uart_tx #(.DIVISOR(DIVISOR)) u_tx (
    .clk(clk), .rst_n(rst_n),
    .data(ch), .valid(ch_valid), .ready(ub_ready),
    .tx(tx)
  );

endmodule
