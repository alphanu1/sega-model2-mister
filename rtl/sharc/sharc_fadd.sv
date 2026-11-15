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
//
// Float add / subtract in two stages, bit-exact to sharc_fp_pkg::f_add / f_sub (MAME's host
// arithmetic with the ALU's input and result flush). Stage 1 registers at `en`; the result
// and flags are stage 2's, combinational, in the clock after.
//
// The inputs are flushed, so each operand is zero, normal or infinite. Two paths:
//   far:  effective add, or subtract with exponent difference >= 2, or subtract with no
//         cancellation: align (stage 1), add, then a normalise of at most one bit and the
//         rounding (stage 2). Never denormal.
//   near: effective subtract with exponent difference <= 1 and cancellation: subtract (stage
//         1), then a leading-zero shift clamped at the denormal boundary (stage 2). Exact.

module sharc_fadd #(
    parameter bit MAME_RND = 1'b0       // 1: MAME's (host) rounding, round to nearest always
) (
    input  logic        clk,
    input  logic        en,             // advance the pipeline
    input  logic [31:0] x,
    input  logic [31:0] y,
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
logic [24:0] n_near, marker;
logic        near;

function automatic logic [26:0] align(input logic [23:0] m, input logic [7:0] d);
    // {m, 3'b000} >> d with the bits shifted out ORed into bit 0
    logic [26:0] v;
    logic        st;
    v = {m, 3'b000};
    st = 1'b0;
    if (d >= 8'd27) begin
        st = m != 0;
        v = '0;
    end else begin
        for (int k = 0; k < 5; k++)
            if (d[k]) begin
                st = st | ((v & ((27'h1 << (1 << k)) - 27'h1)) != 0);
                v = v >> (1 << k);
            end
    end
    return {v[26:1], v[0] | st};
endfunction

always_comb begin
    xf = flush(x);
    yf = flush(y) ^ (sub && !avg ? SIGN : 32'h0);
    nan1 = (sub && !avg) ? nan_sub(x, y) : nan_add(x, y);

    ea = (xf[30:23] == 0) ? 8'd1 : xf[30:23];
    eb = (yf[30:23] == 0) ? 8'd1 : yf[30:23];
    ma = {xf[30:23] != 0, xf[22:0]};
    mb = {yf[30:23] != 0, yf[22:0]};
    dab = {1'b0, ea} - {1'b0, eb};
    dba = {1'b0, eb} - {1'b0, ea};
    big_ab = xf[30:0] >= yf[30:0];
    bx = big_ab ? xf : yf;
    by = big_ab ? yf : xf;
    ex = big_ab ? ea : eb;
    mx = big_ab ? ma : mb;
    my = big_ab ? mb : ma;
    d  = big_ab ? dab[7:0] : dba[7:0];
    esub = bx[31] ^ by[31];

    sx = {mx, 3'b000};
    sy = align(my, d);
    s_far = esub ? {1'b0, sx} - {1'b0, sy} : {1'b0, sx} + {1'b0, sy};

    n_near = {mx, 1'b0} - (d[0] ? {1'b0, my} : {my, 1'b0});
    near = esub && d <= 8'd1 && !n_near[24];
    // a one at bit 25 - ex bounds the leading-zero count at ex - 1 (the denormal boundary)
    marker = (ex <= 8'd25) ? (25'h1 << (8'd25 - ex)) : 25'h0;
end

logic        v_nan, v_inf, v_near, v_trunc, v_sgn, v_nanin, v_infb, v_avg;
logic [31:0] v_infr;
logic [27:0] v_s;
logic [24:0] v_n, v_mark;
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
    v_mark <= marker;
    v_e <= ex;
end

// ---------------------------------------------------------------- stage 2

function automatic logic [4:0] clz25(input logic [24:0] v);
    clz25 = 5'd25;
    for (int i = 0; i < 25; i++) if (v[i]) clz25 = 5'(24 - i);
endfunction

logic [31:0] raw, fr;
logic [31:0] fa, fs;

always_comb begin
    raw = '0;
    if (v_inf) raw = v_infr;
    else if (v_near) begin
        logic [4:0]  lz;
        logic [24:0] t;
        lz = clz25(v_n | v_mark);
        t = v_n << lz;
        if (v_n == 0)   raw = 32'h0;
        else if (t[24]) raw = {v_sgn, v_e - {3'h0, lz}, t[23:1]};
        else            raw = {v_sgn, 8'h00, t[23:1]};
        // the manual's FAVG: exact, so the exponent less one; below 2^-126 tiny (a denormal
        // pattern, which the finish flushes with AUS)
        if (!MAME_RND && v_avg && raw[30:0] != 0)
            raw = (raw[30:23] >= 8'd2) ? {raw[31], raw[30:23] - 8'd1, raw[22:0]} : {raw[31], 31'h1};
    end else begin
        logic [26:0] s;
        logic [8:0]  e;
        logic [24:0] m;
        logic        up;
        e = {1'b0, v_e};
        if (v_s[27])       begin s = {v_s[27:2], v_s[1] | v_s[0]}; e = e + 9'd1; end
        else if (!v_s[26]) begin s = {v_s[25:0], 1'b0}; e = e - 9'd1; end
        else                     s = v_s[26:0];
        up = !(!MAME_RND && v_trunc) && s[2] && (s[1] || s[0] || s[3]);
        m = {1'b0, s[26:3]} + {24'h0, up};
        if (m[24]) begin m = m >> 1; e = e + 9'd1; end
        if (!MAME_RND && v_avg) begin
            // the manual's FAVG: the rounded sum's exponent less one (rounding is the same)
            if (e >= 9'd256)     raw = {v_sgn, INF[30:0]};
            else if (!m[23])     raw = {v_sgn, 8'h00, m[22:0]};   // zero (both operands zero)
            else if (e <= 9'd1)  raw = {v_sgn, 31'h1};      // tiny
            else                 raw = {v_sgn, 8'(e - 9'd1), m[22:0]};
        end
        else if (e >= 9'd255)  raw = {v_sgn, INF[30:0]};
        else if (!m[23])  raw = {v_sgn, 8'h00, m[22:0]};
        else              raw = {v_sgn, e[7:0], m[22:0]};
    end
    // MAME's FAVG: the rounded sum times 0.5f, to nearest even (exact unless the half is denormal)
    if (MAME_RND && v_avg && !is_inf(raw) && raw[30:0] != 0) begin
        if (raw[30:23] >= 8'd2) raw = {raw[31], raw[30:23] - 8'd1, raw[22:0]};
        else begin
            logic [23:0] hm, hq;
            hm = {raw[30:23] != 0, raw[22:0]};
            hq = {1'b0, hm[23:1]} + {23'h0, hm[0] & hm[1]};
            raw = {raw[31], 7'h0, hq};
        end
    end

    // alu_fin (sharc_fp_pkg)
    fr = raw; fa = AF; fs = '0;
    if (is_inf(raw)) begin
        fa |= AV; fs |= AVS;
        if (v_trunc) fr = (raw & SIGN) | 32'h7F7F_FFFF;
    end else if (is_den_or_zero(raw)) begin
        fa |= AZ;
        if (raw[22:0] != 0) fs |= AUS;
        fr = raw & SIGN;
    end
    if (fr[31]) fa |= AN;
end

always_comb begin
    if (v_nan) begin r = NAN; astat = AI | AF; stky = AIS; end
    else       begin r = fr;  astat = fa;      stky = fs;  end
    nan_in = v_nanin;
    inf_both = v_infb;
end

endmodule
