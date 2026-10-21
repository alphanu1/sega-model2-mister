// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// R923: THE TGP HANG PROBE. GitHub #17: Virtua Fighter 2 "crashes at random"
// -- in attract, at a match's start, in round one, after a credit. R871: s1203
// froze in attract with the i960 at 0x7dc4 (three ldq from the TGP's output
// FIFO) and the TGP never answering, and that probe could not say where the
// TGP was or what either side was waiting on. This one can.
//
// Built only with VERILOG_MACRO "M2_PROBE=1" and "M2_PROBE_TGP=1" (with
// M2_NO_DEBUG, as every probe build); the sound and memory-test records of
// M2_PROBE give their place to these. One record every third prof_tick
// (2.46 ms at 80 MHz), a state record and a ring record in turn. Decoder:
// tools/decode_tgp.py.
//
//   'C' {the i960's IP} | {copro_stall, TGP unimplemented op, frozen, 13'd0,
//        the TGP's pc (the last instruction retired)}
//   'h' {m2_copro dbg_fifo: halted, uploading, both FIFOs' flags, the i960's
//        access in flight, words in fin : words in fout} | {m2_tgp dbg_hs:
//        the sequencer's state and every req / ack it can wait on}
//   'j' {words the i960 pushed : the TGP popped} | {the TGP pushed : the
//        i960 popped}, 16 bits each, running
//   'p' {the last word the i960 pushed} | {the last word the TGP popped}
//   'x' {the last word the TGP produced} | {output words the TGP lost on a
//        full output FIFO -- must be 0 : input words dropped (halted TGP)}
//   'i' {the TGP's io address : its retire count} | {its program word}
//   'a' {io_sel, io_we, trap, halted, 4'd0, the i960's I/O address [23:0]}
//        | {the TGP's bank [23:16], the longest copro_stall, clk_sys cycles,
//        saturating at 2^24-1}
//   'r' THE TRANSFER RING: the last 256 words the i960 moved across the
//       coprocessor's ports, in order -- {frozen, 7'd0, write index, this
//       index, vblank count [5:0], kind (0 FIFO push, 1 function push, 2 a
//       result popped, 3 copro_ctl1)} | {the word}. One entry a record.
//
// FROZEN: once the i960 has been held by the coprocessor for 2^FREEZE_BIT
// consecutive cycles (2^23 = 105 ms at 80 MHz, six vblanks; the longest
// legitimate hold measured on any game is under a frame) the ring stops
// taking words, so it holds the 256 transfers before the hang however long
// the capture runs. The state records stay live: a hang holds them still, a
// livelock shows them moving. Nothing here drives the coprocessor; it reads.
//
// THE RING IS ONE M10K (256 x 40), never cleared (it is read only through
// the indices the record carries).

