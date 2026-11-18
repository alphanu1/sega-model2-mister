// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- the 2B SHARC's X-clock compute (study R1028): the fixed
// ALU, the shifter and the float ALU's "misc" functions (everything but FADD / FSUB / FAVG and
// FMUL, which are sharc_fadd / sharc_fmul), on shared parts:
//   one 33-bit adder         the fixed ALU's arithmetic, compares, MIN / MAX / CLIP, ABS / NEG,
//                            and FLOAT's magnitude
//   one funnel shifter       ({H, L, 0} >> k)[32:0], k 0-63: LSHIFT / ASHIFT / ROT, the field
//                            extracts and deposits, FIX's alignment (with its round bit) and
//                            FLOAT's normalisation
//   one magnitude compare    |x| against |y| for FMIN / FMAX / FCOMP / FCLIP
//   one thermometer mask     the field length's mask, FIX's sticky bits
//   one bit decoder          BSET / BCLR / BTGL / BTST, the field's sign bit
// The word does one of the three at most, so nothing is lost by the sharing.
// TIMING (R1029): the fixed ALU and every misc function but FIX and FLOAT are one clock (X's
// first; their inputs are registers, held through X); the shifter two (its funnel operands
// registered). FIX / FIX BY and FLOAT / FLOAT BY
// are three: X's first clock aligns (FIX: the scaled operand's exponent; FLOAT: |Rx| on the
// adder and its leading zeros) into stage A's registers, the second shifts and rounds on the
// shared funnel into stage B's, the third finishes (FIX: the sign and the increment; FLOAT: the
// exponent and FLOAT BY's scale). misc_x says how many clocks after the first the result needs.
// The stage registers load every clock (the inputs are held while X lasts). The results are
// bit for bit m2b_sharc_pkg's alu_fixed / shifter (MAME's compute.hxx as Hornet's v1 restates it)
// and sharc_fp_pkg's f_* (MAME_RND 1) or man_* (MAME_RND 0) functions, which stay the reference:
// sim/sharc/xu checks this unit against them.

