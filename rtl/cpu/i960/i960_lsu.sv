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

module i960_lsu (
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

  typedef enum logic [1:0] { S_IDLE, S_XFER, S_NEXT, S_DONE } state_e;
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
  logic [31:0] rd_q;
  assign rd_byte = rd_q[{cur_addr[1:0], 3'd0} +: 8];
  assign rd_half = cur_addr[1] ? rd_q[31:16] : rd_q[15:0];

  logic [7:0] rd_byte_split;
  assign rd_byte_split = bus_rdata[{byte_addr[1:0], 3'd0} +: 8];

  logic [7:0] st_byte_split;
  assign st_byte_split = st_word[{bidx, 3'd0} +: 8];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state    <= S_IDLE;
      bus_req  <= 1'b0;
      bus_we   <= 1'b0;
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
      rd_q     <= 32'd0;
      ld_widx  <= 3'd0;
    end else begin
      ld_we <= 1'b0;
      done  <= 1'b0;

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
            assemble <= 32'd0;
            state    <= S_XFER;
          end
        end

        S_XFER: begin
          bus_req  <= 1'b1;
          bus_we   <= store_q;
          split    <= word_split;

          if (word_split) begin
            // One byte at a time, little-endian. nbytes is the last index.
            nbytes    <= (sz == 2'd1) ? 2'd1 : 2'd3;
            bus_addr  <= byte_addr;
            bus_be    <= 4'b0001 << byte_addr[1:0];
            bus_wdata <= {4{st_byte_split}};
          end else begin
            bus_addr  <= cur_addr;
            bus_be    <= be_full;
            bus_wdata <= (sz == 2'd0) ? {4{st_word[7:0]}}
                       : (sz == 2'd1) ? {2{st_word[15:0]}}
                                      : st_word;
          end

          if (bus_ack) begin
            bus_req <= 1'b0;
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
              rd_q  <= bus_rdata;   // capture at the ack, extend next state
              state <= S_NEXT;
            end
          end
        end

        S_NEXT: begin
          // Retire the word. A partial load extends here rather than in
          // i960_ldst, because the split path assembles its own value.
          if (!store_q) begin
            ld_we   <= 1'b1;
            ld_widx <= widx;
            if (split) begin
              case (sz)
                2'd1: ld_word <= sext_q ? {{16{assemble[15]}}, assemble[15:0]}
                                        : {16'd0,             assemble[15:0]};
                default: ld_word <= assemble;
              endcase
            end else begin
              case (sz)
                2'd0: ld_word <= sext_q ? {{24{rd_byte[7]}},  rd_byte}
                                        : {24'd0,            rd_byte};
                2'd1: ld_word <= sext_q ? {{16{rd_half[15]}}, rd_half}
                                        : {16'd0,            rd_half};
                default: ld_word <= rd_q;
              endcase
            end
          end

          assemble <= 32'd0;
          if (widx + 3'd1 >= nw) begin
            state <= S_DONE;
          end else begin
            widx <= widx + 3'd1;
            // THE non-obvious line. Only a burst region advances.
            if (burst_q) cur_addr <= cur_addr + 32'd4;
            state <= S_XFER;
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
