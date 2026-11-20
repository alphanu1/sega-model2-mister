// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- the 2B SHARC's float multiplier.
// COPIED from Paul Priest's Konami Hornet core (ppriest/Arcade-KonamiHornet_MiSTer,
// rtl/cpu/sharc2/sharc_fmul.sv @ 87f9866, GPL-3.0-or-later, used with his permission;
// THIRD_PARTY.md). CHANGED (R1027): MAME_RND and `trunc`. MAME_RND 1 is Hornet's unit as it
// was (the generate's first branch, his text unchanged), bit-exact to MAME. MAME_RND 0 (the
// default) is the ADSP-2106x manual's multiplier: denormal operands flushed to zero, a product
// below 2^-126 (after rounding, exponent unbounded) flushed to a signed zero with MU / MUS,
// round toward zero under `trunc` (MODE1.TRUNC) where an overflow gives the largest finite
// (MV / MVS either way). It has no slow path: `busy` is 0.
// CHANGED (R1052, MAME_RND 0 only): stage 2's rounding carry tested beside the increment, not
// taken from its top bit, and the round-up choosing after the increments, not feeding one (the
// same result in every case; see g_man).
//
// His description of the MAME unit:
// Float multiply in two stages, bit-exact to sharc_fp_pkg::f_mul (the multiplier flushes
// neither operands nor result). Stage 1 registers at `en`; the result and flags are stage 2's,
// combinational, in the clock after.
//
// Fast path: normal (or zero, infinite, NaN) operands whose product cannot underflow: one DSP
// product (stage 1), a one-bit normalise and the rounding (stage 2). Slow path: a denormal
// operand, or an exponent sum small enough that the result may be denormal: `busy` holds the
// pipeline (en low) for four clocks while the product is normalised, multiplied, shifted to the
// denormal boundary and rounded in steps; the result then enters stage 2 with the next en.

module sharc_fmul #(
    parameter bit MAME_RND = 1'b0       // 1: MAME's arithmetic (no flush, round to nearest)
) (
    input  logic        clk,
    input  logic        en,             // advance the pipeline
    input  logic        restart,        // new operands: the slow path starts again
    input  logic        valid,          // x, y are a multiply's operands
    input  logic [31:0] x,
    input  logic [31:0] y,
    input  logic        trunc,          // MODE1.TRUNCATE (MAME_RND 0)
    output logic        busy,           // slow path: keep en low and the operands held
    output logic [31:0] r,
    output logic [31:0] astat,          // MN MV MU MI
    output logic [31:0] stky            // MVS MUS MIS
);

import sharc_fp_pkg::*;

generate if (MAME_RND) begin : g_mame


// ---------------------------------------------------------------- stage 1

logic        sg, nan1, spec, slow1;
logic [31:0] spec_r;
logic [23:0] ma, mb;
logic [9:0]  esum;
logic [47:0] p;

