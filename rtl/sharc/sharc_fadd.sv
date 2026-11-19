// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- the 2B SHARC's float adder.
// COPIED from Paul Priest's Konami Hornet core (ppriest/Arcade-KonamiHornet_MiSTer,
// rtl/cpu/sharc2/sharc_fadd.sv @ 87f9866, GPL-3.0-or-later, used with his permission;
// THIRD_PARTY.md). CHANGED (R1027): MAME_RND. 1 is Hornet's unit, bit-exact to MAME; 0 (the
// default) is the ADSP-2106x manual's rounding: under `trunc` (MODE1.TRUNC) the result is
// rounded toward zero, so an overflow gives the largest finite through the same finish. The
// inputs and a denormal result are flushed in both. Nothing else differs: the near path is
// exact and the far path cannot be tiny (study R1027).
// CHANGED (R1028): `avg`, FAVG ((x + y) / 2) on the same paths, as sharc_fp_pkg's f_avg (MAME:
// the sum rounded, then halved with round to nearest and flushed) and man_avg (the manual: the
// exact sum's exponent less one, rounded once: tiny below 2^-126, flushed with AUS).
// CHANGED (R1052, timing): the far path's rounding carry tested beside the increment (the same
// result in both roundings).
//
// CHANGED (R1029, timing at 80 MHz): three stages. Stage 1's magnitude compare on the carry
// chain and the alignment's sticky bit from a mask beside the shifter; stage 2 split -- 2a the
// normalise and rounding to the result's bits, registered; 2b the finish (alu_fin, MAME's FAVG
// halving), combinational. Stages 1 and 2a load at every `en` (the operands are held while
// `en` lasts, two clocks at least), so 2b's result is valid in the clock after an `en` of two.
//
// Float add / subtract, bit-exact to sharc_fp_pkg::f_add / f_sub (MAME's host
// arithmetic with the ALU's input and result flush).
//
// The inputs are flushed, so each operand is zero, normal or infinite. Two paths:
//   far:  effective add, or subtract with exponent difference >= 2, or subtract with no
//         cancellation: align (stage 1), add, then a normalise of at most one bit and the
//         rounding (stage 2). Never denormal.
//   near: effective subtract with exponent difference <= 1 and cancellation: subtract (stage
//         1), then a leading-zero shift clamped at the denormal boundary (stage 2). Exact.

module sharc_fadd #(
    parameter bit MAME_RND = 1'b0,      // 1: MAME's (host) rounding, round to nearest always
    // R1048: the operands' zero-exponent tests (the input flush) from the caller's registers, made
    // a clock earlier from the values x / y are loaded with (xz == (x[30:23] == 0) in every clock
    // x is used); 0 makes them here
    parameter bit PRE = 1'b0
) (
    input  logic        clk,
    input  logic        en,             // advance the pipeline
    input  logic [31:0] x,
    input  logic [31:0] y,
    input  logic        xz,             // PRE: x[30:23] == 0
    input  logic        yz,             // PRE: y[30:23] == 0
    input  logic        sub,
    input  logic        avg,            // FAVG (R1028): x + y halved (sub ignored)
    input  logic        trunc,          // MODE1.TRUNCATE: round to zero (MAME_RND 0); overflow gives the largest finite
    output logic [31:0] r,
    output logic [31:0] astat,          // AZ AV AN AI AF, to OR in after clearing the ALU group
    output logic [31:0] stky,           // AUS AVS AIS
    output logic        nan_in,         // stage 2: an operand was NaN (FADD_FSUB's test)
    output logic        inf_both        // stage 2: both operands infinite
);

import sharc_fp_pkg::*;

// ---------------------------------------------------------------- stage 1

logic [31:0] xf, yf, bx, by;
logic        nan1, big_ab;
logic [7:0]  ea, eb, ex, ey;
logic [23:0] ma, mb, mx, my;
logic [8:0]  dab, dba;
logic [7:0]  d;
logic        esub;
logic [26:0] sx, sy;
logic [27:0] s_far;
logic [24:0] n_near;
logic        near;
logic [4:0]  lz1;

