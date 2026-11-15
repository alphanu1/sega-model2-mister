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
// The word does one of the three at most, so nothing is lost by the sharing. The results are
// bit for bit m2b_sharc_pkg's alu_fixed / shifter (MAME's compute.hxx as Hornet's v1 restates it)
// and sharc_fp_pkg's f_* (MAME_RND 1) or man_* (MAME_RND 0) functions, which stay the reference:
// sim/sharc/xu checks this unit against them.

`timescale 1ns/1ps

module m2b_sharc_xu #(
    parameter bit MAME_RND = 1'b0
) (
    input  logic        fix_on,
    input  logic [7:0]  fix_op,         // alu_fixed's op (cu 0, op[7] 0)
    input  logic        sh_on,
    input  logic [5:0]  sh_op,          // the shifter's op
    input  logic        sh_imm,         // the immediate form
    input  logic [31:0] sh_val,         // the immediate (sh_imm) or R[ry]
    input  logic        misc_on,
    input  logic [4:0]  misc_op,        // tb_sharc_fp's numbering (2 FAVG is the adder's)
    input  logic [31:0] x, y, n,        // fixed / shifter: R[rx], R[ry], R[rn]
    input  logic [31:0] fx, fy,         // float: the adder's operands
    input  logic [31:0] astat,
    input  logic        alusat,
    input  logic        trunc,
    // fixed and shifter results: r, write, the new ASTAT, STKY bits to OR in
    output logic [31:0] fix_r, sh_r,
    output logic        fix_we, sh_we,
    output logic [31:0] fix_astat, sh_astat, fix_stky,
    // the misc float result: r, ASTAT / STKY bits to OR in (after the ALU group is cleared)
    output logic [31:0] misc_r, misc_a, misc_s
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
    ad_a = x; ad_b = y; ad_ci = 1'b0;
    if (misc_on) begin                                   // FLOAT: |Rx|
        ad_a = fx[31] ? 32'h0 : fx; ad_b = fx[31] ? ~fx : 32'h0; ad_ci = fx[31];
    end else
    case (fix_op)
    8'h05: ad_ci = c;
    8'h25: begin ad_b = 32'h0; ad_ci = c; end
    8'h29: ad_b = 32'h1;
    8'h02, 8'h0a, 8'h61, 8'h62: begin ad_b = ~y; ad_ci = 1'b1; end
    8'h06: begin ad_b = ~y; ad_ci = c; end
    8'h26: begin ad_b = 32'hFFFF_FFFF; ad_ci = c; end
    8'h2a: begin ad_b = 32'hFFFF_FFFE; ad_ci = 1'b1; end
    8'h22: begin ad_a = 32'h0; ad_b = ~x; ad_ci = 1'b1; end
    8'h30: begin ad_a = x[31] ? 32'h0 : x; ad_b = x[31] ? ~x : 32'h0; ad_ci = x[31]; end
    8'h63: begin ad_b = ~nay; ad_ci = 1'b1; end          // x < -|y|
    default: ;
    endcase
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
    e = $signed(ry) + ($signed({24'h0, f[30:23]}) - 32'sd127);
    if (e > 32'sd127) return (f & SIGN) | INF;
    if (e < -32'sd126) return f & SIGN;
    return {f[31], 8'(e + 32'sd127), f[22:0]};
endfunction
logic [31:0] sc_in;
assign sc_in = scalb_r(xin, fy);

// ---- FIX: the operand and its alignment
logic [31:0] fv;
logic [7:0]  fe, fee;
logic [23:0] fm;
logic        f_big, f_tiny, f_left;
logic [5:0]  f_k;
always_comb begin
    logic [8:0] kk;
    fv = m_scaled ? sc_in : xin;
    fe = fv[30:23];
    fee = (fe == 8'h00) ? 8'd1 : fe;
    fm = {fe != 8'h00, fv[22:0]};
    f_big = fe == 8'hFF || fe >= 8'd158;
    f_left = fee >= 8'd150;                              // left by fee - 150 (0-7)
    kk = 9'd150 - {1'b0, fee};                           // right by 1-149
    f_tiny = !f_left && kk > 9'd32;
    f_k = f_left ? 6'(6'd32 - 6'(fee - 8'd150)) : kk[5:0];
end

// ---- FLOAT: the magnitude's leading zeros
logic [5:0] fl_lz;
logic       fl_zero;
always_comb begin
    fl_lz = 6'd32;
    for (int i = 0; i < 32; i++) if (ad_s[i]) fl_lz = 6'(31 - i);
    fl_zero = ad_s == 32'h0;
end

// ---- the shifter's controls
logic signed [31:0] s_sh;                               // the shift count (LSHIFT / ASHIFT / ROT)
logic [5:0]  s_bitn, s_len, s_l;
logic        s_fz;                                       // a field op whose result is 0
logic        s_cnt_l, s_cnt_r;                           // the count is 0..31 / -31..-1
logic [4:0]  s_amt_r;                                    // -count for a right shift
logic [31:0] th;                                         // the thermometer (1 << j) - 1
logic [31:0] dec;                                        // the bit decoder 1 << j
logic [31:0] sx_v;                                       // FDEP's sign-extended field
always_comb begin
    logic signed [7:0] sh8;
    logic [5:0] tj;
    logic [4:0] dj;
    sh8 = sh_val[7:0];
    s_sh = sh_imm ? 32'(sh8) : $signed(sh_val);
    if (sh_op == 6'h08) s_sh = 32'(sh8);                 // OR LSHIFT: MAME takes the low byte
    s_cnt_l = s_sh[31:5] == 27'h0;
    s_cnt_r = s_sh[31:5] == 27'h7FF_FFFF && s_sh[4:0] != 5'h0;
    s_amt_r = 5'h0 - s_sh[4:0];
    s_bitn = sh_val[5:0];
    s_len = sh_val[11:6];
    s_l = (s_len > 6'd32) ? 6'd32 : s_len;
    s_fz = s_len == 6'd0 || s_bitn >= 6'd32;
    // the thermometer: the field's length, or FIX's sticky bits below its round bit
    tj = m_fix ? 6'(f_k - 6'd1) : s_l;
    for (int i = 0; i < 32; i++) th[i] = 6'(i) < tj;
    // the decoder: the bit of BSET / BCLR / BTGL / BTST, or the field's top bit (its sign)
    dj = (sh_op[5:4] == 2'b11) ? sh_val[4:0] : 5'(s_l - 6'd1);
    dec = 32'h1 << dj;
    sx_v = x & th;
    if (s_l < 6'd32 && (x & dec) != 0) sx_v = sx_v | ~th;
end

// ---- the funnel: ({H, L, 0} >> k)[32:0]
logic [31:0] fn_h, fn_l, fn_o;
logic [5:0]  fn_k;
logic        fn_g;                                       // the bit below the result (FIX's round bit)
always_comb begin
    logic [64:0] w;
    fn_h = 32'h0; fn_l = 32'h0; fn_k = 6'd32;
    if (misc_on) begin
        if (m_float) begin fn_h = ad_s; fn_k = 6'(6'd32 - fl_lz); end
        else if (f_left) begin fn_h = {8'h0, fm}; fn_k = f_k; end
        else begin fn_l = {8'h0, fm}; fn_k = f_k; end
    end else
    case (sh_op)
    6'h00, 6'h08, 6'h01: begin
        if (!s_sh[31]) begin fn_h = x; fn_k = 6'(6'd32 - {1'b0, s_sh[4:0]}); end
        else begin
            // a right shift: LSHIFT logical (OR LSHIFT's register form arithmetic), ASHIFT arithmetic
            fn_h = ((sh_op == 6'h01 || (sh_op == 6'h08 && !sh_imm)) && x[31]) ? 32'hFFFF_FFFF : 32'h0;
            fn_l = x;
            fn_k = (sh_op == 6'h01 && !s_cnt_r) ? 6'd31 : {1'b0, s_amt_r};
        end
    end
    6'h02: begin fn_h = x; fn_l = x; fn_k = 6'(6'd32 - {1'b0, s_sh[4:0]}); end
    6'h10, 6'h12: begin fn_h = (sh_op == 6'h10 && x[31]) ? 32'hFFFF_FFFF : 32'h0; fn_l = x; fn_k = s_bitn; end
    6'h11, 6'h19: begin fn_h = x & th; fn_k = 6'(6'd32 - s_bitn); end
    6'h13: begin fn_h = sx_v; fn_k = 6'(6'd32 - s_bitn); end
    default: ;
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
    if (set_r) begin
        if (r[31]) a |= AN;
        if (r == 32'h0) a |= AZ;
    end
    fix_r = r;
    fix_we = set_r;
    fix_astat = a & ~AF;
    fix_stky = k;
end

// ============================================================ the shifter
always_comb begin
    logic [31:0] r, a, v;
    logic        we;
    v = fn_o & th;
    a = astat & ~(X_SZ | X_SV | X_SS);
    r = 32'h0;
    we = 1'b1;
    case (sh_op)
    6'h00, 6'h08: begin
        r = (s_cnt_l || s_cnt_r) ? fn_o : 32'h0;
        if (!s_sh[31] && s_sh != 0) a |= X_SV;
        if (sh_op == 6'h08) begin
            if (sh_imm) begin if (r == 0) a |= X_SZ; r = n | r; end
            else begin r = n | r; if (r == 0) a |= X_SZ; end
        end else if (r == 0) a |= X_SZ;
    end
    6'h01: begin
        r = (s_sh[31] || s_cnt_l) ? fn_o : 32'h0;
        if (!s_sh[31] && s_sh != 0) a |= X_SV;
        if (r == 0) a |= X_SZ;
    end
    6'h02: begin
        r = fn_o;
        if (!sh_imm && !s_sh[31] && s_sh != 0) a |= X_SV;
        if (r == 0) a |= X_SZ;
    end
    6'h10, 6'h11, 6'h12, 6'h13, 6'h19: begin
        case (sh_op)
        6'h10: r = s_fz ? 32'h0 : fn_o & th;
        6'h11, 6'h13: r = s_fz ? 32'h0 : fn_o;
        6'h12: begin
            if (s_fz) r = 32'h0;
            else if ({1'b0, s_bitn} + {1'b0, s_len} > 7'd32) r = fn_o;
            else r = (s_l < 6'd32 && (v & dec) != 0) ? (v | ~th) : v;
        end
        default: r = n | ((s_len != 0 && s_bitn < 6'd32) ? fn_o : 32'h0);
        endcase
        if (r == 0) a |= X_SZ;
        if ({1'b0, s_bitn} + {1'b0, s_len} > 7'd32) a |= X_SV;
    end
    6'h30, 6'h31, 6'h32: begin
        r = x;
        if (sh_val[31:5] == 27'h0) begin
            case (sh_op)
            6'h30: r = r | dec;
            6'h31: r = r & ~dec;
            default: r = r ^ dec;
            endcase
        end else a |= X_SV;
        if (r == 0) a |= X_SZ;
    end
    6'h33: begin
        we = 1'b0;
        if (sh_val[31:5] == 27'h0) begin
            if ((x & dec) == 0) a |= X_SZ;
        end else a |= X_SZ | X_SV;
    end
    default: we = 1'b0;
    endcase
    sh_r = r;
    sh_we = we;
    sh_astat = a;
end

// ============================================================ the misc float functions
// the compare: |x| against |y| (flushed in the manual's rounding)
logic cm_lt, cm_eq, cm_zx, cm_zy, cm_ltxy, cm_ltyx, cm_eqxy, cm_nan;
always_comb begin
    cm_lt = xin[30:0] < yin[30:0];
    cm_eq = xin[30:0] == yin[30:0];
    cm_zx = is_zero(xin); cm_zy = is_zero(yin);
    // f_lt(x, y) and f_lt(y, x), f_eq(x, y) (sharc_fp_pkg)
    if (cm_zx && cm_zy) begin cm_ltxy = 1'b0; cm_ltyx = 1'b0; end
    else if (xin[31] != yin[31]) begin cm_ltxy = xin[31]; cm_ltyx = yin[31]; end
    else if (!xin[31]) begin cm_ltxy = cm_lt; cm_ltyx = !cm_lt && !cm_eq; end
    else begin cm_ltxy = !cm_lt && !cm_eq; cm_ltyx = cm_lt; end
    cm_eqxy = (cm_zx && cm_zy) || xin == yin;
    cm_nan = is_nan(xin) || is_nan(yin);
end

always_comb begin
    logic [31:0] r, a, k, acc, q;
    logic        half, rest, up, ng;
    logic [24:0] m;
    logic [7:0]  e;
    logic signed [9:0] eu, es;
    r = 32'h0; a = 32'h0; k = 32'h0; acc = 32'h0; q = 32'h0;
    half = 1'b0; rest = 1'b0; up = 1'b0; ng = 1'b0; m = 25'h0; e = 8'h0; eu = 10'sd0; es = 10'sd0;
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
            if (misc_op == M_MAX) r = cm_ltxy ? yin : xin;
            else                  r = cm_ltyx ? yin : xin;
            if (r[31] && !is_zero(r)) a |= AN;
            if (is_zero(r)) a |= AZ;
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
        if (is_nan(xin)) begin r = NAN; a = AI; k = AIS; end
        else begin
            r = sc_in;
            if (r[31]) a |= AN;
            if (is_zero(r)) a |= AZ;
            if (is_den(r)) k |= AUS;
        end
    end
    M_LOGB: begin
        if (is_inf(xin))       begin r = INF; a = AV; end
        else if (is_zero(xin)) begin r = SIGN | INF; a = AV; end
        else if (is_nan(xin))  begin r = NAN; a = AI; k = AIS; end
        else begin
            r = {24'h0, xin[30:23]} - 32'd127;
            if (r[31]) a |= AN;
            if (r == 0) a |= AZ;
        end
    end
    M_FIX, M_FIXBY, M_FIXBYM: begin
        q = f_tiny ? 32'h0 : fn_o;
        half = !f_left && !f_tiny && fn_g;
        rest = !f_left && (f_tiny ? fm != 0 : ({8'h0, fm} & th) != 0);
        // the rounding: to nearest even, or under TRUNC toward minus infinity (MAME: the
        // multifunction form a C cast, toward zero)
        if (!trunc) up = half && (rest || q[0]);
        else if (MAME_RND && misc_op == M_FIXBYM) up = 1'b0;
        else up = fv[31] && (half || rest);
        ng = fv[31];
        r = f_big ? 32'h8000_0000 : (ng ? ~q : q) + {31'h0, ng ^ up};
        if (r[31]) a |= AN;
        if (r == 0) a |= AZ;
        if (MAME_RND && is_den(fv)) k |= AUS;
        if (is_nan(fx)) a |= AI;
    end
    M_FLOAT, M_FLOATBY, M_FLOATBYM: begin
        up = (MAME_RND || !trunc) && fn_o[7] && (fn_o[6] || fn_o[5:0] != 0 || fn_o[8]);
        m = {1'b0, fn_o[31:8]} + {24'h0, up};
        e = 8'(8'd158 - {2'b00, fl_lz});
        if (m[24]) begin m = m >> 1; e = e + 8'd1; end
        r = fl_zero ? 32'h0 : {fx[31], e, m[22:0]};
        if (misc_op != M_FLOAT) r = scalb_r(r, fy);
        if (misc_op == M_FLOATBYM) begin if (r[31] && !is_zero(r)) a |= AN; end
        else if (r[31]) a |= AN;
        if (is_den_or_zero(r)) a |= AZ;
        if (is_den(r)) k |= AUS;
    end
    M_RECIPS: begin
        if (is_nan(xin))       begin r = NAN; a = AI; k = AIS; end
        else if (is_zero(xin)) begin r = (xin & SIGN) | INF; a = AV; end
        else begin
            // e = 126 - exp: the result's biased exponent 253 - exp, out of range for exp 0 and 253-255
            if (xin[30:23] == 8'h00 || xin[30:23] > 8'd252) r = xin & SIGN;
            else r = {xin[31], 8'(8'd253 - xin[30:23]), recips_lut(xin[22:16])};
            if (xin[31]) a |= AN;
            if (is_zero(r)) a |= AZ;
        end
    end
    M_RSQRTS: begin
        if (xin > SIGN || is_nan(xin)) r = NAN;
        else begin
            eu = $signed({2'b0, xin[30:23]}) - 10'sd127;
            es = -(eu >>> 1) - 10'sd1;
            r = (xin & SIGN) | {1'b0, 8'(es + 10'sd127), rsqrts_lut(xin[23:17])};
        end
        if (xin == SIGN) a |= AN;
        if (is_zero(r)) a |= AZ;
        if (is_zero(xin)) a |= AV;
        if (is_nan(xin) || xin[31]) begin a |= AI; k |= AIS; end
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
                if (is_zero(r)) a |= AZ;
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
