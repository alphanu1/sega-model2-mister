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
// ---------------------------------------------------------------------------
//
// R845: THE LONG-REAL TRANSCENDENTALS -- sinrl, cosrl, tanrl, atanrl -- AS
// MICROCODE ON THE i960's OWN DOUBLE UNITS.
//
// Virtua Cop runs them from 14.73 s (tanrl, cosrl), 18.3 s (atanrl) and in
// play (sinrl), some 60 a second. MAME computes them with the host's libm;
// the programs (tools/i960_fptrans.py, which also generates
// i960_fptrans_rom.svh and is this module's reference) work in double-double
// and round once, so the result is the correctly rounded value -- what glibc
// returns on ~99.8% of arguments and the 80960KB's extended-precision
// microcode would.
//
// The machine: 128 x 64-bit registers in M10K (the first 73 hold the
// constants -- LOG's program 75 -- initialised and never written), a 512-word microcode ROM, a
// four-deep return stack, and two operand registers that drive the adder,
// multiplier and divider i960_top already has (it muxes them in while `act`).
//
//   op  0 ADD  d = a + b     1 SUB  d = a - b     2 MUL  d = a * b
//       3 DIV  d = a / b     4 BR   if cond(a) goto t     5 JMP t
//       6 CALL t             7 RET                8 LDX d = x - 0
//       9 LDY  d = y - 0    10 END  result = a - 0 (on the adder)
//   word: op[31:28] d[27:21] a[20:14] b[13:7] ma[6:5] mb[4:3]
//         BR: cond[27:25] inv[24] a[20:14] t[8:0]; JMP / CALL: t[8:0]
//   modifiers (ma / mb): 1 negate, 2 abs, 3 -abs -- on the sign bit only
//   conditions (on register a, unmodified): 0 sign, 1 zero, 2 NaN, 3 inf,
//   4 bit 0, 5 bit 1 (the quadrant, from a 1.5 x 2^52 rounding add)
//
// The units see A on their .a port and B on .b: a - b, a / b, as the i960's
// src2 - src1 and src2 / src1 are wired.
//
// R998: PIPELINED. R845 ran one instruction at a time -- FETCH, DEC, RA, RB,
// ISSUE and three cycles of WAIT, eight a micro-op -- so cosrl took ~2,200
// cycles where Intel's 80960KB takes 441 at 25 MHz (PRM appendix C). Now the
// next word is fetched while one executes, the register file's one read port
// is kept busy, and an operand whose writer is still in a unit is taken from
// res as it is written, so an op that needs the one before it issues three
// cycles after it, an independent one a cycle or two after, and a JMP / CALL
// / RET costs a cycle. The same operations on the same values in the same
// order, and the same register-file writes: the results are R845's bit for
// bit (tb_i960_fptrans_ab runs both side by side).