function automatic logic [26:0] align(input logic [23:0] m, input logic [7:0] d, input logic big);
    // {m, 3'b000} >> d with the bits shifted out ORed into bit 0: the sticky bit from the mask
    // of the bits below d, beside the shifter (R1029; the same bits as the stepwise form)
    logic [26:0] v, mk;
    logic        st;
    v = {m, 3'b000};
    for (int i = 0; i < 27; i++) mk[i] = 5'(i) < d[4:0];
    if (big) begin                                      // d >= 27 (the caller's, R1029)
        st = m != 0;
        v = '0;
    end else begin
        st = (v & mk) != 0;
        v = v >> d[4:0];
    end
    return {v[26:1], v[0] | st};
endfunction

always_comb begin
    // (R1048: flush with the zero tests possibly a register: the same as flush(x) / flush(y))
    xf = (PRE ? xz : x[30:23] == 8'h00) ? (x & SIGN) : x;
    yf = ((PRE ? yz : y[30:23] == 8'h00) ? (y & SIGN) : y) ^ (sub && !avg ? SIGN : 32'h0);
    nan1 = (sub && !avg) ? nan_sub(x, y) : nan_add(x, y);

    ea = (PRE ? xz : xf[30:23] == 0) ? 8'd1 : xf[30:23];
    eb = (PRE ? yz : yf[30:23] == 0) ? 8'd1 : yf[30:23];
    ma = {PRE ? !xz : xf[30:23] != 0, xf[22:0]};
    mb = {PRE ? !yz : yf[30:23] != 0, yf[22:0]};
    dab = {1'b0, ea} - {1'b0, eb};
    dba = {1'b0, eb} - {1'b0, ea};
    // on the carry chain (Aggressive Area builds a compare as a chain of LUTs)
    begin
        logic [31:0] dd;
        dd = {1'b0, xf[30:0]} - {1'b0, yf[30:0]};
        big_ab = !dd[31];
    end
    bx = big_ab ? xf : yf;
    by = big_ab ? yf : xf;
    mx = big_ab ? ma : mb;
    my = big_ab ? mb : ma;
    esub = xf[31] ^ yf[31];
    // the alignment by the exponents' order alone (R1029: the magnitude compare off its path):
    // they differ only when the exponents are equal, where the shift is 0 and the adder's
    // operands are swapped instead
    begin
        logic        e_ge;
        logic [23:0] mxe, mye;
        logic [26:0] sye;
        logic [8:0]  rab, rba;
        // the shift from the raw exponents (R1029: no flush test before the subtract). It
        // differs from dab / dba only where an operand is zero (exponent 0, flushed), and then
        // that operand is the one aligned (a zero, shifted by anything) or both are zero
        rab = {1'b0, xf[30:23]} - {1'b0, yf[30:23]};
        rba = {1'b0, yf[30:23]} - {1'b0, xf[30:23]};
        e_ge = !rab[8];
        ex = (!dab[8]) ? ea : eb;
        d  = e_ge ? rab[7:0] : rba[7:0];
        mxe = e_ge ? ma : mb;
        mye = e_ge ? mb : ma;
        // d >= 27 from both differences, beside the select (R1029)
        sye = align(mye, d, e_ge ? rab[7:0] >= 8'd27 : rba[7:0] >= 8'd27);
        // (R1028 swapped them by magnitude where the exponents are equal: dead logic -- an effective
        // subtract with exponents within one is always the near path, an add has no order)
        sx = {mxe, 3'b000};
        sy = sye;
    end
    s_far = esub ? {1'b0, sx} - {1'b0, sy} : {1'b0, sx} + {1'b0, sy};

    // both orders, the magnitude compare choosing after (R1029: off the subtract's path); d[0]
    // is the raw exponents' low bits' difference
    begin
        logic [24:0] nab, nba;
        logic        d0;
        d0 = xf[23] ^ yf[23];
        nab = {ma, 1'b0} - (d0 ? {1'b0, mb} : {mb, 1'b0});
        nba = {mb, 1'b0} - (d0 ? {1'b0, ma} : {ma, 1'b0});
        n_near = big_ab ? nab : nba;
    end
    near = esub && d <= 8'd1 && !n_near[24];
    // the leading-zero count is bounded at ex - 1 (the denormal boundary; R1028's marker bit)
    // the near path's leading zeros, here (R1029: off stage 2a's path); a tree -- the top 9
    // bits' count, else 9 + the low 16's
    // R1029: the marker's bound as min(clz(n_near), ex - 1) beside the count, not ORed in before
    begin
        logic [4:0]  h, l, c;
        h = 5'd0; l = 5'd25;
        for (int i = 0; i < 9; i++) if (n_near[16 + i]) h = 5'(8 - i);
        for (int i = 0; i < 16; i++) if (n_near[i]) l = 5'(24 - i);      // (9 + the low half's)
        c = (n_near[24:16] != 9'h0) ? h : l;                 // clz(n_near), 25 for zero
        // R1044: c > ex - 1 is "n_near's top ex bits all zero" (ex >= 1, the denormal boundary's
        // test), a mask from ex beside the count rather than a compare after it -- the same
        // bound: for ex <= 25, clz(n_near) >= ex exactly when n_near[24 : 25 - ex] == 0
        begin
            logic [24:0] tm;
            logic        over;
            for (int i = 0; i < 25; i++) tm[i] = 8'(24 - i) < ex;   // bit i among the top ex bits
            over = ex <= 8'd25 && (n_near & tm) == 25'h0;
            lz1 = over ? 5'(ex - 8'd1) : c;
        end
    end
end

logic        v_nan, v_inf, v_near, v_trunc, v_sgn, v_nanin, v_infb, v_avg;
logic [31:0] v_infr;
logic [27:0] v_s;
logic [24:0] v_n;
logic [4:0]  v_lz;
logic [7:0]  v_e;

always_ff @(posedge clk) if (en) begin
    v_nan <= nan1;
    v_nanin <= is_nan(x) || is_nan(y);
    v_infb <= x[30:23] == 8'hFF && y[30:23] == 8'hFF;
    v_inf <= is_inf(xf) || is_inf(yf);
    v_infr <= is_inf(xf) ? xf : yf;
    v_near <= near;
    v_trunc <= trunc;
    v_avg <= avg;
    v_sgn <= bx[31];
    v_s <= s_far;
    v_n <= n_near;
    v_lz <= lz1;
    v_e <= ex;
end

// ---------------------------------------------------------------- stage 2


logic [31:0] raw_c, raw, fr;
logic [31:0] fa, fs;
logic        w_nan, w_nanin, w_infb, w_trunc, w_avg;

// stage 2a: the result's bits
always_comb begin
    raw_c = '0;
    if (v_inf) raw_c = v_infr;
    else if (v_near) begin
        logic [4:0]  lz;
        logic [24:0] t;
        lz = v_lz;
        t = v_n << lz;
        if (v_n == 0)   raw_c = 32'h0;
        else if (t[24]) raw_c = {v_sgn, v_e - {3'h0, lz}, t[23:1]};
        else            raw_c = {v_sgn, 8'h00, t[23:1]};
        // the manual's FAVG: exact, so the exponent less one; below 2^-126 tiny (a denormal
        // pattern, which the finish flushes with AUS)
        if (!MAME_RND && v_avg && raw_c[30:0] != 0)
            raw_c = (raw_c[30:23] >= 8'd2) ? {raw_c[31], raw_c[30:23] - 8'd1, raw_c[22:0]} : {raw_c[31], 31'h1};
    end else begin
        // R1052: the rounding's carry out of the 24 bits as up && (the 24 bits all ones), tested
        // beside the increment, not read from its top bit (s5303: the sum -> the increment's
        // carry -> e + 1 -> the range tests -> raw, retimed into the finish -> the R file, -0.419);
        // the exponent's tests made for both values of the carry, which chooses last. After a
        // carry the sum is exactly 2^24: the shifted mantissa's low 23 bits are 0, as are the
        // sum's, and its bit 23 is 1 (m23)
        logic [26:0] s;
        logic [8:0]  e, e1, ef;
        logic [24:0] m;
        logic        up, cy, m23;
        logic        ov255, ov256, tiny;
        e = {1'b0, v_e};
        if (v_s[27])       begin s = {v_s[27:2], v_s[1] | v_s[0]}; e = e + 9'd1; end
        else if (!v_s[26]) begin s = {v_s[25:0], 1'b0}; e = e - 9'd1; end
        else                     s = v_s[26:0];
        up = !(!MAME_RND && v_trunc) && s[2] && (s[1] || s[0] || s[3]);
        cy = up && (&s[26:3]);
        m = {1'b0, s[26:3]} + {24'h0, up};
        m23 = m[23] || cy;
        e1 = e + 9'd1;
        ef = cy ? e1 : e;
        ov255 = cy ? (e1 >= 9'd255) : (e >= 9'd255);
        ov256 = cy ? (e1 >= 9'd256) : (e >= 9'd256);
        tiny  = cy ? (e1 <= 9'd1)   : (e <= 9'd1);
        if (!MAME_RND && v_avg) begin
            // the manual's FAVG: the rounded sum's exponent less one (rounding is the same)
            if (ov256)           raw_c = {v_sgn, INF[30:0]};
            else if (!m23)       raw_c = {v_sgn, 8'h00, m[22:0]};   // zero (both operands zero)
            else if (tiny)       raw_c = {v_sgn, 31'h1};      // tiny
            else                 raw_c = {v_sgn, 8'(ef - 9'd1), m[22:0]};
        end
        else if (ov255)   raw_c = {v_sgn, INF[30:0]};
        else if (!m23)    raw_c = {v_sgn, 8'h00, m[22:0]};
        else              raw_c = {v_sgn, ef[7:0], m[22:0]};
    end
end

// R1052: the finish's tests on the result (is_inf, is_den_or_zero, a mantissa) made on raw_c and
// registered with it, for the manual's rounding, where the finish takes raw as it is (s5303: raw
// -> the zero test -> fr -> the landing's select -> the R file -0.419). MAME's FAVG changes q in
// the finish, so MAME_RND 1 tests q there as before
logic        raw_inf, raw_dz, raw_mnz;
always_ff @(posedge clk) if (en) begin
    raw <= raw_c;
    raw_inf <= is_inf(raw_c); raw_dz <= is_den_or_zero(raw_c); raw_mnz <= raw_c[22:0] != 0;
    w_nan <= v_nan; w_nanin <= v_nanin; w_infb <= v_infb; w_trunc <= v_trunc; w_avg <= v_avg;
end

// stage 2b: the finish
always_comb begin
    logic [31:0] q;
    q = raw;
    // MAME's FAVG: the rounded sum times 0.5f, to nearest even (exact unless the half is denormal)
    if (MAME_RND && w_avg && !is_inf(q) && q[30:0] != 0) begin
        if (q[30:23] >= 8'd2) q = {q[31], q[30:23] - 8'd1, q[22:0]};
        else begin
            logic [23:0] hm, hq;
            hm = {q[30:23] != 0, q[22:0]};
            hq = {1'b0, hm[23:1]} + {23'h0, hm[0] & hm[1]};
            q = {q[31], 7'h0, hq};
        end
    end

    // alu_fin (sharc_fp_pkg)
    fr = q; fa = AF; fs = '0;
    if (MAME_RND ? is_inf(q) : raw_inf) begin
        fa |= AV; fs |= AVS;
        if (w_trunc) fr = (q & SIGN) | 32'h7F7F_FFFF;
    end else if (MAME_RND ? is_den_or_zero(q) : raw_dz) begin
        fa |= AZ;
        if (MAME_RND ? q[22:0] != 0 : raw_mnz) fs |= AUS;
        fr = q & SIGN;
    end
    if (fr[31]) fa |= AN;
end

always_comb begin
    if (w_nan) begin r = NAN; astat = AI | AF; stky = AIS; end
    else       begin r = fr;  astat = fa;      stky = fs;  end
    nan_in = w_nanin;
    inf_both = w_infb;
end

endmodule