always_comb begin
    sg = x[31] ^ y[31];
    nan1 = nan_mul(x, y);
    // infinities and zeros give a signed infinity or zero, exactly as ieee_mul's first tests
    spec = is_inf(x) || is_inf(y) || is_zero(x) || is_zero(y);
    spec_r = (is_inf(x) || is_inf(y)) ? {sg, INF[30:0]} : {sg, 31'h0};
    ma = {1'b1, x[22:0]};
    mb = {1'b1, y[22:0]};
    esum = {2'b0, x[30:23]} + {2'b0, y[30:23]};
    // a denormal operand, or a product that may round to a denormal: e = esum - 127 (+1) < 1
    slow1 = valid && !nan1 && !spec && (is_den(x) || is_den(y) || esum <= 10'd128);
    p = ma * mb;
end

// slow path: ieee_mul in four registered steps from the held operands
logic [2:0]  sc;
logic [23:0] qa, qb;
logic signed [11:0] qe;
logic [47:0] qp;
logic [26:0] qs;
logic [31:0] slow_r;

always_ff @(posedge clk) begin
    if (en || restart || !slow1) sc <= 3'd0;
    else if (sc != 3'd4) sc <= sc + 3'd1;
    case (sc)
    3'd0: begin
        logic [4:0]  la, lb;
        logic [23:0] a, b;
        logic signed [11:0] ea, eb;
        a = {x[30:23] != 0, x[22:0]};
        b = {y[30:23] != 0, y[22:0]};
        ea = (x[30:23] == 0) ? 12'sd1 : {4'h0, x[30:23]};
        eb = (y[30:23] == 0) ? 12'sd1 : {4'h0, y[30:23]};
        la = clz24(a); lb = clz24(b);
        qa <= a << la; qb <= b << lb;
        qe <= ea + eb - {7'h0, la} - {7'h0, lb};
    end
    3'd1: qp <= qa * qb;
    3'd2: begin
        logic [47:0] pp;
        logic signed [11:0] e;
        logic [26:0] s;
        if (qp[47]) begin pp = qp; e = qe - 12'sd126; end
        else begin pp = qp << 1; e = qe - 12'sd127; end
        s = {pp[47:22], pp[21:0] != 0};
        if (e < 12'sd1) begin
            logic [11:0] k;
            logic [53:0] wide;
            k = 12'sd1 - e;
            if (k >= 12'd27) s = {26'h0, s != 0};
            else begin
                wide = {s, 27'h0} >> k;
                s = {wide[53:28], wide[27] | (wide[26:0] != 0)};
            end
            e = 12'sd1;
        end
        qs <= s; qe <= e;
    end
    3'd3: slow_r <= round_pack(sg, qe, qs);
    default: ;
    endcase
end

assign busy = slow1 && sc != 3'd4;

logic        v_nan, v_spec, v_slow, v_sg;
logic [31:0] v_r;
logic [47:0] v_p;
logic [9:0]  v_esum;

always_ff @(posedge clk) if (en) begin
    v_nan <= nan1;
    v_spec <= spec;
    v_slow <= slow1;
    v_r <= slow1 ? slow_r : spec_r;
    v_sg <= sg;
    v_p <= p;
    v_esum <= esum;
end

// ---------------------------------------------------------------- stage 2

logic [31:0] res;
always_comb begin
    if (v_spec || v_slow) res = v_r;
    else begin
        logic [26:0] s;
        logic [9:0]  e;
        logic [24:0] m;
        logic        up;
        if (v_p[47]) begin s = {v_p[47:22], v_p[21:0] != 0}; e = v_esum - 10'd126; end
        else         begin s = {v_p[46:21], v_p[20:0] != 0}; e = v_esum - 10'd127; end
        up = s[2] && (s[1] || s[0] || s[3]);
        m = {1'b0, s[26:3]} + {24'h0, up};
        if (m[24]) begin m = m >> 1; e = e + 10'd1; end
        res = (e >= 10'd255) ? {v_sg, INF[30:0]} : {v_sg, e[7:0], m[22:0]};
    end
end

always_comb begin
    if (v_nan) begin r = NAN; astat = MI; stky = MIS; end
    else begin
        r = res;
        astat = (res[31] ? MN : 32'h0) | (is_inf(res) ? MV : 32'h0) | (is_den(res) ? MU : 32'h0);
        stky  = (is_inf(res) ? MVS : 32'h0) | (is_den(res) ? MUS : 32'h0);
    end
end

end else begin : g_man

// ---------------------------------------------------------------- stage 1
logic [31:0] xf, yf;
logic        sg, nan1, inf1, zero1;
logic [47:0] p;
logic [9:0]  esum;
always_comb begin
    xf = flush(x);
    yf = flush(y);
    sg = xf[31] ^ yf[31];
    nan1 = nan_mul(xf, yf);
    inf1 = is_inf(xf) || is_inf(yf);
    zero1 = is_zero(xf) || is_zero(yf);
    p = {1'b1, xf[22:0]} * {1'b1, yf[22:0]};
    esum = {2'b0, xf[30:23]} + {2'b0, yf[30:23]};
end

// the exponent's two outcomes (esum - 127 and - 126: no carry, and the product's top bit or the
// rounding's carry), each tiny / out of range, decided here (R1029: off stage 2's path). R1052:
// the product of two 24-bit mantissas with their top bits set is at most (2^24 - 1)^2 < 2^48 -
// 2^24, so when its top bit is set its top 24 bits are never all ones and the rounding cannot
// carry: the top bit and the carry never come together, and esum - 125 is never reached
logic [1:0]  tiny1, ovf1;
always_comb begin
    for (int i = 0; i < 2; i++) begin
        tiny1[i] = esum < 10'(128 - i);                  // esum - 127 + i < 1
        ovf1[i] = esum >= 10'(382 - i);                  // esum - 127 + i >= 255
    end
end
logic        v_nan, v_inf, v_zero, v_sg, v_trunc;
logic [47:0] v_p;
logic [9:0]  v_esum;
logic [1:0]  v_tiny, v_ovf;
always_ff @(posedge clk) if (en) begin
    v_nan <= nan1; v_inf <= inf1; v_zero <= zero1; v_sg <= sg; v_trunc <= trunc;
    v_p <= p; v_esum <= esum; v_tiny <= tiny1; v_ovf <= ovf1;
end
assign busy = 1'b0;
logic unused_m;
assign unused_m = restart ^ valid;

// ---------------------------------------------------------------- stage 2
// R1052: the rounding's carry out of the 24 bits is up && (the 24 bits all ones), tested beside the
// increment rather than read from its top bit (s5271: v_p -> up -> the 24-bit increment's carry ->
// the m[24] / ei select -> r -> rf_wd -> the R file's MLAB, -0.777 at slow -40C). After a carry the
// sum is exactly 2^24, so the mantissa field is 0 whether or not it is shifted: the field is the
// low 23 bits of the increment, with no shift and no select. The exponent's two values are made from
// v_esum beside it and the carry chooses.
// R1052 (later): the rounding's decision no longer feeds the increment. Both fields -- the
// truncated one and the one plus one -- are made from v_p for each position of the product's top
// bit (four values, the increments straight from the register), and the round-up and the top bit
// choose after them; the round-up of each position from its own guard / sticky bits. The carry
// (only without the top bit, as above) is that position's round-up and its 24 bits all ones, and
// there the round-up needs no sticky bit (below) (s5312: v_p[5] -> the sticky OR -> up -> ei ->
// ovf -> r -> rf_wd -> the R file's MLAB, -0.856 at slow 100C). The same fields, exponent and
// tests as up / s / mf above.
always_comb begin
    logic [22:0] mf, mt1, mt0, mi1, mi0;
    logic [7:0]  e;
    logic        up1, up0, ei, tiny, ovf;
    logic [31:0] res;
    // the exponent of the product, unbounded: esum - 127 (+1 when the product's top bit is set or
    // the rounding carries -- never both); its tests from stage 1
    // (top bit set: s = {v_p[47:22], |v_p[21:0]}; clear: s = {v_p[46:21], |v_p[20:0]}; up is
    // !trunc && s[2] && (s[1] || s[0] || s[3]), the field s[25:3] + up)
    up1 = !v_trunc && v_p[23] && (v_p[22] || (v_p[21:0] != 0) || v_p[24]);
    up0 = !v_trunc && v_p[22] && (v_p[21] || (v_p[20:0] != 0) || v_p[23]);
    mt1 = v_p[46:24]; mi1 = v_p[46:24] + 23'd1;
    mt0 = v_p[45:23]; mi0 = v_p[45:23] + 23'd1;
    mf = v_p[47] ? (up1 ? mi1 : mt1) : (up0 ? mi0 : mt0);
    // the carry, top bit clear: s[26:3] = v_p[46:23] all ones and up0; with the top bit set ei is 1.
    // Where v_p[46:23] is all ones, v_p[23] (s[3]) is set, so up0 is !trunc && v_p[22]: the carry
    // needs no sticky bit, and the exponent / range selects are off the sticky OR (s5312's path: the
    // sticky -> up -> ei -> ovf (33 loads) -> r)
    ei = v_p[47] || (!v_trunc && v_p[22] && (&v_p[46:23]));
    e = ei ? 8'(v_esum[7:0] - 8'd126) : 8'(v_esum[7:0] - 8'd127);
    tiny = v_tiny[ei];
    ovf  = v_ovf[ei];
    res  = ovf ? (v_trunc ? {v_sg, MAXF[30:0]} : {v_sg, INF[30:0]}) : tiny ? {v_sg, 31'h0}
                : {v_sg, e[7:0], mf};
    if (v_nan) begin
        r = NAN; astat = MI; stky = MIS;
    end else if (v_inf) begin
        r = {v_sg, INF[30:0]}; astat = MV | (v_sg ? MN : 32'h0); stky = MVS;
    end else if (v_zero) begin
        r = {v_sg, 31'h0}; astat = v_sg ? MN : 32'h0; stky = '0;
    end else begin
        r = res;
        astat = (v_sg ? MN : 32'h0) | (ovf ? MV : 32'h0) | (tiny ? MU : 32'h0);
        stky  = (ovf ? MVS : 32'h0) | (tiny ? MUS : 32'h0);
    end
end

end endgenerate

endmodule