// R935: LOG -- the 2C build's program (i960_fptrans_rom_log.svh, 465 words):
// the same four (their Horner steps through one subroutine, the same
// operations) plus logrl (entry 4: y * log2 x, House of the Dead from its
// stone-wall section), and two loads that take x apart for it: LDE (op 11)
// d = x's unbiased exponent as a double -- the adder's (MAGIC + e - 1023) -
// MAGIC, exact -- and LDM (op 12) d = x's mantissa in [1, 2). LOG = 0 is
// the 2A builds' sequencer and ROM exactly.
// R998 on 2C: LDE / LDM are loads in the pipeline as LDX / LDY are (no
// register read; they leave D straight to the adder), with LDE's b MAGIC.
// tb_i960_fptrans_ab runs this beside R935's sequencer (the 2C build's before
// R998, sim/i960/i960_fptrans_r935.sv) with LOG = 1.
module i960_fptrans #(
  parameter bit LOG = 1'b0
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        start,        // one cycle; entry and x / y valid from here
  input  logic  [1:0] entry,        // 0 sin, 1 cos, 2 tan, 3 atan (y = src2, x = src1)
  input  logic        lg,           // R935 (LOG only): logrl -- entry 4, y * log2 x
  input  logic [63:0] x,
  input  logic [63:0] y,
  output logic        act,          // the units' operands are opa / opb
  output logic [63:0] opa,          // to the units' .a
  output logic [63:0] opb,          // to the units' .b
  output logic        add_req, mul_req, div_req,   // one-cycle requests
  output logic        sub,          // the adder subtracts (valid with add_req)
  output logic        sel_add, sel_mul, sel_div,   // which unit's y is on res
  input  logic        add_done, mul_done, div_done,
  input  logic [63:0] res,          // the selected unit's y (i960_top's fp_res_wide)
  output logic        fin           // one cycle: END's result is on res
);

  `include "i960_fptrans_rom.svh"
  `include "i960_fptrans_rom_log.svh"

  // ------------------------------------------------------------ storage
  (* ramstyle = "M10K" *) logic [63:0] rf [128];
  initial for (int i = 0; i < 128; i++) rf[i] = LOG ? uconst_log(7'(i)) : uconst(7'(i));

  logic [6:0]  raddr;
  logic [63:0] q;
  logic        we;
  logic [6:0]  waddr;
  always_ff @(posedge clk) begin
    if (we) rf[waddr] <= res;
    q <= rf[raddr];
  end

  logic [8:0]  fa;           // the ROM address this cycle: uw is ucode(fa) next cycle
  logic [8:0]  pc;           // the address uw came from
  logic [31:0] uw;
  generate if (LOG) begin : g_rom_log
    always_ff @(posedge clk) uw <= ucode_log(fa);
  end else begin : g_rom
    always_ff @(posedge clk) uw <= ucode(fa);
  end endgenerate

  // ------------------------------------------------------------ decode
  wire [3:0] op   = uw[31:28];
  wire [6:0] f_d  = uw[27:21];
  wire [6:0] f_a  = uw[20:14];
  wire [6:0] f_b  = uw[13:7];
  wire [1:0] f_ma = uw[6:5];
  wire [1:0] f_mb = uw[4:3];
  wire [2:0] f_c  = uw[27:25];
  wire       f_i  = uw[24];
  wire [8:0] f_t  = uw[8:0];

  wire is_br   = (op == 4'd4);
  wire is_jmp  = (op == 4'd5);
  wire is_call = (op == 4'd6);
  wire is_ret  = (op == 4'd7);
  wire is_alu  = !(is_br || is_jmp || is_call || is_ret);   // 0-3, 8-15 (11-15 never assembled: SUB, as R845's default)
  // R935: LDE / LDM (LOG only: with LOG = 0, 11 and 12 are SUB as above)
  wire is_lde  = LOG && (op == 4'd11);
  wire is_ldm  = LOG && (op == 4'd12);
  wire is_ld   = (op == 4'd8) || (op == 4'd9) || is_lde || is_ldm;
  wire is_end  = (op == 4'd10);
  wire d_mul   = (op == 4'd2);
  wire d_div   = (op == 4'd3);
  wire d_sub   = !(op == 4'd0) && !d_mul && !d_div;          // SUB, LDX, LDY, END (LDE, LDM)
  wire d_wr    = is_alu && !is_end;
  // register 0 is ZERO (a constant: never written), so it is never read --
  // the operand is +-0 by its modifier, which is what the read returned
  wire need_a  = is_alu && !is_ld && (f_a != 7'd0);
  wire need_b  = is_alu && !is_ld && !is_end && (f_b != 7'd0);

  function automatic logic [63:0] modv(input logic [63:0] v, input logic [1:0] m);
    case (m)
      2'd1:    return {~v[63], v[62:0]};
      2'd2:    return {1'b0,   v[62:0]};
      2'd3:    return {1'b1,   v[62:0]};
      default: return v;
    endcase
  endfunction

  wire q_nan  = (q[62:52] == 11'h7ff) && (q[51:0] != 52'd0);
  wire q_inf  = (q[62:52] == 11'h7ff) && (q[51:0] == 52'd0);
  logic cond;
  always_comb begin
    case (f_c)
      3'd0:    cond = q[63];
      3'd1:    cond = (q[62:0] == 63'd0);
      3'd2:    cond = q_nan;
      3'd3:    cond = q_inf;
      3'd4:    cond = q[0];
      3'd5:    cond = q[1];
      default: cond = 1'b0;
    endcase
  end

  // ------------------------------------------------------------ the pipeline
  // An instruction is in D while it reads its operands (one register-file
  // read a cycle), X the cycle its last read lands, ISS the cycle its
  // request is high, P1, then P2: the unit's done, its y on res, written to
  // the register file in that cycle. Add and multiply both take two cycles,
  // so one op a cycle can be in each place. DIV is not piped: D waits from
  // the moment it leaves until the divider's done.
  typedef enum logic [1:0] {S_IDLE, S_RUN, S_DRAIN} st_t;
  st_t st;

  logic        x_v, x_b, x_imm, x_isg, x_w, x_mul, x_div, x_sub, x_end;
  logic [1:0]  x_mod;
  logic [6:0]  x_d;
  logic        i_v, i_w, i_mul, i_end;
  logic [6:0]  i_d;
  logic        p1_v, p1_w, p1_mul, p1_end;
  logic [6:0]  p1_d;
  logic        p2_v, p2_w, p2_mul;
  logic [6:0]  p2_d;
  logic        dv_busy;
  logic [6:0]  dv_d;

  logic [8:0]  ras [4];
  logic [1:0]  sp;
  logic        bph;          // BR: its register read is in flight
  // the operand slots of the instruction in D: not yet read, read last
  // cycle (lands now), waiting for its writer to reach P2, latched
  localparam logic [1:0] SL_NEW = 2'd0, SL_RQ = 2'd1, SL_PEND = 2'd2, SL_OK = 2'd3;
  logic [1:0]  sa, sb;

  // a register with a write still to come (in X, ISS or P1), or being
  // written this cycle (P2: the read would return the old value)
  wire hl_a = (x_v && x_w && (x_d == f_a)) || (i_v && i_w && (i_d == f_a)) || (p1_v && p1_w && (p1_d == f_a));
  wire hl_b = (x_v && x_w && (x_d == f_b)) || (i_v && i_w && (i_d == f_b)) || (p1_v && p1_w && (p1_d == f_b));
  wire hl_d = (x_v && x_w && (x_d == f_d)) || (i_v && i_w && (i_d == f_d)) || (p1_v && p1_w && (p1_d == f_d));
  wire hn_a = p2_v && p2_w && (p2_d == f_a);
  wire hn_b = p2_v && p2_w && (p2_d == f_b);

  wire drun = (st == S_RUN) && !dv_busy;
  wire dalu = drun && is_alu;

  // slot a: lands (its read was last cycle), captured from res (its writer
  // is in P2), or read now. A capture or a latch with no read is never made
  // while X latches the instruction before (x_v): its operands are held.
  // A NEW slot whose writer is in P2 while X holds the operands waits a
  // cycle and reads the register file. A PEND slot's writer is never in P2
  // with X full: X is only ever the first cycle an instruction spends in D.
  wire a_land = dalu && (sa == SL_RQ);
  wire a_cap  = dalu && need_a && (sa == SL_NEW || sa == SL_PEND) && hn_a && !x_v;
  wire a_rd   = dalu && need_a && (sa == SL_NEW) && !hl_a && !hn_a;
  wire a_ok   = !need_a || (sa == SL_OK) || a_land || a_cap;
  wire b_land = dalu && (sb == SL_RQ);
  wire b_cap  = dalu && need_b && (sb == SL_NEW || sb == SL_PEND) && hn_b && !x_v;
  wire b_rd   = dalu && need_b && (sb == SL_NEW) && !hl_b && !hn_b && !a_rd;
  wire b_ok   = !need_b || (sb == SL_OK) || b_land || b_cap;
  // a second write in flight to one register is never made, so a capture
  // always takes the one writer before it
  wire waw    = d_wr && hl_d;
  wire lv_x   = dalu && !waw && ((a_rd && b_ok) || (b_rd && a_ok));
  wire lv_d   = dalu && !waw && !a_rd && !b_rd && a_ok && b_ok && !x_v;

  wire br_rd  = drun && is_br && !bph && !hl_a && !hn_a;
  wire br_ev  = drun && is_br && bph;
  wire ctl    = drun && (is_jmp || is_call || is_ret);
  wire adv    = lv_x || lv_d || br_ev || ctl;

  assign raddr = (is_br || (need_a && sa == SL_NEW && !hl_a && !hn_a)) ? f_a : f_b;

  wire [8:0] pc1 = pc + 9'd1;
  always_comb begin
    if (st == S_IDLE)                  fa = (LOG && lg) ? 9'd4 : {7'd0, entry};
    else if (!adv)                     fa = pc;
    else if (is_jmp || is_call)        fa = f_t;
    else if (is_ret)                   fa = ras[sp - 2'd1];
    else if (is_br)                    fa = (cond ^ f_i) ? f_t : pc1;
    else                               fa = pc1;
  end

  assign we    = (p2_v && p2_w) || (dv_busy && div_done);
  assign waddr = (dv_busy && div_done) ? dv_d : p2_d;

  // R935: LDE's operand, MAGIC + (e - 1023) as a two's-complement add on the
  // low bits (MAGIC's low 51 are zero, so this IS the double MAGIC + e - 1023),
  // and its b, MAGIC; LDM's, x's mantissa with the exponent of 1.0. The load
  // source a_src 2 is x, or one of these for LDE / LDM.
  localparam logic [62:0] MAGIC = 63'h4338_0000_0000_0000;
  wire  [11:0] x_eu  = {1'b0, x[62:52]} - 12'd1023;
  wire  [63:0] x_lde = {1'b0, MAGIC} + {{52{x_eu[11]}}, x_eu};
  wire  [63:0] x_ldm = {1'b0, 11'h3ff, x[51:0]};
  wire  [63:0] x_ld  = is_lde ? x_lde : is_ldm ? x_ldm : x;

  wire imm_a_sg = f_ma[0];             // modv(+0, m): -0 for 1 and 3
  wire imm_b_sg = f_mb[0];

  // The operand registers' next values, as a load, a clear (an immediate
  // +-0: only the sign survives) and a source -- the register file's q, res,
  // x or y -- with the modifier on the sign. The cases are exclusive: X
  // never shares a cycle with a latch by D.
  logic        a_ld, a_zero, a_zsg, b_ld, b_zero, b_zsg, b_mg;   // b_mg: LDE's b is MAGIC
  logic [1:0]  a_src, a_m, b_m;       // a_src: 0 q, 1 res, 2 x (LDE / LDM: x_lde / x_ldm), 3 y
  logic        b_src;                 // 0 q, 1 res
  always_comb begin
    a_ld = 1'b0; a_zero = 1'b0; a_zsg = 1'b0; a_src = 2'd0; a_m = f_ma;
    b_ld = 1'b0; b_zero = 1'b0; b_zsg = 1'b0; b_mg = 1'b0; b_src = 1'b0; b_m = f_mb;
    if (x_v) begin
      a_m = x_mod; b_m = x_mod;
      if (x_b) begin b_ld = 1'b1; a_ld = x_imm; a_zero = 1'b1; a_zsg = x_isg; end
      else     begin a_ld = 1'b1; b_ld = x_imm; b_zero = 1'b1; b_zsg = x_isg; end
    end else if (dalu) begin
      if (a_land) a_ld = 1'b1;
      if (a_cap)  begin a_ld = 1'b1; a_src = 2'd1; end
      if (b_land) b_ld = 1'b1;
      if (b_cap)  begin b_ld = 1'b1; b_src = 1'b1; end
      if (lv_d && !need_a) begin
        a_ld = 1'b1; a_m = 2'd0;
        if (op == 4'd8 || is_lde || is_ldm) a_src = 2'd2;
        else if (op == 4'd9) a_src = 2'd3;
        else begin a_zero = 1'b1; a_zsg = imm_a_sg; end
      end
      if (lv_d && !need_b) begin
        b_ld = 1'b1; b_zero = 1'b1; b_zsg = imm_b_sg && !(is_ld || is_end); b_mg = is_lde;
      end
    end
  end
  logic [63:0] a_v, b_v;
  always_comb begin
    case (a_src)
      2'd0:    a_v = q;
      2'd1:    a_v = res;
      2'd2:    a_v = x_ld;
      default: a_v = y;
    endcase
    b_v = b_src ? res : q;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE; pc <= 9'd0; sp <= 2'd0; bph <= 1'b0;
      sa <= SL_NEW; sb <= SL_NEW;
      opa <= 64'd0; opb <= 64'd0;
      add_req <= 1'b0; mul_req <= 1'b0; div_req <= 1'b0; sub <= 1'b0;
      fin <= 1'b0; act <= 1'b0;
      x_v <= 1'b0; x_b <= 1'b0; x_imm <= 1'b0; x_isg <= 1'b0; x_w <= 1'b0;
      x_mul <= 1'b0; x_div <= 1'b0; x_sub <= 1'b0; x_end <= 1'b0; x_mod <= 2'd0; x_d <= 7'd0;
      i_v <= 1'b0; i_w <= 1'b0; i_mul <= 1'b0; i_end <= 1'b0; i_d <= 7'd0;
      p1_v <= 1'b0; p1_w <= 1'b0; p1_mul <= 1'b0; p1_end <= 1'b0; p1_d <= 7'd0;
      p2_v <= 1'b0; p2_w <= 1'b0; p2_mul <= 1'b0; p2_d <= 7'd0;
      dv_busy <= 1'b0; dv_d <= 7'd0;
      for (int i = 0; i < 4; i++) ras[i] <= 9'd0;
    end else begin
      pc <= fa;
      add_req <= 1'b0; mul_req <= 1'b0; div_req <= 1'b0;
      x_v <= 1'b0; i_v <= 1'b0;
      p1_v <= i_v; p1_w <= i_w; p1_mul <= i_mul; p1_end <= i_end; p1_d <= i_d;
      p2_v <= p1_v; p2_w <= p1_w; p2_mul <= p1_mul; p2_d <= p1_d;
      fin <= p1_v && p1_end;
      if (dv_busy && div_done) dv_busy <= 1'b0;

      case (st)
        S_IDLE: if (start) begin
          st <= S_RUN; act <= 1'b1; sp <= 2'd0; bph <= 1'b0; sa <= SL_NEW; sb <= SL_NEW;
        end
        S_DRAIN: if (fin) begin          // END's result was on res this cycle
          act <= 1'b0; st <= S_IDLE;
        end
        default: ;
      endcase

      if (a_ld) opa <= a_zero ? {a_zsg, 63'd0} : modv(a_v, a_m);
      if (b_ld) opb <= b_zero ? {b_zsg, b_mg ? MAGIC : 63'd0} : modv(b_v, b_m);

      // X: the last read lands; the request goes out
      if (x_v) begin
        add_req <= !x_mul && !x_div; mul_req <= x_mul; div_req <= x_div; sub <= x_sub;
        i_v <= !x_div; i_w <= x_w; i_mul <= x_mul; i_end <= x_end; i_d <= x_d;
      end

      if (dalu) begin
        if (lv_d) begin
          add_req <= !d_mul && !d_div; mul_req <= d_mul; div_req <= d_div; sub <= d_sub;
          i_v <= !d_div; i_w <= d_wr; i_mul <= d_mul; i_end <= is_end; i_d <= f_d;
        end
        if (lv_x) begin
          x_v <= 1'b1; x_b <= b_rd; x_mod <= b_rd ? f_mb : f_ma;
          x_imm <= b_rd ? !need_a : !need_b;
          x_isg <= b_rd ? imm_a_sg : (imm_b_sg && !is_end);
          x_w <= d_wr; x_mul <= d_mul; x_div <= d_div; x_sub <= d_sub; x_end <= is_end; x_d <= f_d;
        end
        if (lv_x || lv_d) begin
          sa <= SL_NEW; sb <= SL_NEW;
          if (d_div) begin dv_busy <= 1'b1; dv_d <= f_d; end
          if (is_end) st <= S_DRAIN;
        end else begin
          if (a_land || a_cap)                              sa <= SL_OK;
          else if (a_rd)                                    sa <= SL_RQ;
          else if (need_a && sa == SL_NEW && hl_a)          sa <= SL_PEND;
          if (b_land || b_cap)                              sb <= SL_OK;
          else if (b_rd)                                    sb <= SL_RQ;
          else if (need_b && sb == SL_NEW && hl_b)          sb <= SL_PEND;
        end
      end

      if (br_rd) bph <= 1'b1;
      if (br_ev) bph <= 1'b0;
      if (ctl && is_call) begin ras[sp] <= pc1; sp <= sp + 2'd1; end
      if (ctl && is_ret)  sp <= sp - 2'd1;
    end
  end

  assign sel_mul = act && p2_v && p2_mul;
  assign sel_div = act && dv_busy && !p2_v;
  assign sel_add = act && !(p2_v && p2_mul) && !(dv_busy && !p2_v);

  // The adder's and multiplier's done are not needed: P2 is their done by
  // construction (both take two cycles). The bench checks it, and the
  // pipeline's own rules, every cycle.
`ifdef VERILATOR
  always_ff @(posedge clk) begin
    if (p2_v && !(p2_mul ? mul_done : add_done))
      $fatal(1, "i960_fptrans: P2 without its unit's done (a unit is no longer two cycles)");
    if (x_v && (lv_d || a_land || b_land || a_cap || b_cap))
      $fatal(1, "i960_fptrans: D latched an operand while X held the instruction before");
    if (we && (p2_v && p2_w) && (dv_busy && div_done))
      $fatal(1, "i960_fptrans: two writes in one cycle");
    if (x_v && ((sa == SL_PEND && hn_a) || (sb == SL_PEND && hn_b)))
      $fatal(1, "i960_fptrans: a pending operand's writer reached P2 while X held the operands");
  end
`endif

endmodule
