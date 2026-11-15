// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- R1027: the 2B SHARC (m2b_sharc) for the replay and
// lockstep benches. With LOCK, Hornet's v1 (sim/sharc/ref, MAME's interpreter transcribed) runs
// beside it on its own copy of the FIFOs; the C++ compares them word by word.
module tb_m2b_sharc #(
    parameter bit MAME_RND = 1'b1,
    parameter bit LOCK = 1'b0
) (
    input  logic        clk, reset, run,
    input  logic        host_iop_we,
    input  logic [7:0]  host_iop_reg,
    input  logic [31:0] host_iop_data,
    input  logic        xdma_we,
    input  logic [1:0]  xdma_phase,
    input  logic [15:0] xdma_data,
    input  logic        fin_empty,
    input  logic [31:0] fin_data,
    output logic        fin_pop,
    input  logic        fout_full,
    output logic        fout_push,
    output logic [31:0] fout_data,
    output logic        ext_req, ext_we,
    output logic [31:0] ext_addr, ext_wdata,
    input  logic        ext_ack,
    input  logic [31:0] ext_rdata,
    output logic        unsup,
    output logic [23:0] unsup_pc,
    output logic [47:0] unsup_op,
    output logic [3:0]  unsup_why,
    output logic        dbg_ret,
    output logic [23:0] dbg_pc,
    output logic [47:0] dbg_op,
    output logic [2:0]  dbg_st,
    // the architectural state, for the hash and the lockstep
    output logic [31:0] o_r [16],
    output logic [31:0] o_i [16],
    output logic [31:0] o_m [16],
    output logic [31:0] o_astat, o_stky, o_mode1, o_curlcntr, o_lcntr,
    output logic [23:0] o_pcstk, o_daddr, o_xpc,
    output logic [5:0]  o_pcstkp,
    output logic [2:0]  o_lstkp,
    // v1 (LOCK)
    input  logic        v_ce,
    input  logic        v_ext_ack,
    input  logic [31:0] v_ext_rdata,
    output logic        v_ext_req, v_ext_we,
    output logic [31:0] v_ext_addr, v_ext_wdata,
    input  logic [1:0]  v_flag,
    output logic        v_exec,
    output logic [23:0] v_pc,
    output logic [47:0] v_op,
    input  logic        v_pm_we,
    input  logic [14:0] v_pm_addr,
    input  logic [47:0] v_pm_wdata,
    input  logic        v_we,
    input  logic [7:0]  v_wsel,
    input  logic [5:0]  v_widx,
    input  logic [63:0] v_wdata,
    output logic [31:0] v_r [16],
    output logic [31:0] v_i [16],
    output logic [31:0] v_m [16],
    output logic [31:0] v_astat, v_stky, v_mode1, v_curlcntr, v_lcntr, v_pcstk, v_pcstkp, v_lstkp
);
    m2b_sharc #(.MAME_RND(MAME_RND), .BENCH(1'b1)) u (
        .clk, .reset, .run, .host_iop_we, .host_iop_reg, .host_iop_data, .xdma_we, .xdma_phase, .xdma_data,
        .fin_empty, .fin_data, .fin_pop, .fout_full, .fout_push, .fout_data, .flag_out(),
        .ext_req, .ext_we, .ext_addr, .ext_wdata, .ext_ack, .ext_rdata,
        .unsup, .unsup_pc, .unsup_op, .unsup_why, .dbg_ret, .dbg_pc, .dbg_op, .dbg_st);
    assign o_r = u.rf;
    assign o_i = u.ir;
    assign o_m = u.mr;
    assign o_astat = u.astat;
    assign o_stky = u.stky;
    assign o_mode1 = u.mode1;
    assign o_curlcntr = u.S.curlcntr;
    assign o_lcntr = u.S.lcntr;
    assign o_pcstk = u.S.pcstk;
    assign o_pcstkp = u.S.pcstkp;
    assign o_lstkp = u.S.lstkp;
    assign o_daddr = u.S.daddr;
    assign o_xpc = u.x_pc;

    generate if (LOCK) begin : g_v1
        sharc_core #(.PM_WORDS(8192), .DM_WORDS(32768), .MAN(!MAME_RND)) v (
            .clk, .reset, .ce(v_ce), .boot(1'b0), .flag_in(v_flag),
            .ext_req(v_ext_req), .ext_we(v_ext_we), .ext_addr(v_ext_addr), .ext_wdata(v_ext_wdata),
            .ext_ack(v_ext_ack), .ext_rdata(v_ext_rdata),
            .irq_in(3'b000), .irq_assert(3'b000), .irq_check_en(1'b0), .dbg_irq_set(32'h0),
            .dbg_exec(v_exec), .dbg_pc(v_pc), .dbg_op(v_op), .dbg_sel(6'd0), .dbg_val(), .dbg_idle(),
            .dbg_pm_we(v_pm_we), .dbg_pm_addr(v_pm_addr), .dbg_pm_wdata(v_pm_wdata),
            .dbg_dm_we(1'b0), .dbg_dm_addr(15'h0), .dbg_dm_wdata(32'h0),
            .dbg_we(v_we), .dbg_wsel(v_wsel), .dbg_widx(v_widx), .dbg_wdata(v_wdata));
        for (genvar k = 0; k < 16; k++) begin : g_r
            assign v_r[k] = v.S.r[k];
        end
        for (genvar k = 0; k < 8; k++) begin : g_dag
            assign v_i[k] = v.S.i1[k];
            assign v_i[8 + k] = v.S.i2[k];
            assign v_m[k] = v.S.m1[k];
            assign v_m[8 + k] = v.S.m2[k];
        end
        assign v_astat = v.S.astat;
        assign v_stky = v.S.stky;
        assign v_mode1 = v.S.mode1;
        assign v_curlcntr = v.S.curlcntr;
        assign v_lcntr = v.S.lcntr;
        assign v_pcstk = v.S.pcstk;
        assign v_pcstkp = v.S.pcstkp;
        assign v_lstkp = v.S.lstkp;
    end else begin : g_nov1
        assign v_ext_req = 1'b0; assign v_ext_we = 1'b0; assign v_ext_addr = 32'h0; assign v_ext_wdata = 32'h0;
        assign v_exec = 1'b0; assign v_pc = 24'h0; assign v_op = 48'h0;
        for (genvar k = 0; k < 16; k++) begin : g_z
            assign v_r[k] = 32'h0; assign v_i[k] = 32'h0; assign v_m[k] = 32'h0;
        end
        assign v_astat = 32'h0; assign v_stky = 32'h0; assign v_mode1 = 32'h0; assign v_curlcntr = 32'h0;
        assign v_lcntr = 32'h0; assign v_pcstk = 32'h0; assign v_pcstkp = 32'h0; assign v_lstkp = 32'h0;
    end endgenerate
endmodule
