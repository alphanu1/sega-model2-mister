// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// THE GEOMETRIZER'S FRONT DOOR: two pointers and a push path.
//
// This is NOT a processor, and believing otherwise cost two study entries
// (R124, R128; corrected by R130). `model2.cpp`:
//
//     void geo_prg_w(u32 data) {
//         if (m_geoctl & 0x80000000) { m_geocnt++; }   // upload: COUNTS, DISCARDS
//         else                       { push_geo_data(data); }
//     }
//     void push_geo_data(u32 d) { m_bufferram[m_geo_write_start_address/4] = d;
//                                 m_geo_write_start_address += 4; }
//
// The microcode upload is thrown away by the reference, which hardcodes the
// pipeline instead. So the 721,831 writes to 0x804000 over 900 attract frames
// are overwhelmingly the game STREAMING ITS DISPLAY LIST into buffer RAM
// through an auto-incrementing pointer. What this block owes the machine is
// therefore small: keep two pointers, and put pushed dwords where they belong.
//
// WHY THE POINTERS MATTER ON THEIR OWN. `geo_r` returns geo_write_start_address
// at 0x2008 and geo_read_start_address at 0x3008. This core returned 0 for both
// -- that region falls into the bridge's T_IO default -- so the game set a
// pointer, read back zero, and derived an address from it. That is the shape of
// the livelock in R129: the i960 walking an unmapped 0x0163FBxx once buffer RAM
// writes started landing.
//
// THE PUSH IS A DMA, NOT A BUS REMAP. Redirecting the CPU write inside
// m2_cpu_bridge would mean rewriting sd_word underneath its S_LO/S_HI walk,
// which splits a dword across two SDRAM words and selects the half from
// r_addr[1]. Instead the write is acknowledged as ordinary I/O and queued here,
// and this block drains the queue into the shared SDRAM write port -- the same
// one the ROM loader, the self-test and the buffer initialiser take turns on.
//
// AND IT NEVER STALLS THE i960. The queue is an M10K FIFO deep enough that
// `dbg_dropped` stays still: the game pushes about 800 dwords a frame, roughly
// 48,000/s, against a drain of millions. If that counter ever moves, the depth
// was wrong -- it is not a reason to add backpressure. Holding the i960 on a
// coprocessor froze this machine once already.