`timescale 1ns/1ps

module m2_tgp_probe #(
  parameter int unsigned DIVISOR    = 694,     // clk / 115200
  parameter int unsigned BUDGET_CYC = 200_000,
  parameter int unsigned FREEZE_BIT = 23
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        prof_tick,     // the probe's slot clock (M2_PROBE's)
  input  logic        vbl_edge,      // one cycle a vblank

  // ---- the i960
  input  logic [31:0] cpu_ip,
  input  logic        cpu_trap,
  input  logic        cpu_halted,
  input  logic        cpu_io_sel,
  input  logic        cpu_io_we,
  input  logic [23:0] cpu_io_addr,

  // ---- the coprocessor (m2_copro's debug ports)
  input  logic        copro_stall,
  input  logic        tgp_unimpl,
  input  logic [15:0] tgp_pc,
  input  logic [31:0] copro_fifo,
  input  logic [31:0] tgp_hs,
  input  logic [15:0] in_pushed,
  input  logic [15:0] in_popped,
  input  logic [15:0] out_pushed,
  input  logic [15:0] out_popped,
  input  logic [31:0] push_data,
  input  logic [31:0] pop_data,
  input  logic [31:0] out_data,
  input  logic [15:0] out_refused,
  input  logic [15:0] in_dropped,
  input  logic [15:0] tgp_io_addr,
  input  logic [15:0] tgp_retires,
  input  logic [31:0] tgp_op,
  input  logic  [7:0] tgp_bank,
  input  logic        xfer,
  input  logic  [1:0] xfer_kind,
  input  logic [31:0] xfer_data,

  output logic        tx,
  output logic [31:0] dbg_dropped,
  output logic        frozen
);

  logic  [1:0] div;
  logic  [2:0] sel;
  logic        valid, ring;
  (* ramstyle = "M10K" *) logic [39:0] mem [256];
  logic  [7:0] wp, rp;
  logic [39:0] q;
  logic  [5:0] vbl;
  logic [23:0] hold, hmax;

  always_ff @(posedge clk) begin
    if (xfer && !frozen) mem[wp] <= {vbl, xfer_kind, xfer_data};   // never cleared
    q <= mem[rp];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      div <= '0; sel <= '0; valid <= 1'b0; ring <= 1'b0;
      wp <= '0; rp <= '0; vbl <= '0; hold <= '0; hmax <= '0; frozen <= 1'b0;
    end else begin
      valid <= 1'b0;
      if (prof_tick) begin
        div <= (div == 2'd2) ? 2'd0 : div + 2'd1;
        if (div == 2'd0) valid <= 1'b1;
      end
      if (valid) begin   // the record went this cycle: choose the next one
        ring <= !ring;
        if (ring) rp  <= rp + 8'd1;
        else      sel <= (sel == 3'd6) ? 3'd0 : sel + 3'd1;
      end
      if (xfer && !frozen) wp <= wp + 8'd1;
      if (vbl_edge) vbl <= vbl + 6'd1;
      hold <= !copro_stall ? 24'd0 : (&hold) ? hold : hold + 24'd1;
      if (hold > hmax) hmax <= hold;
      if (hold[FREEZE_BIT]) frozen <= 1'b1;
    end
  end

  logic [31:0] r_a, r_d;
  logic  [7:0] r_tag;
  always_comb begin
    if (ring) begin
      r_tag = 8'h72;                                   // 'r'
      r_a   = {frozen, 7'd0, wp, rp, q[39:32]};
      r_d   = q[31:0];
    end else begin
      unique case (sel)
        3'd1:    begin r_tag = 8'h68; r_a = copro_fifo;                 r_d = tgp_hs;                    end   // 'h'
        3'd2:    begin r_tag = 8'h6A; r_a = {in_pushed, in_popped};     r_d = {out_pushed, out_popped}; end   // 'j'
        3'd3:    begin r_tag = 8'h70; r_a = push_data;                  r_d = pop_data;                  end   // 'p'
        3'd4:    begin r_tag = 8'h78; r_a = out_data;                   r_d = {out_refused, in_dropped}; end   // 'x'
        3'd5:    begin r_tag = 8'h69; r_a = {tgp_io_addr, tgp_retires}; r_d = tgp_op;                    end   // 'i'
        3'd6:    begin r_tag = 8'h61;
                       r_a = {cpu_io_sel, cpu_io_we, cpu_trap, cpu_halted, 4'd0, cpu_io_addr};
                       r_d = {tgp_bank, hmax};                                                       end   // 'a'
        default: begin r_tag = 8'h43; r_a = cpu_ip;
                       r_d = {copro_stall, tgp_unimpl, frozen, 13'd0, tgp_pc};                       end   // 'C'
      endcase
    end
  end

  m2_dbg_stream #(.DIVISOR(DIVISOR), .BUDGET_CYC(BUDGET_CYC)) u_stream (
    .clk(clk), .rst_n(rst_n),
    .a_valid(valid), .a_addr(r_a), .a_data(r_d),
    .b_valid(1'b0), .b_addr(32'd0), .b_data(32'd0),
    .a_tag(r_tag), .b_tag(8'h47),
    .enable(1'b1),
    .tx(tx), .dbg_dropped(dbg_dropped)
  );

endmodule
