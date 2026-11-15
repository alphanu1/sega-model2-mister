// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- R1028: m2b_sharc_xu (the shared X-clock compute) against
// the functions it replaces, which stay the reference: m2b_sharc_pkg's alu_fixed / shifter (MAME
// as Hornet's v1 restates it) and sharc_fp_pkg's f_* (MAME_RND 1) and man_* (MAME_RND 0) -- those
// checked against MAME and the manual by sim/sharc/fp. Both roundings are built side by side.
module tb_m2b_xu (
    input  logic [1:0]  cls,                // 0 fixed ALU, 1 shifter, 2 misc float
    input  logic [7:0]  fix_op,
    input  logic [5:0]  sh_op,
    input  logic        sh_imm,
    input  logic [31:0] sh_val,
    input  logic [4:0]  misc_op,
    input  logic [31:0] x, y, n, fx, fy, astat,
    input  logic        alusat, trunc,
    // the unit (MAME_RND 1 / 0): r, we, astat, stky
    output logic [31:0] u1_r, u1_a, u1_s, u0_r, u0_a, u0_s,
    output logic        u1_we, u0_we,
    // the references
    output logic [31:0] e1_r, e1_a, e1_s, e0_r, e0_a, e0_s,
    output logic        e1_we, e0_we
);
    import sharc_fp_pkg::*;
    import m2b_sharc_pkg::*;

    logic [31:0] fr1, sr1, fa1, sa1, fs1, mr1, ma1, ms1, fr0, sr0, fa0, sa0, fs0, mr0, ma0, ms0;
    logic        fw1, sw1, fw0, sw0;
    m2b_sharc_xu #(.MAME_RND(1'b1)) u1 (
        .fix_on(cls == 2'd0), .fix_op, .sh_on(cls == 2'd1), .sh_op, .sh_imm, .sh_val,
        .misc_on(cls == 2'd2), .misc_op, .x, .y, .n, .fx, .fy, .astat, .alusat, .trunc,
        .fix_r(fr1), .sh_r(sr1), .fix_we(fw1), .sh_we(sw1), .fix_astat(fa1), .sh_astat(sa1), .fix_stky(fs1),
        .misc_r(mr1), .misc_a(ma1), .misc_s(ms1));
    m2b_sharc_xu #(.MAME_RND(1'b0)) u0 (
        .fix_on(cls == 2'd0), .fix_op, .sh_on(cls == 2'd1), .sh_op, .sh_imm, .sh_val,
        .misc_on(cls == 2'd2), .misc_op, .x, .y, .n, .fx, .fy, .astat, .alusat, .trunc,
        .fix_r(fr0), .sh_r(sr0), .fix_we(fw0), .sh_we(sw0), .fix_astat(fa0), .sh_astat(sa0), .fix_stky(fs0),
        .misc_r(mr0), .misc_a(ma0), .misc_s(ms0));

    always_comb begin
        case (cls)
        2'd0: begin u1_r = fr1; u1_we = fw1; u1_a = fa1; u1_s = fs1; u0_r = fr0; u0_we = fw0; u0_a = fa0; u0_s = fs0; end
        2'd1: begin u1_r = sr1; u1_we = sw1; u1_a = sa1; u1_s = 32'h0; u0_r = sr0; u0_we = sw0; u0_a = sa0; u0_s = 32'h0; end
        default: begin u1_r = mr1; u1_we = 1'b1; u1_a = ma1; u1_s = ms1; u0_r = mr0; u0_we = 1'b1; u0_a = ma0; u0_s = ms0; end
        endcase
    end

    // the references, as m2b_sharc (R1027) called them
    always_comb begin
        xres_t q;
        fres_t o1, o0;
        o1 = '0; o0 = '0;
        e1_we = 1'b1; e0_we = 1'b1;
        case (cls)
        2'd0, 2'd1: begin
            q = (cls == 2'd0) ? alu_fixed(fix_op, x, y, astat, alusat) : shifter(sh_op, x, n, sh_val, sh_imm, astat);
            o1.r = q.r; o1.astat = q.astat; o1.stky = q.stky; o0 = o1;
            e1_we = q.we; e0_we = q.we;
        end
        default: begin
            case (misc_op)
            5'd4:  o1 = f_abs(fx);
            5'd5:  o1 = f_minmax(fx, fy, 1'b0);
            5'd6:  o1 = f_minmax(fx, fy, 1'b1);
            5'd7:  o1 = f_neg(fx);
            5'd8:  o1 = f_pass(fx);
            5'd9:  o1 = f_comp(fx, fy, astat & ~ALU_GRP);
            5'd10: o1 = f_scalb(fx, fy);
            5'd11: o1 = f_logb(fx);
            5'd12: o1 = f_fix(fx, 1'b0, 32'h0, trunc, 1'b0);
            5'd13: o1 = f_fix(fx, 1'b1, fy, trunc, 1'b0);
            5'd14: o1 = f_fix(fx, 1'b1, fy, trunc, 1'b1);
            5'd15: o1 = f_float(fx, 1'b0, 32'h0, 1'b0);
            5'd16: o1 = f_float(fx, 1'b1, fy, 1'b0);
            5'd17: o1 = f_float(fx, 1'b1, fy, 1'b1);
            5'd18: o1 = f_recips(fx);
            5'd19: o1 = f_rsqrts(fx);
            5'd20: o1 = f_copysign(fx, fy);
            5'd21: o1 = f_clip(fx, fy);
            default: o1 = '0;
            endcase
            case (misc_op)
            5'd4:  o0 = f_abs(fx);
            5'd5:  o0 = man_minmax(fx, fy, 1'b0);
            5'd6:  o0 = man_minmax(fx, fy, 1'b1);
            5'd7:  o0 = f_neg(fx);
            5'd8:  o0 = f_pass(fx);
            5'd9:  o0 = man_comp(fx, fy, astat & ~ALU_GRP);
            5'd10: o0 = man_scalb(fx, fy);
            5'd11: o0 = man_logb(fx);
            5'd12: o0 = man_fix(fx, 1'b0, 32'h0, trunc);
            5'd13: o0 = man_fix(fx, 1'b1, fy, trunc);
            5'd14: o0 = man_fix(fx, 1'b1, fy, trunc);
            5'd15: o0 = man_float(fx, 1'b0, 32'h0, 1'b0, trunc);
            5'd16: o0 = man_float(fx, 1'b1, fy, 1'b0, trunc);
            5'd17: o0 = man_float(fx, 1'b1, fy, 1'b1, trunc);
            5'd18: o0 = man_recips(fx);
            5'd19: o0 = man_rsqrts(fx);
            5'd20: o0 = f_copysign(fx, fy);
            5'd21: o0 = f_clip(fx, fy);
            default: o0 = '0;
            endcase
        end
        endcase
        e1_r = o1.r; e1_a = o1.astat; e1_s = o1.stky;
        e0_r = o0.r; e0_a = o0.astat; e0_s = o0.stky;
    end
endmodule
