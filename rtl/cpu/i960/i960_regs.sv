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
// 16 locals (r0-r15) and 16 globals (g0-g15) live in flip-flops and are read
// combinationally. Four saved frames live in a small memory. Spill and fill
// beyond four frames go to external memory through a request/ack port.
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
  parameter int unsigned CACHE_FRAMES = 4    // I960_RCACHE_SIZE. Do not change.
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

  logic [31:0] loc [0:15];
  logic [31:0] glb [0:15];

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
  logic [31:0] rcache_frame_addr [0:CACHE_FRAMES-1];

  logic            rc_we;
  logic [3:0]      rc_waddr;
  logic [3:0]      rc_raddr;
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
    rd1_c = ra1[4] ? glb[ra1[3:0]] : loc[ra1[3:0]];
    rd2_c = ra2[4] ? glb[ra2[3:0]] : loc[ra2[3:0]];
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
  logic [2:0]  fl_frame;     // frame being flushed
  logic [31:0] spill_base;
  logic        to_memory;    // this save/load uses memory rather than the cache

  // Cache slot index. Two bits, not a wide counter: it is only meaningful when
  // the frame is actually in the cache, and `to_memory` already records when it
  // is not. Deriving it from a wide signed value left 29 bits unread, which the
  // lint correctly flagged as a field extracted and then forgotten.
  logic [1:0]  slot;

  // Flattened cache index. ROWS is a power of two, so frame*ROWS + row is a
  // concatenation rather than a multiply.
  logic [3:0]  rc_wr_idx;
  logic [3:0]  rc_fl_idx;
  logic [1:0]  fl_word;      // word within the row being flushed
  assign rc_wr_idx = {slot, idx[3:2]};
  assign rc_fl_idx = {fl_frame[1:0], idx[3:2]};

  // Memory port drive. Combinational from state so the array block above stays
  // a plain inferrable template with nothing conditional inside it.
  always_comb begin
    rc_we    = (state == S_CALL_SAVE) && !to_memory;
    rc_waddr = rc_wr_idx;
    rc_wdata = {loc[{idx[3:2], 2'd3}], loc[{idx[3:2], 2'd2}],
                loc[{idx[3:2], 2'd1}], loc[{idx[3:2], 2'd0}]};
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

  assign dbg_rip        = loc[R_RIP];
  assign dbg_pfp        = loc[R_PFP];
  assign dbg_rcache_pos = rcache_pos;
  assign dbg_to_memory  = to_memory;

  // Frame pointer is g15. Named for readability; there is no separate storage.
  localparam int unsigned R_PFP = 0;
  localparam int unsigned R_SP  = 1;
  localparam int unsigned R_RIP = 2;
  localparam int unsigned G_FP  = 15;

  logic [31:0] fp_masked;
  assign fp_masked = glb[G_FP] & 32'hffff_ffc0;   // FP & ~0x3f

  assign cur_fp       = glb[G_FP];
  assign cur_sp       = loc[R_SP];
  assign cur_pfp_type = loc[R_PFP][2:0];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state         <= S_IDLE;
      rcache_pos    <= 32'sd0;
      idx           <= 4'd0;
      fl_frame      <= 3'd0;
      fl_word       <= 2'd0;
      mem_req       <= 1'b0;
      mem_we        <= 1'b0;
      next_ip_valid <= 1'b0;
      ret_unsupported <= 1'b0;
      to_memory     <= 1'b0;
      spill_base    <= 32'd0;
      slot          <= 2'd0;
      // The register arrays are deliberately NOT cleared here. Clearing an
      // array in reset forces it out of RAM into flip-flops — measured on this
      // toolchain, docs/mister-integration.md. Architectural registers are
      // undefined at reset on the real part too.
    end else begin
      next_ip_valid <= 1'b0;

      // Ordinary write. Frame operations own the file while busy, so an
      // external write during a spill would race the copy.
      if (we && !busy) begin
        if (wa[4]) glb[wa[3:0]] <= wd;
        else       loc[wa[3:0]] <= wd;
      end

      // Written outside the state machine: it happens once, during T_BOOT,
      // before any instruction has executed and so before any state the
      // machine below could be in.
      if (boot_fp_we) begin
        glb[G_FP] <= boot_fp;
        loc[R_SP] <= boot_fp + 32'd64;
      end

      case (state)

        // ------------------------------------------------------------ idle
        S_IDLE: begin
          if (op_call) begin
            // do_call step 1: RIP takes the return address BEFORE the save, so
            // the saved frame carries it.
            loc[R_RIP] <= call_ip;
            slot       <= rcache_pos[1:0];
            to_memory  <= (rcache_pos >= $signed(CACHE_FRAMES));
            spill_base <= fp_masked;
            idx        <= 4'd0;
            state      <= S_CALL_SAVE;
          end else if (op_ret && (loc[R_PFP][2:0] != 3'd0)
                                && (loc[R_PFP][2:0] != 3'd7)) begin
            ret_unsupported <= 1'b1;
          end else if (op_ret) begin
            // do_ret_0 step 1: FP <- PFP & ~0x3f, then the depth decrements and
            // decides where the frame comes from.
            glb[G_FP]  <= loc[R_PFP] & 32'hffff_ffc0;
            spill_base <= loc[R_PFP] & 32'hffff_ffc0;
            slot       <= 2'((rcache_pos - 32'sd1));
            to_memory  <= ((rcache_pos - 32'sd1) >= $signed(CACHE_FRAMES)) ||
                          ((rcache_pos - 32'sd1) <  32'sd0);
            rcache_pos <= (rcache_pos - 32'sd1 < 32'sd0) ? 32'sd0
                                                        : rcache_pos - 32'sd1;
            idx        <= 4'd0;
            state      <= S_RET_LOAD;
          end else if (op_flushreg) begin
            // flushreg clamps the depth to the cache size first, then writes
            // every cached frame out and resets the depth to zero.
            fl_frame <= 3'd0;
            idx      <= 4'd0;
            state    <= (rcache_pos > 32'sd0) ? S_FLUSH_RD : S_IDLE;
            if (rcache_pos <= 32'sd0) rcache_pos <= 32'sd0;
          end
        end

        // ------------------------------------------------------- call save
        S_CALL_SAVE: begin
          if (to_memory) begin
            // Too deep for the cache: 16 dwords out to FP & ~0x3f.
            mem_req   <= 1'b1;
            mem_we    <= 1'b1;
            mem_addr  <= spill_base + {26'd0, idx, 2'b00};
            mem_wdata <= loc[idx];
            if (mem_ack) begin
              mem_req <= 1'b0;
              if (idx == 4'd15) state <= S_CALL_FIN;
              else              idx   <= idx + 4'd1;
            end
          end else begin
            // Into the cache, four words per cycle.
            // rc_we / rc_waddr / rc_wdata are driven above; nothing to do here
            // but record the frame address and advance.
            rcache_frame_addr[slot] <= spill_base;
            if (idx[3:2] == 2'd3) state <= S_CALL_FIN;
            else                  idx   <= idx + 4'd4;
          end
        end

        S_CALL_FIN: begin
          // do_call steps 3-8. The locals are NOT cleared: the callee inherits
          // the caller's values, which is what the reference does and what the
          // header explains at length.
          rcache_pos    <= rcache_pos + 32'sd1;
          loc[R_PFP]    <= (glb[G_FP] & 32'hffff_fff8) | {29'd0, call_type};
          glb[G_FP]     <= ((call_type == 3'd7 ? call_stack : loc[R_SP]) + 32'd63)
                           & 32'hffff_ffc0;
          loc[R_SP]     <= (((call_type == 3'd7 ? call_stack : loc[R_SP]) + 32'd63)
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
              loc[idx] <= mem_rdata;
              if (idx == 4'd15) state <= S_RET_FIN;
              else              idx   <= idx + 4'd1;
            end
          end else begin
            // Address is presented this cycle; the registered read lands next.
            state <= S_RET_CAP;
          end
        end

        S_RET_CAP: begin
          {loc[{idx[3:2], 2'd3}], loc[{idx[3:2], 2'd2}],
           loc[{idx[3:2], 2'd1}], loc[{idx[3:2], 2'd0}]} <= rc_q;
          if (idx[3:2] == 2'd3) state <= S_RET_FIN;
          else begin idx <= idx + 4'd4; state <= S_RET_LOAD; end
        end

        S_RET_FIN: begin
          next_ip       <= loc[R_RIP];
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
          mem_addr  <= rcache_frame_addr[fl_frame[1:0]] + {26'd0, idx[3:2], fl_word, 2'b00};
          mem_wdata <= rc_q[{fl_word, 5'd0} +: 32];
          if (mem_ack) begin
            mem_req <= 1'b0;
            if (fl_word == 2'd3) begin
              if (idx[3:2] == 2'd3) begin
                idx <= 4'd0;
                if ($signed({29'd0, fl_frame}) + 32'sd1 >= rcache_pos ||
                    fl_frame == 3'(CACHE_FRAMES - 1)) begin
                  rcache_pos <= 32'sd0;
                  state      <= S_IDLE;
                end else begin
                  fl_frame <= fl_frame + 3'd1;
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
