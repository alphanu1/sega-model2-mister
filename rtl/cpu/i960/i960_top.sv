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

  // The four external interrupt lines. Sega and Namco both wired the i960 in
  // "normal" mode only, which is the subset MAME implements and the only one
  // modelled here. LEVEL inputs, sampled at an instruction boundary; a rising
  // edge is what raises an interrupt. These arrive from other clock domains on
  // hardware and need a two-flop synchroniser at the integration boundary --
  // that belongs in Model2.sv, not here, so this port expects a synchronous
  // signal.
  input  logic  [3:0] irq,

  // Observability. These exist so the design has real outputs and cannot be
  // optimised away, and because the screen is the only output channel this
  // project will ever have on hardware.
  // System registers, exposed rather than lint-waived. They are written at reset
  // and not yet read by anything -- the interrupt path that consumes them is the
  // next increment -- and the screen is the only output channel on hardware, so
  // making them observable is what one would want regardless.
  output logic [31:0] dbg_pc,
  output logic [31:0] dbg_sat,
  output logic [31:0] dbg_prcb,
  output logic [31:0] dbg_icr,
  // Interrupt observability. Real outputs for the same reason the rest are:
  // the screen is the only output channel on hardware, and an overlay showing
  // "how many interrupts has this core taken" is the first question worth
  // asking when a game boots to a black screen. The lockstep harness needs
  // them too -- it has to tell an instruction retiring apart from an interrupt
  // being taken, and both look like the IP moving.
  output logic [31:0] dbg_intr_cnt,
  output logic        dbg_intr_work,
  // Instructions ACCEPTED, which is exactly one per instruction executed --
  // the sequencer latches `insn` once and runs it to completion. This exists
  // because "the IP changed" is not a retire detector and failed three
  // different ways once interrupts arrived: taking an interrupt moves the IP
  // without retiring, a handler address can equal the IP the window opened at,
  // and a type-7 frame can make `ret` return to its own address so the IP never
  // moves at all. Counting the one unambiguous event removes the whole class.
  output logic [31:0] dbg_acc_cnt,
  output logic [31:0] dbg_ip,
  output logic [31:0] dbg_insn,
  output logic        trap,
  output logic [7:0]  trap_op,
  output logic        halted,
  // Frame state, so a `ret` that lands on an impossible address can be traced
  // to what the frame held rather than inferred from where it went.
  output logic [31:0] dbg_rip,
  output logic [31:0] dbg_pfp,
  output logic signed [31:0] dbg_rcache_pos,
  output logic        dbg_to_memory,
  // Does the register file ASK for memory, and does the arbiter grant it? The
  // spill for a frame at 0x53f6c0 produced no bus traffic at all while
  // dbg_to_memory was set, so "it wants to spill" and "it is spilling" have to
  // be distinguishable.
  output logic        dbg_rf_req,
  output logic        dbg_rf_ack,
  output logic [31:0] dbg_rf_addr
);

  // ------------------------------------------------------------ architectural

  // ARCHITECTURAL STATE THE INTERRUPT PATH CONSUMES, with MAME's reset values
  // (i960.cpp device_reset). These are registers now; what is NOT yet done is
  // loading SAT, PRCB and the initial IP from memory at reset --
  //
  //     SAT = mem[0]   PRCB = mem[4]   IP = mem[12]
  //
  // -- which needs a boot state machine issuing three reads before the first
  // fetch, and therefore either a new bus master or a way for the sequencer to
  // drive the LSU without a decoded instruction. That is its own increment.
  // Until it lands, PRCB reads 0 and the interrupt table would be looked up at
  // the wrong address, which is why interrupts are not yet enabled.
  //
  // PC bit 13 (0x2000) is the interrupt flag and PC[20:16] the priority; both
  // are read by take_interrupt to decide whether an interrupt can be taken and
  // which stack it uses.
  logic [31:0] syn_dst;     // synmov destination, held across the two phases
  logic [31:0] syn_src;     // and its source, latched for the same reason
  logic [31:0] pc_reg;      // process controls
  logic [31:0] sat_reg;     // system address table
  logic [31:0] prcb_reg;    // processor control block
  logic [31:0] icr_reg;     // interrupt control: one vector byte per IRQ line

  // ------------------------------------------------------- interrupt state
  // Transcribed from MAME i960.cpp. Three microprograms share one state and a
  // step counter, because every step is a single aux-bus transaction and a flat
  // sequence can be read against the source line by line:
  //
  //   M_Q     execute_set_input's else branch -- queue into the interrupt table
  //   M_TAKE  take_interrupt
  //   M_PEND  check_pending_irqs -- the dequeue after a type-7 ret
  //
  // WHEN an interrupt is taken is the one place this does not follow MAME
  // literally. MAME calls check_immediate_irqs() once per execute_run(), a
  // scheduler timeslice boundary, which is an emulator artifact; silicon takes
  // it at the next instruction boundary and so does this. The reference states
  // the same rule, because a difference here diverges on timing alone.
  localparam logic [1:0] M_Q = 2'd0, M_TAKE = 2'd1, M_PEND = 2'd2;

  logic  [3:0] irq_prev;    // last sampled line state, for edge detection
  logic  [3:0] irq_edge;    // rising edges captured and not yet processed
  logic        imm_irq;     // the single immediate slot MAME models
  logic  [7:0] imm_vector;
  logic  [4:0] imm_pri;

  logic [31:0] it_base;     // interrupt table, from PRCB+20
  logic [31:0] int_sp;      // interrupt stack, from PRCB+24
  logic [31:0] irqv;        // handler address out of the table
  logic [31:0] scratch;     // read-modify-write holding register
  logic [31:0] pend_pri;    // the priority summary word
  logic [31:0] vword;       // the vector word for one priority group
  logic [31:0] intr_stack;
  logic  [7:0] cur_vec;
  logic  [4:0] cur_lvl;
  logic  [4:0] take_idx;    // bit position within vword, latched before it moves
  logic  [3:0] intr_step;
  logic  [1:0] intr_mode;
  logic        intr_call;   // this call is the type-7 interrupt call
  logic        pend_abort;  // a flagged level with no vector under it
  logic        ret7;        // a type-7 return is in flight
  // synmovq / send_iac. Only the message TYPE of the first IAC word is kept --
  // the low 24 bits are never read by any message MAME implements.
  logic  [7:0] iac_msg;
  logic [31:0] iac1, iac2, iac3;
  logic  [3:0] synq_step;
  logic        synq_iac;
  logic [31:0] ret7_pc, ret7_ac;

  logic  [4:0] cpu_pri;
  assign cpu_pri = pc_reg[20:16];

  // modpc, 0x65.5. Named here because the read-address drive below needs it
  // one state earlier than T_EXEC: modpc reads srcdst as a SOURCE, which no
  // other REG-format instruction does.
  logic is_modpc;
  assign is_modpc = (d_op == 8'h65) && (d_op2 == 4'h5);
  // The PC modpc is about to install. Named because the eligibility test needs
  // its priority field, and a part-select of an expression is not legal here.
  logic [31:0] modpc_new_pc;
  assign modpc_new_pc  = (pc_reg & ~src2_val) | (rd1 & src2_val);
  logic  [4:0] modpc_new_pri;
  assign modpc_new_pri = modpc_new_pc[20:16];

  // Observability for the lockstep harness, which has to tell three things
  // apart that all look like "the IP moved": an instruction retiring, an
  // interrupt being taken at a boundary, and a dequeue after a type-7 ret.
  // intr_taken_cnt counts completed take_interrupts; intr_work says the
  // sequencer is not yet at a settled boundary.
  logic [31:0] intr_taken_cnt;
  logic [31:0] acc_cnt;
  logic        intr_work;

  // Lowest-numbered pending edge first. MAME's order is whatever the driving
  // machine calls execute_set_input in; a fixed order is needed for lockstep,
  // and the reference uses the same one.
  //
  // COMBINATIONAL, not the register: an edge arriving in the same cycle as the
  // boundary test must be visible to that test. Testing the register alone
  // delays it by a cycle, and whether that cycle mattered depended on whether
  // the boundary happened to be a prefetch hit -- so it would have diverged
  // against the reference only sometimes, which is the worst kind.
  logic [3:0] irq_edge_now;
  assign irq_edge_now = irq_edge | (irq & ~irq_prev);

  logic [1:0] edge_line;
  always_comb begin
    if      (irq_edge_now[0]) edge_line = 2'd0;
    else if (irq_edge_now[1]) edge_line = 2'd1;
    else if (irq_edge_now[2]) edge_line = 2'd2;
    else                      edge_line = 2'd3;
  end

  logic [7:0] edge_vec;
  always_comb begin
    case (edge_line)
      2'd0:    edge_vec = icr_reg[7:0];
      2'd1:    edge_vec = icr_reg[15:8];
      2'd2:    edge_vec = icr_reg[23:16];
      default: edge_vec = icr_reg[31:24];
    endcase
  end
  logic [4:0] edge_pri;
  assign edge_pri = edge_vec[7:3];          // priority = vector / 8

  assign intr_work = (|irq_edge_now) ||
                     (imm_irq && ((cpu_pri < imm_pri) || (imm_pri == 5'd31)));

  // check_pending_irqs' scan: highest priority that is both pending and
  // eligible. MAME walks 31 down to 0 and takes the first hit, so this is a
  // find-highest-set over the eligible mask. Level 31 is always eligible.
  logic [31:0] pend_elig;
  assign pend_elig = pend_pri &
                     ({1'b1, 31'd0} | (32'hffff_ffff << ({1'b0, cpu_pri} + 6'd1)));
  logic [4:0] top_lvl;
  logic       have_lvl;
  always_comb begin
    top_lvl  = 5'd0;
    have_lvl = 1'b0;
    for (int i = 0; i < 32; i++)
      if (pend_elig[i]) begin top_lvl = 5'(i); have_lvl = 1'b1; end
  end

  // ...and within that level's byte, the highest vector set.
  logic [7:0] lvl_byte;
  always_comb begin
    case (cur_lvl[1:0])
      2'd0:    lvl_byte = vword[7:0];
      2'd1:    lvl_byte = vword[15:8];
      2'd2:    lvl_byte = vword[23:16];
      default: lvl_byte = vword[31:24];
    endcase
  end
  logic [2:0] top_bit;
  logic       have_bit;
  always_comb begin
    top_bit  = 3'd0;
    have_bit = 1'b0;
    for (int i = 0; i < 8; i++)
      if (lvl_byte[i]) begin top_bit = 3'(i); have_bit = 1'b1; end
  end

  assign dbg_pc   = pc_reg;
  assign dbg_sat  = sat_reg;
  assign dbg_prcb = prcb_reg;
  assign dbg_icr  = icr_reg;
  assign dbg_intr_cnt  = intr_taken_cnt;
  assign dbg_intr_work = intr_work;
  assign dbg_acc_cnt   = acc_cnt;

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

  // Five bits now: the boot walk and synmov's two phases took it past sixteen.
  //
  // NEW STATES GO AT THE END, and that is not cosmetic. T_FETCH and T_FETCH_W
  // must keep encodings 0 and 1: sim/i960/tb_i960_top.cpp's prefetch invariant
  // tests for those two numerically. Putting the boot state first silently
  // repointed that invariant, which would have disabled a check that has caught
  // real faults -- without failing anything.
  //
  // Appending was NEVER SUFFICIENT on its own, and this comment used to claim it
  // was. The harness masked `ts & 15`; at the seventeenth state T_SYNMOV_RD (16)
  // wrapped onto T_FETCH (0) and T_SYNMOV_WR (17) onto T_FETCH_W (1), so the
  // invariant ran during both synmov states and the cycle histogram booked them
  // as fetch. The mask is now 31 and the arrays are 32 entries. Study R20.
  typedef enum logic [4:0] {
    T_FETCH, T_FETCH_W, T_FETCH2, T_FETCH2_W, T_DECODE,
    T_EXEC, T_MEM, T_MEM_W, T_MULDIV, T_MULTI, T_PAIR, T_FP, T_WB, T_FRAME,
    T_TRAP,
    T_BOOT, T_SYNMOV_RD, T_SYNMOV_WR,
    T_INTR, T_RET7, T_MODPC, T_SYNQ
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
  logic [31:0] cur_fp, cur_sp;
  logic  [2:0] cur_pfp_type;
  // A return type other than 0 -- see i960_regs.sv. Raised rather than
  // silently performing an ordinary return.
  logic        rf_ret_unsup;
  logic [31:0] rf_next_ip;
  logic        rf_mem_req, rf_mem_we;
  logic [31:0] rf_mem_addr, rf_mem_wdata;

  i960_regs u_regs (
    .clk(clk), .rst_n(rst_n),
    .ra1(ra1), .ra2(ra2), .rd1(rd1), .rd2(rd2),
    .wa(wa), .wd(wd), .we(we),
    .op_call(rf_call), .op_ret(rf_ret), .op_flushreg(rf_flush),
    .ret_unsupported(rf_ret_unsup),
    // take_interrupt's do_call takes the CURRENT ip, not ip_next: it runs at an
    // instruction boundary, so the instruction to resume at is the one not yet
    // executed. An ordinary call is past its instruction and uses ip_next.
    .call_ip(intr_call ? ip : ip_next), .call_target(call_tgt),
    .call_type(intr_call ? 3'd7 : 3'd0),
    .call_stack(intr_stack),
    .cur_fp(cur_fp), .cur_sp(cur_sp), .cur_pfp_type(cur_pfp_type),
    .busy(rf_busy), .next_ip(rf_next_ip), .next_ip_valid(rf_ip_valid),
    .boot_fp_we(boot_fp_we), .boot_fp(boot_fp),
    .dbg_rip(dbg_rip), .dbg_pfp(dbg_pfp),
    .dbg_rcache_pos(dbg_rcache_pos), .dbg_to_memory(dbg_to_memory),
    .mem_req(rf_mem_req), .mem_we(rf_mem_we), .mem_addr(rf_mem_addr),
    .mem_wdata(rf_mem_wdata), .mem_rdata(bus_rdata), .mem_ack(rf_mem_ack)
  );

  assign dbg_rf_req  = rf_mem_req;
  assign dbg_rf_ack  = rf_mem_ack;
  assign dbg_rf_addr = rf_mem_addr;

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

  // The call target must be LATCHED, not presented live. `next_ip` is sampled
  // in S_CALL_FIN, several cycles after `op_call`, so the target has to hold
  // for the whole frame sequence. For callx the target is `ea`, which depends
  // on rd1/rd2 -- and those change the moment ra1/ra2 revert to their defaults
  // on leaving T_EXEC. CTRL `call` never exposed this because its target is
  // `ip_next + disp`, with no register dependency at all.
  logic [31:0] call_tgt;
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
  // COMBINATIONAL, asserted during T_EXEC rather than registered into T_MEM_W.
  //
  // Registered, the LSU did not see the request until the first T_MEM_W cycle,
  // so that cycle was spent merely accepting it -- one of the three a load
  // costs, against a bus that acks immediately. Driving it from the execute
  // state lets the LSU be in its transfer state by the time T_MEM_W begins.
  //
  // Its inputs are ready: `ea` is combinational from the AGU, and `ls_*` from
  // i960_ldst, both valid throughout T_EXEC. Stores gain nothing (they still
  // wait in S_OPD for the register value) and lose nothing.
  logic        lsu_busy, lsu_done, lsu_ldwe;
  logic        lsu_ldwe_now, lsu_done_now;
  logic [31:0] lsu_ldword_now;
  logic        lsu_req;
  assign lsu_req = (ts == T_EXEC) && (d_fmt == 2'd3) &&
                   ls_valid && agu_valid && !ls_nomem;
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
    .ld_we_now(lsu_ldwe_now), .ld_word_now(lsu_ldword_now),
    .done_now(lsu_done_now),
    .word_idx(lsu_widx), .st_word(rd1), .ld_word(lsu_ldword), .ld_we(lsu_ldwe),
    .bus_req(lsu_breq), .bus_we(lsu_bwe), .bus_addr(lsu_baddr),
    .bus_be(lsu_bbe), .bus_wdata(lsu_bwdata),
    .bus_rdata(bus_rdata), .bus_ack(lsu_back)
  );

  // ---------------------------------------------------------------- I-cache

  /* verilator lint_off UNUSEDSIGNAL */
  logic        ic_req, ic_valid, ic_busy, ic_breq;
  logic [31:2] ic_vaddr;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] ic_data, ic_baddr;

  i960_icache u_icache (
    .clk(clk), .rst_n(rst_n), .inval(1'b0),
    .req(ic_req), .req_demand(1'b1), .addr(fetch_addr[31:2]), .data(ic_data),
    .valid(ic_valid), .vaddr(ic_vaddr), .busy(ic_busy),
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

  // BOOT MASTER. The i960 reads its startup state from low memory before it
  // executes anything (MAME i960.cpp device_reset):
  //
  //     SAT = mem[0]     PRCB = mem[4]     IP = mem[12]
  //
  // It sits ABOVE the register-file spill in priority, which is safe because it
  // only ever runs in T_BOOT, before any other master can have work.
  // Generalised into an AUX MASTER once synmov needed the same thing: an access
  // whose address comes from somewhere other than the AGU. It serves the boot
  // walk and then synmov, which cannot use the LSU because its two addresses are
  // register values rather than a decoded effective address.
  logic        boot_req;
  logic [31:0] boot_addr;
  logic        boot_ack;
  logic  [1:0] boot_step;
  logic        boot_fp_we;
  logic [31:0] boot_fp;
  logic        aux_we;
  logic [31:0] aux_wdata;

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
    boot_ack   = 1'b0;

    if (boot_req) begin
      bus_req = 1'b1; bus_we = aux_we; bus_addr = boot_addr; bus_be = 4'b1111;
      bus_wdata = aux_wdata;
      boot_ack = bus_ack;
    end else if (rf_mem_req) begin
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
        // modpc takes srcdst as an operand and writes the OLD PC back to it.
        // Presented here so rd1 is valid when T_MODPC runs next cycle.
        else if (is_modpc)       ra1 = d_srcdst;
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
      ts        <= T_BOOT;
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
      pc_reg    <= 32'h001f_2002;   // priority 31, supervisor, interrupt flag
      sat_reg   <= 32'd0;
      prcb_reg  <= 32'd0;
      icr_reg   <= 32'hff00_0000;   // IRQ3 vector 0xff, priority 31
      ip_next   <= 32'd4;
      insn      <= 32'd0;
      disp_word <= 32'd0;
      ac        <= 32'd0;
      trap      <= 1'b0;
      trap_op   <= 8'd0;
      halted    <= 1'b0;
      ic_req    <= 1'b0;
      boot_req  <= 1'b1;
      boot_addr  <= 32'd0;
      boot_step  <= 2'd0;
      boot_fp    <= 32'd0;
      boot_fp_we <= 1'b0;
      aux_we    <= 1'b0;
      aux_wdata <= 32'd0;
      syn_dst   <= 32'd0;
      syn_src   <= 32'd0;
      irq_prev  <= 4'd0;
      irq_edge  <= 4'd0;
      imm_irq   <= 1'b0;
      imm_vector<= 8'd0;
      imm_pri   <= 5'd0;
      it_base   <= 32'd0;
      int_sp    <= 32'd0;
      irqv      <= 32'd0;
      scratch   <= 32'd0;
      pend_pri  <= 32'd0;
      vword     <= 32'd0;
      intr_stack<= 32'd0;
      cur_vec   <= 8'd0;
      cur_lvl   <= 5'd0;
      take_idx  <= 5'd0;
      intr_step <= 4'd0;
      intr_mode <= M_Q;
      intr_call <= 1'b0;
      pend_abort<= 1'b0;
      ret7      <= 1'b0;
      ret7_pc   <= 32'd0;
      ret7_ac   <= 32'd0;
      iac_msg   <= 8'd0;
      iac1      <= 32'd0;
      iac2      <= 32'd0;
      iac3      <= 32'd0;
      synq_step <= 4'd0;
      synq_iac  <= 1'b0;
      intr_taken_cnt <= 32'd0;
      acc_cnt        <= 32'd0;
      we        <= 1'b0;
      wa        <= 5'd0;
      wd        <= 32'd0;
      rf_call   <= 1'b0;
      call_tgt  <= 32'd0;
      rf_ret    <= 1'b0;
      rf_flush  <= 1'b0;
      fetch_addr<= 32'd0;
      fadd_req  <= 1'b0;
      fmul_req  <= 1'b0;
      fdiv_req  <= 1'b0;
      fsqrt_req <= 1'b0;
    end else begin
      // ONE SHOT. Set in T_BOOT's last step and cleared here, so the frame
      // pointer is initialised once rather than held over every register the
      // machine writes afterwards. A later assignment in this same block wins,
      // so setting it below still takes effect on the cycle it is set.
      boot_fp_we <= 1'b0;
      ic_req   <= 1'b0;
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

      // Edge capture runs every cycle; the boundary handler below consumes one
      // edge at a time and reasserts this expression with that line masked off.
      // Written as a full re-evaluation rather than relying on a later bit
      // assignment overriding an earlier whole-vector one -- that is legal
      // SystemVerilog and it is also exactly the kind of subtlety that reads as
      // correct while doing something else.
      irq_prev <= irq;
      irq_edge <= irq_edge | (irq & ~irq_prev);

      case (ts)
        // --------------------------------------------------------- boot
        // Three reads before the first instruction fetch, in the order the real
        // part does them. Nothing else is running: the front end has not been
        // asked for anything, so no other master can be mid-transaction.
        T_BOOT: if (boot_ack) begin
          case (boot_step)
            2'd0: begin sat_reg  <= bus_rdata; boot_addr <= 32'd4;
                        boot_step <= 2'd1; end
            2'd1: begin prcb_reg <= bus_rdata; boot_addr <= 32'd12;
                        boot_step <= 2'd2; end
            2'd2: begin
              // mem[12] is the initial IP. The prefetch slot is left invalid, so
              // the first fetch goes to this address rather than to whatever the
              // front end had speculated from the reset value of 0.
              ip       <= bus_rdata;
              pf_ip    <= bus_rdata;
              pf_valid <= 1'b0;
              pf_armed <= 1'b0;
              // A FOURTH READ: the initial frame pointer, at PRCB+24.
              //
              //   m_r[I960_FP] = m_program.read_dword(m_PRCB+24);   i960.cpp
              //
              // This walk used to stop at the IP, so FP stayed at its reset
              // value of zero and frames allocated from there: 0x40, 0x80,
              // 0xc0, 0x100. Those are the boot record and program ROM.
              //
              // It survived 803,355 instructions verified against MAME because
              // NOTHING TOUCHES MEMORY UNTIL A FRAME SPILLS, and a spill needs
              // the call depth to exceed the four-frame register cache. The
              // boot reaches depth five once, in a tile-RAM fill at 0x18d74,
              // and the spill wrote to 0x100 -- program ROM, where writes are
              // discarded -- so the fill read ROM back and the closing `ret`
              // took its return address from it and branched to zero.
              boot_addr <= prcb_reg + 32'd24;
              boot_step <= 2'd3;
            end
            default: begin
              boot_fp    <= bus_rdata;
              boot_fp_we <= 1'b1;
              boot_req   <= 1'b0;
              ts         <= T_FETCH;
            end
          endcase
        end

        // ------------------------------------------------------- synmov
        T_SYNMOV_RD: if (!boot_req) begin
          boot_addr <= syn_src;
          boot_req  <= 1'b1;
        end else if (boot_ack) begin
          if (syn_dst == 32'hff00_0004) begin
            // The interrupt control register, not memory.
            icr_reg  <= bus_rdata;
            boot_req <= 1'b0;
            ac       <= {ac[31:3], 3'd2};
            ip       <= ip_next;
            ts       <= T_FETCH;
          end else begin
            aux_wdata <= bus_rdata;
            boot_addr <= syn_dst;
            aux_we    <= 1'b1;
            boot_req  <= 1'b0;
            ts        <= T_SYNMOV_WR;
          end
        end

        T_SYNMOV_WR: if (!boot_req) begin
          boot_req <= 1'b1;
        end else if (boot_ack) begin
          boot_req <= 1'b0;
          aux_we   <= 1'b0;
          ac       <= {ac[31:3], 3'd2};
          ip       <= ip_next;
          ts       <= T_FETCH;
        end

        // T_FETCH and T_FETCH_W share one body. The front end below appears
        // ONCE on purpose: it used to live in T_DECODE, and duplicating it into
        // the prefetch-hit path and the fill path is exactly how those two
        // drift apart without either copy looking wrong.
        T_FETCH, T_FETCH_W: begin
          // INSTRUCTION BOUNDARY. Edges are processed first and one at a time,
          // then the immediate slot is checked -- the same order as the
          // reference, where the harness calls set_irq for each line and step()
          // then calls check_immediate_irqs. Queueing returns here, so a second
          // edge is picked up on re-entry.
          //
          // Only in T_FETCH, never T_FETCH_W: the latter is mid-fill, which is
          // not a boundary. An interrupt arriving during a fill is taken after
          // that instruction retires.
          if ((ts == T_FETCH) && !boot_req && (|irq_edge_now)) begin
            irq_edge <= irq_edge_now & ~(4'd1 << edge_line);
            if (edge_vec == 8'd0) begin
              // Vector 0 means the line is in IAC mode, which MAME logs and
              // declines to handle. Dropping it is the same behaviour.
            end else if (((cpu_pri < edge_pri) || (edge_pri == 5'd31))
                         && !imm_irq) begin
              imm_irq    <= 1'b1;
              imm_vector <= edge_vec;
              imm_pri    <= edge_pri;
            end else begin
              cur_vec   <= edge_vec;
              intr_mode <= M_Q;
              intr_step <= 4'd0;
              ts        <= T_INTR;
            end
          end else if ((ts == T_FETCH) && !boot_req && imm_irq &&
                       ((cpu_pri < imm_pri) || (imm_pri == 5'd31))) begin
            imm_irq   <= 1'b0;
            cur_vec   <= imm_vector;
            cur_lvl   <= imm_pri;
            intr_mode <= M_TAKE;
            intr_step <= 4'd0;
            ts        <= T_INTR;
          end else if (fetch_word_ok) begin
            insn     <= fetch_word;
            acc_cnt  <= acc_cnt + 32'd1;
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
                8'h09: begin rf_call <= 1'b1; call_tgt <= alu_or_ea;
                             ts <= T_FRAME; end                          // call
                8'h0a: begin                                              // ret
                  // A type-7 frame restores PC and AC from FP-16/FP-12, and
                  // they must be READ BEFORE do_ret_0, which moves FP. Types
                  // 1-6 still reach the register file and raise
                  // ret_unsupported there.
                  if (cur_pfp_type == 3'd7) begin
                    intr_step <= 4'd0; ts <= T_RET7;
                  end else begin
                    rf_ret <= 1'b1; ts <= T_FRAME;
                  end
                end
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
              // synmov: a dword from mem[src2] to mem[src1], except that the
              // magic destination 0xff000004 loads ICR instead. That is the only
              // way ICR is ever written, and ICR supplies the vector byte for
              // each external IRQ line -- so interrupts are unreachable without
              // it (MAME i960.cpp 0x60.0).
              //
              // It uses the aux master rather than the LSU because both
              // addresses are register values, not a decoded effective address.
              if (is_modpc) begin
                // set_ri is a fatalerror on the literal form, so that is a trap
                // here rather than a silently-dropped write.
                if (d_dst_lit) begin
                  trap_op <= 8'h65; ts <= T_TRAP;
                end else begin
                  ts <= T_MODPC;   // rd1 (= r[srcdst]) is valid next cycle
                end
              end else if ((d_op == 8'h60) && (d_op2 == 4'h2)) begin
                // synmovq. Destination 0xff000010 is the IAC port and copies
                // nothing; anything else is a four-dword move.
                syn_dst   <= (d_src1_lit ? {27'd0, d_src1} : rd1) & 32'hffff_fffc;
                syn_src   <= (d_src2_lit ? {27'd0, d_src2} : rd2) & 32'hffff_fffc;
                synq_iac  <= ((d_src1_lit ? {27'd0, d_src1} : rd1) == 32'hff00_0010);
                synq_step <= 4'd0;
                aux_we    <= 1'b0;
                boot_req  <= 1'b0;
                ts        <= T_SYNQ;
              end else if ((d_op == 8'h60) && (d_op2 != 4'h0)) begin
                // MAME fatalerrors on every other 0x60 sub-opcode. Announce it
                // rather than falling through to the ALU, which would execute
                // something unrelated.
                trap_op <= 8'h60; ts <= T_TRAP;
              end else if ((d_op == 8'h60) && (d_op2 == 4'h0)) begin
                // BOTH addresses are latched here and the request is raised in
                // the NEXT state, the same shape as callx. Note this was NOT
                // what fixed the original divergence: latching produced a
                // bit-identical failure, and the fault was in the reference's
                // accessors. It is kept because presenting a register value
                // live to the bus register is the callx defect exactly, and a
                // later change to when rd1/rd2 settle would reintroduce it.
                //
                // Word aligned because synmov is an atomic WORD operation and
                // the i960 requires both operands aligned. The reference states
                // the same rule independently; neither is copying the other,
                // and the downstream bus is not relied on to drop the bits.
                syn_dst  <= (d_src1_lit ? {27'd0, d_src1} : rd1) & 32'hffff_fffc;
                syn_src  <= (d_src2_lit ? {27'd0, d_src2} : rd2) & 32'hffff_fffc;
                aux_we   <= 1'b0;
                boot_req <= 1'b0;
                ts       <= T_SYNMOV_RD;
              end else if (is_movx) begin
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
              end else if (ls_nomem && (d_op == 8'h86)) begin  // callx
                rf_call <= 1'b1; call_tgt <= ea; ts <= T_FRAME;
              end else if (ls_nomem && (d_op == 8'h84)) begin  // bx
                ip <= ea; ts <= T_FETCH;
              end else if (ls_nomem && (d_op == 8'h85)) begin  // balx
                // The link register takes ip_next, because MAME's m_IP is
                // already past the instruction when execute_op runs.
                wa <= d_srcdst; wd <= ip_next; we <= 1'b1;
                ip <= ea; ts <= T_FETCH;
              end else if (ls_nomem) begin                // lda
                wa <= d_srcdst; wd <= ea; we <= 1'b1;
                ip <= ip_next; ts <= T_FETCH;
              end else begin
                ts <= T_MEM_W;   // lsu_req is already asserted, see above
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
          // Loaded words are written back as they arrive. The `_now` forms are
          // the same retire seen a cycle earlier, in the ack itself, which is
          // what removes the cycle the sequencer used to spend noticing.
          // Byte-split accesses still arrive on the registered path.
          if (lsu_ldwe_now) begin
            wa <= (d_srcdst & ls_regmask) + {2'd0, lsu_curidx};
            wd <= lsu_ldword_now;
            we <= 1'b1;
          end else if (lsu_ldwe) begin
            wa <= (d_srcdst & ls_regmask) + {2'd0, lsu_widx};
            wd <= lsu_ldword;
            we <= 1'b1;
          end
          if (lsu_done_now || lsu_done) begin ip <= ip_next; ts <= T_FETCH; end
        end

        // The strobe must be part of the wait condition. `busy` is
        // `state != S_IDLE` in the register file, and the register file has not
        // yet SEEN the request in the first T_FRAME cycle -- op_call is only
        // being presented then, so busy is still low and this exits one cycle
        // early, before the frame operation has started. The sequencer then
        // refetches the same instruction, because `rf_ip_valid` is a one-cycle
        // strobe that has not pulsed yet, and executes the call a second time.
        //
        // Usually harmless by accident: the second strobe lands while the file
        // is mid-save and S_CALL_SAVE ignores op_call, so it is swallowed. But
        // when the refetch is slow -- an I-cache fill -- the file finishes the
        // whole frame and is back in S_IDLE before the sequencer returns, and
        // then the second strobe is a REAL second call. One callx was observed
        // building five frames and spilling to memory.
        //
        // Neither `call` nor `ret` was ever emitted by the whole-CPU generator,
        // so nothing had exercised this path at CPU level; the register-file
        // unit test drives op_call directly and cannot see a sequencer that
        // asserts it twice.
        T_FRAME: if (rf_ret_unsup) begin
          // Unsupported return type: announce it instead of returning wrongly.
          trap_op <= 8'h0a; ts <= T_TRAP;
        end else if (!rf_busy && !rf_call && !rf_ret && !rf_flush) begin
          if (rf_ip_valid) ip <= rf_next_ip;
          if (ret7) begin
            ret7   <= 1'b0;
            ac     <= ret7_ac;
            pc_reg <= ret7_pc;
            // Giving up the priority this interrupt ran at can release a queued
            // one, so MAME checks here. pc_reg lands this cycle, so the scan
            // next cycle sees the RESTORED priority -- which is the one the
            // eligibility test has to use.
            intr_mode <= M_PEND;
            intr_step <= 4'd0;
            ts        <= T_INTR;
          end else ts <= T_FETCH;
        end

        // -------------------------------------------------- type-7 return
        // Two reads, then the ordinary return. FP is still the interrupt
        // frame's here; do_ret_0 moves it, which is why this cannot be folded
        // into T_FRAME.
        T_RET7: if (!boot_req) begin
          aux_we    <= 1'b0;
          boot_addr <= (intr_step == 4'd0) ? (cur_fp - 32'd16) : (cur_fp - 32'd12);
          boot_req  <= 1'b1;
        end else if (boot_ack) begin
          boot_req <= 1'b0;
          if (intr_step == 4'd0) begin
            ret7_pc   <= bus_rdata;
            intr_step <= 4'd1;
          end else begin
            ret7_ac <= bus_rdata;
            ret7    <= 1'b1;
            rf_ret  <= 1'b1;
            ts      <= T_FRAME;
          end
        end

        // --------------------------------------------------------- synmovq
        T_SYNQ: if (synq_iac) begin
          case (synq_step)
            // Four reads of the IAC message.
            4'd0, 4'd1, 4'd2, 4'd3: if (!boot_req) begin
              aux_we    <= 1'b0;
              boot_addr <= syn_src + {28'd0, synq_step[1:0], 2'b00};
              boot_req  <= 1'b1;
            end else if (boot_ack) begin
              boot_req <= 1'b0;
              case (synq_step[1:0])
                2'd0:    iac_msg <= bus_rdata[31:24];
                2'd1:    iac1    <= bus_rdata;
                2'd2:    iac2    <= bus_rdata;
                default: iac3    <= bus_rdata;
              endcase
              synq_step <= synq_step + 4'd1;
            end

            4'd4: begin
              ac <= {ac[31:3], 3'd2};
              case (iac_msg)
                // Reinit. THE IP COMES FROM THE MESSAGE, so this must not
                // advance to ip_next -- Daytona's boot builds a PRCB in work
                // RAM, points the CPU at it with this, and resumes at 0x924.
                8'h93: begin
                  sat_reg  <= iac1;
                  prcb_reg <= iac2;
                  ip       <= iac3;
                  ts       <= T_FETCH;
                end
                8'h80: synq_step <= 4'd5;              // store SAT and PRCB
                8'h41: begin                           // test for pending
                  ip        <= ip_next;
                  intr_mode <= M_PEND;
                  intr_step <= 4'd0;
                  ts        <= T_INTR;
                end
                // Generate IRQ, invalidate I-cache, breakpoints, stop,
                // continue: MAME logs and ignores each one.
                default: begin ip <= ip_next; ts <= T_FETCH; end
              endcase
            end

            default: if (!boot_req) begin             // steps 5 and 6
              aux_we    <= 1'b1;
              boot_addr <= (synq_step == 4'd5) ? iac1 : (iac1 + 32'd4);
              aux_wdata <= (synq_step == 4'd5) ? sat_reg : prcb_reg;
              boot_req  <= 1'b1;
            end else if (boot_ack) begin
              boot_req <= 1'b0;
              if (synq_step == 4'd5) synq_step <= 4'd6;
              else begin
                aux_we <= 1'b0;
                ip     <= ip_next;
                ts     <= T_FETCH;
              end
            end
          endcase
        end else if (!boot_req) begin
          // Memory to memory, four dwords. Even steps read the source, odd
          // steps write the destination; synq_step[2:1] is the word index.
          aux_we    <= synq_step[0];
          boot_addr <= (synq_step[0] ? syn_dst : syn_src)
                     + {28'd0, synq_step[2:1], 2'b00};
          aux_wdata <= scratch;
          boot_req  <= 1'b1;
        end else if (boot_ack) begin
          boot_req <= 1'b0;
          if (!synq_step[0]) scratch <= bus_rdata;
          if (synq_step == 4'd7) begin
            aux_we <= 1'b0;
            ac     <= {ac[31:3], 3'd2};
            ip     <= ip_next;
            ts     <= T_FETCH;
          end else synq_step <= synq_step + 4'd1;
        end

        // ------------------------------------------------------------ modpc
        // One state, because srcdst has to be READ before it is written and the
        // REG read port presents src1 there for every other instruction.
        T_MODPC: begin
          pc_reg <= modpc_new_pc;
          wa     <= d_srcdst;
          wd     <= pc_reg;                       // set_ri writes the OLD PC
          we     <= 1'b1;
          ip     <= ip_next;
          // Only a priority that went DOWN can release a queued interrupt, and
          // MAME checks on exactly that condition rather than on any change.
          if (cpu_pri > modpc_new_pri) begin
            intr_mode <= M_PEND;
            intr_step <= 4'd0;
            ts        <= T_INTR;
          end else ts <= T_FETCH;
        end

        // ------------------------------------------------------- interrupts
        T_INTR: case (intr_mode)

          // ---- execute_set_input, the queue branch. Two read-modify-writes:
          // a priority summary at int_tab, and one bit per vector in the word
          // for that priority group.
          M_Q: if (!boot_req) begin
            boot_req <= 1'b1;
            case (intr_step)
              4'd0: begin aux_we <= 1'b0; boot_addr <= prcb_reg + 32'd20; end
              4'd1: begin aux_we <= 1'b0; boot_addr <= it_base; end
              4'd2: begin aux_we <= 1'b1; boot_addr <= it_base;
                          aux_wdata <= scratch | (32'd1 << cur_vec[7:3]); end
              4'd3: begin aux_we <= 1'b0;
                          boot_addr <= it_base + {27'd0, cur_vec[7:5], 2'b00}
                                               + 32'd4; end
              default: begin aux_we <= 1'b1;
                          boot_addr <= it_base + {27'd0, cur_vec[7:5], 2'b00}
                                               + 32'd4;
                          aux_wdata <= scratch | (32'd1 << cur_vec[4:0]); end
            endcase
          end else if (boot_ack) begin
            boot_req <= 1'b0;
            case (intr_step)
              4'd0: begin it_base <= bus_rdata; intr_step <= 4'd1; end
              4'd1: begin scratch <= bus_rdata; intr_step <= 4'd2; end
              4'd2: begin                       intr_step <= 4'd3; end
              4'd3: begin scratch <= bus_rdata; intr_step <= 4'd4; end
              default: begin aux_we <= 1'b0; ts <= T_FETCH; end
            endcase
          end

          // ---- take_interrupt ----
          M_TAKE: case (intr_step)
            4'd0, 4'd1, 4'd2: if (!boot_req) begin
              aux_we   <= 1'b0;
              boot_req <= 1'b1;
              case (intr_step)
                4'd0: boot_addr <= prcb_reg + 32'd20;
                4'd1: boot_addr <= prcb_reg + 32'd24;
                // int_tab + 36 + (vector-8)*4. MAME does not guard vector < 8,
                // and the wrap is reproduced rather than corrected: vectors
                // below 8 are reserved on the part, so the address it forms is
                // undefined either way and inventing a guard here would make
                // this disagree with the oracle for no gain.
                default: boot_addr <= it_base + 32'd36
                                    + ((({24'd0, cur_vec}) - 32'd8) << 2);
              endcase
            end else if (boot_ack) begin
              boot_req <= 1'b0;
              case (intr_step)
                4'd0: it_base <= bus_rdata;
                4'd1: int_sp  <= bus_rdata;
                default: irqv <= bus_rdata;
              endcase
              intr_step <= intr_step + 4'd1;
            end

            // do_call(IRQV, 7, SP). A nested interrupt keeps the running SP; a
            // first one switches to the dedicated interrupt stack. PC bit 13 is
            // the interrupt flag. The +64 is MAME's padding against a save
            // underflow and is not optional -- the three writes below land
            // under FP.
            4'd3: begin
              rf_call    <= 1'b1;
              intr_call  <= 1'b1;
              call_tgt   <= irqv;
              intr_stack <= ((((pc_reg[13] ? cur_sp : int_sp) + 32'd63)
                              & 32'hffff_ffc0) + 32'd64);
              intr_step  <= 4'd4;
            end

            4'd4: if (!rf_busy && !rf_call && !rf_ret && !rf_flush) begin
              intr_call <= 1'b0;
              intr_step <= 4'd5;
            end

            // Save the interrupted process state under the NEW frame.
            4'd5, 4'd6, 4'd7: if (!boot_req) begin
              aux_we   <= 1'b1;
              boot_req <= 1'b1;
              case (intr_step)
                4'd5: begin boot_addr <= cur_fp - 32'd16; aux_wdata <= pc_reg; end
                4'd6: begin boot_addr <= cur_fp - 32'd12; aux_wdata <= ac; end
                default: begin boot_addr <= cur_fp - 32'd8;
                               aux_wdata <= {24'd0, cur_vec} - 32'd8; end
              endcase
            end else if (boot_ack) begin
              boot_req  <= 1'b0;
              intr_step <= intr_step + 4'd1;
            end

            default: begin
              aux_we <= 1'b0;
              // MAME clears 0x1f00 -- bits 8 to 12 -- and then ORs the new level
              // into bits 16 to 20 WITHOUT clearing them first. Its own comment
              // says "clear priority", and 0x1f00 is not the priority field, so
              // the priority accumulates bits across nested interrupts. That is
              // the oracle's behaviour and it is what the games were validated
              // against, so it is reproduced exactly. Recorded in study R21;
              // do not "fix" it without evidence from silicon.
              pc_reg <= ((pc_reg & ~32'h0000_1f00)
                         | ({27'd0, cur_lvl} << 16)) | 32'h0000_2002;
              ip     <= irqv;
              ts     <= T_FETCH;
              intr_taken_cnt <= intr_taken_cnt + 32'd1;
            end
          endcase

          // ---- check_pending_irqs ----
          default: case (intr_step)
            4'd0, 4'd1: if (!boot_req) begin
              aux_we    <= 1'b0;
              boot_req  <= 1'b1;
              boot_addr <= (intr_step == 4'd0) ? (prcb_reg + 32'd20) : it_base;
            end else if (boot_ack) begin
              boot_req <= 1'b0;
              if (intr_step == 4'd0) begin it_base  <= bus_rdata; intr_step <= 4'd1; end
              else                   begin pend_pri <= bus_rdata; intr_step <= 4'd2; end
            end

            4'd2: if (!have_lvl) ts <= T_FETCH;      // nothing eligible
                  else begin cur_lvl <= top_lvl; intr_step <= 4'd3; end

            4'd3: if (!boot_req) begin
              aux_we    <= 1'b0;
              boot_addr <= it_base + {27'd0, cur_lvl[4:2], 2'b00} + 32'd4;
              boot_req  <= 1'b1;
            end else if (boot_ack) begin
              boot_req  <= 1'b0;
              vword     <= bus_rdata;
              intr_step <= 4'd4;
            end

            // take_idx is latched HERE because step 5 rewrites vword, and
            // top_bit is combinational from it.
            4'd4: if (!have_bit) begin
              pend_abort <= 1'b1;
              intr_step  <= 4'd7;
            end else begin
              take_idx   <= {cur_lvl[1:0], top_bit};
              cur_vec    <= {cur_lvl[4:2], cur_lvl[1:0], top_bit};
              pend_abort <= 1'b0;
              intr_step  <= 4'd5;
            end

            4'd5: if (!boot_req) begin
              aux_we    <= 1'b1;
              boot_addr <= it_base + {27'd0, cur_lvl[4:2], 2'b00} + 32'd4;
              aux_wdata <= vword & ~(32'd1 << take_idx);
              boot_req  <= 1'b1;
            end else if (boot_ack) begin
              boot_req  <= 1'b0;
              aux_we    <= 1'b0;
              vword     <= vword & ~(32'd1 << take_idx);
              intr_step <= 4'd6;
            end

            // If that level has no vectors left, clear its summary bit too.
            4'd6: intr_step <= (lvl_byte == 8'd0) ? 4'd7 : 4'd8;

            4'd7: if (!boot_req) begin
              aux_we    <= 1'b1;
              boot_addr <= it_base;
              aux_wdata <= pend_pri & ~(32'd1 << cur_lvl);
              boot_req  <= 1'b1;
            end else if (boot_ack) begin
              boot_req <= 1'b0;
              aux_we   <= 1'b0;
              // A flagged level with no vector under it is a corrupt table.
              // MAME logs, clears the level and gives up rather than taking
              // anything; reproduced, because a generator can build this state.
              if (pend_abort) ts <= T_FETCH;
              else            intr_step <= 4'd8;
            end

            default: begin
              intr_mode <= M_TAKE;
              intr_step <= 4'd0;
            end
          endcase
        endcase

        T_TRAP: begin
          trap   <= 1'b1;
          halted <= 1'b1;
        end

        default: ts <= T_FETCH;
      endcase
    end
  end

endmodule
