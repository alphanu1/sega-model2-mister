// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE for the full text.
//
// ---------------------------------------------------------------------------
//
// i960KB integration top — the eight P1 blocks wired together by a multi-cycle
// sequencer, with one arbitrated bus port.
//
// WHAT THIS IS, AND WHAT IT IS NOT.
//
// It is a real structural integration: every block is connected the way it will
// really be connected, every port is driven, and nothing dangles — so the
// fitter sees representative loading and the area and Fmax numbers mean
// something. Model 1's M0 recorded that no individual block was near the
// assembled core's Fmax and that "the critical path is created by assembly",
// which is precisely the thing a per-module measurement cannot show.
//
// It is NOT the design docs/p1-i960-spike.md §4.4 requires. That section is
// unambiguous: a multi-cycle FSM needs 123-164 MHz to hit the i960's throughput
// and does not close. This sequencer is multi-cycle. Its purpose is to connect
// the blocks, expose the assembled critical path, and be the skeleton the
// pipeline replaces — not to meet the CPI target.
//
// Instruction coverage is deliberately partial and traps loudly rather than
// guessing: REG 0x58-0x5b through the ALU, the MEM load/store forms, CTRL
// branches with call and ret, and COBR conditional branches. Everything else
// raises `trap` with the opcode latched, which is the same discipline the
// blocks use for what the reference reaches fatalerror on.

