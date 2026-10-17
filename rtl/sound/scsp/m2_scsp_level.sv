// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// THE SCSP's SIX LEVEL WORDS OF A SLOT, WITHOUT MAME's 64 K-ENTRY TABLE
// (study R856). Derived from MAME 0.289 scsp.cpp (BSD-3-Clause, ElSemi,
// R. Belmont; notice in THIRD_PARTY.md), which mixes a slot through
// LPANTABLE / RPANTABLE[TL | PAN << 8 | SDL << 13] = FIX(4.0f * LPAN * TL *
// fSDL): three single-precision factors multiplied in float, x 4096,
// truncated. Here each factor is a 24-bit mantissa and an exponent (one ROM,
// scsp_lvl.hex: TL 0-255, PAN 256-271, SDL 272-279), each of the two
// products is rounded to nearest-even as a float multiply rounds, and the
// result is x 2^14 and truncated -- equal to MAME's table in all 131,072
// entries (sim/sound/scsp_level_check.cpp; tb_m2_scsp_level checks this RTL).
//
// The six words of slot s (MAME's DoMasterSamples, UpdateSlot), RAM row {s, word}:
//   0 direct L  Enc = (SDIR ? 0 : TL) | DIPAN << 8 | DISDL << 13, LPANTABLE
//   1 direct R  the same Enc, RPANTABLE
//   2 DSP send  Enc = (SDIR ? 0 : TL) | IMXL << 13 (pan 0: LPAN = 1.0)
//   3 effect L  Enc = EFPAN << 8 | EFSDL << 13 (TL 0: 1.0), LPANTABLE
//   4 effect R  the same, RPANTABLE
//   5 FM ring   Enc = (SDIR ? 0 : TL) | 7 << 13 (a slot's write to the ring buffer)
// recomputed when the engine hands over the slot's words 6, 10 and 11 after
// a write to one of them; 54 clocks a slot. A word is 15 bits (<= 16,384).
//
// Every factor is <= 1.0, so an exponent is kept as its negation N >= 0
// (value = 1.m x 2^-N) and the word is the mantissa >> (9 + N).

