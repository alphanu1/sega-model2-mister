// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- R1027: the 2B SHARC (m2b_sharc) for the replay and
// lockstep benches. With LOCK, Hornet's v1 (sim/sharc/ref, MAME's interpreter transcribed) runs
// beside it on its own copy of the FIFOs; the C++ compares them word by word.
module tb_m2b_sharc #(
    parameter bit MAME_RND = 1'b1,
    parameter bit LOCK = 1'b0,
    parameter bit RF_ONES = 1'b0,
    parameter bit PXIM = 1'b1,         // R1038: m2b_sharc PXIM (0 = the 2B build's: no PX / IMASK)
    parameter bit SKLR = 1'b1,         // R1039: m2b_sharc SKLR (0 = the 2B build's: no STKY / CURLCNTR / LCNTR reads)
    // R1042: m2b_sharc PMB1_MAME (1: a block-1 PM-bus word as MAME's pm_r<1>, to compare with a
    // MAME capture; 0: the manual's, as v1); v1's MAN_ORD (1: type 1's DM access first, the core's)
    parameter bit PMB1_MAME = 1'b0,
    parameter bit MAN_ORD = 1'b1,
    // R1031: the core's on-chip block-1 words and the DM cache's shape (m2b_xbus / m2b_dmc); a
    // small DM_AW sends Dead or Alive's data words through the cache and the C++ SDRAM model
    parameter int DM_AW = 13,
    parameter int LN_AW = 6,
    parameter int WD_AW = 4
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
    // R1031: the board's side of the external bus (m2b_xbus): the DM page, buffer RAM / ROM
    output logic        o_busy,
    output logic        sdm_req, sdm_we,
    output logic [15:0] sdm_addr, sdm_din,
    input  logic        sdm_ack,
    input  logic [31:0] sdm_dout,
    output logic        dat_req, dat_is_buf, dat_hi,
    output logic [19:0] dat_addr,
    input  logic        dat_ack,
    input  logic [31:0] dat_rdata,
    output logic        bufw_req,
    output logic [18:0] bufw_addr,
    output logic [15:0] bufw_data,
    input  logic        bufw_ack,
    output logic        o_fill, o_wait, o_dm_acc, o_dm_wr,
    output logic        unsup,
    output logic [23:0] unsup_pc,
    output logic [47:0] unsup_op,
    output logic [3:0]  unsup_why,
    output logic        dbg_ret,
    output logic [23:0] dbg_pc,
    output logic [47:0] dbg_op,
    output logic [2:0]  dbg_st,
    output logic        o_rf2w,             // R1028: two R-file writes in this clock (a statistic)
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
    logic        ext_req, ext_we, ext_ack;
    logic [31:0] ext_addr, ext_wdata, ext_rdata;
    m2b_sharc #(.MAME_RND(MAME_RND), .DM_AW(DM_AW), .BENCH(1'b1), .RF_ONES(RF_ONES), .PXIM(PXIM), .SKLR(SKLR), .PMB1_MAME(PMB1_MAME)) u (
        .clk, .reset, .run(run && !o_busy), .host_iop_we, .host_iop_reg, .host_iop_data, .xdma_we, .xdma_phase, .xdma_data,
        .fin_empty, .fin_data, .fin_pop, .fout_full, .fout_push, .fout_data, .flag_out(),
        .ext_req, .ext_we, .ext_addr, .ext_wdata, .ext_ack, .ext_rdata,
        .unsup, .unsup_pc, .unsup_op, .unsup_why, .dbg_ret, .dbg_pc, .dbg_op, .dbg_st, .obs_pc());
    m2b_xbus #(.DM_AW(DM_AW), .LN_AW(LN_AW), .WD_AW(WD_AW), .BENCH(1'b1)) u_x (
        .clk, .reset, .busy(o_busy),
        .ext_req, .ext_we, .ext_addr, .ext_wdata, .ext_ack, .ext_rdata,
        .dat_req, .dat_addr, .dat_is_buf, .dat_hi, .dat_ack, .dat_rdata,
        .bufw_req, .bufw_addr, .bufw_data, .bufw_ack, .wq_busy(),
        .sdm_req, .sdm_we, .sdm_addr, .sdm_din, .sdm_ack, .sdm_dout,
        .st_fill(o_fill), .st_wait(o_wait));
    assign o_dm_acc = u_x.u_dmc.c_ack;
    assign o_dm_wr  = u_x.u_dmc.c_ack && ext_we;
    assign o_r = u.g_rf[0].u.mem;               // R0-R15: the MLAB model (port A's copy)
    assign o_i = u.u_iu.mem;
    assign o_m = u.u_mu.mem;
    assign o_rf2w = u.rf_pw;
    assign o_astat = u.astat;
    assign o_stky = u.stky;
    assign o_mode1 = u.mode1;
    assign o_curlcntr = u.S_dbg.curlcntr;
    assign o_lcntr = u.S_dbg.lcntr;
    assign o_pcstk = u.S_dbg.pcstk;
    assign o_pcstkp = u.S_dbg.pcstkp;
    assign o_lstkp = u.S_dbg.lstkp;
    assign o_daddr = u.S_dbg.daddr;
    assign o_xpc = u.x_pc;

    generate if (LOCK) begin : g_v1
        sharc_core #(.PM_WORDS(8192), .DM_WORDS(32768), .MAN(!MAME_RND), .MAN_ORD(MAN_ORD)) v (
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