module i960_top (
  input  logic        clk,
  input  logic        rst_n,

  // One 32-bit bus port, arbitrated between instruction fetch and data.
  output logic        bus_req,
  output logic        bus_we,
  output logic [31:0] bus_addr,
  output logic [3:0]  bus_be,
  output logic [31:0] bus_wdata,
  input  logic [31:0] bus_rdata,
  input  logic        bus_ack,

  // Observability. These exist so the design has real outputs and cannot be
  // optimised away, and because the screen is the only output channel this
  // project will ever have on hardware.
  output logic [31:0] dbg_ip,
  output logic [31:0] dbg_insn,
  output logic        trap,
  output logic [7:0]  trap_op,
  output logic        halted
);

  // ------------------------------------------------------------ architectural

  logic [31:0] ip, ip_next, insn, disp_word;

  assign dbg_ip   = ip;
  assign dbg_insn = insn;

  // ------------------------------------------------------------------ decode
  //
  // Several sub-module outputs are not consumed at this level, and the reasons
  // differ. The suppression below is scoped to these declarations rather than
  // set globally, and each group is listed, because an unused signal is
  // normally a field extracted and forgotten.
  //
  //  * d_memb, d_memb_mode, d_abase, d_index, d_scale, d_mema_offset,
  //    d_mema_rel, agu_needs_disp — the AGU consumes the same instruction bits
  //    directly, so the decoder's copies are redundant AT THIS LEVEL. They stay
  //    on the decoder because a pipelined front end will latch them there
  //    rather than re-derive them in the address stage.
  //
  //  * d_dst_lit — a literal destination is illegal and should raise a fault.
  //    Fault handling is not built (§1 excludes fault-on-FAULT), so this is
  //    genuinely pending work, not redundancy.
  //
  //  * ls_load, ls_unaligned, lsu_busy, ic_busy — status the multi-cycle
  //    sequencer does not need because it waits on `done`/`valid` instead. A
  //    pipeline will need all four.
  //
  //  * ls_ldres, ls_stdata, ls_stbe — DUPLICATION, and worth fixing. i960_lsu
  //    performs its own sign extension and lane placement because the unaligned
  //    path has to assemble bytes itself, which left i960_ldst's data path with
  //    no consumer. One of the two should own it. Recorded rather than papered
  //    over; see the spike document.
  /* verilator lint_off UNUSEDSIGNAL */

  logic [1:0]  d_fmt;
  logic [7:0]  d_op;
  logic [3:0]  d_op2;
  logic        d_valid, d_len2;
  logic [4:0]  d_src1, d_src2, d_srcdst;
  logic        d_src1_lit, d_src2_lit, d_dst_lit;
  logic        d_memb, d_mema_rel, d_memb_bad;
  logic [3:0]  d_memb_mode;
  logic [4:0]  d_abase, d_index;
  logic [2:0]  d_scale;
  logic [12:0] d_mema_offset;
  logic [31:0] d_disp;
  /* verilator lint_on UNUSEDSIGNAL */

  typedef enum logic [3:0] {
    T_FETCH, T_FETCH_W, T_FETCH2, T_FETCH2_W, T_DECODE,
    T_EXEC, T_MEM, T_MEM_W, T_MULDIV, T_MULTI, T_PAIR, T_FP, T_WB, T_FRAME,
    T_TRAP
  } tstate_e;

  tstate_e ts;

  // One decoder reads the word ARRIVING during a fetch state (u_dec_in), the
  // other reads the latched word (u_dec). This is what removes T_DECODE: the
  // register numbers, the trap check and the prefetch decision are all
  // available in the cycle the instruction lands, so fetch goes straight to
  // execute. Even at a 100% prefetch hit rate the old FETCH -> DECODE -> EXEC
  // walk could not beat 3 CPI, and 3 CPI at 27.44 MHz is 9.15 M instr/s against
  // a 12.5 M floor.
  //
  // T_DECODE is retained in the enum but is now unreachable; the state numbers
  // are load-bearing for the harness profile, so renumbering them would
  // silently relabel every measurement taken so far.
  //
  // TWO decoders, not one muxed decoder, and the reason is a measured false
  // path. Selecting the decoder input with `(ts == T_FETCH) ? fetch_word : insn`
  // creates a static path ip -> (pf_ip == ip) -> dec_in -> decode -> ALU -> wd.
  // No cycle ever uses it -- during T_EXEC the decoder reads the latched word --
  // but static timing does not know that, and it became the critical path at
  // ip[26] -> wd[13] with NEGATIVE slack, costing 27.44 -> 24.63 MHz.
  //
  // A second decoder costs ~103 ALM and removes the path outright: the
  // arriving-word decode feeds only the register numbers and the front-end
  // decisions, and never reaches writeback. Cheaper than an SDC false-path
  // exception, and it cannot rot -- a constraint that stops being true fails
  // silently, whereas this is structural.
  logic        fetch_word_ok;
  logic [31:0] fetch_word;

  logic [1:0]  f_fmt;
  logic [7:0]  f_op;
  logic        f_valid, f_len2, f_memb_bad;
  logic [4:0]  f_src1, f_src2, f_srcdst;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [3:0]  f_op2, f_memb_mode;
  logic        f_src1_lit, f_src2_lit, f_dst_lit, f_memb, f_mema_rel;
  logic [4:0]  f_abase, f_index;
  logic [2:0]  f_scale;
  logic [12:0] f_mema_offset;
  logic [31:0] f_disp;
  /* verilator lint_on UNUSEDSIGNAL */

  i960_dec u_dec_in (
    .insn(fetch_word), .fmt(f_fmt), .op(f_op), .op2(f_op2), .valid(f_valid),
    .insn_len2(f_len2), .src1(f_src1), .src2(f_src2), .srcdst(f_srcdst),
    .src1_lit(f_src1_lit), .src2_lit(f_src2_lit), .dst_lit(f_dst_lit),
    .memb(f_memb), .memb_mode(f_memb_mode), .abase(f_abase), .index(f_index),
    .scale(f_scale), .mema_rel(f_mema_rel), .mema_offset(f_mema_offset),
    .memb_bad(f_memb_bad), .disp(f_disp)
  );

  i960_dec u_dec (
    .insn(insn), .fmt(d_fmt), .op(d_op), .op2(d_op2), .valid(d_valid),
    .insn_len2(d_len2), .src1(d_src1), .src2(d_src2), .srcdst(d_srcdst),
    .src1_lit(d_src1_lit), .src2_lit(d_src2_lit), .dst_lit(d_dst_lit),
    .memb(d_memb), .memb_mode(d_memb_mode), .abase(d_abase), .index(d_index),
    .scale(d_scale), .mema_rel(d_mema_rel), .mema_offset(d_mema_offset),
    .memb_bad(d_memb_bad), .disp(d_disp)
  );

  // ----------------------------------------------------------- register file

  logic [4:0]  ra1, ra2, wa;

  // Read addresses are COMBINATIONAL, driven one state ahead of the consumer,
  // because i960_regs now registers its read. Each address below sits in the
  // state before the one that uses the data, which is exactly where the old
  // registered assignments sat -- the expressions are unchanged, only the cycle
  // they take effect. The register file supplies the delay that the sequencer
  // used to.
  //
  // The address must also stay STABLE for as long as its data is in use, not
  // merely for the cycle that issues it: rd1 re-registers every cycle, so a
  // moving address silently replaces the operand under a multi-cycle consumer.
  // That is why T_MEM_W holds the store source and why the default is d_src1 --
  // it keeps the operand steady across T_EXEC, T_FP and T_MULDIV.
  logic [31:0] rd1, rd2, wd;
  logic        we;
  logic        rf_call, rf_ret, rf_flush, rf_busy, rf_ip_valid;
  logic [31:0] rf_next_ip;
  logic        rf_mem_req, rf_mem_we;
  logic [31:0] rf_mem_addr, rf_mem_wdata;

  i960_regs u_regs (
    .clk(clk), .rst_n(rst_n),
    .ra1(ra1), .ra2(ra2), .rd1(rd1), .rd2(rd2),
    .wa(wa), .wd(wd), .we(we),
    .op_call(rf_call), .op_ret(rf_ret), .op_flushreg(rf_flush),
    .call_ip(ip_next), .call_target(alu_or_ea), .call_type(3'd0),
    .call_stack(32'd0),
    .busy(rf_busy), .next_ip(rf_next_ip), .next_ip_valid(rf_ip_valid),
    .mem_req(rf_mem_req), .mem_we(rf_mem_we), .mem_addr(rf_mem_addr),
    .mem_wdata(rf_mem_wdata), .mem_rdata(bus_rdata), .mem_ack(rf_mem_ack)
  );

  // Literal operands: the field is the value, not a register number.
  logic [31:0] src1_val, src2_val;
  assign src1_val = d_src1_lit ? {27'd0, d_src1} : rd1;
  assign src2_val = d_src2_lit ? {27'd0, d_src2} : rd2;

  // COBR operands use different fields and a different literal bit from REG:
  //   get_1_ci  bit 13 selects literal, field (insn>>19)&0x1f
  //   get_2_ci  always a register,      field (insn>>14)&0x1f
  // The register file is read with ra1 = srcdst for COBR, so rd1 carries the
  // first operand in both formats and only the literal test differs.
  logic [31:0] ci1_val, ci2_val;
  assign ci1_val = d_dst_lit ? {27'd0, d_srcdst} : rd1;
  assign ci2_val = rd2;

  // The compare is routed through the ALU rather than duplicated here: 0x5a.0
  // is cmpo (unsigned) and 0x5a.1 is cmpi (signed), which is exactly what
  // cmpob<cc> and cmpib<cc> need. Sharing it costs two operand muxes and saves
  // a second 32-bit comparator.
  logic        is_cobr_cmp;
  logic [7:0]  alu_op;
  logic [3:0]  alu_op2;
  logic [31:0] alu_s1, alu_s2;

  assign is_cobr_cmp = (d_fmt == 2'd1) &&
                       ((d_op >= 8'h31 && d_op <= 8'h36) ||
                        (d_op >= 8'h39 && d_op <= 8'h3e));
  assign alu_op  = is_cobr_cmp ? 8'h5a : d_op;
  assign alu_op2 = is_cobr_cmp ? (d_op[3] ? 4'd1 : 4'd0) : d_op2;  // 0x39+ signed
  assign alu_s1  = is_cobr_cmp ? ci1_val : src1_val;
  assign alu_s2  = is_cobr_cmp ? ci2_val : src2_val;

  // ---------------------------------------------------------------- ALU

  logic [31:0] alu_result, ac, alu_ac;
  logic        alu_we, alu_valid;

  i960_alu u_alu (
    .op(alu_op), .op2(alu_op2), .src1(alu_s1), .src2(alu_s2), .ac_in(ac),
    .result(alu_result), .result_we(alu_we), .ac_out(alu_ac), .valid(alu_valid)
  );

  // ------------------------------------------------------- multiply/divide
  //
  // 0x70, 0x74 and 0x67 do not go through the ALU: they are multi-cycle and
  // claim DSP blocks. `md_valid` is checked before `alu_valid` in execute,
  // because the ALU reports these opcodes as invalid.

  /* verilator lint_off UNUSEDSIGNAL */
  logic        md_req, md_busy, md_done, md_valid, md_pair;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] md_lo, md_hi;

  i960_muldiv u_muldiv (
    .clk(clk), .rst_n(rst_n),
    .req(md_req), .op(d_op), .op2(d_op2),
    .src1(src1_val), .src2(src2_val), .src2_hi(32'd0),
    .busy(md_busy), .done(md_done),
    .res_lo(md_lo), .res_hi(md_hi), .res_pair(md_pair), .valid(md_valid)
  );

  // ------------------------------------------------------------------ FPU
  //
  // Single-precision (`r`) forms only for now. The `rl` forms read and write
  // register PAIRS, which needs four register reads against the file's two
  // ports and therefore its own fetch sequence — flagged rather than
  // half-wired, the same way emul/ediv were before the pair writes existed.
  //
  // Operand rules, from get_1_rif / get_2_rif:
  //   bit 11 / bit 12 clear -> a general register, reinterpreted as single
  //   set                   -> index < 4 selects fp0-fp3, 0x16 means 1.0,
  //                            anything else means 0.0

  logic [63:0] fpr [0:3];                        // fp0-fp3, 64-bit per §8

  logic [63:0] fp_a_wide, fp_b_wide, fp_res_wide;
  logic [31:0] fp_res_single;

  i960_fpcvt u_cvt_a (.s_in(rd1), .d_out(fp_a_wide),
                      .d_in(fp_res_wide), .s_out(fp_res_single));
  // Only the widening half of this instance is used — the narrowing path
  // belongs to u_cvt_a, which sees the result. Named explicitly rather than
  // left empty so the intent is visible.
  i960_fpcvt u_cvt_b (.s_in(rd2), .d_out(fp_b_wide),
                      .d_in(64'd0), .s_out(cvt_b_dead));

  function automatic logic [63:0] fp_lit(input logic [4:0] idx,
                                         input logic [63:0] fpsel);
    if (idx < 5'd4)        fp_lit = fpsel;
    else if (idx == 5'h16) fp_lit = 64'h3ff0_0000_0000_0000;   // 1.0
    else                   fp_lit = 64'd0;
  endfunction

  logic [63:0] fp_a, fp_b;
  assign fp_a = d_src1_lit ? fp_lit(d_src1, fpr[d_src1[1:0]]) : fp_a_wide;
  assign fp_b = d_src2_lit ? fp_lit(d_src2, fpr[d_src2[1:0]]) : fp_b_wide;

  logic        fadd_req, fadd_done, fmul_req, fmul_done;
  // busy is not consulted: the sequencer waits on `done` and issues nothing
  // else meanwhile, so there is no second requester to arbitrate against.
  /* verilator lint_off UNUSEDSIGNAL */
  logic        fdiv_req, fdiv_done, fdiv_busy;
  logic        fsqrt_req, fsqrt_done, fsqrt_busy;
  logic [31:0] cvt_b_dead;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [63:0] fadd_y, fmul_y, fdiv_y, fsqrt_y, fmisc_y;
  logic [31:0] fmisc_yi;
  logic [2:0]  fmisc_cc;
  logic        fadd_sub;

  i960_fpadd  u_fpadd  (.clk(clk), .rst_n(rst_n), .req(fadd_req),
                        .sub(fadd_sub), .a(fp_b), .b(fp_a),
                        .y(fadd_y), .done(fadd_done));
  i960_fpmul  u_fpmul  (.clk(clk), .rst_n(rst_n), .req(fmul_req),
                        .a(fp_b), .b(fp_is_scale ? pow2 : fp_a),
                        .y(fmul_y), .done(fmul_done));
  i960_fpdiv  u_fpdiv  (.clk(clk), .rst_n(rst_n), .req(fdiv_req),
                        .a(fp_b), .b(fp_a), .y(fdiv_y),
                        .busy(fdiv_busy), .done(fdiv_done));
  i960_fpsqrt u_fpsqrt (.clk(clk), .rst_n(rst_n), .req(fsqrt_req),
                        .a(fp_a), .y(fsqrt_y),
                        .busy(fsqrt_busy), .done(fsqrt_done));

  // scaler takes its FP operand from src2 and its integer from src1, unlike
  // every other fpmisc operation which reads src1. Feeding it fp_a silently
  // scaled the wrong value.
  logic fp_is_scale;
  assign fp_is_scale = (d_op == 8'h67) && (d_op2 == 4'h7);

  // scaler is `t2f * pow(2.0, n)` in the reference — a genuine multiply, not an
  // exponent add. The difference shows when pow overflows: 0 * inf is NaN,
  // where adding to the exponent returns zero. So 2^n is materialised as a
  // double and pushed through the multiplier, which already handles every
  // special case correctly.
  logic signed [12:0] pow2_exp;
  logic [63:0]        pow2;
  assign pow2_exp = $signed(src1_val[12:0]) + 13'sd1023;
  assign pow2 = ($signed(src1_val) >  32'sd1023) ? {1'b0, 11'h7ff, 52'd0}
              : ($signed(src1_val) < -32'sd1074) ? 64'd0
              : (pow2_exp >= 13'sd2047)          ? {1'b0, 11'h7ff, 52'd0}
              : (pow2_exp <= 13'sd0)             ? 64'd0
                                                 : {1'b0, pow2_exp[10:0], 52'd0};

  logic [2:0] fmisc_op;
  assign fp_res_wide = fp_is_add  ? fadd_y
                     : fp_is_mul  ? fmul_y
                     : fp_is_div  ? fdiv_y
                     : fp_is_sqrt ? fsqrt_y
                                  : fmisc_y;
  i960_fpmisc u_fpmisc (.op(fmisc_op), .rmode(ac[31:30]),
                        .a(fp_a), .b(fp_b), .ai(src1_val),
                        .y(fmisc_y), .yi(fmisc_yi), .cc(fmisc_cc));

  // Which unit an opcode belongs to, and whether it is wired at all.
  logic fp_is_add, fp_is_mul, fp_is_div, fp_is_sqrt, fp_is_misc, fp_valid;
  always_comb begin
    fp_is_add = 1'b0; fp_is_mul = 1'b0; fp_is_div = 1'b0;
    fp_is_sqrt = 1'b0; fp_is_misc = 1'b0; fadd_sub = 1'b0;
    fmisc_op = 3'd7;
    case (d_op)
      8'h78: case (d_op2)                        // single-precision arithmetic
               4'hf: fp_is_add = 1'b1;                              // addr
               4'hd: begin fp_is_add = 1'b1; fadd_sub = 1'b1; end   // subr
               4'hc: fp_is_mul = 1'b1;                              // mulr
               4'hb: fp_is_div = 1'b1;                              // divr
               default: ;
             endcase
      8'h68: case (d_op2)
               4'h5: begin fp_is_misc = 1'b1; fmisc_op = 3'd0; end  // cmpr
               4'h8: fp_is_sqrt = 1'b1;                             // sqrtr
               4'ha: begin fp_is_misc = 1'b1; fmisc_op = 3'd1; end  // logbnr
               4'hb: begin fp_is_misc = 1'b1; fmisc_op = 3'd5; end  // roundr
               default: ;
             endcase
      8'h6c: case (d_op2)
               4'h0: begin fp_is_misc = 1'b1; fmisc_op = 3'd3; end  // cvtri
               4'h2: begin fp_is_misc = 1'b1; fmisc_op = 3'd4; end  // cvtzri
               4'h9: begin fp_is_misc = 1'b1; fmisc_op = 3'd7; end  // movr
               default: ;
             endcase
      8'h67: case (d_op2)
               4'h4: begin fp_is_misc = 1'b1; fmisc_op = 3'd2; end  // cvtir
               4'h7: fp_is_mul = 1'b1;                              // scaler
               default: ;
             endcase
      default: ;
    endcase
    fp_valid = fp_is_add | fp_is_mul | fp_is_div | fp_is_sqrt | fp_is_misc;
  end

  // cmpr writes only the condition code; cvtri and cvtzri write an integer;
  // everything else writes a float through the narrowing path.
  logic fp_writes_int, fp_writes_cc;
  assign fp_writes_cc  = fp_is_misc && (fmisc_op == 3'd0);
  assign fp_writes_int = fp_is_misc && ((fmisc_op == 3'd3) || (fmisc_op == 3'd4));

  // ---------------------------------------------------------------- AGU

  logic [31:0] ea;
  /* verilator lint_off UNUSEDSIGNAL */
  logic        agu_needs_disp, agu_valid;
  /* verilator lint_on UNUSEDSIGNAL */

  i960_agu u_agu (
    .insn(insn[13:0]), .abase_val(rd2), .index_val(rd1),
    .disp_word(disp_word), .ip_after_disp(ip + 32'd8),
    .ea(ea), .needs_disp(agu_needs_disp), .valid(agu_valid)
  );

  logic [31:0] alu_or_ea;
  assign alu_or_ea = (d_fmt == 2'd3) ? ea : (ip_next + d_disp);   // call target

  // ------------------------------------------------------------- load/store

  /* verilator lint_off UNUSEDSIGNAL */
  logic        ls_load, ls_store, ls_nomem, ls_sext, ls_valid, ls_unaligned;
  logic [1:0]  ls_size;
  logic [2:0]  ls_nwords;
  logic [4:0]  ls_regmask;
  logic [31:0] ls_ldres, ls_stdata;
  logic [3:0]  ls_stbe;
  /* verilator lint_on UNUSEDSIGNAL */

  i960_ldst u_ldst (
    .op(d_op), .is_load(ls_load), .is_store(ls_store), .no_mem(ls_nomem),
    .size(ls_size), .sign_ext(ls_sext), .n_words(ls_nwords),
    .reg_mask(ls_regmask), .valid(ls_valid),
    .addr_lo(ea[1:0]), .rd_data(bus_rdata), .ld_result(ls_ldres),
    .st_value(rd1), .st_data(ls_stdata), .st_be(ls_stbe),
    .unaligned(ls_unaligned)
  );

  logic mm_burst;
  i960_memmap u_memmap (.addr(ea), .is_burst(mm_burst));

  /* verilator lint_off UNUSEDSIGNAL */
  logic        lsu_req, lsu_busy, lsu_done, lsu_ldwe;
  logic [2:0]  lsu_curidx;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [2:0]  lsu_widx;
  logic [31:0] lsu_ldword;
  logic        lsu_breq, lsu_bwe;
  logic [31:0] lsu_baddr, lsu_bwdata;
  logic [3:0]  lsu_bbe;

  i960_lsu u_lsu (
    .clk(clk), .rst_n(rst_n),
    .req(lsu_req), .addr(ea), .size(ls_size), .n_words(ls_nwords),
    .is_store(ls_store), .sign_ext(ls_sext), .is_burst(mm_burst),
    .busy(lsu_busy), .done(lsu_done), .cur_idx(lsu_curidx),
    .word_idx(lsu_widx), .st_word(rd1), .ld_word(lsu_ldword), .ld_we(lsu_ldwe),
    .bus_req(lsu_breq), .bus_we(lsu_bwe), .bus_addr(lsu_baddr),
    .bus_be(lsu_bbe), .bus_wdata(lsu_bwdata),
    .bus_rdata(bus_rdata), .bus_ack(lsu_back)
  );

  // ---------------------------------------------------------------- I-cache

  /* verilator lint_off UNUSEDSIGNAL */
  logic        ic_req, ic_valid, ic_busy, ic_breq;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] ic_data, ic_baddr;

  i960_icache u_icache (
    .clk(clk), .rst_n(rst_n), .inval(1'b0),
    .req(ic_req), .addr(fetch_addr[31:2]), .data(ic_data),
    .valid(ic_valid), .busy(ic_busy),
    .bus_req(ic_breq), .bus_addr(ic_baddr),
    .bus_rdata(bus_rdata), .bus_ack(ic_back)
  );

  // Low two bits unused: the I-cache port is [31:2] because instructions are
  // dword-aligned.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] fetch_addr;
  /* verilator lint_on UNUSEDSIGNAL */

  // ------------------------------------------------------------- bus arbiter
  //
  // Data before instruction. An instruction fetch can always be retried; a
  // data access in progress cannot be abandoned without losing the transaction.
  // Register-file spill outranks both because it is mid-frame-operation.

  logic rf_mem_ack, lsu_back, ic_back;

  always_comb begin
    bus_req   = 1'b0;
    bus_we    = 1'b0;
    bus_addr  = 32'd0;
    bus_be    = 4'b1111;
    bus_wdata = 32'd0;
    rf_mem_ack = 1'b0;
    lsu_back   = 1'b0;
    ic_back    = 1'b0;

    if (rf_mem_req) begin
      bus_req = 1'b1; bus_we = rf_mem_we; bus_addr = rf_mem_addr;
      bus_wdata = rf_mem_wdata; bus_be = 4'b1111;
      rf_mem_ack = bus_ack;
    end else if (lsu_breq) begin
      bus_req = 1'b1; bus_we = lsu_bwe; bus_addr = lsu_baddr;
      bus_wdata = lsu_bwdata; bus_be = lsu_bbe;
      lsu_back = bus_ack;
    end else if (ic_breq) begin
      bus_req = 1'b1; bus_we = 1'b0; bus_addr = ic_baddr; bus_be = 4'b1111;
      ic_back = bus_ack;
    end
  end

  // -------------------------------------------------- multi-word reg writes
  //
  // movl, movt and movq copy 2, 3 or 4 consecutive registers; emul and ediv
  // write a pair. The register file has one write port, so these take a cycle
  // per word.
  //
  // The destination masks differ and are NOT uniform:
  //   movl  (srcdst & 0x1e)      movt, movq  (srcdst & 0x1c)
  //   emul, ediv  (srcdst & 0x1f) — unmasked
  //
  // Unmasked means `emul` with srcdst = 31 writes r[32], one past the end of
  // the reference's 32-entry array. That is a buffer overrun in the reference
  // and therefore undefined; the harness never generates it, the same way it
  // never generates a zero divisor. Here the index simply wraps.
  //
  // The SOURCE of a mov is not masked either — `opcode & 0x1f` — so a
  // misaligned source with an aligned destination is legal and must work.
  logic [2:0]  mw_n, mw_i;
  logic [4:0]  mw_base, mw_src;
  logic        mw_lit;
  logic [31:0] mw_litval;

  logic [4:0]  mov_base;
  logic [2:0]  mov_n;
  always_comb begin
    case (d_op)
      8'h5d:   begin mov_base = d_srcdst & 5'h1e; mov_n = 3'd2; end   // movl
      8'h5e:   begin mov_base = d_srcdst & 5'h1c; mov_n = 3'd3; end   // movt
      default: begin mov_base = d_srcdst & 5'h1c; mov_n = 3'd4; end   // movq
    endcase
  end

  logic is_movx;
  assign is_movx = (d_fmt == 2'd2) && (d_op2 == 4'hc) &&
                   (d_op == 8'h5d || d_op == 8'h5e || d_op == 8'h5f);

  // --------------------------------------------------------------- prefetch
  //
  // Measured: instruction fetch was 58% of all cycles, and 53% even after the
  // I-cache fill was fixed. On a hit the path still costs three cycles —
  // T_FETCH to issue, then two in T_FETCH_W because the cache registers its
  // read and then asserts valid. Execute is one cycle.
  //
  // So the request for the NEXT instruction is issued during decode of the
  // current one, predicting sequential. By the time execute retires, a hit has
  // landed and the sequencer goes straight back to decode, skipping both fetch
  // states entirely. A taken branch discards the prefetch and refetches — the
  // cost of a misprediction is exactly the fetch this scheme was avoiding, so
  // the worst case is today's behaviour.
  //
  // Eight-byte instructions use the cache port in decode for their
  // displacement word, so they do not prefetch and fall back to T_FETCH.
  logic [31:0] pf_insn, pf_ip;
  logic        pf_valid, pf_armed, pf_issued;

  // ------------------------------------------------------------- sequencer


  // Which instruction word, if any, is arriving this cycle. Split out of the
  // sequencer so the decoder can see it (dec_in) and so both fetch states share
  // one definition of "the word landed".
  //
  // `pf_ip` is compared against the actual IP rather than trusted, so a taken
  // branch or any redirect falls back automatically. Two ways a prediction can
  // be good: already latched, or landing this very cycle -- `ic_req` is
  // registered, so a prefetch issued alongside execute has its `valid` arrive
  // exactly here, one cycle after a latched-only check would catch it. Checking
  // only the latched copy misses every hit and the prefetch does nothing, which
  // is precisely what the first version measured.
  always_comb begin
    fetch_word_ok = 1'b0;
    fetch_word    = ic_data;
    case (ts)
      T_FETCH: begin
        if (pf_valid && (pf_ip == ip)) begin
          fetch_word_ok = 1'b1;
          fetch_word    = pf_insn;
        end else if (pf_armed && ic_valid && (pf_ip == ip)) begin
          fetch_word_ok = 1'b1;
        end
      end
      T_FETCH_W: fetch_word_ok = ic_valid;
      default: ;
    endcase
  end

  // Read-address drive. See the note at the ra1/ra2 declaration: each case is
  // the state BEFORE the consumer, and the expressions are the ones the
  // registered assignments used.
  always_comb begin
    ra1 = d_src1;
    ra2 = d_src2;
    case (ts)
      // COBR reads (insn>>19) on port 1; REG and MEM read src1 there. Driven
      // from the arriving word, so rd1/rd2 are valid when T_EXEC begins.
      T_FETCH, T_FETCH_W: begin
        ra1 = (f_fmt == 2'd1) ? f_srcdst : f_src1;
        ra2 = f_src2;
      end
      T_FETCH2_W: ra1 = (d_fmt == 2'd1) ? d_srcdst : d_src1;
      T_EXEC: begin
        if      (is_movx)        ra1 = d_src1 + 5'd1;   // second word of movl/t/q
        else if (d_fmt == 2'd3)  ra1 = d_srcdst & ls_regmask;  // store source
      end
      // Held, not merely issued: a multi-word store consumes st_value over
      // several cycles and the address must not move under it.
      // Multi-word stores read consecutive registers. Held fixed, every word
      // of an stl/stt/stq wrote the SAME register's value to consecutive
      // addresses -- visible in the data-memory comparison as one value
      // repeated. Only reachable once the generator emitted stores.
      T_MEM, T_MEM_W: ra1 = (d_srcdst & ls_regmask) + {2'd0, lsu_curidx};
      T_MULTI:        ra1 = mw_src + 5'({1'b0, mw_i}) + 5'd1;
      default: ;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ts        <= T_FETCH;
      fpr[0]    <= 64'd0;
      fpr[1]    <= 64'd0;
      fpr[2]    <= 64'd0;
      fpr[3]    <= 64'd0;
      pf_valid  <= 1'b0;
      pf_armed  <= 1'b0;
      pf_issued <= 1'b0;
      pf_insn   <= 32'd0;
      pf_ip     <= 32'd0;
      ip        <= 32'd0;
      ip_next   <= 32'd4;
      insn      <= 32'd0;
      disp_word <= 32'd0;
      ac        <= 32'd0;
      trap      <= 1'b0;
      trap_op   <= 8'd0;
      halted    <= 1'b0;
      ic_req    <= 1'b0;
      lsu_req   <= 1'b0;
      we        <= 1'b0;
      wa        <= 5'd0;
      wd        <= 32'd0;
      rf_call   <= 1'b0;
      rf_ret    <= 1'b0;
      rf_flush  <= 1'b0;
      fetch_addr<= 32'd0;
      fadd_req  <= 1'b0;
      fmul_req  <= 1'b0;
      fdiv_req  <= 1'b0;
      fsqrt_req <= 1'b0;
    end else begin
      ic_req   <= 1'b0;
      lsu_req  <= 1'b0;
      md_req   <= 1'b0;
      // These are one-cycle strobes and were missing from this list. Left
      // asserted, a unit restarts the instant it returns to idle, spins
      // permanently busy, and the NEXT instruction of that type reads `done`
      // from the spurious run rather than its own -- which is how a sqrtr
      // retired without ever writing its FP register.
      fadd_req  <= 1'b0;
      fmul_req  <= 1'b0;
      fdiv_req  <= 1'b0;
      fsqrt_req <= 1'b0;

      // A prefetch issued in decode lands during execute. Capture it wherever
      // the sequencer happens to be.
      // Arm one cycle AFTER issuing, never in the same cycle. `ic_valid` is a
      // pulse, and the front end now issues the prefetch in the very cycle the
      // previous DEMAND fetch's valid is still asserted -- T_DECODE used to sit
      // between them. Arming immediately captured that stale valid and stored
      // the PREVIOUS instruction as the prefetched one; because pf_ip still
      // matched, T_FETCH then accepted it and executed the wrong word.
      //
      // Cost is nothing: the request is registered, so the earliest a genuine
      // valid can arrive is the cycle this makes pf_armed true.
      pf_armed  <= pf_issued;
      pf_issued <= 1'b0;

      if (pf_armed && ic_valid) begin
        pf_insn  <= ic_data;
        pf_valid <= 1'b1;
        pf_armed <= 1'b0;
      end
      we       <= 1'b0;
      rf_call  <= 1'b0;
      rf_ret   <= 1'b0;
      rf_flush <= 1'b0;

      case (ts)
        // T_FETCH and T_FETCH_W share one body. The front end below appears
        // ONCE on purpose: it used to live in T_DECODE, and duplicating it into
        // the prefetch-hit path and the fill path is exactly how those two
        // drift apart without either copy looking wrong.
        T_FETCH, T_FETCH_W: begin
          if (fetch_word_ok) begin
            insn     <= fetch_word;
            pf_valid <= 1'b0;
            pf_armed <= 1'b0;

            // --- what T_DECODE used to do, now in the cycle the word lands ---
            // The decoder is reading the ARRIVING word (see dec_in), so these
            // describe the instruction being latched now, not the previous one.
            if (!f_valid || f_memb_bad) begin
              trap_op <= f_op;
              ts      <= T_TRAP;
            end else if (f_len2) begin
              fetch_addr <= ip + 32'd4;
              ic_req     <= 1'b1;
              ip_next    <= ip + 32'd8;
              ts         <= T_FETCH2_W;
            end else begin
              // Predict sequential and start the next fetch NOW, overlapping it
              // with execute. Eight-byte forms take the branch above and use
              // the cache port for their displacement word instead.
              fetch_addr <= ip + 32'd4;
              ic_req     <= 1'b1;
              ip_next    <= ip + 32'd4;
              pf_ip      <= ip + 32'd4;
              pf_issued  <= 1'b1;
              ts         <= T_EXEC;
            end
          end else if (ts == T_FETCH) begin
            // Issue unconditionally. This waited for `!ic_busy` because the
            // cache ignored requests while filling, so a mispredicted prefetch
            // left a fill in flight for a line nothing wanted and the wait
            // state accepted its stale `valid`. The cache now ABANDONS a fill
            // when a different line is requested, so the request is honoured.
            // Do not restore the guard without removing the abort; they are a
            // pair, and test_i960_icache's redirect pass is what holds the
            // cache to its half of it.
            pf_valid   <= 1'b0;
            pf_armed   <= 1'b0;
            fetch_addr <= ip;
            ic_req     <= 1'b1;
            ts         <= T_FETCH_W;
          end
        end

        T_FETCH2_W: if (ic_valid) begin
          disp_word <= ic_data;
          ts        <= T_EXEC;
        end

        T_EXEC: begin
          case (d_fmt)
            2'd0: begin                                   // CTRL
              case (d_op)
                // The reference advances m_IP past the instruction BEFORE
                // execute_op runs, so `m_IP += get_disp()` is ip_next + disp,
                // not ip + disp. Both this module and its reference model had
                // `ip + d_disp` and agreed with each other, which is exactly
                // why lockstep could not see it.
                8'h08: begin ip <= ip_next + d_disp; ts <= T_FETCH; end   // b
                8'h09: begin rf_call <= 1'b1;   ts <= T_FRAME; end        // call
                8'h0a: begin rf_ret  <= 1'b1;   ts <= T_FRAME; end        // ret
                8'h0b: begin                                              // bal
                  wa <= 5'd30; wd <= ip_next; we <= 1'b1;
                  ip <= ip_next + d_disp; ts <= T_FETCH;
                end
                default: begin
                  if (d_op[7:3] == 5'b00010) begin                        // b<cc>
                    // bxx masks the IP after a taken branch; plain b does not.
                    ip <= (|(ac[2:0] & d_op[2:0]))
                            ? ((ip_next + d_disp) & 32'hffff_fffc) : ip_next;
                    ts <= T_FETCH;
                  end else if (d_op == 8'h18) begin                       // faultno
                    // The reference makes this a conditional BRANCH, not a
                    // fault: `if(!(m_AC & 7)) m_IP += get_disp(opcode);`.
                    // Note it does not mask the IP, unlike bxx.
                    ip <= (~|ac[2:0]) ? (ip_next + d_disp) : ip_next;
                    ts <= T_FETCH;
                  end else if (d_op[7:3] == 5'b00011) begin                // fault<cc>
                    // fxx() reaches fatalerror when the condition holds:
                    //   "Taking the fault on a FAULT insn not yet supported"
                    // and does nothing at all when it does not. §1 scopes the
                    // taken case out, so trap it and fall through otherwise.
                    if (|(ac[2:0] & d_op[2:0])) begin
                      trap_op <= d_op;
                      ts      <= T_TRAP;
                    end else begin
                      ip <= ip_next;
                      ts <= T_FETCH;
                    end
                  end else begin
                    trap_op <= d_op;
                    ts      <= T_TRAP;
                  end
                end
              endcase
            end

            2'd1: begin                                   // COBR
              ts <= T_FETCH;
              if (d_op[7:3] == 5'b00100) begin
                // test<cc>: writes 1 or 0 and does NOT branch. testno (0x20)
                // tests !(AC & 7); the rest test AC & (op & 7).
                wa <= d_srcdst;
                wd <= ((d_op[2:0] == 3'd0) ? (~|ac[2:0]) : (|(ac[2:0] & d_op[2:0])))
                      ? 32'd1 : 32'd0;
                we <= 1'b1;
                ip <= ip_next;
              end else if (d_op == 8'h30 || d_op == 8'h37) begin
                // bbc / bbs: bit test, set the condition code, branch. Note the
                // IP is NOT masked here, unlike bxx_s below — that asymmetry is
                // in the reference and is reproduced rather than tidied.
                if (ci2_val[ci1_val[4:0]] == (d_op == 8'h37)) begin
                  ac <= {ac[31:3], 3'b010};
                  ip <= ip_next + d_disp;
                end else begin
                  ac <= {ac[31:3], 3'b000};
                  ip <= ip_next;
                end
              end else if (is_cobr_cmp) begin
                // cmpob<cc> / cmpib<cc>: compare, THEN branch on the result of
                // that compare — not on whatever AC happened to hold. Missing
                // this was the first defect whole-CPU lockstep found.
                ac <= alu_ac;
                ip <= (|(alu_ac[2:0] & d_op[2:0])) ? ((ip_next + d_disp) & 32'hffff_fffc)
                                                   : ip_next;
              end else begin
                trap_op <= d_op;
                ts      <= T_TRAP;
              end
            end

            2'd2: begin                                   // REG
              if (is_movx) begin
                // First word now; the rest one per cycle. ra1 already holds the
                // source base from decode, so rd1 is live this cycle.
                mw_base   <= mov_base;
                mw_n      <= mov_n;
                mw_src    <= d_src1;
                mw_lit    <= d_src1_lit;
                mw_litval <= {27'd0, d_src1};
                wa <= mov_base;
                wd <= d_src1_lit ? {27'd0, d_src1} : rd1;
                we <= 1'b1;
                mw_i <= 3'd1;
                ts   <= T_MULTI;
              end else if (fp_valid) begin
                // Single-cycle units (fpmisc) still route through T_FP so the
                // writeback path is shared and there is one place that knows
                // how an FP result reaches a register.
                fadd_req  <= fp_is_add;
                fmul_req  <= fp_is_mul;
                fdiv_req  <= fp_is_div;
                fsqrt_req <= fp_is_sqrt;
                ts        <= T_FP;
              end else if (md_valid) begin
                // Multiply, divide, remainder and modulo. Multi-cycle and
                // DSP-backed, so they leave the single-state execute path.
                md_req <= 1'b1;
                ts     <= T_MULDIV;
              end else if (alu_valid) begin
                ac <= alu_ac;
                wa <= d_srcdst; wd <= alu_result; we <= alu_we;
                ip <= ip_next;
                ts <= T_FETCH;
              end else begin
                trap_op <= d_op; ts <= T_TRAP;            // FPU and friends
              end
            end

            default: begin                                // MEM
              if (!ls_valid || !agu_valid) begin
                trap_op <= d_op; ts <= T_TRAP;
              end else if (ls_nomem) begin                // lda
                wa <= d_srcdst; wd <= ea; we <= 1'b1;
                ip <= ip_next; ts <= T_FETCH;
              end else begin
                lsu_req <= 1'b1;
                ts      <= T_MEM_W;
              end
            end
          endcase
        end

        T_MULDIV: if (md_done) begin
          wa <= d_srcdst;
          wd <= md_lo;
          we <= 1'b1;
          if (md_pair) begin
            // emul and ediv write a pair, unmasked.
            mw_base <= d_srcdst;
            ts      <= T_PAIR;
          end else begin
            ip <= ip_next;
            ts <= T_FETCH;
          end
        end

        T_PAIR: begin
          wa <= mw_base + 5'd1;
          wd <= md_hi;
          we <= 1'b1;
          ip <= ip_next;
          ts <= T_FETCH;
        end

        T_MULTI: begin
          wa <= mw_base + {2'd0, mw_i};
          wd <= mw_lit ? mw_litval : rd1;
          we <= 1'b1;
          if (mw_i + 3'd1 >= mw_n) begin
            ip <= ip_next;
            ts <= T_FETCH;
          end else begin
            mw_i <= mw_i + 3'd1;
          end
        end

        T_FP: begin
          // Each unit's done is qualified by whether THIS instruction issued
          // to it. Accepting any unit's done lets a stale strobe from an
          // earlier instruction retire the wrong result — and the multi-cycle
          // units (divide, sqrt) are exactly where that window is wide.
          if (fp_is_misc
              || (fp_is_add  && fadd_done)
              || (fp_is_mul  && fmul_done)
              || (fp_is_div  && fdiv_done)
              || (fp_is_sqrt && fsqrt_done)) begin
            if (fp_writes_cc) begin
              ac <= {ac[31:3], fmisc_cc};
            end else if (fp_writes_int) begin
              wa <= d_srcdst; wd <= fmisc_yi; we <= 1'b1;
            end else if (d_dst_lit) begin
              // A "literal" destination on an FP op selects fp0-fp3.
              fpr[d_srcdst[1:0]] <= fp_res_wide;
            end else begin
              wa <= d_srcdst; wd <= fp_res_single; we <= 1'b1;
            end
            ip <= ip_next;
            ts <= T_FETCH;
          end
        end

        T_MEM_W: begin
          // Loaded words are written back as they arrive.
          if (lsu_ldwe) begin
            wa <= (d_srcdst & ls_regmask) + {2'd0, lsu_widx};
            wd <= lsu_ldword;
            we <= 1'b1;
          end
          if (lsu_done) begin ip <= ip_next; ts <= T_FETCH; end
        end

        T_FRAME: if (!rf_busy) begin
          if (rf_ip_valid) ip <= rf_next_ip;
          ts <= T_FETCH;
        end

        T_TRAP: begin
          trap   <= 1'b1;
          halted <= 1'b1;
        end

        default: ts <= T_FETCH;
      endcase
    end
  end

endmodule
