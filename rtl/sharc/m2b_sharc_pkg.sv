// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- the 2B SHARC (ADSP-21062): constants and the one-clock
// compute operations (fixed ALU, shifter, conditions) of m2b_sharc (study R1027).
//
// The semantics are MAME 0.289's interpreter (src/devices/cpu/sharc: compute.hxx,
// sharcops.hxx), as Paul Priest transcribed them in his Konami Hornet core's v1 SHARC
// (rtl/cpu/sharc/sharc_core_ops.svh @ 87f9866, GPL-3.0-or-later, used with his permission;
// THIRD_PARTY.md): alu_fixed, shift_op and if_cond there are restated here as functions of
// their operands, returning the result and the new ASTAT, so that the core can place them in
// its X clock. Line for line the same arithmetic and flags.

package m2b_sharc_pkg;

// ASTAT: AZ AV AN AC AS AI MN MV MU MI AF are sharc_fp_pkg's (one definition: Quartus 17 makes a
// name imported from two packages invisible)
import sharc_fp_pkg::*;
localparam logic [31:0] SV = 32'h0000_0800, SZ = 32'h0000_1000, SS = 32'h0000_2000,
                        BTF = 32'h0004_0000, FLGS = 32'h0078_0000;
localparam logic [31:0] ALU_GRP = AZ | AN | AV | AC | AS | AI;
localparam logic [31:0] MUL_GRP = MN | MV | MU | MI;
// STKY
localparam logic [31:0] AOS = 32'h0000_0004;
localparam logic [31:0] PCFL = 32'h0020_0000, PCEM = 32'h0040_0000, SSOV = 32'h0080_0000,
                        SSEM = 32'h0100_0000, LSOV = 32'h0200_0000, LSEM = 32'h0400_0000;
localparam logic [31:0] STK_BITS = LSEM | LSOV | SSEM | SSOV | PCEM | PCFL;
// MODE1
localparam logic [31:0] M1_SWAPS = 32'h0000_04F8;      // SRD1H SRD1L SRD2H SRD2L SRRFH SRRFL
localparam int M1_ALUSAT = 13, M1_TRUNC = 15, M1_RND32 = 16;

typedef struct packed {
    logic [31:0] r;
    logic        we;
    logic [31:0] astat;
    logic [31:0] stky;      // bits to OR in
} xres_t;

function automatic logic [31:0] sext24(input logic [23:0] v);
    return {{8{v[23]}}, v};
endfunction
function automatic logic [31:0] sext6(input logic [5:0] v);
    return {{26{v[5]}}, v};
endfunction

// ---------------------------------------------------------------- conditions (if_cond)

function automatic logic cond_lt(input logic [31:0] a, input logic alusat);
    cond_lt = (a & AF) != 0 ? ((a & AN) != 0 && (a & AZ) == 0)
                            : (((a & AN) != 0) != (((a & AV) != 0) && !alusat));
endfunction
function automatic logic cond_le(input logic [31:0] a, input logic alusat);
    cond_le = (a & AZ) != 0 ||
              ((a & AF) != 0 ? (a & AN) != 0 : (((a & AN) != 0) != (((a & AV) != 0) && !alusat)));
endfunction

