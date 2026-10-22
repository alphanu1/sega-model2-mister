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
// Semantics transcribed from MAME's i960 device (BSD-3-Clause, Farfetch'd and
// R. Belmont): do_call, do_ret, do_ret_0 and flushreg. See THIRD_PARTY.md.
//
// ---------------------------------------------------------------------------
//
// i960KB register file, register cache, and the call/return frame machinery.
//
// 16 locals (r0-r15) and 16 globals (g0-g15), read through registered ports.
// Four saved frames live in a small memory. Spill and fill beyond four frames
// go to external memory through a request/ack port.
//
// R866: THE REGISTERS ARE LUT RAM, NOT FLIP-FLOPS. r0-r2 and g15 (PFP, SP,
// RIP, FP) stay in flops: the frame operations write two or three of them in
// one cycle and the interrupt path reads them all the time. The other 28 live
// in MLAB as four banks by register number [1:0] (bank b holds r/g {row, b},
// eight words addressed {g, row}), so a frame row is four words at one address
// -- the cache's own shape -- and S_RET_CAP still lands a row a cycle. Every
// write into the banks is one architectural write, one memory fill word or one
// row: never two in a cycle (the architectural write needs !busy, the others
// are busy states). Three copies are written alike and read at three
// addresses: ra1, ra2 and the frame row the call save copies out. The reads are
// asynchronous and the registered ports and their bypass are unchanged, so
// every output is the flip-flop file's on every cycle (sim/i960/
// tb_i960_regs_miter.cpp runs both side by side).
//
// Named registers, from i960.h:
//   r0  PFP  previous frame pointer      r1  SP   stack pointer
//   r2  RIP  return instruction pointer  g15 FP   frame pointer
//
// ---------------------------------------------------------------------------
// Why the frames are copied rather than banked.
//
// The obvious optimisation is to hold five frames in one memory and make `call`
// a bank-pointer increment — O(1), no copy. It is wrong here, and the reason is
// easy to miss: MAME copies the locals into the cache and **does not clear
// them**, so the callee's frame starts life holding the caller's register
// values. A banked design would instead hand the callee whatever the last call
// at that same depth left behind. Both are "undefined" to a compiler; they are
// different to a lockstep comparison, which is the only oracle this core has.
//
// So the copy stays, and is made cheap instead of skipped: the cache is four
// words wide, so a frame moves in 4 cycles rather than 16 — inside the 9 cycles
// the reference already charges for `call`.
//
// ---------------------------------------------------------------------------
// Why MLAB and not M10K.
//
// 4 frames x 16 words x 32 bits = 2048 bits. It would fit in a single M10K, but
// design study §5.6 records that M10K is the resource under pressure on this
// part — the Model 1 core reports 409 of 553 spent with a simpler renderer, and
// Model 2 adds ~78 blocks of tile buffer and texture cache that Model 1 never
// needed. ALM has the headroom; M10K does not. `ramstyle = "MLAB"` spends LUTs
// instead, deliberately.
//
// The tag is explicit so a regression is a build error rather than a silent
// resource catastrophe, per docs/mister-integration.md. Single write port and
// single read port: Quartus 17.0 will not infer a two-write-port memory, and
// the array is never cleared in reset.
//
// MEASURED, and the first attempt failed. Written with the array read directly
// inside the control FSM, Quartus reported:
//
//   Info (276009): RAM logic "rcache" is uninferred due to unsupported
//                  read-during-write behavior
//   Total MLAB memory bits : 0
//
// It became flip-flops instead: 3,303 registers and 2,355 ALM for the module.
// Simulation cannot see this — Verilator has no opinion about where storage
// lands — and it is why the standing rule is to watch the register count, not
// just the memory count. The array now has a dedicated write port and a
// dedicated registered read port driven by their own address signals, which is
// the pattern the tool infers. The read latency that buys costs one extra
// cycle per row on the fill and flush paths, which is why those states are
// split into issue and capture.
//
// ---------------------------------------------------------------------------
// Cache depth is architecturally invisible and memory-visible.
//
// The architecture leaves the depth implementation-defined and correct software
// must not depend on it. That does NOT make it free to change: a spilled frame
// writes to external memory, so depth changes the memory write stream, which is
// exactly what lockstep compares. Four frames, matching the reference.
// docs/p1-i960-spike.md §2.2.

