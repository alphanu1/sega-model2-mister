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
// Sequencing transcribed from MAME's i960 device: the MEM opcodes and
// i960_read/write_word/dword_unaligned (BSD-3-Clause, Farfetch'd, R. Belmont).
// See THIRD_PARTY.md.
//
// ---------------------------------------------------------------------------
//
// i960KB load/store sequencer.
//
// Turns one architectural load or store into the exact sequence of bus
// transactions the reference performs, in the same order. That order is
// architecturally visible — it is what lockstep compares — so this is not free
// to optimise.
//
// Three behaviours drive the whole design:
//
// 1. UNALIGNED ACCESS SPLITS INTO BYTES. The reference does not do a wide
//    access and rotate; it issues individual byte reads at addr, addr+1, ...
//    and assembles them little-endian:
//
//      if (!DWORD_ALIGNED(address))
//        return read_byte(address) | read_byte(address+1)<<8 | ...
//
//    So an unaligned dword is four bus transactions, not one, and a device with
//    side effects sees four accesses.
//
// 2. MULTI-WORD FORMS ADVANCE THE ADDRESS ONLY IN BURST REGIONS.
//
//      if (pack.second & BURST) t1 += 4;
//
//    In a non-burst region every word of ldl/ldt/ldq comes from the SAME
//    address. That is how the coprocessor FIFO is drained. i960_memmap decides.
//
// 3. THE DESTINATION REGISTER GROUP IS ALIGNED DOWN, by i960_ldst's reg_mask.
//    ldl uses srcdst & 0x1e; ldt and ldq use srcdst & 0x1c — ldt moves three
//    words but still aligns to four.
//
// The bus port is byte-address plus byte enables. Byte enables rather than a
// size code because that is what a 32-bit fabric wants, and byte address rather
// than dword address because it keeps the transaction stream directly
// comparable with the reference's own read_byte/read_dword calls.

