// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// THE YM3438 AS DAYTONA USES IT: TWO TIMERS, A STATUS BYTE AND SILENCE (R833).
//
// A stand-in for jt12 on the Model 1 sound board, selected by m2_sound_board's
// YM_STUB. Same ports as jt12 (jt12.v), so it drops into the same place.
//
// WHY IT IS ENOUGH FOR THIS GAME, MEASURED (R819, R833). MAME 0.289's ymsnd
// output is exactly zero through Daytona's attract, a game and GAME OVER, on
// both sound programs (daytona / Revision A, epr-16720/16721; daytona93,
// epr-16489/16490). The firmware writes the operators' TL to 127 and keys
// every channel OFF at boot, and from then on uses the chip for one thing:
// timer B, reloaded and its flag cleared by writing 0x2A to register 0x27,
// which paces its music sequencer (R820). It polls the status byte -- bit 1
// (timer B) in its main loop and bit 7 (busy) before every write -- and never
// takes an interrupt from it: segam1audio.cpp leaves the YM's IRQ unconnected,
// and so does m2_sound_board.
//
// WHAT IT IS: jt12's own timer path, re-expressed and nothing else --
//
//   jt12_top     cen_reg (cen one clk late); timer_cen = fast_timers ? cen_reg
//                : clk_en
//   jt12_div     the 1/6 FM prescaler (mask_div=1 fixes div_setting at 2'b10),
//                cen_int and clk_en registered on the NEGATIVE clock edge, the
//                counter with no reset and a power-up value of 0
//   jt12_reg     the 24-slot operator counter {cur_op, cur_ch} and `zero`,
//                which marks slot 0 (no reset; the SIMULATION initial kept)
//   jt12_mmr     the address latch and part bit, registers 0x21 (fast_timers),
//                0x24/0x25 (timer A), 0x26 (timer B), 0x27 (load, enable,
//                reset-flag; the reset-flag bits self-clear on clk_en without
//                a write), all part 0 only, synchronous reset; and busy, set
//                by a data write and held for 32 clk_en
//   jt12_timers  timer A (10 bits, one step a `zero`), timer B (8 bits, one
//                step every 16 `zero`s), the flags and irq_n
//   jt12_dout    dout = {busy, 5'b0, flag_B, flag_A}, registered, for every
//                address (use_ssg = use_adpcm = 0)
//
// -- every register, enable and edge as jt12 has it, so the status the 68000
// polls is the same on every clock. tb_m2_ym_timers drives both with MAME's
// captured write stream and with random programming and compares dout and
// irq_n every cycle; tb_m2_sndboard with YM_STUB=1 gives the same 68000 bus
// trace and the same MultiPCM output, cycle for cycle, as with jt12.
//
// WHAT IT IS NOT: a sound chip. snd_left / snd_right are 0. A game that keys
// the FM on with a non-zero level would be silent where it should sound --
// not Daytona, which never does; any other Model 1 sound board game must be
// measured before YM_STUB is set for it. CSM key-on, the LFO and the CH3
// special mode are audio-only and are not here.
//
// Not jt12's code: written from jt12 @ 4cf1c5b (GPL-3.0, Jose Tejada Gomez),
// whose behaviour it must equal; see THIRD_PARTY.md.