`timescale 1ns/1ps

module m2_scsp_level (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        req,           // taken when !busy
  input  logic  [4:0] req_slot,
  input  logic [15:0] req_w6,
  input  logic [15:0] req_w10,
  input  logic [15:0] req_w11,
  output logic        busy,
  // the engine's read port: {slot, word}, registered (one clock)
  input  logic  [7:0] rd_addr,
  output logic [14:0] rd_q
);

  logic  [4:0] s_slot;
  logic  [7:0] tl;
  logic  [4:0] dipan, efpan;
  logic  [2:0] disdl, efsdl, imxl;

  // the factors: {N (5), mantissa without the hidden bit (23)}
  (* ramstyle = "M10K" *) logic [27:0] from [512];
  initial $readmemh("scsp_lvl.hex", from);
  logic  [8:0] f_addr;
  logic [27:0] f_q;
  always_ff @(posedge clk) f_q <= from[f_addr];

  logic        run;
  logic  [2:0] w;
  logic  [3:0] ph;
  logic        zero_w;
  logic  [8:0] a_idx, b_idx, c_idx;
  logic        z_acc;
  logic  [6:0] n_acc;
  logic [23:0] ma, mb;
  (* multstyle = "dsp" *) logic [47:0] prod;

  always_ff @(posedge clk) prod <= ma * mb;

  localparam logic [8:0] ONE = 9'd0;            // TL 0 = 1.0
  localparam logic [8:0] PAN = 9'd256;
  localparam logic [8:0] SDL = 9'd272;

  // factor a (the pan side), b (TL or 1.0), c (SDL) of word w, and its zeros
  always_comb begin
    case (w)
      3'd0:    begin a_idx = (dipan < 5'd16) ? PAN + {5'd0, dipan[3:0]} : ONE; b_idx = {1'b0, tl}; c_idx = SDL + {6'd0, disdl};
                     zero_w = (dipan == 5'd15) || disdl == 3'd0; end
      3'd1:    begin a_idx = (dipan < 5'd16) ? ONE : PAN + {5'd0, dipan[3:0]}; b_idx = {1'b0, tl}; c_idx = SDL + {6'd0, disdl};
                     zero_w = (dipan == 5'd31) || disdl == 3'd0; end
      3'd2:    begin a_idx = ONE;                                              b_idx = {1'b0, tl}; c_idx = SDL + {6'd0, imxl};
                     zero_w = imxl == 3'd0; end
      3'd3:    begin a_idx = (efpan < 5'd16) ? PAN + {5'd0, efpan[3:0]} : ONE; b_idx = ONE;        c_idx = SDL + {6'd0, efsdl};
                     zero_w = (efpan == 5'd15) || efsdl == 3'd0; end
      3'd4:    begin a_idx = (efpan < 5'd16) ? ONE : PAN + {5'd0, efpan[3:0]}; b_idx = ONE;        c_idx = SDL + {6'd0, efsdl};
                     zero_w = (efpan == 5'd31) || efsdl == 3'd0; end
      default: begin a_idx = ONE;                                              b_idx = {1'b0, tl}; c_idx = SDL + 9'd7;
                     zero_w = 1'b0; end   // 5: the FM ring's write, Enc = (SDIR ? 0 : TL) | 7 << 13
    endcase
    case (ph)
      4'd0:    f_addr = a_idx;
      4'd1:    f_addr = b_idx;
      default: f_addr = c_idx;                   // (and held: c is read where it is used)
    endcase
  end

  // round the 48-bit product to 24 bits, nearest-even; r_d: how far the
  // exponent rises (1 for a product in [2, 4), +1 if rounding carried out)
  logic [23:0] r_m;
  logic  [1:0] r_d;
  always_comb begin
    logic [24:0] q;
    logic        up;
    if (prod[47]) begin
      q  = {1'b0, prod[47:24]};
      up = (prod[23:0] > 24'h800000) || (prod[23:0] == 24'h800000 && prod[24]);
    end else begin
      q  = {1'b0, prod[46:23]};
      up = (prod[22:0] > 23'h400000) || (prod[22:0] == 23'h400000 && prod[23]);
    end
    q = q + {24'd0, up};
    if (q[24]) begin r_m = 24'h800000; r_d = {1'b0, prod[47]} + 2'd1; end
    else       begin r_m = q[23:0];    r_d = {1'b0, prod[47]};        end
  end

  // the word: r_m >> (N + 9), taken through the multiplier as
  // (r_m x 2^(24 - N - 9)) >> 24; past a shift of 23 it is 0
  logic [6:0]  n_fin;
  logic [7:0]  sh;
  always_comb begin
    n_fin = n_acc - {5'd0, r_d};
    sh    = {1'b0, n_fin} + 8'd9;
  end
  wire [14:0] v = prod[38:24];

  // ph 0 read a | 1 a in; read b | 2 b in; read c | 3 product a b | 4 round,
  // times c | 5 product | 6 round, times 2^(24 - shift) | 7 product | 8 write
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      run <= 1'b0; w <= 3'd0; ph <= 4'd0;
    end else if (!run) begin
      if (req) begin run <= 1'b1; w <= 3'd0; ph <= 4'd0; end
    end else begin
      ph <= ph + 4'd1;
      case (ph)
        4'd1: begin ma <= {1'b1, f_q[22:0]}; n_acc <= {2'd0, f_q[27:23]}; end
        4'd2: begin mb <= {1'b1, f_q[22:0]}; n_acc <= n_acc + {2'd0, f_q[27:23]}; z_acc <= zero_w; end
        4'd4: begin ma <= r_m; mb <= {1'b1, f_q[22:0]}; n_acc <= n_acc - {5'd0, r_d} + {2'd0, f_q[27:23]}; end
        4'd6: begin ma <= r_m; mb <= (z_acc || sh >= 8'd24) ? 24'd0 : 24'(1) << (5'd24 - sh[4:0]); end
        4'd8: begin
          ph <= 4'd0;
          w  <= w + 3'd1;
          if (w == 3'd5) run <= 1'b0;
        end
        default: ;
      endcase
    end
  end

  always_ff @(posedge clk) begin
    if (!run && req) begin
      s_slot <= req_slot;
      tl     <= req_w6[8] ? 8'd0 : req_w6[7:0];   // SDIR: MAME's eff_tl / dir_tl are 0
      imxl   <= req_w10[2:0];
      disdl  <= req_w11[15:13]; dipan <= req_w11[12:8];
      efsdl  <= req_w11[7:5];   efpan <= req_w11[4:0];
    end
  end
  assign busy = run;

  // the level RAM, a word per row; power-up 0 = MAME's level for all-zero
  // registers (DISDL / IMXL / EFSDL 0: fSDL = 0)
  (* ramstyle = "M10K" *) logic [14:0] lram [256];
  always_ff @(posedge clk) begin
    if (run && ph == 4'd8) lram[{s_slot, w}] <= v;
    rd_q <= lram[rd_addr];
  end

  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, req_w6[15:9], req_w10[15:3]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
