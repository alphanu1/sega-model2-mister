// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- the 2B SHARC's float operations.
// COPIED from Paul Priest's Konami Hornet core (ppriest/Arcade-KonamiHornet_MiSTer,
// rtl/cpu/sharc/sharc_fp_pkg.sv @ 87f9866, GPL-3.0-or-later, used with his permission;
// THIRD_PARTY.md). Everything down to the "R1027" section is his, unchanged; the R1027
// section adds the ADSP-2106x manual's rounding (study R1024 / R1027).
//
// ADSP-2106x floating-point operations as MAME computes them (src/devices/cpu/sharc/compute.hxx).
// MAME uses the host's IEEE single arithmetic, round to nearest even, and flushes denormals only
// where compute.hxx says so: the ALU flushes its inputs and its result, the multiplier flushes
// neither. These functions reproduce that bit for bit, flags included; every departure from the
// chip that this inherits is MAME's and is listed in docs/MAME_KLUDGES.md.
//
// Each function returns the result and the ASTAT and STKY bits to OR in. Clearing the ALU or
// multiplier flag group first (CLEAR_ALU_FLAGS / CLEAR_MULTIPLIER_FLAGS) is the caller's job.

package sharc_fp_pkg;

localparam logic [31:0] AZ = 32'h0000_0001, AV = 32'h0000_0002, AN = 32'h0000_0004,
                        AC = 32'h0000_0008, AS = 32'h0000_0010, AI = 32'h0000_0020,
                        MN = 32'h0000_0040, MV = 32'h0000_0080, MU = 32'h0000_0100,
                        MI = 32'h0000_0200, AF = 32'h0000_0400;
localparam logic [31:0] AUS = 32'h0000_0001, AVS = 32'h0000_0002, AIS = 32'h0000_0020,
                        MVS = 32'h0000_0080, MUS = 32'h0000_0100, MIS = 32'h0000_0200;

localparam logic [31:0] NAN   = 32'hFFFF_FFFF;    // FLOAT_CANONICAL_NAN
localparam logic [31:0] INF   = 32'h7F80_0000;
localparam logic [31:0] SIGN  = 32'h8000_0000;

typedef struct packed {
    logic [31:0] r;
    logic [31:0] astat;
    logic [31:0] stky;
} fres_t;

function automatic logic is_nan(input logic [31:0] r);
    is_nan = r[30:23] == 8'hFF && r[22:0] != 0;
endfunction
function automatic logic is_inf(input logic [31:0] r);
    is_inf = r[30:0] == INF[30:0];
endfunction
function automatic logic is_zero(input logic [31:0] r);
    is_zero = r[30:0] == 31'h0;
endfunction
function automatic logic is_den(input logic [31:0] r);
    is_den = r[30:23] == 8'h00 && r[22:0] != 0;
endfunction
function automatic logic is_den_or_zero(input logic [31:0] r);
    is_den_or_zero = r[30:23] == 8'h00;
endfunction
function automatic logic [31:0] flush(input logic [31:0] r);
    flush = is_den_or_zero(r) ? (r & SIGN) : r;
endfunction

function automatic logic nan_add(input logic [31:0] a, input logic [31:0] b);
    logic ae, be;
    ae = a[30:23] == 8'hFF; be = b[30:23] == 8'hFF;
    nan_add = (ae && a[22:0] != 0) || (be && b[22:0] != 0) || (ae && be && (a[31] ^ b[31]));
endfunction
function automatic logic nan_sub(input logic [31:0] a, input logic [31:0] b);
    logic ae, be;
    ae = a[30:23] == 8'hFF; be = b[30:23] == 8'hFF;
    nan_sub = (ae && a[22:0] != 0) || (be && b[22:0] != 0) || (ae && be && !(a[31] ^ b[31]));
endfunction
function automatic logic nan_mul(input logic [31:0] a, input logic [31:0] b);
    logic ae, be;
    ae = a[30:23] == 8'hFF; be = b[30:23] == 8'hFF;
    nan_mul = (ae && (a[22:0] != 0 || is_zero(b))) || (be && (b[22:0] != 0 || is_zero(a)));
endfunction

// Host float comparison (denormals as values, +0 == -0); a and b are not NaN.
function automatic logic f_lt(input logic [31:0] a, input logic [31:0] b);
    if (is_zero(a) && is_zero(b)) f_lt = 1'b0;
    else if (a[31] != b[31])      f_lt = a[31];
    else if (!a[31])              f_lt = a[30:0] < b[30:0];
    else                          f_lt = a[30:0] > b[30:0];
endfunction
function automatic logic f_eq(input logic [31:0] a, input logic [31:0] b);
    f_eq = (is_zero(a) && is_zero(b)) || a == b;
endfunction

function automatic logic [4:0] clz24(input logic [23:0] v);
    clz24 = 5'd24;
    for (int i = 0; i < 24; i++) if (v[i]) clz24 = 5'(23 - i);
endfunction
function automatic logic [5:0] clz32(input logic [31:0] v);
    clz32 = 6'd32;
    for (int i = 0; i < 32; i++) if (v[i]) clz32 = 6'(31 - i);
endfunction

