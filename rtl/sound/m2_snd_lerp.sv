// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// THE SOUND BOARD'S 44.1 kHz OUTPUT, LINEARLY INTERPOLATED (study R949).
//
// The framework samples AUDIO_L / AUDIO_R at its own 48 kHz (sys/audio_out.sv,
// sample_ce). With its IIR filter switched off for room (R788,
// MISTER_DISABLE_AUDIO_FILTER) nothing smooths the 44.1 kHz staircase first,
// so each 48 kHz tick takes whichever 44.1 kHz sample is current: content at f
// comes back also at f + 3.9 kHz and folded copies of everything above ~16 kHz
// land in 4-16 kHz -- inharmonic, audible as a tinny, high-pitched layer. A
// pure tone of 2 kHz carries spurs at -22 dB, 4 kHz at -16 dB; House of the
// Dead's FM voice (most of its energy at 16-22 kHz) aliases to only 8.5 dB
// below itself.
//
// Here the output moves along the straight line from the previous sample to
// the current one, one sample late, re-evaluated every 64 clocks (1.25 MHz at
// 80 MHz): the framework's 48 kHz tick then reads the line, not the step,
// and the images fall by the extra sinc of a first-order hold (the FM voice's
// aliasing 8.5 -> 15.9 dB below it, the rest of House of the Dead's chapter-2
// mix 24.9 -> 40.4 dB, in the bench model). The value holds for 64 clocks, so
// audio_out's two-flop equality check takes it cleanly.
//
// The phase is the clocks since the sample changed, scaled to the drain's
// period (T44_DEN / 441 clocks), so the line spans one output period. LERP = 0: the input, unchanged, as
// before.

`timescale 1ns/1ps

module m2_snd_lerp #(
  parameter bit          LERP    = 1'b1,
  parameter int unsigned T44_DEN = 800000,  // the drain accumulator's period (m2_2a_sound)
  parameter int unsigned TW      = 21
) (
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic                 tick,        // the drain: in_l / in_r take their next sample the clock after
  input  logic        [TW-1:0] tacc,        // the drain accumulator: 0 .. T44_DEN-1 through a period
  input  logic signed [15:0]   in_l, in_r,
  output logic signed [15:0]   out_l, out_r
);
  generate if (!LERP) begin : g_off
    assign out_l = in_l;
    assign out_r = in_r;
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, clk, rst_n, tick, tacc};
    /* verilator lint_on UNUSEDSIGNAL */
  end else begin : g_on
    // the phase in 1/256 of a period from the clocks since the sample changed:
    // fr = cs x round(2^19 x 441 / T44_DEN) >> 11 (80 MHz: cs x 289 >> 11,
    // 255.98 at the period's 1,814th clock), held at 255 past the end
    localparam int unsigned PER = (T44_DEN + 440) / 441;              // clocks a period, rounded up
    localparam int CW = $clog2(PER + 1) + 1;
    localparam longint unsigned KL = ((64'd1 << 19) * 64'd441 + 64'(T44_DEN) / 2) / 64'(T44_DEN);
    localparam int KW = $clog2(KL + 1);
    logic tick_d;
    logic signed [15:0] a_l, a_r, b_l, b_r;      // the sample before, the sample now
    logic signed [15:0] c_l, c_r;                // a as it was when the phase was taken
    logic      [CW-1:0] cs;                      // clocks since a / b last moved
    logic        [5:0]  u;
    logic        [7:0]  fr;
    logic signed [16:0] d_l, d_r;
    logic               s1;
    wire       [CW+KW-1:0] ph = (CW+KW)'(cs) * (CW+KW)'(KL);   // a constant: shifts and adds
    (* multstyle = "dsp" *) logic signed [26:0] p_l, p_r;
    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        tick_d <= 1'b0; cs <= '0; a_l <= '0; a_r <= '0; b_l <= '0; b_r <= '0; c_l <= '0; c_r <= '0;
        u <= '0; fr <= '0; d_l <= '0; d_r <= '0; s1 <= 1'b0; out_l <= '0; out_r <= '0;
      end else begin
        tick_d <= tick;
        if (tick_d) begin a_l <= b_l; a_r <= b_r; b_l <= in_l; b_r <= in_r; cs <= '0; end
        else if (cs != '1) cs <= cs + 1'd1;
        u  <= u + 6'd1;
        // every 64 clocks: the phase, the difference and a; then the sum
        s1 <= u == 6'd0;
        if (u == 6'd0) begin
          fr  <= (ph >> 11) > (CW+KW)'(255) ? 8'd255 : ph[18:11];
          d_l <= 17'(b_l) - 17'(a_l);
          d_r <= 17'(b_r) - 17'(a_r);
          c_l <= a_l; c_r <= a_r;
        end
        if (s1) begin
          out_l <= 16'(17'(c_l) + 17'(p_l >>> 8));   // (between c and b: in range)
          out_r <= 16'(17'(c_r) + 17'(p_r >>> 8));
        end
      end
    end
    always_comb begin
      p_l = 27'(d_l) * $signed({1'b0, fr});
      p_r = 27'(d_r) * $signed({1'b0, fr});
    end
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, tacc};
    /* verilator lint_on UNUSEDSIGNAL */
  end endgenerate
endmodule