module i960_lsu #(
  // R1011: A STORE'S FIRST WORD GOES OUT THE CYCLE AFTER THE REQUEST. i960_top
  // presents the store source to the register file in T_EXEC (ra1 = srcdst),
  // the cycle the request is made, so st_word is that register from the next
  // cycle -- the S_XFER cycle. S_OPD waited a cycle more for it. A later word
  // of stl / stt / stq still passes S_OPD (its register is addressed from
  // cur_idx, which moves on the previous word's acknowledge). 0: as before.
  parameter bit ST1 = 1'b1,
  // R1011: A ONE-WORD ALIGNED STORE IS POSTED. With ST1, its request goes out
  // the cycle after the LSU takes it, and in that same cycle the store is
  // reported done (done_now) -- the instruction retires -- while the request
  // stays up until the bus acknowledges it (`busy` meanwhile). Its data is
  // held in wd_q from that first cycle, since the register file's port moves
  // on with the next instruction. i960_top keeps the next load or store in
  // T_EXEC while `busy`, and every other master is behind the arbiter's grant,
  // which this request holds from its first cycle: every bus access is the
  // one it was, in the order it was; only the instructions between run
  // earlier. 0: the store retires on its acknowledge, as before.
  parameter bit POST = 1'b0
) (
  input  logic        clk,
  input  logic        rst_n,

  // ------- request. Assert `req` for one cycle with `busy` low.
  input  logic        req,
  input  logic [31:0] addr,
  input  logic [1:0]  size,          // 0 byte, 1 half, 2 word — from i960_ldst
  input  logic [2:0]  n_words,       // 1, 2, 3 or 4
  input  logic        is_store,
  input  logic        sign_ext,
  input  logic        is_burst,      // from i960_memmap, for this address

  output logic        busy,
  output logic        done,          // one cycle when the whole request retires

  // ------- register file side. `word_idx` selects which word of a multi-word
  // form is being moved; the caller adds it to the masked base register.
  output logic [2:0]  word_idx,
  input  logic [31:0] st_word,       // caller presents the word being stored
  output logic [2:0]  cur_idx,      // live word index, for the STORE source
  output logic [31:0] ld_word,

  // COMBINATIONAL mirrors of the retire, valid in the ack cycle rather than the
  // one after. `done` and `ld_we` are registered, so the sequencer spent a
  // whole cycle merely noticing an access had finished -- one of the two a load
  // costs against a bus that acks immediately. These let it act in the same
  // cycle; the registered versions stay for the byte-split path, which retires
  // a state later out of `assemble` and cannot be known early.
  output logic        ld_we_now,
  output logic [31:0] ld_word_now,
  output logic        done_now,
  output logic        ld_we,

  // ------- bus
  output logic        bus_req,
  output logic        bus_we,
  output logic [31:0] bus_addr,      // byte address
  output logic [3:0]  bus_be,
  output logic [31:0] bus_wdata,
  input  logic [31:0] bus_rdata,
  input  logic        bus_ack
);

  // S_OPD exists because the caller's register read is REGISTERED: r[base+widx]
  // arrives one cycle after the address is presented. Rather than compensate
  // for that in the caller -- which cannot work, because word 0's address comes
  // from T_EXEC and later words from S_NEXT, so no constant offset suits both --
  // the LSU announces the index it wants and spends one cycle waiting for it.
  //
  // Stores only. A load has no operand to fetch, so it goes straight to S_XFER
  // and pays nothing.
  typedef enum logic [2:0] { S_IDLE, S_OPD, S_XFER, S_NEXT, S_DONE } state_e;
  state_e state;

  logic [31:0] cur_addr;     // address of the word currently being moved
  logic [2:0]  widx;
  logic [2:0]  nw;
  logic [1:0]  sz;
  logic        store_q, sext_q, burst_q;

  logic [1:0]  bidx;         // byte counter within an unaligned access
  logic [1:0]  nbytes;       // bytes to move for this word, minus one
  logic        split;        // this word needs byte-wise sequencing
  logic [31:0] assemble;     // little-endian accumulator

  assign busy     = (state != S_IDLE);

  // The aligned, non-split retire, known combinationally in the ack cycle.
  logic retire_now;
  assign retire_now  = (state == S_XFER) && bus_ack && !word_split;
  assign ld_we_now   = retire_now && !store_q;
  logic post_q, post_first;   // R1011: this transfer is a posted store; its first cycle
  logic [31:0] wd_q;
  assign done_now    = (retire_now && ((widx + 3'd1) >= nw) && !post_q)
                     || ((state == S_XFER) && post_first);
  assign ld_word_now = (sz == 2'd0) ? (sext_q ? {{24{rd_byte[7]}},  rd_byte}
                                              : {24'd0,            rd_byte})
                     : (sz == 2'd1) ? (sext_q ? {{16{rd_half[15]}}, rd_half}
                                              : {16'd0,            rd_half})
                                    : bus_rdata;

  // Bus outputs combinational from registered state only. Registered, they
  // appeared the cycle AFTER S_XFER was entered, so every access spent a cycle
  // merely raising a request. No loop: bus_req depends on `state`, never on
  // bus_ack -- the ack retires the state and the state drops the request.
  assign bus_req   = (state == S_XFER);
  assign bus_we    = store_q;
  assign bus_addr  = word_split ? byte_addr : cur_addr;
  assign bus_be    = word_split ? (4'b0001 << byte_addr[1:0]) : be_full;
  wire [31:0] wdata_c = word_split ? {4{st_byte_split}}
                      : (sz == 2'd0) ? {4{st_word[7:0]}}
                      : (sz == 2'd1) ? {2{st_word[15:0]}}
                                     : st_word;
  assign bus_wdata = (post_q && !post_first) ? wd_q : wdata_c;   // R1011
  // The index that goes with ld_word, captured when ld_word is, NOT the live
  // counter. S_NEXT asserts ld_we and advances widx in the same cycle, so a
  // consumer sampling `widx` alongside `ld_we` sees the NEXT word's index --
  // writebacks landed on 1,2,2 instead of 0,1,2, leaving the first destination
  // register untouched and the last written twice.
  //
  // Same defect class as rd_q above: a value read one state after the one that
  // produced it. Both were unreachable until the whole-CPU generator learned to
  // emit loads.
  logic [2:0] ld_widx;
  assign word_idx = ld_widx;

  // Stores need the LIVE index, not the captured one: the caller has to present
  // r[base + cur_idx] while this word is being issued, whereas `word_idx` is
  // deliberately one behind so it matches ld_word. Two indices because they
  // answer two different questions.
  // The index whose register value the caller must present. Held from the
  // moment the word is selected until S_XFER has consumed it, so the operand is
  // stable for the whole transfer -- including a byte-split store, which reads
  // several lanes out of the same word across several bus cycles.
  assign cur_idx = widx;

  // Alignment test, exactly the reference's: a half needs bit 0 clear, a word
  // needs both low bits clear, a byte is always aligned.
  logic word_split;
  always_comb begin
    case (sz)
      2'd0:    word_split = 1'b0;
      2'd1:    word_split = cur_addr[0];
      default: word_split = |cur_addr[1:0];
    endcase
  end

  // Byte enables for a whole-width access.
  logic [3:0] be_full;
  always_comb begin
    case (sz)
      2'd0:    be_full = 4'b0001 << cur_addr[1:0];
      2'd1:    be_full = cur_addr[1] ? 4'b1100 : 4'b0011;
      default: be_full = 4'b1111;
    endcase
  end

  logic [31:0] byte_addr;
  assign byte_addr = cur_addr + {30'd0, bidx};

  // R952: a burst's next word, one adder for S_XFER and S_NEXT's two copies.
  wire [31:0] cur_addr_p4 = cur_addr + 32'd4;

  // Named intermediates for the lane selects. Quartus 17.0 rejects indexing the
  // result of a part-select:
  //   Error (10768): range must be the final index in the indexed name
  // so `bus_rdata[{cur_addr[1:0], 3'd0} +: 8][7]` is illegal there, while the
  // simulator and yosys both accept it happily. Same family as Model 1's rule
  // about bit selects on a function call, and the same fix: name the
  // intermediate. Note the line wrapping here is deliberate — a comment line
  // that BEGINS with the linter's own name is parsed as a pragma and fails the
  // lint. That has now cost two edits in this project; keep the tool name away
  // from the start of a line.
  logic [7:0]  rd_byte;
  logic [15:0] rd_half;
  // Extracted from the CAPTURED word, not from the live bus. The extraction
  // happens in S_NEXT, one state after the ack, and `bus_rdata` belongs to
  // whatever the bus is doing by then -- an instruction fetch, usually. The
  // split path always captured (`assemble <= rd_byte_split` at ack time) and
  // the non-split path did not, which is the asymmetry that hid this: word
  // loads happened to read a stale 0xffffffff and looked correct, while byte
  // and half loads returned whatever had since appeared on the bus.
  //
  // Never reached before now, because the whole-CPU generator emitted no
  // load or store at all.
  // Extracted from the LIVE bus, which is correct HERE because this is now used
  // in the cycle the ack arrives, not a state later. The original defect was
  // doing this extraction in S_NEXT, where bus_rdata belongs to whatever the
  // bus is doing next; the fix then was to capture into rd_q, and the fix now
  // is to do the work at the ack and skip the state entirely.
  assign rd_byte = bus_rdata[{cur_addr[1:0], 3'd0} +: 8];
  assign rd_half = cur_addr[1] ? bus_rdata[31:16] : bus_rdata[15:0];

  logic [7:0] rd_byte_split;
  assign rd_byte_split = bus_rdata[{byte_addr[1:0], 3'd0} +: 8];

  logic [7:0] st_byte_split;
  assign st_byte_split = st_word[{bidx, 3'd0} +: 8];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state    <= S_IDLE;
      ld_we    <= 1'b0;
      done     <= 1'b0;
      widx     <= 3'd0;
      bidx     <= 2'd0;
      nbytes   <= 2'd0;
      split    <= 1'b0;
      assemble <= 32'd0;
      cur_addr <= 32'd0;
      nw       <= 3'd1;
      sz       <= 2'd2;
      store_q  <= 1'b0;
      sext_q   <= 1'b0;
      burst_q  <= 1'b0;
      ld_widx  <= 3'd0;
      post_q   <= 1'b0;
      post_first <= 1'b0;
      wd_q     <= 32'd0;
    end else begin
      ld_we <= 1'b0;
      done  <= 1'b0;
      post_first <= 1'b0;
      if (post_first) wd_q <= wdata_c;   // R1011: the store's data, held

      case (state)
        S_IDLE: begin
          if (req) begin
            cur_addr <= addr;
            nw       <= n_words;
            sz       <= size;
            store_q  <= is_store;
            sext_q   <= sign_ext;
            burst_q  <= is_burst;
            widx     <= 3'd0;
            bidx     <= 2'd0;
            // Set here rather than in S_XFER. It used to be assigned alongside
            // the registered bus drive, and moving that drive combinational
            // took this with it -- leaving nbytes at 0, so a byte-split access
            // finished after one byte instead of two. The block harness caught
            // it as "op count got=1 want=2"; the whole-CPU harness could not,
            // until unaligned addresses were generated.
            nbytes   <= (size == 2'd1) ? 2'd1 : 2'd3;
            assemble <= 32'd0;
            // A store must wait for the caller to deliver r[base+0]; a load has
            // no operand and goes straight to the transfer.
            state    <= (is_store && !ST1) ? S_OPD : S_XFER;
            // R1011: post a one-word store whose word goes out in one transfer
            // (aligned for its size: the byte split stays as it was)
            post_q     <= POST && ST1 && is_store && (n_words == 3'd1) &&
                          ((size == 2'd0) || ((size == 2'd1) && !addr[0]) || (addr[1:0] == 2'd0));
            post_first <= POST && ST1 && is_store && (n_words == 3'd1) &&
                          ((size == 2'd0) || ((size == 2'd1) && !addr[0]) || (addr[1:0] == 2'd0));
          end
        end

        // One cycle for the registered read to deliver r[base + widx]. `cur_idx`
        // already announces widx, so the caller's address was presented on the
        // way in and rd1 is valid on the way out.
        S_OPD: state <= S_XFER;

        S_XFER: begin
          if (bus_ack) begin
            // Latched for S_NEXT, which needs to know how this word was
            // fetched after cur_addr may have moved on. Assigned alongside the
            // registered bus drive before, and lost with it -- which made a
            // split access retire down the aligned path and return the raw bus
            // word instead of the assembled halfword.
            split <= word_split;
            if (word_split) begin
              if (!store_q)
                assemble[{bidx, 3'd0} +: 8] <= rd_byte_split;
              if (bidx == nbytes) begin
                bidx  <= 2'd0;
                state <= S_NEXT;
              end else begin
                bidx <= bidx + 2'd1;
              end
            end else begin
              // ALIGNED PATH RETIRES HERE. Everything S_NEXT used to do for
              // this case is done in the ack cycle, which removes a state per
              // word -- and per-access cycles are where the throughput gap is:
              // T_MEM_W measured 4.90 cyc/instr, ~10 cycles per access, against
              // a bus that acks immediately.
              //
              // The byte-split path still needs S_NEXT: its last byte is merged
              // into `assemble` by this very cycle's non-blocking write, so the
              // assembled word is not readable until the next one.
              if (!store_q) begin
                ld_we   <= 1'b1;
                ld_widx <= widx;
                case (sz)
                  2'd0: ld_word <= sext_q ? {{24{rd_byte[7]}},  rd_byte}
                                          : {24'd0,            rd_byte};
                  2'd1: ld_word <= sext_q ? {{16{rd_half[15]}}, rd_half}
                                          : {16'd0,            rd_half};
                  default: ld_word <= bus_rdata;
                endcase
              end
              if (widx + 3'd1 >= nw) begin
                done  <= !post_q;   // R1011: a posted store retired already
                post_q <= 1'b0;
                state <= S_IDLE;
              end else begin
                widx <= widx + 3'd1;
                if (burst_q) cur_addr <= cur_addr_p4;   // R952
                state <= store_q ? S_OPD : S_XFER;
              end
            end
          end
        end

        S_NEXT: begin
          // Retire the word. A partial load extends here rather than in
          // i960_ldst, because the split path assembles its own value.
          if (!store_q) begin
            ld_we   <= 1'b1;
            ld_widx <= widx;
            // Reachable only for a split access; the guard states that rather
            // than relying on it.
            if (split) begin
              case (sz)
                2'd1: ld_word <= sext_q ? {{16{assemble[15]}}, assemble[15:0]}
                                        : {16'd0,             assemble[15:0]};
                default: ld_word <= assemble;
              endcase
            end
            // No non-split branch here any more: an aligned access retires in
            // the ack cycle in S_XFER, and only the byte-split path reaches
            // this state -- it needs one extra cycle for `assemble` to become
            // readable after its last byte is merged.
          end

          assemble <= 32'd0;
          if (widx + 3'd1 >= nw) begin
            state <= S_DONE;
          end else begin
            widx <= widx + 3'd1;
            // THE non-obvious line. Only a burst region advances.
            if (burst_q) cur_addr <= cur_addr_p4;   // R952
            state <= store_q ? S_OPD : S_XFER;
          end
        end

        S_DONE: begin
          done  <= 1'b1;
          state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
