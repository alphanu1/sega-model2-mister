// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// A SHOW-AHEAD FIFO WHOSE STORAGE IS M10K, NOT FLIP-FLOPS.
//
// The coprocessor's input queue was a 128 x 32 array read ASYNCHRONOUSLY -- the
// TGP sees the head combinationally -- and an asynchronously read array on this
// part is registers, not memory. 128 entries cost about 1,543 ALM; 512 took the
// design to 45,005 of 41,910 ALM and would not fit at all.
//
// So the storage moves to a synchronously read block and a HEAD REGISTER puts
// the combinational read back. `q`/`q_valid` are the front word, available
// without a cycle of latency, exactly as the array was.
//
// THE COST IS A BUBBLE, AND IT IS DELIBERATE. After a pop the next word takes
// two cycles to reach the head, so `q_valid` falls between back-to-back pops.
// That is safe here and it is worth saying why rather than discovering it:
//
//   * the i960 is NEVER held. `full` is an output the caller uses to DROP, and
//     nothing in this module can assert backpressure toward the CPU. Holding
//     the i960 on the coprocessor froze the machine on hardware once already.
//   * the TGP already tolerates it -- `mb86233_core` holds when a register-file
//     FIFO read is not acknowledged, which is the same path an empty FIFO uses.
//   * the TGP pops far slower than one word per cycle, so the bubble is not on
//     any real critical path.
//
// THE ARRAY IS NEVER CLEARED IN RESET. Clearing it is what stops Quartus
// inferring M10K, which is the whole point of the change.

`timescale 1ns/1ps

module m2_fifo_m10k #(
  parameter int unsigned DW    = 32,
  parameter int unsigned DEPTH = 128           // must be a power of two
) (
  input  logic          clk,
  input  logic          rst_n,

  input  logic          push,
  input  logic [DW-1:0] din,

  input  logic          pop,
  output logic [DW-1:0] q,                     // the front word, combinational
  output logic          q_valid,

  output logic          full,
  output logic [15:0]   count,                 // words held, head included
  output logic [31:0]   dropped                // pushes refused while full
);

  localparam int unsigned AW = $clog2(DEPTH);

  (* ramstyle = "M10K" *) logic [DW-1:0] mem [DEPTH];

  logic [AW-1:0] wp, rp;
  logic [AW:0]   mem_cnt;                      // words in the ARRAY, not the head
  logic [DW-1:0] rdq;
  logic          rd_pending;

  wire mem_full  = (mem_cnt == (AW+1)'(DEPTH));
  wire mem_avail = (mem_cnt != '0);
  // A push is refused only when the array is full AND the head is occupied,
  // so the usable depth is DEPTH+1 and `full` means what the caller thinks.
  assign full    = mem_full;
  assign count   = 16'(mem_cnt) + 16'(q_valid);

  // The head slot frees this cycle if it is empty or being popped.
  wire head_free = !q_valid || pop;
  wire do_read   = head_free && !rd_pending && mem_avail;

  always_ff @(posedge clk) begin
    if (push && !mem_full) mem[wp] <= din;     // never cleared in reset
    rdq <= mem[rp];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wp <= '0; rp <= '0; mem_cnt <= '0;
      q <= '0; q_valid <= 1'b0; rd_pending <= 1'b0;
      dropped <= 32'd0;
    end else begin
      // ---- push
      if (push) begin
        if (!mem_full) begin
          wp      <= wp + AW'(1);
          mem_cnt <= mem_cnt + (AW+1)'(1);
        end else if (!(&dropped)) begin
          dropped <= dropped + 32'd1;
        end
      end

      // ---- pop clears the head; the refill below may fill it again
      if (pop && q_valid) q_valid <= 1'b0;

      // ---- issue a read one cycle ahead of needing it
      rd_pending <= 1'b0;
      if (do_read) begin
        rp         <= rp + AW'(1);
        rd_pending <= 1'b1;
        // mem_cnt falls here and may rise from a push in the same cycle
        if (!(push && !mem_full)) mem_cnt <= mem_cnt - (AW+1)'(1);
        else                      mem_cnt <= mem_cnt;
      end

      // ---- the read lands
      if (rd_pending) begin
        q       <= rdq;
        q_valid <= 1'b1;
      end
    end
  end

endmodule