module i960_regs #(
  // I960_RCACHE_SIZE. Do not change with RING = 0: MAME's rule and its
  // memory stream, which the lockstep benches compare.
  parameter int unsigned CACHE_FRAMES = 4,
  // R927: THE CHIP'S RING, NOT MAME'S DEPTH RULE. 0: MAME's do_call / do_ret_0
  // (the frames at depth 0-3 since the last flushreg live in the cache, EVERY
  // deeper one goes to memory on its call and comes back on its return). 1:
  // the i960's own local-register cache -- CACHE_FRAMES saved frames in a
  // ring; a call that finds it full writes the OLDEST out to its own frame
  // first, a return that finds it empty reads the frame from memory, flushreg
  // writes every cached frame. Code at a steady depth then never touches
  // memory for its frames, however deep it runs. The difference is visible
  // only in the 64-byte register save areas, which the architecture leaves
  // undefined until flushreg (MAME's own stream is one implementation's).
  // CACHE_FRAMES a power of two, at most 8 (one MLAB deep).
  parameter bit          RING         = 1'b0
) (
  input  logic        clk,
  input  logic        rst_n,

  // ------- architectural read/write, combinational read
  input  logic [4:0]  ra1,
  input  logic [4:0]  ra2,
  output logic [31:0] rd1,
  output logic [31:0] rd2,

  input  logic [4:0]  wa,
  input  logic [31:0] wd,
  input  logic        we,

  // ------- frame operations. Assert for one cycle with `busy` low.
  input  logic        op_call,       // do_call
  input  logic        op_ret,        // do_ret
  // PFP[2:0] IS THE RETURN TYPE, and this module ignored it. So did its
  // reference, which is why lockstep stayed silent -- the two agreed while both
  // were wrong (study R14). MAME dispatches: 0 is an ordinary return, 7 is an
  // interrupt return that also restores PC and AC from the frame, and 1 to 6 are
  // fatalerror.
  //
  // Types 1-6 now raise this rather than silently performing a type-0 return.
  //
  // TYPE 7 IS NOT AN ERROR: it is the interrupt return, and MAME performs a full
  // do_ret_0 for it and then restores PC and AC from the frame. This module does
  // the do_ret_0 half, which is all of it that is reachable -- nothing here can
  // create a type-7 frame until interrupts exist. The PC and AC restore lands
  // with the interrupt work, and its absence is recorded rather than trapped,
  // because trapping a legal return type would be a different wrong answer.
  output logic        ret_unsupported,
  input  logic        op_flushreg,   // flushreg
  input  logic [31:0] call_ip,       // IP of the instruction after the call
  input  logic [31:0] call_target,   // new IP
  input  logic [2:0]  call_type,     // PFP low bits; 7 = interrupt
  input  logic [31:0] call_stack,    // SP override, used when call_type == 7
  output logic        busy,
  output logic [31:0] next_ip,       // IP the sequencer should take
  output logic        next_ip_valid,

  // Taps the interrupt path needs. take_interrupt saves PC, AC and the vector
  // at FP-16/-12/-8 AFTER the type-7 call has moved FP, a type-7 ret reads them
  // back from FP BEFORE do_ret_0 moves it again, and the return type itself is
  // PFP[2:0]. Dedicated outputs rather than borrowing ra1/ra2, which decode
  // owns -- sharing them would make the interrupt sequence depend on what the
  // interrupted instruction happened to be reading.
  output logic [31:0] cur_fp,
  output logic [31:0] cur_sp,
  output logic  [2:0] cur_pfp_type,
  // FRAME STATE, for tracing a `ret` that goes somewhere impossible. cur_fp and
  // cur_sp say where the frame IS; these say what it CONTAINS and whether the
  // register cache is deep enough to hold it, which is the difference between
  // a frame that was restored wrongly and one that was never saved.
  // THE INITIAL FRAME POINTER, FROM THE PRCB. i960.cpp's device_reset:
  //
  //   m_r[I960_FP] = m_program.read_dword(m_PRCB+24);
  //   m_r[I960_SP] = m_r[I960_FP] + 64;
  //
  // Without it FP starts at zero and frames allocate upwards from there --
  // 0x40, 0x80, 0xc0, 0x100 -- which are the boot record and program ROM. That
  // is invisible until the call depth exceeds the register cache, because
  // nothing touches memory until a frame has to spill.
  input  logic        boot_fp_we,
  input  logic [31:0] boot_fp,

  output logic [31:0] dbg_rip,
  output logic [31:0] dbg_pfp,
  output logic signed [31:0] dbg_rcache_pos,
  output logic        dbg_to_memory,

  // ------- external memory, request/ack. Ack is a level, not a pulse:
  // docs/mister-integration.md — a pulsed ack to a ce-gated requester is
  // missed and the requester waits forever. That fault bit Model 1 twice.
  output logic        mem_req,
  output logic        mem_we,
  output logic [31:0] mem_addr,
  output logic [31:0] mem_wdata,
  input  logic [31:0] mem_rdata,
  input  logic        mem_ack
);

  localparam int unsigned W        = 4;                 // words moved per cycle
  localparam int unsigned ROWS     = 16 / W;            // rows per frame
  localparam int unsigned CACHE_SZ = CACHE_FRAMES * ROWS;

  // --------------------------------------------------------------- storage

  // R866: r0-r2 and g15 in flops; the other 28 in the banks below.
  logic [31:0] r_pfp, r_sp, r_rip, g_fp;

  // Bank write port: one address and a word enable per bank, shared by the
  // three copies.
  logic [3:0]   bk_we;
  logic [2:0]   bk_wa;
  logic [127:0] bk_wd;
  logic [127:0] bk_q1, bk_q2, bk_qr;           // rows at ra1, ra2, the frame row
  wire  [2:0]   bk_ra1 = {ra1[4], ra1[3:2]};
  wire  [2:0]   bk_ra2 = {ra2[4], ra2[3:2]};
  logic [2:0]   bk_rar;                        // {0, idx[3:2]}, below idx

  genvar gb;
  generate for (gb = 0; gb < 4; gb = gb + 1) begin : g_bank
    i960_rf_bank u_b1 (.clk(clk), .we(bk_we[gb]), .wa(bk_wa), .wd(bk_wd[gb*32 +: 32]),
                       .ra(bk_ra1), .q(bk_q1[gb*32 +: 32]));
    i960_rf_bank u_b2 (.clk(clk), .we(bk_we[gb]), .wa(bk_wa), .wd(bk_wd[gb*32 +: 32]),
                       .ra(bk_ra2), .q(bk_q2[gb*32 +: 32]));
    i960_rf_bank u_br (.clk(clk), .we(bk_we[gb]), .wa(bk_wa), .wd(bk_wd[gb*32 +: 32]),
                       .ra(bk_rar), .q(bk_qr[gb*32 +: 32]));
  end endgenerate

  // A register by number from a bank row, the four flops taking their own.
  function automatic logic [31:0] pick(input logic [4:0] n, input logic [127:0] row,
                                       input logic [31:0] pfp, input logic [31:0] sp,
                                       input logic [31:0] rip, input logic [31:0] fp);
    case (n)
      5'd0:    pick = pfp;
      5'd1:    pick = sp;
      5'd2:    pick = rip;
      5'd31:   pick = fp;
      default: pick = row[n[1:0]*32 +: 32];
    endcase
  endfunction

  localparam int unsigned SW = $clog2(CACHE_FRAMES);   // R927: slot bits (2 for 4)

  // Four saved frames, four words per row. MLAB rather than M10K — see header.
  // Dedicated ports: one write, one registered read, each with its own address.
  // Reading the array inside the control FSM is what defeated inference.
  (* ramstyle = "MLAB" *) logic [W*32-1:0] rcache [0:CACHE_SZ-1];
  // Four words. Quartus inferred this into an altsyncram and spent a whole
  // 10 Kbit M10K block on 128 bits -- one of 553, for a resource §5.6 records
  // as the one under pressure on this part while ALM has headroom. It is
  // addressed by two different indices in the same cycle and is far too small
  // to be worth a block, so it is pinned to logic. Caught only because the
  // fitter report started printing M10K; it had been extracting and discarding
  // that column since the first measurement.
  (* ramstyle = "logic" *)
  // R927: [31:6] -- a frame is 64-byte aligned (FP & ~0x3f), so its words'
  // addresses are a concatenation, not a sum.
  logic [31:6] rcache_frame_addr [0:CACHE_FRAMES-1];

  logic            rc_we;
  logic [SW+1:0]   rc_waddr;
  logic [SW+1:0]   rc_raddr;
  logic [W*32-1:0] rc_wdata;
  logic [W*32-1:0] rc_q;

  always_ff @(posedge clk) begin
    if (rc_we) rcache[rc_waddr] <= rc_wdata;
    rc_q <= rcache[rc_raddr];
  end

  // Depth counter, exactly MAME's m_rcache_pos. Signed, because do_ret_0
  // decrements first and tests for < 0 to detect the post-flushreg case.
  logic signed [31:0] rcache_pos;

  // --------------------------------------------------------------- read

  // Registered, not combinational. The measured critical path was
  // `ra1[2]` -> `wd[28]`: the read address ran through this 32:1 multiplexer,
  // through the ALU and FP result muxing, and into writeback -- one
  // combinational path from address to result, which is why Fmax sat at 25 MHz.
  // Terminating the read at a register splits that path in two.
  //
  // The sequencer tolerates the latency without change: every read address is
  // presented in the state before the one that consumes it, so i960_top drives
  // ra1/ra2 combinationally and this register supplies the cycle the sequencer
  // used to. Cost measured at zero -- the lockstep run takes the same 65,630
  // cycles either way.
  //
  // WRITE BYPASS, and it earns its place -- but it did not always. The history
  // is worth keeping, because the same evidence gave opposite answers either
  // side of a front-end change.
  //
  // When the sequencer still had a T_DECODE state, both bypass forms were
  // mutation-tested and BOTH SURVIVED: across 3,870 retires and 147,060 checks
  // nothing distinguished having them. It was removed as dead logic that also
  // changed semantics in a case with no oracle -- an overlapping movl/movt/movq
  // (`movl r4, r5`), where T_MULTI writes word i while reading word i+1, and
  // which MAME implements with memcpy on overlapping regions (undefined in C).
  //
  // Removing T_DECODE made the hazard ordinary. The read address is now
  // presented in the same cycle the previous instruction's write lands, where
  // T_FETCH and T_DECODE used to separate them, so a plain read returns the
  // stale word. Restored, and BOTH mutants are now KILLED.
  //
  // The lesson is about the evidence, not the bypass: "no test distinguishes
  // this" is a statement about the design as it stands, and it expires the
  // moment the pipeline around it changes. Re-run the mutation, do not recall
  // the result. The overlapping-movl behaviour is still unspecified by the
  // oracle; it now propagates, and only the i960KB manual or silicon can say
  // whether that is right. See HANDOFF.md.
  logic [31:0] rd1_c, rd2_c;
  always_comb begin
    rd1_c = pick(ra1, bk_q1, r_pfp, r_sp, r_rip, g_fp);
    rd2_c = pick(ra2, bk_q2, r_pfp, r_sp, r_rip, g_fp);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd1 <= 32'd0;
      rd2 <= 32'd0;
    end else begin
      rd1 <= (we && (wa == ra1)) ? wd : rd1_c;
      rd2 <= (we && (wa == ra2)) ? wd : rd2_c;
    end
  end

  // --------------------------------------------------------------- control

  typedef enum logic [2:0] {
    S_IDLE,
    S_CALL_SAVE,     // current locals -> cache slot, or -> memory if too deep
    S_CALL_FIN,
    S_RET_LOAD,      // cache slot -> current locals, or memory -> locals
    S_RET_CAP,       // registered cache read lands here
    S_RET_FIN,
    S_FLUSH_RD,      // issue a cache row read
    S_FLUSH_WR       // drive its four words out to memory
  } state_e;

  state_e      state;
  logic [3:0]  idx;          // word index within a frame, 0..15
  logic [SW:0] fl_frame;     // frame being flushed
  // R927 (RING): the ring's newest frame, how many it holds, a spill that a
  // call makes before its save (fl_call), and the frames a flushreg has left
  logic [SW-1:0] r_head;
  logic [SW:0]   r_n, fl_left;
  logic          fl_call;
  logic [31:0] spill_base;
  logic        to_memory;    // this save/load uses memory rather than the cache

  // Cache slot index. Two bits, not a wide counter: it is only meaningful when
  // the frame is actually in the cache, and `to_memory` already records when it
  // is not. Deriving it from a wide signed value left 29 bits unread, which the
  // lint correctly flagged as a field extracted and then forgotten.
  logic [SW-1:0] slot;

  // Flattened cache index. ROWS is a power of two, so frame*ROWS + row is a
  // concatenation rather than a multiply.
  logic [SW+1:0] rc_wr_idx;
  logic [SW+1:0] rc_fl_idx;
  logic [1:0]  fl_word;      // word within the row being flushed
  assign rc_wr_idx = {slot, idx[3:2]};
  assign bk_rar    = {1'b0, idx[3:2]};
  assign rc_fl_idx = {fl_frame[SW-1:0], idx[3:2]};

  // Memory port drive. Combinational from state so the array block above stays
  // a plain inferrable template with nothing conditional inside it.
  always_comb begin
    rc_we    = (state == S_CALL_SAVE) && !to_memory;
    rc_waddr = rc_wr_idx;
    // R866: the frame row from the bank copy at {0, idx[3:2]}; row 0's first
    // three words are the flops
    rc_wdata = (idx[3:2] == 2'd0) ? {bk_qr[127:96], r_rip, r_sp, r_pfp} : bk_qr;
    // The read address must be HELD for as long as rc_q is being consumed, not
    // just during the cycle that issues it: the array registers rc_q every
    // cycle, so letting the address move mid-row silently replaces the data
    // under the flush. That produced correct addresses carrying the wrong
    // frame's words — the exact shape of bug the memory-stream comparison is
    // there to catch.
    rc_raddr = (state == S_FLUSH_RD || state == S_FLUSH_WR) ? rc_fl_idx
                                                            : rc_wr_idx;
  end

  assign busy = (state != S_IDLE);

  // R866: the banks' one write port. The architectural write needs !busy; the
  // memory fill word and the cache row are busy states -- never two at once.
  // Nothing is written in reset, as the flip-flop file's writes sat in the
  // reset's else branch.
  always_comb begin
    bk_we = 4'd0;
    bk_wa = {wa[4], wa[3:2]};
    bk_wd = {4{wd}};
    if (we && !busy) bk_we[wa[1:0]] = 1'b1;
    if (state == S_RET_LOAD && to_memory && mem_ack) begin
      bk_wa = {1'b0, idx[3:2]};
      bk_wd = {4{mem_rdata}};
      bk_we = 4'd1 << idx[1:0];
    end
    if (state == S_RET_CAP) begin
      bk_wa = {1'b0, idx[3:2]};
      bk_wd = rc_q;
      bk_we = 4'hf;
    end
    if (!rst_n) bk_we = 4'd0;
  end

  assign dbg_rip        = r_rip;
  assign dbg_pfp        = r_pfp;
  assign dbg_rcache_pos = rcache_pos;
  assign dbg_to_memory  = to_memory;

  // r0 = r_pfp, r1 = r_sp, r2 = r_rip, g15 (the frame pointer) = g_fp.

  logic [31:0] fp_masked;
  assign fp_masked = g_fp & 32'hffff_ffc0;   // FP & ~0x3f

  assign cur_fp       = g_fp;
  assign cur_sp       = r_sp;
  assign cur_pfp_type = r_pfp[2:0];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state         <= S_IDLE;
      rcache_pos    <= 32'sd0;
      idx           <= 4'd0;
      fl_frame      <= '0;
      r_head        <= '1;     // R927: the first frame lands in slot 0
      r_n           <= '0;
      fl_left       <= '0;
      fl_call       <= 1'b0;
      fl_word       <= 2'd0;
      mem_req       <= 1'b0;
      mem_we        <= 1'b0;
      next_ip_valid <= 1'b0;
      ret_unsupported <= 1'b0;
      to_memory     <= 1'b0;
      spill_base    <= 32'd0;
      slot          <= '0;
      // The register arrays are deliberately NOT cleared here. Clearing an
      // array in reset forces it out of RAM into flip-flops — measured on this
      // toolchain, docs/mister-integration.md. Architectural registers are
      // undefined at reset on the real part too.
    end else begin
      next_ip_valid <= 1'b0;

      // Ordinary write. Frame operations own the file while busy, so an
      // external write during a spill would race the copy.
      if (we && !busy) begin
        // R866: the four flops here; every number also goes to the banks
        // (bk_we, below), where 0-2 and 31 are written and never read.
        case (wa)
          5'd0:  r_pfp <= wd;
          5'd1:  r_sp  <= wd;
          5'd2:  r_rip <= wd;
          5'd31: g_fp  <= wd;
          default: ;
        endcase
      end

      // Written outside the state machine: it happens once, during T_BOOT,
      // before any instruction has executed and so before any state the
      // machine below could be in.
      if (boot_fp_we) begin
        g_fp <= boot_fp;
        r_sp <= boot_fp + 32'd64;
      end

      case (state)

        // ------------------------------------------------------------ idle
        S_IDLE: begin
          if (op_call) begin
            // do_call step 1: RIP takes the return address BEFORE the save, so
            // the saved frame carries it.
            r_rip      <= call_ip;
            spill_base <= fp_masked;
            idx        <= 4'd0;
            if (RING) begin
              // R927: into the slot after the newest; a full ring writes
              // that slot's frame (the oldest) out first
              slot      <= r_head + 1'b1;
              to_memory <= 1'b0;
              fl_frame  <= {1'b0, r_head + 1'b1};
              fl_call   <= (r_n == (SW+1)'(CACHE_FRAMES));
              state     <= (r_n == (SW+1)'(CACHE_FRAMES)) ? S_FLUSH_RD : S_CALL_SAVE;
            end else begin
              slot       <= rcache_pos[SW-1:0];
              to_memory  <= (rcache_pos >= $signed(CACHE_FRAMES));
              state      <= S_CALL_SAVE;
            end
          end else if (op_ret && (r_pfp[2:0] != 3'd0)
                                && (r_pfp[2:0] != 3'd7)) begin
            ret_unsupported <= 1'b1;
          end else if (op_ret) begin
            // do_ret_0 step 1: FP <- PFP & ~0x3f, then the depth decrements and
            // decides where the frame comes from.
            g_fp       <= r_pfp & 32'hffff_ffc0;
            spill_base <= r_pfp & 32'hffff_ffc0;
            if (RING) begin
              // R927: the newest cached frame, or memory when the ring is empty
              slot      <= r_head;
              to_memory <= (r_n == '0);
              if (r_n != '0) begin r_head <= r_head - 1'b1; r_n <= r_n - 1'b1; end
            end else begin
              slot       <= SW'((rcache_pos - 32'sd1));
              to_memory  <= ((rcache_pos - 32'sd1) >= $signed(CACHE_FRAMES)) ||
                            ((rcache_pos - 32'sd1) <  32'sd0);
            end
            rcache_pos <= (rcache_pos - 32'sd1 < 32'sd0) ? 32'sd0
                                                        : rcache_pos - 32'sd1;
            idx        <= 4'd0;
            state      <= S_RET_LOAD;
          end else if (op_flushreg) begin
            // flushreg clamps the depth to the cache size first, then writes
            // every cached frame out and resets the depth to zero.
            idx      <= 4'd0;
            if (RING) begin
              // R927: every cached frame, oldest first
              fl_frame <= {1'b0, r_head - SW'(r_n) + 1'b1};
              fl_left  <= r_n;
              fl_call  <= 1'b0;
              state    <= (r_n != '0) ? S_FLUSH_RD : S_IDLE;
              rcache_pos <= 32'sd0;
            end else begin
              fl_frame <= '0;
              state    <= (rcache_pos > 32'sd0) ? S_FLUSH_RD : S_IDLE;
              if (rcache_pos <= 32'sd0) rcache_pos <= 32'sd0;
            end
          end
        end

        // ------------------------------------------------------- call save
        S_CALL_SAVE: begin
          if (to_memory) begin
            // Too deep for the cache: 16 dwords out to FP & ~0x3f.
            mem_req   <= 1'b1;
            mem_we    <= 1'b1;
            mem_addr  <= spill_base + {26'd0, idx, 2'b00};
            mem_wdata <= pick({1'b0, idx}, bk_qr, r_pfp, r_sp, r_rip, g_fp);
            if (mem_ack) begin
              mem_req <= 1'b0;
              if (idx == 4'd15) state <= S_CALL_FIN;
              else              idx   <= idx + 4'd1;
            end
          end else begin
            // Into the cache, four words per cycle.
            // rc_we / rc_waddr / rc_wdata are driven above; nothing to do here
            // but record the frame address and advance.
            rcache_frame_addr[slot] <= spill_base[31:6];
            if (idx[3:2] == 2'd3) state <= S_CALL_FIN;
            else                  idx   <= idx + 4'd4;
          end
        end

        S_CALL_FIN: begin
          // do_call steps 3-8. The locals are NOT cleared: the callee inherits
          // the caller's values, which is what the reference does and what the
          // header explains at length.
          rcache_pos    <= rcache_pos + 32'sd1;
          if (RING) begin
            r_head <= slot;
            if (r_n != (SW+1)'(CACHE_FRAMES)) r_n <= r_n + 1'b1;
          end
          r_pfp         <= (g_fp & 32'hffff_fff8) | {29'd0, call_type};
          g_fp          <= ((call_type == 3'd7 ? call_stack : r_sp) + 32'd63)
                           & 32'hffff_ffc0;
          r_sp          <= (((call_type == 3'd7 ? call_stack : r_sp) + 32'd63)
                           & 32'hffff_ffc0) + 32'd64;
          next_ip       <= call_target;
          next_ip_valid <= 1'b1;
          state         <= S_IDLE;
        end

        // -------------------------------------------------------- ret load
        S_RET_LOAD: begin
          if (to_memory) begin
            mem_req  <= 1'b1;
            mem_we   <= 1'b0;
            mem_addr <= spill_base + {26'd0, idx, 2'b00};
            if (mem_ack) begin
              mem_req  <= 1'b0;
              case (idx)                     // R866: the banks take it too
                4'd0: r_pfp <= mem_rdata;
                4'd1: r_sp  <= mem_rdata;
                4'd2: r_rip <= mem_rdata;
                default: ;
              endcase
              if (idx == 4'd15) state <= S_RET_FIN;
              else              idx   <= idx + 4'd1;
            end
          end else begin
            // Address is presented this cycle; the registered read lands next.
            state <= S_RET_CAP;
          end
        end

        S_RET_CAP: begin
          if (idx[3:2] == 2'd0)              // R866: the banks take the row
            {r_rip, r_sp, r_pfp} <= rc_q[95:0];
          if (idx[3:2] == 2'd3) state <= S_RET_FIN;
          else begin idx <= idx + 4'd4; state <= S_RET_LOAD; end
        end

        S_RET_FIN: begin
          next_ip       <= r_rip;
          next_ip_valid <= 1'b1;
          state         <= S_IDLE;
        end

        // ----------------------------------------------------------- flush
        S_FLUSH_RD: begin
          // Address presented; rc_q is valid next cycle.
          fl_word <= 2'd0;
          state   <= S_FLUSH_WR;
        end

        S_FLUSH_WR: begin
          mem_req   <= 1'b1;
          mem_we    <= 1'b1;
          mem_addr  <= {rcache_frame_addr[fl_frame[SW-1:0]], idx[3:2], fl_word, 2'b00};
          mem_wdata <= rc_q[{fl_word, 5'd0} +: 32];
          if (mem_ack) begin
            mem_req <= 1'b0;
            if (fl_word == 2'd3) begin
              if (idx[3:2] == 2'd3) begin
                idx <= 4'd0;
                if (RING && fl_call) begin
                  // R927: the oldest frame is out; its slot takes the call's
                  fl_call <= 1'b0;
                  state   <= S_CALL_SAVE;
                end else if (RING) begin
                  fl_frame <= {1'b0, fl_frame[SW-1:0] + 1'b1};
                  fl_left  <= fl_left - 1'b1;
                  if (fl_left == (SW+1)'(1)) begin
                    r_n   <= '0;
                    state <= S_IDLE;
                  end else
                    state <= S_FLUSH_RD;
                end else if ($signed({{(31-SW){1'b0}}, fl_frame}) + 32'sd1 >= rcache_pos ||
                    fl_frame == (SW+1)'(CACHE_FRAMES - 1)) begin
                  rcache_pos <= 32'sd0;
                  state      <= S_IDLE;
                end else begin
                  fl_frame <= fl_frame + 1'b1;
                  state    <= S_FLUSH_RD;
                end
              end else begin
                idx   <= idx + 4'd4;
                state <= S_FLUSH_RD;
              end
            end else begin
              fl_word <= fl_word + 2'd1;
            end
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule

// R866: one bank of the register file -- eight 32-bit words, one write port,
// an asynchronous read (MLAB, like the i-cache's tags). Never cleared.
module i960_rf_bank (
  input  logic        clk,
  input  logic        we,
  input  logic [2:0]  wa,
  input  logic [31:0] wd,
  input  logic [2:0]  ra,
  output logic [31:0] q
);
  (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] mem [0:7];
  always_ff @(posedge clk) if (we) mem[wa] <= wd;
  assign q = mem[ra];
endmodule