// Round a significand whose hidden bit is s[26] (value s * 2^(e - 127 - 26)) to nearest even and
// pack it. e is the biased exponent with denormals at e = 1 and s[26] = 0. e >= 255 packs infinity.
function automatic logic [31:0] round_pack(input logic sgn, input logic signed [11:0] e,
                                           input logic [26:0] s);
    logic [24:0] m;
    logic        up;
    logic signed [11:0] ee;
    up = s[2] && (s[1] || s[0] || s[3]);
    m  = {1'b0, s[26:3]} + {24'h0, up};
    ee = e;
    if (m[24]) begin m = m >> 1; ee = ee + 12'sd1; end
    if (ee >= 12'sd255)  round_pack = {sgn, INF[30:0]};
    else if (!m[23])     round_pack = {sgn, 8'h00, m[22:0]};
    else                 round_pack = {sgn, ee[7:0], m[22:0]};
endfunction

// IEEE single a + b, round to nearest even, gradual underflow, as the host computes it.
// Neither operand is NaN and a + b is not inf - inf.
function automatic logic [31:0] ieee_add(input logic [31:0] a, input logic [31:0] b);
    logic [31:0] x, y;
    logic [7:0]  ex, ey;
    logic [23:0] mx, my;
    logic [8:0]  d;
    logic [26:0] sx, sy;
    logic [27:0] s;
    logic        stk;
    logic signed [11:0] e;
    logic [4:0]  lz;
    logic [5:0]  sh;
    if (is_inf(a))      return a;
    if (is_inf(b))      return b;
    // x has the larger magnitude
    if (a[30:0] >= b[30:0]) begin x = a; y = b; end else begin x = b; y = a; end
    ex = (x[30:23] == 0) ? 8'd1 : x[30:23];
    ey = (y[30:23] == 0) ? 8'd1 : y[30:23];
    mx = {x[30:23] != 0, x[22:0]};
    my = {y[30:23] != 0, y[22:0]};
    d  = {1'b0, ex} - {1'b0, ey};
    sx = {mx, 3'b000};
    if (d >= 9'd27) begin
        sy = {26'h0, my != 0};
    end else begin
        logic [53:0] wide;
        wide = {my, 3'b000, 27'h0} >> d;
        sy   = {wide[53:28], wide[27] | (wide[26:0] != 0)};
    end
    e = {4'h0, ex};
    if (x[31] == y[31]) begin
        s = {1'b0, sx} + {1'b0, sy};
        if (s[27]) begin
            stk = s[0];
            s   = s >> 1;
            s[0] = s[0] | stk;
            e   = e + 12'sd1;
        end
        return round_pack(x[31], e, s[26:0]);
    end else begin
        s = {1'b0, sx} - {1'b0, sy};
        if (s == 0) return 32'h0000_0000;           // exact cancellation: +0 in round-to-nearest
        lz = 5'd0;
        for (int i = 0; i < 27; i++) if (s[i]) lz = 5'(26 - i);
        sh = (e - 12'sd1 < {7'h0, lz}) ? 6'(e - 12'sd1) : {1'b0, lz};
        s  = s << sh;
        e  = e - {6'h0, sh};
        return round_pack(x[31], e, s[26:0]);
    end
endfunction

// IEEE single a * b, round to nearest even, gradual underflow. Not NaN, not inf * 0.
function automatic logic [31:0] ieee_mul(input logic [31:0] a, input logic [31:0] b);
    logic        sg;
    logic [23:0] ma, mb;
    logic signed [11:0] ea, eb, e;
    logic [47:0] p;
    logic [26:0] s;
    logic [4:0]  la, lb;
    sg = a[31] ^ b[31];
    if (is_inf(a) || is_inf(b)) return {sg, INF[30:0]};
    if (is_zero(a) || is_zero(b)) return {sg, 31'h0};
    ma = {a[30:23] != 0, a[22:0]};
    mb = {b[30:23] != 0, b[22:0]};
    ea = (a[30:23] == 0) ? 12'sd1 : {4'h0, a[30:23]};
    eb = (b[30:23] == 0) ? 12'sd1 : {4'h0, b[30:23]};
    la = clz24(ma); lb = clz24(mb);
    ma = ma << la;  mb = mb << lb;
    ea = ea - {7'h0, la}; eb = eb - {7'h0, lb};
    p  = ma * mb;
    // normalise to p[47] set
    if (p[47]) e = ea + eb - 12'sd126;
    else begin p = p << 1; e = ea + eb - 12'sd127; end
    s = {p[47:22], p[21:0] != 0};
    if (e < 12'sd1) begin
        // gradual underflow: shift right to e = 1, keeping a sticky bit
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
    return round_pack(sg, e, s);
endfunction

// int32 -> single, round to nearest even
function automatic logic [31:0] i2f(input logic [31:0] v);
    logic        sg;
    logic [31:0] m;
    logic [5:0]  lz;
    logic [31:0] n;
    logic [26:0] s;
    sg = v[31];
    m  = sg ? -v : v;
    if (m == 0) return 32'h0;
    lz = clz32(m);
    n  = m << lz;                                   // top bit at 31
    s  = {n[31:6], n[5:0] != 0};
    return round_pack(sg, 12'sd158 - {6'h0, lz}, s);
endfunction

// single -> int32: 0 round to nearest even (nearbyintf), 1 floor (floorf), 2 toward zero
// (the C cast). Out of range, infinity and NaN give 0x80000000, as the x86 conversion does.
function automatic logic [31:0] f2i(input logic [31:0] f, input logic [1:0] mode);
    logic [7:0]  e;
    logic [23:0] m;
    logic [31:0] q;
    logic [55:0] w;
    logic        half, rest, up;
    logic signed [9:0] k;
    e = f[30:23];
    m = {e != 0, f[22:0]};
    if (e == 8'hFF || e >= 8'd158) return 32'h8000_0000;      // |f| >= 2^31, inf, NaN
    k = 10'sd150 - $signed({2'b0, e == 0 ? 8'd1 : e});       // right shift of m
    if (k <= 0) begin
        q = {8'h0, m} << (-k);
        half = 1'b0; rest = 1'b0;
    end else if (k > 10'sd32) begin
        q = 32'h0;                                           // |f| < 2^-8: all fraction
        half = 1'b0;
        rest = m != 0;
    end else begin
        w = {m, 32'h0} >> k;                                 // integer part w[55:32]
        q = {8'h0, w[55:32]};
        half = w[31];
        rest = w[30:0] != 0;
    end
    case (mode)
    2'd0:    up = half && (rest || q[0]);
    2'd1:    up = f[31] && (half || rest);
    default: up = 1'b0;
    endcase
    q = q + {31'h0, up};
    return f[31] ? -q : q;
endfunction

// SCALB (compute.hxx:404-428): exponent arithmetic on the raw fields, denormals included
function automatic fres_t scalb(input logic [31:0] fx, input logic [31:0] ry);
    // MAME adds in a C int: the sum wraps at 32 bits (compute.hxx:409-410)
    logic signed [31:0] e;
    fres_t o;
    o = '0;
    e = $signed({24'h0, fx[30:23]}) - 32'sd127 + $signed(ry);
    if (e > 32'sd127)       begin o.r = (fx & SIGN) | INF; o.astat = AV; end
    else if (e < -32'sd126) begin o.r = fx & SIGN; o.astat = AZ; end
    else                    o.r = (fx & SIGN) | {1'b0, 8'(e + 32'sd127), fx[22:0]};
    return o;
endfunction

// ------------------------------------------------------------------------------------------
// ALU operations (the float half of COMPUTE, cu = 0)
// ------------------------------------------------------------------------------------------

// shared result classification of FADD, FSUB, FAVG (compute.hxx:156-172)
function automatic fres_t alu_fin(input logic [31:0] r, input logic trunc);
    fres_t o;
    o = '0;
    o.r = r;
    if (is_inf(r)) begin
        o.astat |= AV; o.stky |= AVS;
        if (trunc) o.r = (r & SIGN) | 32'h7F7F_FFFF;
    end else if (is_den_or_zero(r)) begin
        o.astat |= AZ;
        if (r[22:0] != 0) o.stky |= AUS;
        o.r = r & SIGN;
    end
    if (o.r[31]) o.astat |= AN;
    o.astat |= AF;
    return o;
endfunction

function automatic fres_t f_add(input logic [31:0] x, input logic [31:0] y, input logic trunc);
    fres_t o;
    if (nan_add(x, y)) begin o = '0; o.r = NAN; o.astat = AI | AF; o.stky = AIS; return o; end
    return alu_fin(ieee_add(flush(x), flush(y)), trunc);
endfunction

function automatic fres_t f_sub(input logic [31:0] x, input logic [31:0] y, input logic trunc);
    fres_t o;
    if (nan_sub(x, y)) begin o = '0; o.r = NAN; o.astat = AI | AF; o.stky = AIS; return o; end
    return alu_fin(ieee_add(flush(x), flush(y) ^ SIGN), trunc);
endfunction

// (x + y) * 0.5f: the sum rounded to single, then halved and rounded again
function automatic fres_t f_avg(input logic [31:0] x, input logic [31:0] y, input logic trunc);
    fres_t o;
    if (nan_add(x, y)) begin o = '0; o.r = NAN; o.astat = AI | AF; o.stky = AIS; return o; end
    return alu_fin(ieee_mul(ieee_add(flush(x), flush(y)), 32'h3F00_0000), trunc);
endfunction

// FADD_FSUB (compute.hxx:326-402)
typedef struct packed {
    logic [31:0] add, sub;
    logic [31:0] astat, stky;
} fdual_t;

function automatic fdual_t f_addsub(input logic [31:0] x, input logic [31:0] y, input logic trunc);
    fdual_t o;
    logic xe, ye;
    fres_t a, s;
    o = '0;
    xe = x[30:23] == 8'hFF; ye = y[30:23] == 8'hFF;
    if ((xe && x[22:0] != 0) || (ye && y[22:0] != 0)) begin
        o.add = NAN; o.sub = NAN; o.astat = AI; o.stky = AIS;
    end else if (!xe || !ye) begin
        a = alu_fin(ieee_add(flush(x), flush(y)), trunc);
        s = alu_fin(ieee_add(flush(x), flush(y) ^ SIGN), trunc);
        o.add = a.r; o.sub = s.r;
        o.astat = (a.astat | s.astat) & ~AN;
        o.stky  = a.stky | s.stky;
        if ((a.r | s.r) & SIGN) o.astat |= AN;
    end else begin
        // both infinite. MAME assigns the integer pattern to the float member here, so the
        // register gets that integer converted to float (compute.hxx:386, 391)
        logic [31:0] pat;
        pat = (x & SIGN) | (trunc ? 32'h7F7F_FFFF : INF);
        if (x[31] ^ y[31]) begin o.add = NAN; o.sub = i2f_u(pat); end
        else               begin o.add = i2f_u(pat); o.sub = NAN; end
        o.astat = (x[31] ? AN : 32'h0) | AV | AI;
        o.stky  = AVS | AIS;
    end
    o.astat |= AF;
    return o;
endfunction

// uint32 -> single, round to nearest even (for the MAME slip above)
function automatic logic [31:0] i2f_u(input logic [31:0] v);
    logic [5:0]  lz;
    logic [31:0] n;
    if (v == 0) return 32'h0;
    lz = clz32(v);
    n  = v << lz;
    return round_pack(1'b0, 12'sd158 - {6'h0, lz}, {n[31:6], n[5:0] != 0});
endfunction

function automatic fres_t f_abs(input logic [31:0] x);
    fres_t o;
    o = '0;
    if (is_nan(x)) begin o.r = NAN; o.astat = AI; o.stky = AIS; end
    else begin
        if (is_den_or_zero(x)) begin o.r = 32'h0; o.astat = AZ; end
        else o.r = x & ~SIGN;
        if (x[31]) o.astat |= AS;
    end
    o.astat |= AF;
    return o;
endfunction

function automatic fres_t f_minmax(input logic [31:0] x, input logic [31:0] y, input logic max);
    fres_t o;
    o = '0;
    if (is_nan(x) || is_nan(y)) begin o.r = NAN; o.astat = AI; o.stky = AIS; end
    else begin
        // std::min(a, b) = (b < a) ? b : a; std::max(a, b) = (a < b) ? b : a
        if (max) o.r = f_lt(x, y) ? y : x;
        else     o.r = f_lt(y, x) ? y : x;
        if (f_lt(o.r, 32'h0)) o.astat |= AN;
        if (is_zero(o.r))     o.astat |= AZ;
    end
    o.astat |= AF;
    return o;
endfunction

function automatic fres_t f_neg(input logic [31:0] x);
    fres_t o;
    o = '0;
    if (is_nan(x)) begin o.r = NAN; o.astat = AI; o.stky = AIS; end
    else begin
        if (is_den_or_zero(x)) begin o.r = ~x & SIGN; o.astat = AZ; end
        else o.r = x ^ SIGN;
        if (o.r[31]) o.astat |= AN;
    end
    o.astat |= AF;
    return o;
endfunction

function automatic fres_t f_pass(input logic [31:0] x);
    fres_t o;
    o = '0;
    if (is_nan(x)) begin o.r = NAN; o.astat = AI; o.stky = AIS; end
    else begin
        if (is_den_or_zero(x)) begin o.r = x & SIGN; o.astat = AZ; end
        else o.r = x;
        if (o.r[31]) o.astat |= AN;
    end
    o.astat |= AF;
    return o;
endfunction

// COMP(Fx, Fy): AZ/AN, then the compare accumulator (compute.hxx:892-918)
function automatic fres_t f_comp(input logic [31:0] x, input logic [31:0] y, input logic [31:0] astat);
    fres_t o;
    logic [31:0] acc;
    o = '0;
    if (is_nan(x) || is_nan(y)) begin o.astat = AI; o.stky = AIS; end
    else if (f_eq(x, y)) o.astat = AZ;
    else if (f_lt(x, y)) o.astat = AN;
    // the accumulator is built from ASTAT after CLEAR_ALU_FLAGS and the new AZ/AN
    acc = ((astat & ~(AZ | AN | AV | AC | AS | AI)) >> 1) & 32'h7F00_0000;
    if ((o.astat & (AZ | AN)) == 0) acc |= 32'h8000_0000;
    o.r = acc;                        // the new top byte of ASTAT
    o.astat |= AF;
    return o;
endfunction

function automatic fres_t f_scalb(input logic [31:0] x, input logic [31:0] ry);
    fres_t o, s;
    o = '0;
    if (is_nan(x)) begin o.r = NAN; o.astat = AI; o.stky = AIS; end
    else begin
        s = scalb(x, ry);
        o.r = s.r;
        if (s.r[31]) o.astat |= AN;
        if (is_zero(s.r)) o.astat |= AZ;
        if (is_den(s.r)) o.stky |= AUS;
    end
    o.astat |= AF;
    return o;
endfunction

function automatic fres_t f_logb(input logic [31:0] x);
    fres_t o;
    logic signed [31:0] e;
    o = '0;
    if (is_inf(x))       begin o.r = INF; o.astat = AV; end
    else if (is_zero(x)) begin o.r = SIGN | INF; o.astat = AV; end
    else if (is_nan(x))  begin o.r = NAN; o.astat = AI; o.stky = AIS; end
    else begin
        e = $signed({24'h0, x[30:23]}) - 32'sd127;
        o.r = e;
        if (e[31]) o.astat |= AN;
        if (e == 0) o.astat |= AZ;
    end
    o.astat |= AF;
    return o;
endfunction

// FIX Fx [BY Ry]; mode as f2i. `multi` is the multifunction form, whose truncation is a C cast
// rather than floorf (compute.hxx:1594-1601 against 1065-1072)
function automatic fres_t f_fix(input logic [31:0] x, input logic scaled, input logic [31:0] ry,
                                input logic trunc, input logic multi);
    fres_t o, sc;
    logic [31:0] v;
    o = '0;
    sc = scalb(x, ry);
    v = scaled ? sc.r : x;
    o.r = f2i(v, trunc ? (multi ? 2'd2 : 2'd1) : 2'd0);
    if (o.r[31]) o.astat |= AN;
    if (o.r == 0) o.astat |= AZ;
    if (is_den(v)) o.stky |= AUS;
    if (is_nan(x)) o.astat |= AI;
    o.astat |= AF;
    return o;
endfunction

// FLOAT Rx [BY Ry]. The flags differ between the forms (compute.hxx:1119-1155, 1555-1579)
function automatic fres_t f_float(input logic [31:0] rx, input logic scaled, input logic [31:0] ry,
                                  input logic multi);
    fres_t o, sc;
    o = '0;
    o.r = i2f(rx);
    sc = scalb(o.r, ry);
    if (scaled) o.r = sc.r;
    if (multi) begin
        if (f_lt(o.r, 32'h0)) o.astat |= AN;
    end else begin
        if (o.r[31]) o.astat |= AN;
    end
    if (is_den_or_zero(o.r)) o.astat |= AZ;
    if (is_den(o.r)) o.stky |= AUS;
    o.astat |= AF;
    return o;
endfunction

function automatic logic [22:0] recips_lut(input logic [6:0] i);
    case (i)
    7'd0: recips_lut = 23'h7f8000; 7'd1: recips_lut = 23'h7e0000; 7'd2: recips_lut = 23'h7c0000; 7'd3: recips_lut = 23'h7a0000;
    7'd4: recips_lut = 23'h780000; 7'd5: recips_lut = 23'h760000; 7'd6: recips_lut = 23'h740000; 7'd7: recips_lut = 23'h720000;
    7'd8: recips_lut = 23'h700000; 7'd9: recips_lut = 23'h6f0000; 7'd10: recips_lut = 23'h6d0000; 7'd11: recips_lut = 23'h6b0000;
    7'd12: recips_lut = 23'h6a0000; 7'd13: recips_lut = 23'h680000; 7'd14: recips_lut = 23'h660000; 7'd15: recips_lut = 23'h650000;
    7'd16: recips_lut = 23'h630000; 7'd17: recips_lut = 23'h610000; 7'd18: recips_lut = 23'h600000; 7'd19: recips_lut = 23'h5e0000;
    7'd20: recips_lut = 23'h5d0000; 7'd21: recips_lut = 23'h5b0000; 7'd22: recips_lut = 23'h5a0000; 7'd23: recips_lut = 23'h590000;
    7'd24: recips_lut = 23'h570000; 7'd25: recips_lut = 23'h560000; 7'd26: recips_lut = 23'h540000; 7'd27: recips_lut = 23'h530000;
    7'd28: recips_lut = 23'h520000; 7'd29: recips_lut = 23'h500000; 7'd30: recips_lut = 23'h4f0000; 7'd31: recips_lut = 23'h4e0000;
    7'd32: recips_lut = 23'h4c0000; 7'd33: recips_lut = 23'h4b0000; 7'd34: recips_lut = 23'h4a0000; 7'd35: recips_lut = 23'h490000;
    7'd36: recips_lut = 23'h470000; 7'd37: recips_lut = 23'h460000; 7'd38: recips_lut = 23'h450000; 7'd39: recips_lut = 23'h440000;
    7'd40: recips_lut = 23'h430000; 7'd41: recips_lut = 23'h410000; 7'd42: recips_lut = 23'h400000; 7'd43: recips_lut = 23'h3f0000;
    7'd44: recips_lut = 23'h3e0000; 7'd45: recips_lut = 23'h3d0000; 7'd46: recips_lut = 23'h3c0000; 7'd47: recips_lut = 23'h3b0000;
    7'd48: recips_lut = 23'h3a0000; 7'd49: recips_lut = 23'h390000; 7'd50: recips_lut = 23'h380000; 7'd51: recips_lut = 23'h370000;
    7'd52: recips_lut = 23'h360000; 7'd53: recips_lut = 23'h350000; 7'd54: recips_lut = 23'h340000; 7'd55: recips_lut = 23'h330000;
    7'd56: recips_lut = 23'h320000; 7'd57: recips_lut = 23'h310000; 7'd58: recips_lut = 23'h300000; 7'd59: recips_lut = 23'h2f0000;
    7'd60: recips_lut = 23'h2e0000; 7'd61: recips_lut = 23'h2d0000; 7'd62: recips_lut = 23'h2c0000; 7'd63: recips_lut = 23'h2b0000;
    7'd64: recips_lut = 23'h2a0000; 7'd65: recips_lut = 23'h290000; 7'd66: recips_lut = 23'h280000; 7'd67: recips_lut = 23'h280000;
    7'd68: recips_lut = 23'h270000; 7'd69: recips_lut = 23'h260000; 7'd70: recips_lut = 23'h250000; 7'd71: recips_lut = 23'h240000;
    7'd72: recips_lut = 23'h230000; 7'd73: recips_lut = 23'h230000; 7'd74: recips_lut = 23'h220000; 7'd75: recips_lut = 23'h210000;
    7'd76: recips_lut = 23'h200000; 7'd77: recips_lut = 23'h1f0000; 7'd78: recips_lut = 23'h1f0000; 7'd79: recips_lut = 23'h1e0000;
    7'd80: recips_lut = 23'h1d0000; 7'd81: recips_lut = 23'h1c0000; 7'd82: recips_lut = 23'h1c0000; 7'd83: recips_lut = 23'h1b0000;
    7'd84: recips_lut = 23'h1a0000; 7'd85: recips_lut = 23'h190000; 7'd86: recips_lut = 23'h190000; 7'd87: recips_lut = 23'h180000;
    7'd88: recips_lut = 23'h170000; 7'd89: recips_lut = 23'h170000; 7'd90: recips_lut = 23'h160000; 7'd91: recips_lut = 23'h150000;
    7'd92: recips_lut = 23'h140000; 7'd93: recips_lut = 23'h140000; 7'd94: recips_lut = 23'h130000; 7'd95: recips_lut = 23'h120000;
    7'd96: recips_lut = 23'h120000; 7'd97: recips_lut = 23'h110000; 7'd98: recips_lut = 23'h100000; 7'd99: recips_lut = 23'h100000;
    7'd100: recips_lut = 23'h0f0000; 7'd101: recips_lut = 23'h0f0000; 7'd102: recips_lut = 23'h0e0000; 7'd103: recips_lut = 23'h0d0000;
    7'd104: recips_lut = 23'h0d0000; 7'd105: recips_lut = 23'h0c0000; 7'd106: recips_lut = 23'h0c0000; 7'd107: recips_lut = 23'h0b0000;
    7'd108: recips_lut = 23'h0a0000; 7'd109: recips_lut = 23'h0a0000; 7'd110: recips_lut = 23'h090000; 7'd111: recips_lut = 23'h090000;
    7'd112: recips_lut = 23'h080000; 7'd113: recips_lut = 23'h070000; 7'd114: recips_lut = 23'h070000; 7'd115: recips_lut = 23'h060000;
    7'd116: recips_lut = 23'h060000; 7'd117: recips_lut = 23'h050000; 7'd118: recips_lut = 23'h050000; 7'd119: recips_lut = 23'h040000;
    7'd120: recips_lut = 23'h040000; 7'd121: recips_lut = 23'h030000; 7'd122: recips_lut = 23'h030000; 7'd123: recips_lut = 23'h020000;
    7'd124: recips_lut = 23'h020000; 7'd125: recips_lut = 23'h010000; 7'd126: recips_lut = 23'h010000; default: recips_lut = 23'h000000;
    endcase
endfunction

function automatic logic [22:0] rsqrts_lut(input logic [6:0] i);
    case (i)
    7'd0: rsqrts_lut = 23'h350000; 7'd1: rsqrts_lut = 23'h330000; 7'd2: rsqrts_lut = 23'h320000; 7'd3: rsqrts_lut = 23'h300000;
    7'd4: rsqrts_lut = 23'h2f0000; 7'd5: rsqrts_lut = 23'h2e0000; 7'd6: rsqrts_lut = 23'h2d0000; 7'd7: rsqrts_lut = 23'h2b0000;
    7'd8: rsqrts_lut = 23'h2a0000; 7'd9: rsqrts_lut = 23'h290000; 7'd10: rsqrts_lut = 23'h280000; 7'd11: rsqrts_lut = 23'h270000;
    7'd12: rsqrts_lut = 23'h260000; 7'd13: rsqrts_lut = 23'h250000; 7'd14: rsqrts_lut = 23'h230000; 7'd15: rsqrts_lut = 23'h220000;
    7'd16: rsqrts_lut = 23'h210000; 7'd17: rsqrts_lut = 23'h200000; 7'd18: rsqrts_lut = 23'h1f0000; 7'd19: rsqrts_lut = 23'h1e0000;
    7'd20: rsqrts_lut = 23'h1e0000; 7'd21: rsqrts_lut = 23'h1d0000; 7'd22: rsqrts_lut = 23'h1c0000; 7'd23: rsqrts_lut = 23'h1b0000;
    7'd24: rsqrts_lut = 23'h1a0000; 7'd25: rsqrts_lut = 23'h190000; 7'd26: rsqrts_lut = 23'h180000; 7'd27: rsqrts_lut = 23'h170000;
    7'd28: rsqrts_lut = 23'h160000; 7'd29: rsqrts_lut = 23'h160000; 7'd30: rsqrts_lut = 23'h150000; 7'd31: rsqrts_lut = 23'h140000;
    7'd32: rsqrts_lut = 23'h130000; 7'd33: rsqrts_lut = 23'h130000; 7'd34: rsqrts_lut = 23'h120000; 7'd35: rsqrts_lut = 23'h110000;
    7'd36: rsqrts_lut = 23'h100000; 7'd37: rsqrts_lut = 23'h100000; 7'd38: rsqrts_lut = 23'h0f0000; 7'd39: rsqrts_lut = 23'h0e0000;
    7'd40: rsqrts_lut = 23'h0e0000; 7'd41: rsqrts_lut = 23'h0d0000; 7'd42: rsqrts_lut = 23'h0c0000; 7'd43: rsqrts_lut = 23'h0b0000;
    7'd44: rsqrts_lut = 23'h0b0000; 7'd45: rsqrts_lut = 23'h0a0000; 7'd46: rsqrts_lut = 23'h0a0000; 7'd47: rsqrts_lut = 23'h090000;
    7'd48: rsqrts_lut = 23'h080000; 7'd49: rsqrts_lut = 23'h080000; 7'd50: rsqrts_lut = 23'h070000; 7'd51: rsqrts_lut = 23'h070000;
    7'd52: rsqrts_lut = 23'h060000; 7'd53: rsqrts_lut = 23'h050000; 7'd54: rsqrts_lut = 23'h050000; 7'd55: rsqrts_lut = 23'h040000;
    7'd56: rsqrts_lut = 23'h040000; 7'd57: rsqrts_lut = 23'h030000; 7'd58: rsqrts_lut = 23'h030000; 7'd59: rsqrts_lut = 23'h020000;
    7'd60: rsqrts_lut = 23'h020000; 7'd61: rsqrts_lut = 23'h010000; 7'd62: rsqrts_lut = 23'h010000; 7'd63: rsqrts_lut = 23'h000000;
    7'd64: rsqrts_lut = 23'h7f8000; 7'd65: rsqrts_lut = 23'h7e0000; 7'd66: rsqrts_lut = 23'h7c0000; 7'd67: rsqrts_lut = 23'h7a0000;
    7'd68: rsqrts_lut = 23'h780000; 7'd69: rsqrts_lut = 23'h760000; 7'd70: rsqrts_lut = 23'h740000; 7'd71: rsqrts_lut = 23'h730000;
    7'd72: rsqrts_lut = 23'h710000; 7'd73: rsqrts_lut = 23'h6f0000; 7'd74: rsqrts_lut = 23'h6e0000; 7'd75: rsqrts_lut = 23'h6c0000;
    7'd76: rsqrts_lut = 23'h6a0000; 7'd77: rsqrts_lut = 23'h690000; 7'd78: rsqrts_lut = 23'h670000; 7'd79: rsqrts_lut = 23'h660000;
    7'd80: rsqrts_lut = 23'h640000; 7'd81: rsqrts_lut = 23'h630000; 7'd82: rsqrts_lut = 23'h620000; 7'd83: rsqrts_lut = 23'h600000;
    7'd84: rsqrts_lut = 23'h5f0000; 7'd85: rsqrts_lut = 23'h5e0000; 7'd86: rsqrts_lut = 23'h5c0000; 7'd87: rsqrts_lut = 23'h5b0000;
    7'd88: rsqrts_lut = 23'h5a0000; 7'd89: rsqrts_lut = 23'h590000; 7'd90: rsqrts_lut = 23'h570000; 7'd91: rsqrts_lut = 23'h560000;
    7'd92: rsqrts_lut = 23'h550000; 7'd93: rsqrts_lut = 23'h540000; 7'd94: rsqrts_lut = 23'h530000; 7'd95: rsqrts_lut = 23'h520000;
    7'd96: rsqrts_lut = 23'h510000; 7'd97: rsqrts_lut = 23'h4f0000; 7'd98: rsqrts_lut = 23'h4e0000; 7'd99: rsqrts_lut = 23'h4d0000;
    7'd100: rsqrts_lut = 23'h4c0000; 7'd101: rsqrts_lut = 23'h4b0000; 7'd102: rsqrts_lut = 23'h4a0000; 7'd103: rsqrts_lut = 23'h490000;
    7'd104: rsqrts_lut = 23'h480000; 7'd105: rsqrts_lut = 23'h470000; 7'd106: rsqrts_lut = 23'h460000; 7'd107: rsqrts_lut = 23'h450000;
    7'd108: rsqrts_lut = 23'h450000; 7'd109: rsqrts_lut = 23'h440000; 7'd110: rsqrts_lut = 23'h430000; 7'd111: rsqrts_lut = 23'h420000;
    7'd112: rsqrts_lut = 23'h410000; 7'd113: rsqrts_lut = 23'h400000; 7'd114: rsqrts_lut = 23'h3f0000; 7'd115: rsqrts_lut = 23'h3e0000;
    7'd116: rsqrts_lut = 23'h3e0000; 7'd117: rsqrts_lut = 23'h3d0000; 7'd118: rsqrts_lut = 23'h3c0000; 7'd119: rsqrts_lut = 23'h3b0000;
    7'd120: rsqrts_lut = 23'h3a0000; 7'd121: rsqrts_lut = 23'h3a0000; 7'd122: rsqrts_lut = 23'h390000; 7'd123: rsqrts_lut = 23'h380000;
    7'd124: rsqrts_lut = 23'h370000; 7'd125: rsqrts_lut = 23'h370000; 7'd126: rsqrts_lut = 23'h360000; default: rsqrts_lut = 23'h350000;
    endcase
endfunction

function automatic fres_t f_recips(input logic [31:0] x);
    fres_t o;
    logic signed [9:0] e;
    logic [22:0] m;
    o = '0;
    if (is_nan(x))       begin o.r = NAN; o.astat = AI; o.stky = AIS; end
    else if (is_zero(x)) begin o.r = (x & SIGN) | INF; o.astat = AV; end
    else begin
        e = -($signed({2'b0, x[30:23]}) - 10'sd127) - 10'sd1;
        m = recips_lut(x[22:16]);
        if (e > 10'sd125 || e < -10'sd126) begin e = 10'sd0; m = 23'h0; o.r = x & SIGN; end
        else o.r = (x & SIGN) | {1'b0, 8'(e + 10'sd127), m};
        if (x[31]) o.astat |= AN;
        if (is_zero(o.r)) o.astat |= AZ;
    end
    o.astat |= AF;
    return o;
endfunction

function automatic fres_t f_rsqrts(input logic [31:0] x);
    fres_t o;
    logic signed [9:0] eu, e;
    o = '0;
    if (x > SIGN)       o.r = NAN;
    else if (is_nan(x)) o.r = NAN;
    else begin
        eu = $signed({2'b0, x[30:23]}) - 10'sd127;
        e  = -(eu >>> 1) - 10'sd1;
        o.r = (x & SIGN) | {1'b0, 8'(e + 10'sd127), rsqrts_lut(x[23:17])};
    end
    if (x == SIGN) o.astat |= AN;
    if (is_zero(o.r)) o.astat |= AZ;
    if (is_zero(x)) o.astat |= AV;
    if (is_nan(x) || x[31]) begin o.astat |= AI; o.stky |= AIS; end
    o.astat |= AF;
    return o;
endfunction

function automatic fres_t f_copysign(input logic [31:0] x, input logic [31:0] y);
    fres_t o;
    o = '0;
    if (is_nan(x) || is_nan(y)) begin o.r = NAN; o.astat = AI; o.stky = AIS; end
    else begin
        o.r = y & SIGN;
        if (o.r != 0) o.astat |= AN;
        if (is_den_or_zero(x)) o.astat |= AZ;
        else o.r |= x & ~SIGN;
    end
    o.astat |= AF;
    return o;
endfunction

function automatic fres_t f_clip(input logic [31:0] x, input logic [31:0] y);
    fres_t o;
    logic [31:0] hi, lo;
    o = '0;
    if (is_nan(x) || is_nan(y)) begin o.r = NAN; o.astat = AI; o.stky = AIS; end
    else begin
        if (is_den_or_zero(x) || is_den_or_zero(y)) begin o.r = x & SIGN; o.astat = AZ; end
        else begin
            hi = y & ~SIGN; lo = y | SIGN;
            // std::clamp(v, lo, hi) = v < lo ? lo : hi < v ? hi : v
            o.r = f_lt(x, lo) ? lo : f_lt(hi, x) ? hi : x;
            if (is_zero(o.r)) o.astat |= AZ;
        end
        if (o.r[31]) o.astat |= AN;
    end
    o.astat |= AF;
    return o;
endfunction

// ------------------------------------------------------------------------------------------
// Multiplier
// ------------------------------------------------------------------------------------------

function automatic fres_t f_mul(input logic [31:0] x, input logic [31:0] y);
    fres_t o;
    o = '0;
    if (nan_mul(x, y)) begin o.r = NAN; o.astat = MI; o.stky = MIS; end
    else begin
        o.r = ieee_mul(x, y);
        if (o.r[31])      o.astat |= MN;
        if (is_inf(o.r))  begin o.astat |= MV; o.stky |= MVS; end
        if (is_den(o.r))  begin o.astat |= MU; o.stky |= MUS; end
    end
    return o;
endfunction

// ------------------------------------------------------------------------------------------
// R1027: the ADSP-2106x manual's rounding (study R1024, Ben's decision "FP aim towards
// accuracy"). TRUNC (MODE1 bit 15) = round toward zero, else to nearest even, for the ALU's
// float results and the multiplier's; denormal operands flushed to zero as they enter every
// unit (the multiplier too); a result below 2^-126 after rounding at 24 bits with the exponent
// unbounded is flushed to a signed zero with the underflow flags; FIX under TRUNC rounds
// toward minus infinity in both forms. Where the manual was not re-read (an infinite operand
// under TRUNC, FIX out of range, the flag details), MAME's behaviour above is kept. RND32 is
// assumed set (32-bit results): the core flags RND32 = 0 as unsupported.
// ------------------------------------------------------------------------------------------

localparam logic [31:0] MAXF = 32'h7F7F_FFFF;

typedef struct packed {
    logic [31:0] r;
    logic        tiny;      // flushed: the rounded result is below 2^-126
    logic        ovf;       // the rounded result is 2^128 or more: r is the infinity
} mres_t;

// s: significand with the hidden bit at s[26] and guard / round / sticky in s[2:0];
// e: biased exponent, unbounded (s[26] set)
function automatic mres_t man_round(input logic sgn, input logic signed [11:0] e,
                                    input logic [26:0] s, input logic rz);
    mres_t o;
    logic [24:0] m;
    logic        up;
    logic signed [11:0] ee;
    up = !rz && s[2] && (s[1] || s[0] || s[3]);
    m  = {1'b0, s[26:3]} + {24'h0, up};
    ee = e;
    if (m[24]) begin m = m >> 1; ee = ee + 12'sd1; end
    o.tiny = ee < 12'sd1;
    o.ovf  = ee >= 12'sd255;
    o.r = o.ovf ? {sgn, INF[30:0]} : o.tiny ? {sgn, 31'h0} : {sgn, ee[7:0], m[22:0]};
    return o;
endfunction

// the exact sum of two flushed, finite operands, normalised: zero (z), or sign / exponent /
// significand for man_round. Hornet's ieee_add without the gradual-underflow clamp.
typedef struct packed {
    logic        z;
    logic        sgn;
    logic signed [11:0] e;
    logic [26:0] s;
} msum_t;

function automatic msum_t man_sum(input logic [31:0] a, input logic [31:0] b);
    msum_t o;
    logic [31:0] x, y;
    logic [7:0]  ex, ey;
    logic [23:0] mx, my;
    logic [8:0]  d;
    logic [26:0] sx, sy;
    logic [27:0] s;
    logic        stk;
    logic [4:0]  lz;
    o = '0;
    if (is_zero(a) && is_zero(b)) begin o.z = 1'b1; o.sgn = a[31] & b[31]; return o; end
    if (a[30:0] >= b[30:0]) begin x = a; y = b; end else begin x = b; y = a; end
    ex = x[30:23];
    ey = y[30:23];
    mx = {1'b1, x[22:0]};
    my = {ey != 0, y[22:0]};
    if (ey == 0) ey = ex;                          // y is zero: no shift, nothing added
    d  = {1'b0, ex} - {1'b0, ey};
    sx = {mx, 3'b000};
    if (d >= 9'd27) sy = {26'h0, my != 0};
    else begin
        logic [53:0] wide;
        wide = {my, 3'b000, 27'h0} >> d;
        sy   = {wide[53:28], wide[27] | (wide[26:0] != 0)};
    end
    o.sgn = x[31];
    o.e = {4'h0, ex};
    if (x[31] == y[31]) begin
        s = {1'b0, sx} + {1'b0, sy};
        if (s[27]) begin
            stk = s[0];
            s = s >> 1;
            s[0] = s[0] | stk;
            o.e = o.e + 12'sd1;
        end
        o.s = s[26:0];
    end else begin
        s = {1'b0, sx} - {1'b0, sy};
        if (s == 0) begin o.z = 1'b1; o.sgn = 1'b0; return o; end   // exact: +0 in both modes
        lz = 5'd0;
        for (int i = 0; i < 27; i++) if (s[i]) lz = 5'(26 - i);
        s = s << lz;
        o.e = o.e - {7'h0, lz};
        o.s = s[26:0];
    end
    return o;
endfunction

// the ALU's float finish: MAME's alu_fin flags (AV on an infinite result, the largest finite
// under TRUNC; AZ on zero), AUS on a flushed (tiny) result
function automatic fres_t man_alu_fin(input mres_t m, input logic trunc);
    fres_t o;
    o = '0;
    o.r = m.r;
    if (is_inf(m.r)) begin
        o.astat |= AV; o.stky |= AVS;
        if (trunc) o.r = (m.r & SIGN) | MAXF;
    end else if (is_zero(m.r)) begin
        o.astat |= AZ;
        if (m.tiny) o.stky |= AUS;
    end
    if (o.r[31]) o.astat |= AN;
    o.astat |= AF;
    return o;
endfunction

function automatic mres_t man_addr(input logic [31:0] x, input logic [31:0] y, input logic rz,
                                   input logic half);
    mres_t o;
    msum_t q;
    o = '0;
    if (is_inf(x)) begin o.r = x; return o; end
    if (is_inf(y)) begin o.r = y; return o; end
    q = man_sum(x, y);
    if (q.z) begin o.r = {q.sgn, 31'h0}; return o; end
    return man_round(q.sgn, q.e - (half ? 12'sd1 : 12'sd0), q.s, rz);
endfunction

function automatic fres_t man_add(input logic [31:0] x, input logic [31:0] y, input logic trunc);
    fres_t o;
    if (nan_add(x, y)) begin o = '0; o.r = NAN; o.astat = AI | AF; o.stky = AIS; return o; end
    return man_alu_fin(man_addr(flush(x), flush(y), trunc, 1'b0), trunc);
endfunction

function automatic fres_t man_sub(input logic [31:0] x, input logic [31:0] y, input logic trunc);
    fres_t o;
    if (nan_sub(x, y)) begin o = '0; o.r = NAN; o.astat = AI | AF; o.stky = AIS; return o; end
    return man_alu_fin(man_addr(flush(x), flush(y) ^ SIGN, trunc, 1'b0), trunc);
endfunction

// (x + y) / 2 rounded once: the exact sum's exponent less one
function automatic fres_t man_avg(input logic [31:0] x, input logic [31:0] y, input logic trunc);
    fres_t o;
    if (nan_add(x, y)) begin o = '0; o.r = NAN; o.astat = AI | AF; o.stky = AIS; return o; end
    return man_alu_fin(man_addr(flush(x), flush(y), trunc, 1'b1), trunc);
endfunction

function automatic fdual_t man_addsub(input logic [31:0] x, input logic [31:0] y, input logic trunc);
    fdual_t o;
    fres_t a, s;
    a = man_add(x, y, trunc);
    s = man_sub(x, y, trunc);
    o.add = a.r; o.sub = s.r;
    o.astat = (a.astat | s.astat) & ~AN;
    o.stky  = a.stky | s.stky;
    if ((a.r | s.r) & SIGN) o.astat |= AN;
    return o;
endfunction

// the multiplier: denormal operands flushed, a tiny product flushed (MU / MUS), round to zero
// under TRUNC, where an overflow gives the largest finite (MV / MVS either way)
function automatic fres_t man_mul(input logic [31:0] x, input logic [31:0] y, input logic trunc);
    fres_t o;
    logic [31:0] xf, yf;
    logic        sg;
    logic [47:0] p;
    logic signed [11:0] e;
    logic [26:0] s;
    mres_t m;
    o = '0;
    xf = flush(x); yf = flush(y);
    if (nan_mul(xf, yf)) begin o.r = NAN; o.astat = MI; o.stky = MIS; return o; end
    sg = xf[31] ^ yf[31];
    if (is_inf(xf) || is_inf(yf)) begin
        o.r = {sg, INF[30:0]}; o.astat = MV | (sg ? MN : 32'h0); o.stky = MVS; return o;
    end
    if (is_zero(xf) || is_zero(yf)) begin o.r = {sg, 31'h0}; o.astat = sg ? MN : 32'h0; return o; end
    p = {1'b1, xf[22:0]} * {1'b1, yf[22:0]};
    if (p[47]) begin s = {p[47:22], p[21:0] != 0}; e = $signed({4'h0, xf[30:23]}) + $signed({4'h0, yf[30:23]}) - 12'sd126; end
    else       begin s = {p[46:21], p[20:0] != 0}; e = $signed({4'h0, xf[30:23]}) + $signed({4'h0, yf[30:23]}) - 12'sd127; end
    m = man_round(sg, e, s, trunc);
    o.r = m.r;
    if (m.ovf) begin
        o.astat |= MV; o.stky |= MVS;
        if (trunc) o.r = {sg, MAXF[30:0]};
    end
    if (m.tiny) begin o.astat |= MU; o.stky |= MUS; end
    if (o.r[31]) o.astat |= MN;
    return o;
endfunction

// int32 -> single, rounded by the mode
function automatic logic [31:0] man_i2f(input logic [31:0] v, input logic rz);
    logic        sg;
    logic [31:0] m, n;
    logic [5:0]  lz;
    mres_t       q;
    sg = v[31];
    m  = sg ? -v : v;
    if (m == 0) return 32'h0;
    lz = clz32(m);
    n  = m << lz;
    q  = man_round(sg, 12'sd158 - {6'h0, lz}, {n[31:6], n[5:0] != 0}, rz);
    return q.r;
endfunction

// FLOAT Rx [BY Ry]: MAME's f_float with the conversion rounded by TRUNC
function automatic fres_t man_float(input logic [31:0] rx, input logic scaled, input logic [31:0] ry,
                                    input logic multi, input logic trunc);
    fres_t o, sc;
    o = '0;
    o.r = man_i2f(rx, trunc);
    sc = scalb(o.r, ry);
    if (scaled) o.r = sc.r;
    if (multi) begin
        if (f_lt(o.r, 32'h0)) o.astat |= AN;
    end else begin
        if (o.r[31]) o.astat |= AN;
    end
    if (is_den_or_zero(o.r)) o.astat |= AZ;
    if (is_den(o.r)) o.stky |= AUS;
    o.astat |= AF;
    return o;
endfunction

// FIX Fx [BY Ry]: the operand flushed; toward minus infinity under TRUNC in every form
// (MAME: the multifunction form a C cast, toward zero), else to nearest even
function automatic fres_t man_fix(input logic [31:0] x, input logic scaled, input logic [31:0] ry,
                                  input logic trunc);
    fres_t o, sc;
    logic [31:0] v, xf;
    o = '0;
    xf = flush(x);
    sc = scalb(xf, ry);
    v = scaled ? sc.r : xf;
    if (is_den(v)) v = v & SIGN;
    o.r = f2i(v, trunc ? 2'd1 : 2'd0);
    if (o.r[31]) o.astat |= AN;
    if (o.r == 0) o.astat |= AZ;
    if (is_nan(x)) o.astat |= AI;
    o.astat |= AF;
    return o;
endfunction

// the rest of the float ALU: MAME's functions on flushed operands
function automatic fres_t man_minmax(input logic [31:0] x, input logic [31:0] y, input logic max);
    return f_minmax(flush(x), flush(y), max);
endfunction
function automatic fres_t man_comp(input logic [31:0] x, input logic [31:0] y, input logic [31:0] astat);
    return f_comp(flush(x), flush(y), astat);
endfunction
function automatic fres_t man_scalb(input logic [31:0] x, input logic [31:0] ry);
    return f_scalb(flush(x), ry);
endfunction
function automatic fres_t man_logb(input logic [31:0] x);
    return f_logb(flush(x));
endfunction
function automatic fres_t man_recips(input logic [31:0] x);
    return f_recips(flush(x));
endfunction
function automatic fres_t man_rsqrts(input logic [31:0] x);
    return f_rsqrts(flush(x));
endfunction

endpackage