// flg: MAME's flag[0..3] (the input pins as last set); lce: CURLCNTR != 1
function automatic logic if_cond(input logic [31:0] a, input logic [3:0] flg, input logic alusat,
                                 input logic lce_ne1, input logic [4:0] c);
    logic t;
    case (c[3:0])
    4'h0: t = (a & AZ) != 0;
    4'h1: t = cond_lt(a, alusat);
    4'h2: t = cond_le(a, alusat);
    4'h3: t = (a & AC) != 0;
    4'h4: t = (a & AV) != 0;
    4'h5: t = (a & MV) != 0;
    4'h6: t = (a & MN) != 0;
    4'h7: t = (a & SV) != 0;
    4'h8: t = (a & SZ) != 0;
    4'h9: t = flg[0];
    4'ha: t = flg[1];
    4'hb: t = flg[2];
    4'hc: t = flg[3];
    4'hd: t = (a & BTF) != 0;
    4'he: t = 1'b0;
    default: t = lce_ne1;
    endcase
    if (c == 5'h1e) return 1'b1;            // TRUE (MAME: the default of the switch)
    if (c == 5'h1f) return 1'b1;
    if (c == 5'h0e) return 1'b0;
    return c[4] ? !t : t;
endfunction

// does condition c read ASTAT (not a flag pin, LCE, TRUE or FALSE)?
function automatic logic cond_astat(input logic [4:0] c);
    if (c == 5'h1e || c == 5'h1f) return 1'b0;
    case (c[3:0])
    4'h9, 4'ha, 4'hb, 4'hc, 4'he, 4'hf: return 1'b0;
    default: return 1'b1;
    endcase
endfunction

// DO_CONDITION_CODE: 0x0f is LCE (CURLCNTR == 1), 0x1f FOREVER (never)
function automatic logic do_cond(input logic [31:0] a, input logic [3:0] flg, input logic alusat,
                                 input logic lce_ne1, input logic [4:0] c);
    if (c == 5'h0f) return !lce_ne1;
    if (c == 5'h1f) return 1'b0;
    return if_cond(a, flg, alusat, lce_ne1, c);
endfunction

// ---------------------------------------------------------------- fixed-point ALU

function automatic logic [31:0] saturate(input logic [31:0] r);
    return {32{r[31]}} ^ 32'h8000_0000;
endfunction

// does op (cu 0, op[7] = 0) exist in MAME's compute? (v1's alu_fixed cases)
function automatic logic alu_fixed_ok(input logic [7:0] op);
    case (op)
    8'h01, 8'h05, 8'h25, 8'h29, 8'h02, 8'h06, 8'h26, 8'h2a, 8'h0a, 8'h21, 8'h22, 8'h30,
    8'h40, 8'h41, 8'h42, 8'h43, 8'h61, 8'h62, 8'h63: return 1'b1;
    default: return 1'b0;
    endcase
endfunction

function automatic xres_t alu_fixed(input logic [7:0] op, input logic [31:0] x, input logic [31:0] y,
                                    input logic [31:0] astat_in, input logic sat);
    xres_t o;
    logic [31:0] r, c, a;
    logic set_r;
    o = '0;
    r = 32'h0;
    c = (astat_in & AC) != 0 ? 32'd1 : 32'd0;
    a = astat_in & ~ALU_GRP;
    set_r = 1'b1;
    case (op)
    8'h01, 8'h05, 8'h25, 8'h29: begin                // ADD, ADD+CI, Rx+CI, INC
        logic [31:0] yy;
        yy = (op == 8'h29) ? 32'd1 : (op == 8'h25) ? 32'd0 : y;
        r = x + yy + ((op == 8'h05 || op == 8'h25) ? c : 32'd0);
        if ((~(x ^ yy) & (x ^ r) & 32'h8000_0000) != 0) begin a |= AV; o.stky |= AOS; end
        if (r < x) a |= AC;
        if (op == 8'h05 && c == 1 && y == 32'hFFFF_FFFF) a |= AC;
        if (sat && (a & AV) != 0) r = saturate(r);
    end
    8'h02, 8'h06, 8'h26, 8'h2a: begin                // SUB, SUB+CI-1, Rx+CI-1, DEC
        logic [31:0] yy;
        yy = (op == 8'h2a) ? 32'd1 : (op == 8'h26) ? 32'd0 : y;
        r = x - yy;
        if (op == 8'h06 || op == 8'h26) r = r + c - 1;
        if (((x ^ yy) & (x ^ r) & 32'h8000_0000) != 0) begin a |= AV; o.stky |= AOS; end
        if (op == 8'h06) begin
            if (c != 0 || y != 32'hFFFF_FFFF) begin if (r <= x) a |= AC; end
        end else if (r <= x) a |= AC;
        if (sat && (a & AV) != 0) r = saturate(r);
    end
    8'h0a: begin                                     // COMP
        logic [31:0] acc;
        set_r = 1'b0;
        if (x == y) a |= AZ;
        else if ($signed(x) < $signed(y)) a |= AN;
        acc = (a >> 1) & 32'h7F00_0000;
        if ((a & (AZ | AN)) == 0) acc |= 32'h8000_0000;
        a = (a & 32'h00FF_FFFF) | acc;
    end
    8'h21: r = x;                                    // PASS
    8'h22: begin                                     // NEG
        r = -x;
        if ((x & r & 32'h8000_0000) != 0) begin a |= AV; o.stky |= AOS; end
        if (r <= 32'h0) a |= AC;
        if (sat && (a & AV) != 0) r = saturate(r);
    end
    8'h30: begin                                     // ABS
        r = x[31] ? -x : x;
        if (r[31]) begin a |= AV; o.stky |= AOS; if (sat) r = 32'h7FFF_FFFF; end
        if (x[31]) a |= AS;
    end
    8'h40: r = x & y;
    8'h41: r = x | y;
    8'h42: r = x ^ y;
    8'h43: r = ~x;
    8'h61: r = ($signed(x) < $signed(y)) ? x : y;    // MIN
    8'h62: r = ($signed(x) < $signed(y)) ? y : x;    // MAX
    8'h63: begin                                     // CLIP
        logic [31:0] ay;
        ay = y[31] ? -y : y;
        r = ($signed(x) < -$signed(ay)) ? -ay : ($signed(ay) < $signed(x)) ? ay : x;
    end
    default: set_r = 1'b0;
    endcase
    if (set_r) begin
        if (r[31]) a |= AN;
        if (r == 0) a |= AZ;
    end
    o.r = r;
    o.we = set_r;
    o.astat = a & ~AF;
    return o;
endfunction

// ---------------------------------------------------------------- shifter

function automatic logic shift_ok(input logic [5:0] sop);
    case (sop)
    6'h00, 6'h08, 6'h01, 6'h02, 6'h10, 6'h11, 6'h12, 6'h13, 6'h19, 6'h30, 6'h31, 6'h32, 6'h33: return 1'b1;
    default: return 1'b0;
    endcase
endfunction

// x = R[rx], rnv = R[rn] (the OR forms), sval = the immediate (imm) or R[ry]
function automatic xres_t shifter(input logic [5:0] sop, input logic [31:0] x, input logic [31:0] rnv,
                                  input logic [31:0] sval, input logic imm, input logic [31:0] astat_in);
    xres_t o;
    logic [31:0] r, a;
    logic signed [7:0] sh8;
    logic signed [31:0] sh;
    logic [5:0] bitn, len;
    o = '0;
    a = astat_in & ~(SZ | SV | SS);
    sh8 = sval[7:0];
    sh = imm ? {{24{sh8[7]}}, sh8} : $signed(sval);
    bitn = sval[5:0]; len = sval[11:6];
    r = 32'h0;
    o.we = 1'b1;
    case (sop)
    6'h00, 6'h08: begin                              // LSHIFT, OR LSHIFT
        logic signed [31:0] shx;
        shx = (sop == 6'h08 && !imm) ? {{24{sh8[7]}}, sh8} : sh;
        if (shx < 0) r = (shx > -32) ? ((sop == 6'h08 && !imm) ? 32'($signed(x) >>> (-shx)) : x >> (-shx)) : 32'h0;
        else begin
            r = (shx < 32) ? x << shx : 32'h0;
            if (shx > 0) a |= SV;
        end
        if (sop == 6'h08) begin
            if (imm) begin if (r == 0) a |= SZ; r = rnv | r; end
            else begin r = rnv | r; if (r == 0) a |= SZ; end
        end else if (r == 0) a |= SZ;
    end
    6'h01: begin                                     // ASHIFT
        if (sh < 0) r = 32'($signed(x) >>> ((sh > -32) ? -sh : 31));
        else begin
            r = (sh < 32) ? x << sh : 32'h0;
            if (sh > 0) a |= SV;
        end
        if (r == 0) a |= SZ;
    end
    6'h02: begin                                     // ROT
        logic [4:0] n5;
        n5 = sh[4:0];
        r = (x << n5) | (x >> (6'd32 - {1'b0, n5}));
        if (n5 == 0) r = x;
        if (!imm && sh > 0) a |= SV;
        if (r == 0) a |= SZ;
    end
    6'h10, 6'h11, 6'h12, 6'h13, 6'h19: begin         // FEXT, FDEP, the sign forms, OR FDEP
        logic [31:0] mk;
        logic [5:0]  l;
        l = (len > 6'd32) ? 6'd32 : len;
        mk = (l >= 32) ? 32'hFFFF_FFFF : ((32'h1 << l) - 1);
        case (sop)
        6'h10: r = (len == 0 || bitn >= 32) ? 32'h0 : 32'($signed(x) >>> bitn) & mk;
        6'h11: r = (len == 0 || bitn >= 32) ? 32'h0 : (x & mk) << bitn;
        6'h12: begin
            if (len == 0 || bitn >= 32) r = 32'h0;
            else if (bitn + len > 32) r = x >> bitn;
            else begin
                logic [31:0] v;
                v = (x >> bitn) & mk;
                r = (l < 32 && v[l - 1]) ? (v | ~mk) : v;
            end
        end
        6'h13: begin
            logic [31:0] v;
            if (len == 0 || bitn >= 32) r = 32'h0;
            else begin
                v = x & mk;
                if (l < 32 && v[l - 1]) v = v | ~mk;
                r = v << bitn;
            end
        end
        default: r = rnv | ((len != 0 && bitn < 32) ? (x & mk) << bitn : 32'h0);
        endcase
        if (r == 0) a |= SZ;
        if ({1'b0, bitn} + {1'b0, len} > 7'd32) a |= SV;
    end
    6'h30, 6'h31, 6'h32: begin                       // BSET, BCLR, BTGL
        r = x;
        if (sval < 32) begin
            case (sop)
            6'h30: r = r | (32'h1 << sval[4:0]);
            6'h31: r = r & ~(32'h1 << sval[4:0]);
            default: r = r ^ (32'h1 << sval[4:0]);
            endcase
        end else a |= SV;
        if (r == 0) a |= SZ;
    end
    6'h33: begin                                     // BTST
        o.we = 1'b0;
        if (sval < 32) begin
            if ((x & (32'h1 << sval[4:0])) == 0) a |= SZ;
        end else a |= SZ | SV;
    end
    default: o.we = 1'b0;
    endcase
    o.r = r;
    o.astat = a;
    return o;
endfunction

endpackage
