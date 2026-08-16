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
  assign alu_or_ea = (d_fmt == 2'd3) ? ea : (ip + d_disp);

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
    .busy(lsu_busy), .done(lsu_done),
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

  // ------------------------------------------------------------- sequencer

  typedef enum logic [3:0] {
    T_FETCH, T_FETCH_W, T_FETCH2, T_FETCH2_W, T_DECODE,
    T_EXEC, T_MEM, T_MEM_W, T_WB, T_FRAME, T_TRAP
  } tstate_e;

  tstate_e ts;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ts        <= T_FETCH;
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
      ra1       <= 5'd0;
      ra2       <= 5'd0;
      rf_call   <= 1'b0;
      rf_ret    <= 1'b0;
      rf_flush  <= 1'b0;
      fetch_addr<= 32'd0;
    end else begin
      ic_req   <= 1'b0;
      lsu_req  <= 1'b0;
      we       <= 1'b0;
      rf_call  <= 1'b0;
      rf_ret   <= 1'b0;
      rf_flush <= 1'b0;

      case (ts)
        T_FETCH: begin
          fetch_addr <= ip;
          ic_req     <= 1'b1;
          ts         <= T_FETCH_W;
        end

        T_FETCH_W: if (ic_valid) begin
          insn    <= ic_data;
          ip_next <= ip + 32'd4;
          ts      <= T_DECODE;
        end

        T_DECODE: begin
          // Operand register numbers are presented now; the file reads
          // combinationally so the values are available next state.
          // COBR reads (insn>>19) on port 1; REG and MEM read src1 there.
          ra1 <= (d_fmt == 2'd1) ? d_srcdst : d_src1;
          ra2 <= d_src2;
          if (!d_valid || d_memb_bad) begin
            trap_op <= d_op;
            ts      <= T_TRAP;
          end else if (d_len2) begin
            fetch_addr <= ip + 32'd4;
            ic_req     <= 1'b1;
            ip_next    <= ip + 32'd8;
            ts         <= T_FETCH2_W;
          end else begin
            ts <= T_EXEC;
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
                8'h08: begin ip <= ip + d_disp; ts <= T_FETCH; end        // b
                8'h09: begin rf_call <= 1'b1;   ts <= T_FRAME; end        // call
                8'h0a: begin rf_ret  <= 1'b1;   ts <= T_FRAME; end        // ret
                8'h0b: begin                                              // bal
                  wa <= 5'd30; wd <= ip_next; we <= 1'b1;
                  ip <= ip + d_disp; ts <= T_FETCH;
                end
                default: begin
                  if (d_op[7:3] == 5'b00010) begin                        // b<cc>
                    // bxx masks the IP after a taken branch; plain b does not.
                    ip <= (|(ac[2:0] & d_op[2:0]))
                            ? ((ip_next + d_disp) & 32'hffff_fffc) : ip_next;
                    ts <= T_FETCH;
                  end else begin
                    trap_op <= d_op;                                      // fault<cc>
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
              if (alu_valid) begin
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
                ra1     <= d_srcdst & ls_regmask;
                lsu_req <= 1'b1;
                ts      <= T_MEM_W;
              end
            end
          endcase
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