`timescale 1ns/1ps

module m2_geo #(
  parameter int unsigned AW    = 25,
  parameter int unsigned DEPTH = 128
) (
  input  logic          clk,
  input  logic          rst_n,

  // ---- the i960's side, decoded by the top level
  input  logic          wr_ctl,          // 0x00980008  geo_ctl1
  input  logic          wr_setwp,        // 0x00801008  set write pointer
  input  logic          wr_setrp,        // 0x00803008  set read pointer
  input  logic          wr_push,         // 0x00800000-0fff and 0x00804000-7fff
  input  logic [31:0]   wdata,

  output logic [31:0]   rd_wp,           // 0x00802008
  output logic [31:0]   rd_rp,           // 0x00803008

  // ---- where buffer RAM lives, and the shared SDRAM write port
  input  logic [AW:1]   base_buffer,
  output logic          sd_wr_req,
  output logic [AW:1]   sd_wr_addr,
  output logic [15:0]   sd_wr_din,
  input  logic          sd_wr_ack,
  output logic          sd_busy,         // hold the port while a dword is in flight

  output logic [31:0]   dbg_pushes,
  output logic [31:0]   dbg_dropped,
  output logic [15:0]   dbg_geocnt,
  output logic [31:0]   dbg_geoctl
);

  // ---------------------------------------------------------------- registers
  logic [31:0] geoctl;
  logic [19:0] geo_wp, geo_rp;
  logic [15:0] geocnt;

  wire uploading = geoctl[31];

  assign rd_wp      = {12'd0, geo_wp};
  assign rd_rp      = {12'd0, geo_rp};
  assign dbg_geocnt = geocnt;
  assign dbg_geoctl = geoctl;

  // A push only queues when the reference would have queued it: in upload mode
  // the data is counted and discarded, exactly as geo_prg_w does.
  wire push_now = wr_push && !uploading;

  // THE DESTINATION TRAVELS WITH THE DWORD. The queue decouples the push from
  // the drain, so a drain-side counter would be wrong the moment the game sets
  // the write pointer with 0x801008 -- the queued words would land where the
  // pointer USED to be. 52 bits wide: {byte pointer, dword}.
  logic        q_valid;
  logic [51:0] q_data;
  logic        q_pop;
  logic [15:0] q_count;
  logic        q_full;

  m2_fifo_m10k #(.DW(52), .DEPTH(DEPTH)) u_pushq (
    .clk(clk), .rst_n(rst_n),
    .push(push_now), .din({geo_wp, wdata}),
    .pop(q_pop), .q(q_data), .q_valid(q_valid),
    .full(q_full), .count(q_count), .dropped(dbg_dropped)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      geoctl <= 32'd0; geo_wp <= 20'd0; geo_rp <= 20'd0;
      geocnt <= 16'd0; dbg_pushes <= 32'd0;
    end else begin
      // geo_ctl1_w: the hi bit CHANGING starts or ends an upload, and starting
      // one resets the count. The reference watches the transition, not the level.
      if (wr_ctl) begin
        if ((wdata ^ geoctl) == 32'h8000_0000 && wdata[31]) geocnt <= 16'd0;
        geoctl <= wdata;
      end
      if (wr_setwp) geo_wp <= wdata[19:0];
      if (wr_setrp) geo_rp <= wdata[19:0];

      // Upload mode counts and drops on the floor, as the reference does.
      if (wr_push && uploading && !(&geocnt)) geocnt <= geocnt + 16'd1;

      // The pointer advances when the dword is ACCEPTED, not when it lands --
      // the game reads it back to find where it is, and it is four ahead of the
      // last word it wrote. A drop must not advance it, or the list gains a hole
      // AND a wrong pointer.
      if (push_now && !q_full) begin
        geo_wp <= geo_wp + 20'd4;
        if (!(&dbg_pushes)) dbg_pushes <= dbg_pushes + 32'd1;
      end
    end
  end

  // ------------------------------------------------------ the drain, one dword
  // Two 16-bit writes, low half first: the bridge reads back the half selected
  // by r_addr[1], so an EVEN word index must hold bits 15:0.
  typedef enum logic [1:0] { D_IDLE, D_LO, D_HI, D_NEXT } dstate_t;
  dstate_t dst;
  logic [19:0] wr_ptr;
  logic [15:0] dw_hi;

  assign sd_busy = (dst != D_IDLE);
  assign q_pop   = (dst == D_IDLE) && q_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dst <= D_IDLE; sd_wr_req <= 1'b0; sd_wr_addr <= '0; sd_wr_din <= 16'd0;
      wr_ptr <= 20'd0; dw_hi <= 16'd0;
    end else begin
      case (dst)
        D_IDLE: if (q_valid) begin
          wr_ptr     <= q_data[51:32];
          dw_hi      <= q_data[31:16];
          sd_wr_addr <= base_buffer + AW'(q_data[48:33]);   // (ptr & 0x1ffff) >> 1
          sd_wr_din  <= q_data[15:0];
          sd_wr_req  <= 1'b1;
          dst        <= D_LO;
        end
        D_LO: if (sd_wr_ack) begin
          sd_wr_req  <= 1'b0;
          sd_wr_addr <= base_buffer + AW'(wr_ptr[16:1]) + AW'(1);
          sd_wr_din  <= dw_hi;
          dst        <= D_HI;
        end
        D_HI: begin
          sd_wr_req <= 1'b1;
          dst       <= D_NEXT;
        end
        D_NEXT: if (sd_wr_ack) begin
          sd_wr_req <= 1'b0;
          dst       <= D_IDLE;
        end
        default: dst <= D_IDLE;
      endcase
    end
  end

endmodule
