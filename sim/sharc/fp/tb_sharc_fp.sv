// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- R1027: the 2B SHARC's float units and float functions,
// both roundings, for tb_sharc_fp.cpp (which holds the references).
//
//   the units: sharc_fadd / sharc_fmul at MAME_RND 1 (MAME) and 0 (the manual), fed the same
//     operands every advancing clock; the result is read in the clock after the second en (R1029:
//     the adder's stage 2a).
//   the package: every float function, MAME's (f_*) and the manual's (man_*), combinational.
module tb_sharc_fp (
    input  logic        clk,
    input  logic        en,
    input  logic [4:0]  op,
    input  logic [31:0] x, y, astat_in,
    input  logic        trunc, sub, avg,
    output logic        busy,
    // units, MAME / manual
    output logic [31:0] am_r, am_a, am_s, an_r, an_a, an_s,
    output logic [31:0] mm_r, mm_a, mm_s, mn_r, mn_a, mn_s,
    // package, MAME / manual
    output logic [31:0] pm_r, pm_r2, pm_a, pm_s,
    output logic [31:0] pn_r, pn_r2, pn_a, pn_s
);
    import sharc_fp_pkg::*;

    sharc_fadd #(.MAME_RND(1'b1)) u_am (.clk, .en, .x, .y, .sub, .avg, .trunc, .r(am_r), .astat(am_a), .stky(am_s),
                                         .nan_in(), .inf_both());
    sharc_fadd #(.MAME_RND(1'b0)) u_an (.clk, .en, .x, .y, .sub, .avg, .trunc, .r(an_r), .astat(an_a), .stky(an_s),
                                         .nan_in(), .inf_both());
    sharc_fmul #(.MAME_RND(1'b1)) u_mm (.clk, .en, .restart(1'b0), .valid(1'b1), .x, .y, .trunc, .busy,
                                         .r(mm_r), .astat(mm_a), .stky(mm_s));
    sharc_fmul #(.MAME_RND(1'b0)) u_mn (.clk, .en, .restart(1'b0), .valid(1'b1), .x, .y, .trunc, .busy(),
                                         .r(mn_r), .astat(mn_a), .stky(mn_s));

    fres_t  o, q;
    fdual_t d, e;
    always_comb begin
        o = '0; d = '0; q = '0; e = '0;
        pm_r2 = 32'h0; pn_r2 = 32'h0;
        case (op)
        5'd0:  begin o = f_add(x, y, trunc);             q = man_add(x, y, trunc); end
        5'd1:  begin o = f_sub(x, y, trunc);             q = man_sub(x, y, trunc); end
        5'd2:  begin o = f_avg(x, y, trunc);             q = man_avg(x, y, trunc); end
        5'd3:  begin d = f_addsub(x, y, trunc); o.r = d.add; o.astat = d.astat; o.stky = d.stky; pm_r2 = d.sub;
                     e = man_addsub(x, y, trunc); q.r = e.add; q.astat = e.astat; q.stky = e.stky; pn_r2 = e.sub; end
        5'd4:  begin o = f_abs(x);                       q = f_abs(x); end
        5'd5:  begin o = f_minmax(x, y, 1'b0);           q = man_minmax(x, y, 1'b0); end
        5'd6:  begin o = f_minmax(x, y, 1'b1);           q = man_minmax(x, y, 1'b1); end
        5'd7:  begin o = f_neg(x);                       q = f_neg(x); end
        5'd8:  begin o = f_pass(x);                      q = f_pass(x); end
        5'd9:  begin o = f_comp(x, y, astat_in);         q = man_comp(x, y, astat_in); end
        5'd10: begin o = f_scalb(x, y);                  q = man_scalb(x, y); end
        5'd11: begin o = f_logb(x);                      q = man_logb(x); end
        5'd12: begin o = f_fix(x, 1'b0, y, trunc, 1'b0); q = man_fix(x, 1'b0, y, trunc); end
        5'd13: begin o = f_fix(x, 1'b1, y, trunc, 1'b0); q = man_fix(x, 1'b1, y, trunc); end
        5'd14: begin o = f_fix(x, 1'b1, y, trunc, 1'b1); q = man_fix(x, 1'b1, y, trunc); end
        5'd15: begin o = f_float(x, 1'b0, y, 1'b0);      q = man_float(x, 1'b0, y, 1'b0, trunc); end
        5'd16: begin o = f_float(x, 1'b1, y, 1'b0);      q = man_float(x, 1'b1, y, 1'b0, trunc); end
        5'd17: begin o = f_float(x, 1'b1, y, 1'b1);      q = man_float(x, 1'b1, y, 1'b1, trunc); end
        5'd18: begin o = f_recips(x);                    q = man_recips(x); end
        5'd19: begin o = f_rsqrts(x);                    q = man_rsqrts(x); end
        5'd20: begin o = f_copysign(x, y);               q = f_copysign(x, y); end
        5'd21: begin o = f_clip(x, y);                   q = f_clip(x, y); end
        5'd22: begin o = f_mul(x, y);                    q = man_mul(x, y, trunc); end
        default: ;
        endcase
        pm_r = o.r; pm_a = o.astat; pm_s = o.stky;
        pn_r = q.r; pn_a = q.astat; pn_s = q.stky;
    end
endmodule