`timescale 1ns/1ps

// jt12 resets its register file synchronously and its busy and flags
// asynchronously, from the same rst; this keeps both, deliberately.
/* verilator lint_off SYNCASYNCNET */
module m2_ym_timers (
  input  logic        rst,          // active high, as jt12's
  input  logic        clk,
  input  logic        cen,
  input  logic  [7:0] din,
  input  logic  [1:0] addr,
  input  logic        cs_n,
  input  logic        wr_n,

  output logic  [7:0] dout,
  output logic        irq_n,
  input  logic        en_hifi_pcm,
  output logic signed [15:0] snd_right,
  output logic signed [15:0] snd_left,
  output logic        snd_sample
);

  wire write = !cs_n && !wr_n;

  // ------------------------------------------------ jt12_top / jt12_div
  logic cen_reg;
  always_ff @(posedge clk) cen_reg <= cen;

  // FM prescaler 1/6. No reset, power-up 0 -- jt12_div's `opn_cnt = 4'd0`.
  /* verilator lint_off PROCASSINIT */
  logic [2:0] opn_cnt = 3'd0;
  /* verilator lint_on PROCASSINIT */
  always_ff @(posedge clk)
    if (cen_reg) opn_cnt <= (opn_cnt == 3'd5) ? 3'd0 : opn_cnt + 3'd1;

  // jt12_div registers its enables on the falling edge; so does this.
  logic cen_int, clk_en;
  always_ff @(negedge clk) begin
    cen_int <= (opn_cnt == 3'd0);
    clk_en  <= cen_reg & cen_int;
  end

  // -------------------------------------------- jt12_reg's slot counter
  // {cur_op, cur_ch}: ch 0,1,2,4,5,6 then op+1 -- 24 slots; zero marks the
  // pass's first. No reset, as jt12's.
  logic [1:0] cur_op;
  logic [2:0] cur_ch;
  logic       zero;
`ifdef SIMULATION
  initial begin cur_op = 2'd0; cur_ch = 3'd0; zero = 1'b1; end
`endif
  wire [1:0] next_op = (cur_ch == 3'd6) ? cur_op + 2'd1 : cur_op;
  wire [2:0] next_ch = (cur_ch[1:0] == 2'b10) ? cur_ch + 3'd2 : cur_ch + 3'd1;
  always_ff @(posedge clk)
    if (clk_en) begin
      {cur_op, cur_ch} <= {next_op, next_ch};
      zero             <= ({next_op, next_ch} == 5'd0);
    end

  // ---------------------------------------------------- jt12_mmr's subset
  logic [7:0] sel_reg;
  logic       part;
  logic [9:0] value_A;
  logic [7:0] value_B;
  logic       load_A, load_B, enable_irq_A, enable_irq_B, clr_flag_A, clr_flag_B;
  logic       fast_timers;

  always_ff @(posedge clk) begin
    if (rst) begin
      sel_reg <= 8'd0; part <= 1'b0;
      value_A <= 10'd0; value_B <= 8'd0;
      {clr_flag_B, clr_flag_A, enable_irq_B, enable_irq_A, load_B, load_A} <= 6'd0;
      fast_timers <= 1'b0;
    end else if (write) begin
      if (!addr[0]) begin
        sel_reg <= din;
        part    <= addr[1];
      end else if (!part) begin
        case (sel_reg)
          8'h21: fast_timers   <= din[2];
          8'h24: value_A[9:2]  <= din;
          8'h25: value_A[1:0]  <= din[1:0];
          8'h26: value_B       <= din;
          8'h27: {clr_flag_B, clr_flag_A, enable_irq_B, enable_irq_A, load_B, load_A} <= din[5:0];
          default: ;
        endcase
      end
    end else if (clk_en) begin
      {clr_flag_B, clr_flag_A} <= 2'd0;
    end
  end

  // busy: 32 clk_en from the last data write
  logic       busy;
  logic [4:0] busy_cnt;
  wire  [5:0] nx_busy = {1'b0, busy_cnt} + {5'd0, busy};
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      busy <= 1'b0; busy_cnt <= 5'd0;
    end else if (write && addr[0]) begin
      busy <= 1'b1; busy_cnt <= 5'd0;
    end else if (clk_en) begin
      busy     <= ~nx_busy[5] & busy;
      busy_cnt <= nx_busy[4:0];
    end
  end

  // ------------------------------------------------------ jt12_timers
  wire tcen = fast_timers ? cen_reg : clk_en;
  wire tick = tcen && zero;

  // Timer A: 10 bits, a step every slot-0.
  logic [9:0] cnt_A;
  logic       load_A_l, flag_A;
  wire  [10:0] sum_A = {1'b0, cnt_A} + 11'd1;
  wire         ov_A  = sum_A[10];
  always_ff @(posedge clk) begin
    load_A_l <= load_A;
    if (!load_A_l && load_A)  cnt_A <= value_A;
    else if (tick && load_A)  cnt_A <= ov_A ? value_A : sum_A[9:0];
  end
  always_ff @(posedge clk or posedge rst)
    if (rst)                            flag_A <= 1'b0;
    else if (clr_flag_A)                flag_A <= 1'b0;
    else if (tick && load_A && ov_A)    flag_A <= 1'b1;

  // Timer B: 8 bits, a step every 16 slot-0s (the 4-bit free-running count).
  logic [7:0] cnt_B;
  logic [3:0] free_B;
  logic       load_B_l, flag_B;
  wire  [4:0] fsum_B = {1'b0, free_B} + 5'd1;
  wire  [8:0] sum_B  = {1'b0, cnt_B} + {8'd0, fsum_B[4]};
  wire        ov_B   = sum_B[8];
  always_ff @(posedge clk) begin
    if (rst)       free_B <= 4'd0;
    else if (tick) free_B <= fsum_B[3:0];
  end
  always_ff @(posedge clk) begin
    load_B_l <= load_B;
    if (!load_B_l && load_B)  cnt_B <= value_B;
    else if (tick && load_B)  cnt_B <= ov_B ? value_B : sum_B[7:0];
  end
  always_ff @(posedge clk or posedge rst)
    if (rst)                            flag_B <= 1'b0;
    else if (clr_flag_B)                flag_B <= 1'b0;
    else if (tick && load_B && ov_B)    flag_B <= 1'b1;

  assign irq_n = ~((flag_A & enable_irq_A) | (flag_B & enable_irq_B));

  // -------------------------------------------------------- jt12_dout
  always_ff @(posedge clk) dout <= {busy, 5'd0, flag_B, flag_A};

  // ---------------------------------------------------------- silence
  assign snd_left   = 16'sd0;
  assign snd_right  = 16'sd0;
  assign snd_sample = zero;

  wire _unused = &{1'b0, en_hifi_pcm, addr[1], 1'b0};

endmodule
/* verilator lint_on SYNCASYNCNET */