`timescale 1ns/1ps

module m2b_sharc_xu #(
    parameter bit MAME_RND = 1'b0,
    // R1048: the field length (s_l) and the decoder's bit (dj) from the caller's registers, made a
    // clock earlier from the value sh_val is loaded with (pre_l / pre_dj equal them in every clock
    // they are used); 0 makes them here from sh_val
    parameter bit PRE = 1'b0
) (
    input  logic        clk,
    input  logic        fix_on,
    input  logic [7:0]  fix_op,         // alu_fixed's op (cu 0, op[7] 0)
    input  logic [10:0] fix_k,          // m2b_sharc_pkg::fix_k_of(fix_op): the adder's operands (R1029)
    input  logic        sh_on,
    input  logic [5:0]  sh_op,          // the shifter's op
    input  logic        sh_imm,         // the immediate form
    input  logic [31:0] sh_val,         // the immediate (sh_imm) or R[ry]
    input  logic [5:0]  pre_l,          // PRE: min(sh_val[11:6], 32)
    input  logic [4:0]  pre_dj,         // PRE: the decoder's bit (below)
    input  logic        misc_on,
    input  logic [4:0]  misc_op,        // tb_sharc_fp's numbering (2 FAVG is the adder's)
    input  logic [31:0] x, y, n,        // fixed / shifter: R[rx], R[ry], R[rn]
    input  logic [31:0] fx, fy,         // float: the adder's operands
    input  logic [31:0] astat,
    input  logic        alusat,
    input  logic        trunc,
    // fixed and shifter results: r, write, the new ASTAT, STKY bits to OR in
    output logic [31:0] fix_r, sh_r,
    output logic        fix_we, sh_we,          // (fix_we: AN / AZ are the result's, set at the landing)
    output logic [31:0] fix_astat, sh_astat, fix_stky,
    // the misc float result: r, ASTAT / STKY bits to OR in (after the ALU group is cleared)
    output logic [31:0] misc_r, misc_a, misc_s,
    output logic [1:0]  misc_x,         // X clocks the misc result needs after the first (R1029)
    output logic [1:0]  sh_x            // ... and the shifter's
);

import sharc_fp_pkg::*;

// ASTAT / STKY bits not in sharc_fp_pkg (m2b_sharc_pkg has them; a function package would need
// both imports, which Quartus 17 refuses -- R1027)
localparam logic [31:0] X_SV = 32'h0000_0800, X_SZ = 32'h0000_1000, X_SS = 32'h0000_2000;
localparam logic [31:0] X_AOS = 32'h0000_0004;
localparam logic [31:0] X_ALU_GRP = AZ | AN | AV | AC | AS | AI;

// ============================================================ decode of the op
logic k_add, k_addc, k_sub, k_subc, k_cmp, k_min, k_max, k_clip, k_neg, k_abs, k_pass;
logic k_and, k_or, k_xor, k_not;
always_comb begin
    {k_add, k_addc, k_sub, k_subc, k_cmp, k_min, k_max, k_clip, k_neg, k_abs, k_pass} = '0;
    {k_and, k_or, k_xor, k_not} = '0;
    case (fix_op)
    8'h01, 8'h05, 8'h25, 8'h29: k_add = 1'b1;
    8'h02, 8'h06, 8'h26, 8'h2a: k_sub = 1'b1;
    8'h0a: k_cmp = 1'b1;
    8'h21: k_pass = 1'b1;
    8'h22: k_neg = 1'b1;
    8'h30: k_abs = 1'b1;
    8'h40: k_and = 1'b1;
    8'h41: k_or = 1'b1;
    8'h42: k_xor = 1'b1;
    8'h43: k_not = 1'b1;
    8'h61: k_min = 1'b1;
    8'h62: k_max = 1'b1;
    8'h63: k_clip = 1'b1;
    default: ;
    endcase
    k_addc = fix_op == 8'h05 || fix_op == 8'h25;
    k_subc = fix_op == 8'h06 || fix_op == 8'h26;
end

localparam logic [4:0] M_ABS = 5'd4, M_MIN = 5'd5, M_MAX = 5'd6, M_NEG = 5'd7, M_PASS = 5'd8,
                       M_COMP = 5'd9, M_SCALB = 5'd10, M_LOGB = 5'd11, M_FIX = 5'd12, M_FIXBY = 5'd13,
                       M_FIXBYM = 5'd14, M_FLOAT = 5'd15, M_FLOATBY = 5'd16, M_FLOATBYM = 5'd17,
                       M_RECIPS = 5'd18, M_RSQRTS = 5'd19, M_COPYSIGN = 5'd20, M_CLIP = 5'd21;
logic m_fix, m_float, m_scaled;
assign m_fix = misc_on && (misc_op == M_FIX || misc_op == M_FIXBY || misc_op == M_FIXBYM);
assign m_float = misc_on && (misc_op == M_FLOAT || misc_op == M_FLOATBY || misc_op == M_FLOATBYM);
assign m_scaled = misc_op == M_FIXBY || misc_op == M_FIXBYM || misc_op == M_FLOATBY || misc_op == M_FLOATBYM;
assign misc_x = (m_fix || m_float) ? 2'd2 : 2'd0;
assign sh_x = 2'd1;

// ============================================================ the shared parts

// ---- the negation of y (CLIP's |y| and -|y|)
logic [31:0] ny, ay, nay;
assign ny = 32'h0 - y;
assign ay = y[31] ? ny : y;
assign nay = y[31] ? y : ny;

// ---- the adder: s = A + B + cin
logic [31:0] ad_a, ad_b, ad_s;
logic        ad_ci, ad_co, ad_v, ad_lt, ad_eq;
always_comb begin
    logic c;
    c = (astat & AC) != 0;
    // the fixed ALU's only (R1029: FLOAT's |Rx| has its own); an AND-OR on fix_k. CLIP: x < -|y|
    // is x - y for y < 0, x + y for y >= 0 -- the same exact sum as x - nay, without the
    // negation's adder before this one
    ad_a = ((fix_k[6] && x[31]) || fix_k[7]) ? 32'h0 : x;
    ad_b = ({32{fix_k[0]}} & y) | ({32{fix_k[1]}} & ~y) | {31'h0, fix_k[3]} | {{31{fix_k[4] | fix_k[5]}}, fix_k[4]} |
           ({32{fix_k[7] || (fix_k[6] && x[31])}} & ~x) | ({32{fix_k[8]}} & (y ^ {32{y[31]}}));
    ad_ci = fix_k[9] || (fix_k[10] && c) || (fix_k[6] && x[31]) || (fix_k[8] && y[31]);
    {ad_co, ad_s} = {1'b0, ad_a} + {1'b0, ad_b} + {32'h0, ad_ci};
    ad_v = (~(ad_a ^ ad_b) & (ad_a ^ ad_s)) >> 31 != 0;
    ad_lt = ad_s[31] ^ ad_v;                             // signed A < ~B + 1 (the compares)
    ad_eq = ad_s == 32'h0;
end

// ---- the float operands, flushed in the manual's rounding where man_* flushes them
logic [31:0] xin, yin;
assign xin = MAME_RND ? fx : flush(fx);
assign yin = MAME_RND ? fy : flush(fy);

// ---- scalb on xin (SCALB, FIX BY) and on FLOAT's result (FLOAT BY): exponent + Ry
function automatic logic [31:0] scalb_r(input logic [31:0] f, input logic [31:0] ry);
    logic signed [31:0] e;                               // MAME's C int: wraps at 32 bits
    // ry + (exp - 127) as ry + (exp - 128) + 1: exp - 128 is the exponent's bits, its top one
    // inverted, sign-extended (R1029: one adder, no subtract before it)
    e = $signed(ry) + 32'(signed'({~f[30], f[29:23]})) + 32'sd1;
    // e > 127, e < -126 as bit tests (R1029: Aggressive Area builds the compares as chains)
    if (!e[31] && e[30:7] != 24'h0) return (f & SIGN) | INF;
    if (e[31] && (e[30:7] != 24'hFF_FFFF || e[6:0] <= 7'h01)) return f & SIGN;
    return {f[31], 8'(e + 32'sd127), f[22:0]};
endfunction
logic [31:0] sc_in;
assign sc_in = scalb_r(xin, fy);

// ---- FIX: the operand and its alignment (stage A: computed in X's first clock, registered)
logic [23:0] fm;
logic        f_big, f_tiny, f_left, f_sgn, f_den;
logic [5:0]  f_km1;                                      // f_k - 1 (the sticky bits' thermometer, R1029)
logic        th_fix;                                     // the thermometer is FIX's (its sticky bits)
logic [5:0]  f_k;
logic [23:0] fm_c;
logic        f_big_c, f_tiny_c, f_left_c, f_sgn_c, f_den_c;
logic [5:0]  f_k_c;
always_comb begin
    logic [31:0] fv;
    logic [7:0]  fe, fee;
    logic [8:0]  kk;
    fv = m_scaled ? sc_in : xin;
    fe = fv[30:23];
    fee = (fe == 8'h00) ? 8'd1 : fe;
    fm_c = {fe != 8'h00, fv[22:0]};
    f_big_c = fe == 8'hFF || fe >= 8'd158;
    f_left_c = fe >= 8'd150;                             // left by fee - 150 (0-7)
    kk = 9'd150 - {1'b0, fee};                           // right by 1-149
    f_tiny_c = fe < 8'd118;                              // (= !f_left && kk > 32, on the exponent: R1029)
    f_k_c = kk[5:0] ^ {f_left_c, 5'h0};                  // (32 - (fee - 150) = kk + 32, mod 64)
    f_sgn_c = fv[31];
    f_den_c = is_den(fv);
end

// ---- FLOAT: the magnitude (its own negation, R1029) and its leading zeros (stage A)
logic [31:0] fl_m, fl_abs;
logic [5:0]  fl_k;                                       // 32 - fl_lz (the funnel's count, R1029)
assign fl_abs = fx[31] ? 32'h0 - fx : fx;
logic [5:0]  fl_lz;
logic        fl_zero;
logic [5:0]  fl_lz_c;
always_comb begin
    // a tree: the upper half's count, else 16 + the lower's (Aggressive Area builds a priority
    // loop as a chain)
    logic [4:0] h, l;
    h = 5'd16; l = 5'd16;
    for (int i = 0; i < 16; i++) if (fl_abs[16 + i]) h = 5'(15 - i);
    for (int i = 0; i < 16; i++) if (fl_abs[i]) l = 5'(15 - i);
    fl_lz_c = (h != 5'd16) ? {1'b0, h} : 6'd16 + {1'b0, l};
end
always_ff @(posedge clk) begin
    fm <= fm_c; f_big <= f_big_c; f_tiny <= f_tiny_c; f_left <= f_left_c; f_k <= f_k_c; f_km1 <= 6'(f_k_c - 6'd1);
    f_sgn <= f_sgn_c; f_den <= f_den_c;
    fl_m <= fl_abs; fl_lz <= fl_lz_c; fl_k <= 6'(6'd32 - fl_lz_c); fl_zero <= fl_abs == 32'h0;
end

// ---- the shifter's controls
logic signed [31:0] s_sh;                               // the shift count (LSHIFT / ASHIFT / ROT)
logic [5:0]  s_bitn, s_len, s_l;
logic        s_fz;                                       // a field op whose result is 0
logic        s_cnt_l, s_cnt_r;                           // the count is 0..31 / -31..-1
logic [4:0]  s_amt_r;                                    // -count for a right shift
logic [31:0] th, th1;                                    // the thermometer (1 << j) - 1 (th1: X's first clock)
logic [31:0] dec, dec1;                                  // the bit decoder 1 << j
logic [4:0]  dj;
logic [31:0] sx_v;                                       // FDEP's sign-extended field
always_comb begin
    logic signed [7:0] sh8;
    sh8 = sh_val[7:0];
    s_sh = sh_imm ? 32'(sh8) : $signed(sh_val);
    if (sh_op == 6'h08) s_sh = 32'(sh8);                 // OR LSHIFT: MAME takes the low byte
    s_cnt_l = s_sh[31:5] == 27'h0;
    s_cnt_r = s_sh[31:5] == 27'h7FF_FFFF && s_sh[4:0] != 5'h0;
    s_amt_r = 5'h0 - s_sh[4:0];
    s_bitn = sh_val[5:0];
    s_len = sh_val[11:6];
    s_l = PRE ? pre_l : (s_len > 6'd32) ? 6'd32 : s_len;
    s_fz = s_len == 6'd0 || s_bitn >= 6'd32;
    // the thermometer: the field's length (the funnel operands, X's first clock)
    for (int i = 0; i < 32; i++) th1[i] = 6'(i) < s_l;
    // the decoder: the bit of BSET / BCLR / BTGL / BTST, or the field's top bit (its sign)
    dj = PRE ? pre_dj : (sh_op[5:4] == 2'b11) ? sh_val[4:0] : 5'(s_l - 6'd1);
    dec1 = 32'h1 << dj;
    sx_v = x & th1;
    if (s_l < 6'd32 && (x & dec1) != 0) sx_v = sx_v | ~th1;
end
// the shifter's controls, registered with its funnel operands (R1029: X's second clock reads
// registers only); the thermometer and decoder again from them -- the thermometer FIX's sticky
// bits too (below its round bit, from stage A)
logic        r_rng;
logic [5:0]  r_l;
logic [4:0]  r_dj;
always_ff @(posedge clk) begin r_rng <= sh_val[31:5] == 27'h0; r_l <= s_l; r_dj <= dj; end
always_comb begin
    logic [5:0] tj;
    tj = th_fix ? f_km1 : r_l;                           // (registered select and count, R1029)
    for (int i = 0; i < 32; i++) th[i] = 6'(i) < tj;
    dec = 32'h1 << r_dj;
end

// ---- the shifter's funnel operands (X's first clock), registered (R1029: a shift is two X
// clocks, its funnel and result in the second)
logic [31:0] sf_h, sf_l, shf_h, shf_l;
logic [5:0]  sf_k, shf_k;
always_comb begin
    sf_h = 32'h0; sf_l = 32'h0; sf_k = 6'd32;
    case (sh_op)
    6'h00, 6'h08, 6'h01: begin
        if (!s_sh[31]) begin sf_h = x; sf_k = 6'(6'd32 - {1'b0, s_sh[4:0]}); end
        else begin
            // a right shift: LSHIFT logical (OR LSHIFT's register form arithmetic), ASHIFT arithmetic
            sf_h = ((sh_op == 6'h01 || (sh_op == 6'h08 && !sh_imm)) && x[31]) ? 32'hFFFF_FFFF : 32'h0;
            sf_l = x;
            sf_k = (sh_op == 6'h01 && !s_cnt_r) ? 6'd31 : {1'b0, s_amt_r};
        end
    end
    6'h02: begin sf_h = x; sf_l = x; sf_k = 6'(6'd32 - {1'b0, s_sh[4:0]}); end
    6'h10, 6'h12: begin sf_h = (sh_op == 6'h10 && x[31]) ? 32'hFFFF_FFFF : 32'h0; sf_l = x; sf_k = s_bitn; end
    6'h11, 6'h19: begin sf_h = x & th1; sf_k = 6'(6'd32 - s_bitn); end
    6'h13: begin sf_h = sx_v; sf_k = 6'(6'd32 - s_bitn); end
    default: ;
    endcase
end
logic [1:0]  fn_sel;                                    // 0 the shifter's, 1 FLOAT's, 2 FIX left, 3 FIX right
always_ff @(posedge clk) begin
    shf_h <= sf_h; shf_l <= sf_l; shf_k <= sf_k;
    fn_sel <= !misc_on ? 2'd0 : m_float ? 2'd1 : f_left_c ? 2'd2 : 2'd3;
    th_fix <= m_fix;
end

// ---- the funnel: ({H, L, 0} >> k)[32:0], on registers (X's second clock): the shifter's, or
// FIX / FLOAT's from stage A
logic [31:0] fn_h, fn_l, fn_o;
logic [5:0]  fn_k;
logic        fn_g;                                       // the bit below the result (FIX's round bit)
always_comb begin
    logic [64:0] w;
    // the source by a select registered with stage A (R1029: no decode of the op before it)
    case (fn_sel)
    2'd0: begin fn_h = shf_h; fn_l = shf_l; fn_k = shf_k; end
    2'd1: begin fn_h = fl_m; fn_l = 32'h0; fn_k = fl_k; end
    2'd2: begin fn_h = {8'h0, fm}; fn_l = 32'h0; fn_k = f_k; end
    default: begin fn_h = 32'h0; fn_l = {8'h0, fm}; fn_k = f_k; end
    endcase
    w = {fn_h, fn_l, 1'b0} >> fn_k;
    fn_o = w[32:1];
    fn_g = w[0];
end

// ============================================================ the fixed ALU
always_comb begin
    logic [31:0] r, a, k, acc;
    logic        set_r, lt2;
    acc = 32'h0;
    a = astat & ~X_ALU_GRP;
    k = 32'h0;
    r = 32'h0;
    set_r = 1'b1;
    lt2 = $signed(ay) < $signed(x);
    if (k_add || k_sub) begin
        r = ad_s;
        if (ad_v) begin a |= AV; k |= X_AOS; end
        if (ad_co) a |= AC;
        if (alusat && ad_v) r = {32{ad_s[31]}} ^ 32'h8000_0000;
    end else if (k_cmp) begin
        set_r = 1'b0;
        if (ad_eq) a |= AZ;
        else if (ad_lt) a |= AN;
        acc = (a >> 1) & 32'h7F00_0000;
        if ((a & (AZ | AN)) == 0) acc |= 32'h8000_0000;
        a = (a & 32'h00FF_FFFF) | acc;
    end else if (k_pass) r = x;
    else if (k_neg) begin
        r = ad_s;
        if (ad_v) begin a |= AV; k |= X_AOS; end
        if (ad_co) a |= AC;
        if (alusat && ad_v) r = {32{ad_s[31]}} ^ 32'h8000_0000;
    end else if (k_abs) begin
        r = ad_s;
        if (ad_s[31]) begin a |= AV; k |= X_AOS; if (alusat) r = 32'h7FFF_FFFF; end
        if (x[31]) a |= AS;
    end else if (k_and) r = x & y;
    else if (k_or) r = x | y;
    else if (k_xor) r = x ^ y;
    else if (k_not) r = ~x;
    else if (k_min) r = ad_lt ? x : y;
    else if (k_max) r = ad_lt ? y : x;
    else if (k_clip) r = ad_lt ? nay : lt2 ? ay : x;
    else set_r = 1'b0;
    // a written result's AN / AZ are the landing's, from the result register (R1029: off X's
    // path); fix_fz says so
    fix_r = r;
    fix_we = set_r;
    fix_astat = a & ~AF;
    fix_stky = k;
end

// ============================================================ the shifter
// The result as one AND-OR over the funnel's output, its controls decided in X's first clock
// and registered (R1029: a case over the ops built a deep select). Op for op the same result
// and flags as R1028's case: LSHIFT / OR LSHIFT / ASHIFT / ROT, FEXT (SE), FDEP (SE, OR), BSET /
// BCLR / BTGL, BTST.
logic       q_en, q_mth, q_sx, q_orn, q_szp, q_sv;
logic [1:0] q_cls, q_bk;                                 // 0 funnel, 1 BSET / BCLR / BTGL, 2 BTST, 3 none
always_ff @(posedge clk) begin
    logic en, mth, sx, orn, szp, sv;
    logic [1:0] cls;
    en = 1'b0; mth = 1'b0; sx = 1'b0; orn = 1'b0; szp = 1'b0; sv = 1'b0; cls = 2'd0;
    case (sh_op)
    6'h00, 6'h08: begin
        en = s_cnt_l || s_cnt_r; sv = !s_sh[31] && s_sh != 0;
        orn = sh_op == 6'h08; szp = sh_op == 6'h08 && sh_imm;
    end
    6'h01: begin en = s_sh[31] || s_cnt_l; sv = !s_sh[31] && s_sh != 0; end
    6'h02: begin en = 1'b1; sv = !sh_imm && !s_sh[31] && s_sh != 0; end
    6'h10, 6'h11, 6'h12, 6'h13, 6'h19: begin
        logic ovf;
        ovf = {1'b0, s_bitn} + {1'b0, s_len} > 7'd32;
        sv = ovf;
        en = !s_fz;
        case (sh_op)
        6'h10: mth = 1'b1;
        // FEXT SE: the field's top bit is x[bitn + len - 1] (no ovf), registered (R1029: off
        // the funnel's output); none for an empty field
        6'h12: begin mth = !ovf; sx = !ovf && s_l < 6'd32 && !s_fz && x[5'(s_bitn + s_len - 6'd1)]; end
        6'h19: begin en = s_len != 6'd0 && s_bitn < 6'd32; orn = 1'b1; end
        default: ;
        endcase
    end
    6'h30, 6'h31, 6'h32: begin cls = 2'd1; sv = sh_val[31:5] != 27'h0; end
    6'h33: begin cls = 2'd2; sv = sh_val[31:5] != 27'h0; end
    default: cls = 2'd3;
    endcase
    q_en <= en; q_mth <= mth; q_sx <= sx; q_orn <= orn; q_szp <= szp; q_sv <= sv; q_cls <= cls;
    q_bk <= sh_op[1:0];
end
always_comb begin
    logic [31:0] f, v, rf, ro, rb, r;
    logic        sz, we;
    f = q_en ? fn_o : 32'h0;
    v = q_mth ? f & th : f;
    rf = q_sx ? (v | ~th) : v;
    ro = q_orn ? (n | rf) : rf;
    if (!r_rng) rb = x;
    else case (q_bk)
        2'd0: rb = x | dec;
        2'd1: rb = x & ~dec;
        default: rb = x ^ dec;
    endcase
    case (q_cls)
    // (ro == 0 is rf == 0 and n == 0 where n is ORed in: one zero test after the funnel, R1029)
    2'd0: begin r = ro; we = 1'b1; sz = rf == 32'h0 && !(q_orn && !q_szp && n != 32'h0); end
    2'd1: begin r = rb; we = 1'b1; sz = rb == 32'h0; end
    2'd2: begin r = 32'h0; we = 1'b0; sz = r_rng ? (x & dec) == 32'h0 : 1'b1; end
    default: begin r = 32'h0; we = 1'b0; sz = 1'b0; end
    endcase
    sh_r = r;
    sh_we = we;
    sh_astat = (astat & ~(X_SZ | X_SV | X_SS)) | (sz ? X_SZ : 32'h0) | (q_sv && q_cls != 2'd3 ? X_SV : 32'h0);
end

// ============================================================ the misc float functions
// FIX and FLOAT: stage B (X's second clock, from stage A on the funnel), registered; the finish
// (X's third clock) from it
logic [31:0] fb_q;
logic        fb_up, fb_ng, fb_big, fb_den;
logic [24:0] fb_m;
logic [7:0]  fb_e;
logic        fb_zero, fb_sg;
always_ff @(posedge clk) begin
    logic        half, rest, up;
    logic [24:0] m;
    logic [7:0]  e;
    // FIX: the rounding, to nearest even, or under TRUNC toward minus infinity (MAME: the
    // multifunction form a C cast, toward zero)
    fb_q <= f_tiny ? 32'h0 : fn_o;
    half = !f_left && !f_tiny && fn_g;
    rest = !f_left && (f_tiny ? fm != 0 : ({8'h0, fm} & th) != 0);
    if (!trunc) fb_up <= half && (rest || (!f_tiny && fn_o[0]));
    else if (MAME_RND && misc_op == M_FIXBYM) fb_up <= 1'b0;
    else fb_up <= f_sgn && (half || rest);
    fb_ng <= f_sgn; fb_big <= f_big; fb_den <= f_den;
    // FLOAT: the rounding and the exponent
    up = (MAME_RND || !trunc) && fn_o[7] && (fn_o[6] || fn_o[5:0] != 0 || fn_o[8]);
    m = {1'b0, fn_o[31:8]} + {24'h0, up};
    e = 8'(8'd158 - {2'b00, fl_lz});
    if (m[24]) begin m = m >> 1; e = e + 8'd1; end
    fb_m <= m; fb_e <= e; fb_zero <= fl_zero; fb_sg <= fx[31];
end
logic [31:0] fx_r, fl_r;
assign fx_r = fb_big ? 32'h8000_0000 : (fb_ng ? ~fb_q : fb_q) + {31'h0, fb_ng ^ fb_up};
assign fl_r = fb_zero ? 32'h0 : {fb_sg, fb_e, fb_m[22:0]};

// the operands' tests from fx / fy (R1029: off the flush's path; a flush keeps the sign, the
// exponent and a NaN, and makes a denormal a zero)
logic xz, yz;
assign xz = MAME_RND ? is_zero(fx) : is_den_or_zero(fx);    // is_zero(xin)
assign yz = MAME_RND ? is_zero(fy) : is_den_or_zero(fy);
// the compare: |x| against |y| (flushed in the manual's rounding)
logic cm_lt, cm_eq, cm_zx, cm_zy, cm_ltxy, cm_ltyx, cm_eqxy, cm_nan;
always_comb begin
    begin                                                // both orders on the carry chain (R1029)
        logic [31:0] dd, de;
        dd = {1'b0, xin[30:0]} - {1'b0, yin[30:0]};
        de = {1'b0, yin[30:0]} - {1'b0, xin[30:0]};
        cm_lt = dd[31];
        cm_eq = !dd[31] && !de[31];
    end
    cm_zx = xz; cm_zy = yz;
    // f_lt(x, y) and f_lt(y, x), f_eq(x, y) (sharc_fp_pkg)
    if (cm_zx && cm_zy) begin cm_ltxy = 1'b0; cm_ltyx = 1'b0; end
    else if (xin[31] != yin[31]) begin cm_ltxy = xin[31]; cm_ltyx = yin[31]; end
    else if (!xin[31]) begin cm_ltxy = cm_lt; cm_ltyx = !cm_lt && !cm_eq; end
    else begin cm_ltxy = !cm_lt && !cm_eq; cm_ltyx = cm_lt; end
    cm_eqxy = (cm_zx && cm_zy) || xin == yin;
    cm_nan = is_nan(fx) || is_nan(fy);                  // (a flush leaves a NaN one: R1029, off its path)
end

always_comb begin
    logic [31:0] r, a, k, acc;
    logic signed [9:0] eu, es;
    logic        sel, z;
    r = 32'h0; a = 32'h0; k = 32'h0; acc = 32'h0; eu = 10'sd0; es = 10'sd0; sel = 1'b0; z = 1'b0;
    case (misc_op)
    M_ABS: begin
        if (is_nan(fx)) begin r = NAN; a = AI; k = AIS; end
        else begin
            if (is_den_or_zero(fx)) begin r = 32'h0; a = AZ; end
            else r = fx & ~SIGN;
            if (fx[31]) a |= AS;
        end
    end
    M_MIN, M_MAX: begin
        if (cm_nan) begin r = NAN; a = AI; k = AIS; end
        else begin
            sel = (misc_op == M_MAX) ? cm_ltxy : cm_ltyx;
            r = sel ? yin : xin;
            z = sel ? cm_zy : cm_zx;                     // is_zero(r), from the operands (R1029)
            if (r[31] && !z) a |= AN;
            if (z) a |= AZ;
        end
    end
    M_NEG: begin
        if (is_nan(fx)) begin r = NAN; a = AI; k = AIS; end
        else begin
            if (is_den_or_zero(fx)) begin r = ~fx & SIGN; a = AZ; end
            else r = fx ^ SIGN;
            if (r[31]) a |= AN;
        end
    end
    M_PASS: begin
        if (is_nan(fx)) begin r = NAN; a = AI; k = AIS; end
        else begin
            if (is_den_or_zero(fx)) begin r = fx & SIGN; a = AZ; end
            else r = fx;
            if (r[31]) a |= AN;
        end
    end
    M_COMP: begin
        if (cm_nan) begin a = AI; k = AIS; end
        else if (cm_eqxy) a = AZ;
        else if (cm_ltxy) a = AN;
        acc = ((astat & ~X_ALU_GRP) >> 1) & 32'h7F00_0000;
        if ((a & (AZ | AN)) == 0) acc |= 32'h8000_0000;
        r = acc;
    end
    M_SCALB: begin
        if (is_nan(fx)) begin r = NAN; a = AI; k = AIS; end
        else begin
            r = sc_in;
            if (r[31]) a |= AN;
            if (is_zero(r)) a |= AZ;
            if (is_den(r)) k |= AUS;
        end
    end
    M_LOGB: begin
        if (is_inf(fx))       begin r = INF; a = AV; end
        else if (xz) begin r = SIGN | INF; a = AV; end
        else if (is_nan(fx))  begin r = NAN; a = AI; k = AIS; end
        else begin
            r = {24'h0, xin[30:23]} - 32'd127;
            if (r[31]) a |= AN;
            if (r == 0) a |= AZ;
        end
    end
    M_FIX, M_FIXBY, M_FIXBYM: begin
        r = fx_r;
        if (r[31]) a |= AN;
        if (r == 0) a |= AZ;
        if (MAME_RND && fb_den) k |= AUS;
        if (is_nan(fx)) a |= AI;
    end
    M_FLOAT, M_FLOATBY, M_FLOATBYM: begin
        r = fl_r;
        if (misc_op != M_FLOAT) r = scalb_r(r, fy);
        if (misc_op == M_FLOATBYM) begin if (r[31] && !is_zero(r)) a |= AN; end
        else if (r[31]) a |= AN;
        if (is_den_or_zero(r)) a |= AZ;
        if (is_den(r)) k |= AUS;
    end
    M_RECIPS: begin
        if (is_nan(fx))       begin r = NAN; a = AI; k = AIS; end
        else if (xz) begin r = (xin & SIGN) | INF; a = AV; end
        else begin
            // e = 126 - exp: the result's biased exponent 253 - exp, out of range for exp 0 and 253-255
            if (xin[30:23] == 8'h00 || xin[30:23] > 8'd252) r = xin & SIGN;
            else r = {xin[31], 8'(8'd253 - xin[30:23]), recips_lut(xin[22:16])};
            if (fx[31]) a |= AN;
            if (is_zero(r)) a |= AZ;
        end
    end
    M_RSQRTS: begin
        if ((fx[31] && !xz) || is_nan(fx)) r = NAN;              // (xin > SIGN)
        else begin
            eu = $signed({2'b0, xin[30:23]}) - 10'sd127;
            es = -(eu >>> 1) - 10'sd1;
            r = (xin & SIGN) | {1'b0, 8'(es + 10'sd127), rsqrts_lut(xin[23:17])};
        end
        if (fx[31] && xz) a |= AN;                              // (xin == SIGN)
        if (is_zero(r)) a |= AZ;
        if (xz) a |= AV;
        if (is_nan(fx) || fx[31]) begin a |= AI; k |= AIS; end
    end
    M_COPYSIGN: begin
        if (is_nan(fx) || is_nan(fy)) begin r = NAN; a = AI; k = AIS; end
        else begin
            r = fy & SIGN;
            if (r != 0) a |= AN;
            if (is_den_or_zero(fx)) a |= AZ;
            else r |= fx & ~SIGN;
        end
    end
    M_CLIP: begin
        if (is_nan(fx) || is_nan(fy)) begin r = NAN; a = AI; k = AIS; end
        else begin
            if (is_den_or_zero(fx) || is_den_or_zero(fy)) begin r = fx & SIGN; a = AZ; end
            else begin
                // std::clamp(x, -|y|, |y|): |x| > |y| clamps to the bound of x's sign
                r = (!cm_lt && !cm_eq) ? (fx[31] ? (fy | SIGN) : (fy & ~SIGN)) : fx;
                // (r is never zero here: neither operand is)
            end
            if (r[31]) a |= AN;
        end
    end
    default: ;
    endcase
    misc_r = r;
    misc_a = a | AF;
    misc_s = k;
end

endmodule
