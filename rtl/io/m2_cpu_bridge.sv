// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// The i960's bus, decoded and brought into the memory clock domain.
//
// WHY A BRIDGE AND NOT A DECODER
//
// The CPU runs at 25 MHz because that is what it fits at -- 26.4 MHz measured,
// study R23 -- and everything it talks to runs at 40 MHz with the SDRAM. A
// clock enable would not help: with an enable the logic still has to settle
// inside one 40 MHz period, and it does not. So there is a domain crossing, and
// the honest place for it is here, once, rather than scattered through the top
// level.
//
// THE CROSSING IS A FOUR-PHASE HANDSHAKE, deliberately, not a FIFO. The i960
// bus is already request/acknowledge and it stalls until it is answered, so a
// FIFO would buy nothing and cost a pointer pair in each direction. `req`
// crosses into the memory domain through two flops, the payload is held stable
// by the requester for the whole transaction and is NOT synchronised -- it is
// stable long before `req` arrives -- and `ack` crosses back the same way.
//
// docs/mister-integration.md: ONE ACCESS IS `req & ack`, NOT ONE CYCLE OF
// `req`. A side-effecting target must act on the handshake. The Model 1 TGP
// popped every FIFO word twice and deadlocked on hardware for exactly this.
// The `busy` flag below is what makes each crossing fire once.
//
// THE MEMORY MAP IS model2o, NOT 2A-CRX. daytona93 runs on the original Model 2
// board and the two differ where it matters (study R25):
//
//   model2o:  0x00200000-0x0021ffff  RAM, 128 KB
//             0x00220000-0x0023ffff  ROM MIRROR of program ROM + 0x20000
//   2A-CRX:   0x00200000-0x0023ffff  RAM, 256 KB
//
// Selected by a parameter rather than assumed, because getting it wrong is not
// visible for half a million instructions and then looks like a decoder fault.

`timescale 1ns/1ps

module m2_cpu_bridge #(
  parameter int unsigned AW = 25,        // SDRAM word address width
  parameter bit          BOARD_2A = 0    // 0 = model2o, 1 = 2A-CRX
) (
  // ------------------------------------------------- CPU domain (25 MHz)
  input  logic        clk_cpu,
  input  logic        rst_n_cpu,

  input  logic        bus_req,
  input  logic        bus_we,
  input  logic [31:0] bus_addr,
  input  logic  [3:0] bus_be,
  input  logic [31:0] bus_wdata,
  output logic [31:0] bus_rdata,
  output logic        bus_ack,

  // ------------------------------------------------- memory domain (40 MHz)
  input  logic        clk_mem,
  input  logic        rst_n_mem,

  // Where the ROM images live in SDRAM, in 16-bit words.
  input  logic [AW:1] base_prog,         // program ROM,   0x00000000
  input  logic [AW:1] base_data,         // main_data,     0x02000000
  input  logic [AW:1] base_work,         // work RAM,      0x00500000
  input  logic [AW:1] base_board,        // board RAM,     0x00200000
  input  logic [AW:1] base_char,         // char RAM,      0x01080000

  // SDRAM port. Sixteen bits wide, so a 32-bit access is TWO transactions --
  // the sequencer below issues the low half then the high half.
  //
  // Only sd_dout[15:0] is read. Port 0 is a SINGLE-WORD port -- m2_sdram's
  // blen() is hardcoded per port and gives ports 0 and 4 one word where 1-3
  // burst four -- so the upper 48 bits are not populated on this port, and
  // reading them would return whatever the previous burst left. Model2.sv's
  // comment records a readback that got a correct low half and a permanently
  // zero upper half from exactly this confusion.
  /* verilator lint_off UNUSEDSIGNAL */
  output logic        sd_req,
  output logic        sd_we,
  output logic [AW:1] sd_addr,
  output logic [15:0] sd_din,
  output logic  [1:0] sd_be,
  input  logic [63:0] sd_dout,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic        sd_ack,

  // On-chip tile RAM and palette, 16-bit, one word per access.
  output logic        oc_tram_we,
  output logic        oc_pal_we,
  output logic [14:0] oc_addr,
  output logic [15:0] oc_din,
  input  logic [15:0] oc_tram_q,
  input  logic [15:0] oc_pal_q,

  // Colour translation table, 96 entries.
  output logic        oc_xlat_we,
  output logic  [6:0] oc_xlat_addr,
  output logic  [7:0] oc_xlat_din,

  // I/O the core answers itself.
  input  logic [31:0] io_rdata,
  output logic        io_sel,
  output logic        io_we,
  output logic [31:0] io_addr,
  output logic [31:0] io_wdata,

  // Observability. A core that decodes nothing looks identical to a core whose
  // CPU is not running, and both present as a black screen.
  output logic [31:0] dbg_cpu_reads,
  output logic [31:0] dbg_cpu_writes,
  output logic [31:0] dbg_unmapped,

  // The last SDRAM word address issued and the last data captured. Reads are
  // being issued, decoded correctly and coming back ZERO on hardware, and those
  // three facts together do not say whether the address is wrong or the data
  // is. These do.
  output logic [31:0] dbg_last_addr,
  output logic [31:0] dbg_last_dout,
  output logic [31:0] dbg_probe6,
  output logic [31:0] dbg_probe2,

  // WHAT THIS BRIDGE GETS FOR WORD 6, latched the first time it reads it.
  // The ROM readback reads the same word through the same controller and gets
  // 00000860; this bridge gets zero for the words either side of it. Same
  // address, two readers, one number each -- which is the only way left to
  // tell a bad read from a bad address.
);

  // ------------------------------------------------------------ CDC: request
  //
  // The payload registers are written in the CPU domain while `req_cpu` is low
  // and read in the memory domain only after `req_mem` has been high for two
  // flops, so they are stable for far longer than the crossing takes. That is
  // the standard condition for not synchronising a data bus, and it is the
  // reason this is a handshake rather than a FIFO.
  logic        req_cpu;
  logic  [1:0] req_sync, ack_sync;
  logic        req_mem, ack_mem;
  logic        busy;

  logic        r_we;
  logic [31:0] r_addr, r_wdata;
  logic  [3:0] r_be;
  logic [31:0] r_rdata;

  always_ff @(posedge clk_cpu or negedge rst_n_cpu) begin
    if (!rst_n_cpu) begin
      req_cpu <= 1'b0; busy <= 1'b0; bus_ack <= 1'b0;
      ack_sync <= 2'd0;
      r_we <= 1'b0; r_addr <= 32'd0; r_wdata <= 32'd0; r_be <= 4'd0;
    end else begin
      ack_sync <= {ack_sync[0], ack_mem};
      bus_ack  <= 1'b0;
      if (!busy && bus_req) begin
        r_we    <= bus_we;
        r_addr  <= bus_addr;
        r_wdata <= bus_wdata;
        r_be    <= bus_be;
        req_cpu <= 1'b1;
        busy    <= 1'b1;
      end else if (busy && ack_sync[1]) begin
        // The far side has answered. Drop the request and hold ack for one
        // cycle, which is what the i960's bus expects.
        req_cpu   <= 1'b0;
        bus_rdata <= r_rdata;
        bus_ack   <= 1'b1;
        busy      <= 1'b0;
      end
    end
  end

  always_ff @(posedge clk_mem or negedge rst_n_mem) begin
    if (!rst_n_mem) req_sync <= 2'd0;
    else            req_sync <= {req_sync[0], req_cpu};
  end
  assign req_mem = req_sync[1];

  // --------------------------------------------------------------- decoding
  //
  // Regions are tested in the order model2.cpp declares them, and the ROM
  // mirror is tested BEFORE the RAM it overlaps so a stray write cannot shadow
  // it. Anything not listed is counted, not silently zero: an unmapped access
  // is a fact about the port map and it should be visible.
  typedef enum logic [2:0] {
    T_SDRAM, T_TRAM, T_PAL, T_XLAT, T_IO, T_NONE
  } tgt_e;

  tgt_e        tgt;
  logic [AW:1] sd_word;          // 16-bit word address for the low half
  logic        is_rom;           // read-only: writes are dropped, as .rom().nopw()

  always_comb begin
    tgt     = T_NONE;
    sd_word = '0;
    is_rom  = 1'b0;
    if (r_addr < 32'h0020_0000) begin                       // program ROM
      tgt = T_SDRAM; is_rom = 1'b1;
      sd_word = base_prog + AW'(r_addr[20:1]);
    end else if (!BOARD_2A && r_addr >= 32'h0022_0000 && r_addr < 32'h0024_0000) begin
      // model2o's ROM mirror of the program ROM's second 128 KB.
      tgt = T_SDRAM; is_rom = 1'b1;
      sd_word = base_prog + AW'(20'h10000) + AW'(r_addr[16:1]);
    end else if (r_addr >= 32'h0020_0000 && r_addr < (BOARD_2A ? 32'h0024_0000
                                                              : 32'h0022_0000)) begin
      tgt = T_SDRAM;
      sd_word = base_board + AW'(r_addr[17:1]);
    end else if (r_addr >= 32'h0050_0000 && r_addr < 32'h0060_0000) begin
      tgt = T_SDRAM;
      sd_word = base_work + AW'(r_addr[19:1]);
    end else if (r_addr >= 32'h0108_0000 && r_addr < 32'h0110_0000) begin
      tgt = T_SDRAM;                                        // char RAM, 512 KB
      sd_word = base_char + AW'(r_addr[18:1]);
    end else if (r_addr >= 32'h0200_0000 && r_addr < 32'h0400_0000) begin
      tgt = T_SDRAM; is_rom = 1'b1;                         // main_data
      sd_word = base_data + AW'(r_addr[24:1]);
    end else if (r_addr >= 32'h0600_0000 && r_addr < 32'h0700_0000) begin
      tgt = T_SDRAM; is_rom = 1'b1;                         // the +0x1000000 alias
      sd_word = base_data + AW'(24'h800000) + AW'(r_addr[23:1]);
    end else if (r_addr >= 32'h0100_0000 && r_addr < 32'h0102_0000) begin
      tgt = T_TRAM;                                         // tile RAM
    end else if (r_addr >= 32'h0180_0000 && r_addr < 32'h0180_4000) begin
      tgt = T_PAL;
    end else if (r_addr >= 32'h0181_0000 && r_addr < 32'h0181_c000) begin
      tgt = T_XLAT;
    end else if (r_addr >= 32'h0080_0000 && r_addr < 32'h0100_0000) begin
      tgt = T_IO;                                           // geo, copro, video, irq
    end else if (r_addr >= 32'h0102_0000 && r_addr < 32'h0108_0000) begin
      tgt = T_IO;                                           // tile control registers
    end else if (r_addr >= 32'h01a0_0000 && r_addr < 32'h0200_0000) begin
      tgt = T_IO;                                           // comm, I/O, backup
    end else if (r_addr >= 32'h1000_0000) begin
      tgt = T_IO;                                           // renderer, framebuffer
    end
  end

  // Tile RAM and the palette are 16 bits wide and the CPU addresses them by
  // byte, so a 32-bit access is two words -- and the SECOND ONE IS AT THE NEXT
  // ADDRESS. The first version drove `r_addr[15:1]` flat for both halves, so
  // the high half wrote over the low one and a readback returned the same word
  // twice: 0x00220022 for a value of 0x00110022.
  //
  // Combinational off `half`, and the data with it, because these are M10K with
  // a registered read: the address has to be presented a cycle before the value
  // is captured, which is what the S_IDLE -> S_LO -> S_HI walk below does.
  assign oc_addr      = r_addr[15:1] + {14'd0, half};
  assign oc_din       = half ? r_wdata[31:16] : r_wdata[15:0];
  assign oc_xlat_addr = r_addr[7:1];

  // ---------------------------------------------------------- the sequencer
  //
  // Two halves for anything 16 bits wide, one for I/O. `half` names which is in
  // flight; the low half lands in bits 15:0 and the high half in 31:16.
  // S_LO_W and S_HI_W wait for the controller's ACK TO FALL before the next
  // request goes out. m2_sdram holds p_ack for ACK_HOLD cycles -- 2, by its own
  // parameter, "so requesters on a slower synchronous clock see exactly one
  // rising edge" -- and this bridge runs on the SAME clock as the controller.
  // Issuing the second half while the first half's ack is still asserted means
  // sampling it immediately and capturing the FIRST word again, so a 32-bit read
  // returns its low half in both halves.
  //
  // On hardware that made the i960 read its boot IP as 0x00600860 where the ROM
  // holds 0x00000860 -- the low half right, the high half not.
  typedef enum logic [2:0] { S_IDLE, S_LO, S_LO_W, S_HI, S_HI_W, S_RDB, S_DONE } st_e;
  st_e  st;
  logic half;

  always_ff @(posedge clk_mem or negedge rst_n_mem) begin
    if (!rst_n_mem) begin
      st <= S_IDLE; ack_mem <= 1'b0; half <= 1'b0;
      sd_req <= 1'b0; sd_we <= 1'b0; sd_addr <= '0; sd_din <= 16'd0; sd_be <= 2'b11;
      oc_tram_we <= 1'b0; oc_pal_we <= 1'b0; oc_xlat_we <= 1'b0;
      io_sel <= 1'b0; io_we <= 1'b0;
      r_rdata <= 32'd0;
      dbg_cpu_reads <= 32'd0; dbg_cpu_writes <= 32'd0; dbg_unmapped <= 32'd0;
      dbg_last_addr <= 32'd0; dbg_last_dout <= 32'd0;
      dbg_probe6 <= 32'hEEEE_EEEE; dbg_probe2 <= 32'hEEEE_EEEE;
    end else begin
      oc_tram_we <= 1'b0; oc_pal_we <= 1'b0; oc_xlat_we <= 1'b0;
      io_sel     <= 1'b0;

      case (st)
        // !sd_ack as well as req_mem: the previous access's ack may still be
        // held when the next request arrives, and issuing into it has exactly
        // the same effect as issuing into it below.
        S_IDLE: if (req_mem && !ack_mem && !sd_ack) begin
          if (r_we) dbg_cpu_writes <= dbg_cpu_writes + 32'd1;
          else      dbg_cpu_reads  <= dbg_cpu_reads  + 32'd1;
          half <= 1'b0;
          case (tgt)
            T_SDRAM: begin
              if (r_we && is_rom) begin
                ack_mem <= 1'b1; st <= S_DONE;    // .rom().nopw()
              end else if (!r_we) begin
                // ONE BURST. Port 0 returns four 16-bit words in p_dout, and
                // the two we want are words 0 and 1 -- the burst starts at the
                // address requested. Two transactions are no longer needed, and
                // the second one was where the held-acknowledge hazard lived.
                sd_addr <= sd_word;
                sd_we   <= 1'b0;
                sd_be   <= 2'b11;
                sd_req  <= 1'b1;
                st      <= S_RDB;
              end else begin
                sd_addr <= sd_word;
                sd_we   <= r_we;
                sd_din  <= r_wdata[15:0];
                sd_be   <= r_be[1:0];
                sd_req  <= 1'b1;
                st      <= S_LO;
              end
            end
            T_TRAM, T_PAL: begin
              // `half` is already 0 here, so oc_addr and oc_din name the low
              // word this cycle.
              oc_tram_we <= r_we && (tgt == T_TRAM);
              oc_pal_we  <= r_we && (tgt == T_PAL);
              st         <= S_LO;
            end
            T_XLAT: begin
              oc_xlat_din <= r_wdata[7:0];
              oc_xlat_we  <= r_we;
              ack_mem     <= 1'b1;
              st          <= S_DONE;
            end
            T_IO: begin
              io_sel  <= 1'b1;
              io_we   <= r_we;
              r_rdata <= io_rdata;
              ack_mem <= 1'b1;
              st      <= S_DONE;
            end
            default: begin
              dbg_unmapped <= dbg_unmapped + 32'd1;
              r_rdata      <= 32'd0;
              ack_mem      <= 1'b1;
              st           <= S_DONE;
            end
          endcase
        end

        // SDRAM low half, then high. The on-chip arrays answer in one cycle and
        // reuse the same two states, which is why S_LO tests `tgt`.
        S_LO: begin
          if (tgt == T_SDRAM) begin
            if (sd_ack) begin
              sd_req <= 1'b0;
              if (!r_we) r_rdata[15:0] <= sd_dout[15:0];
              dbg_last_addr <= {7'd0, sd_addr};
              dbg_last_dout <= {16'd0, sd_dout[15:0]};
              st <= S_LO_W;              // let the held ack fall first
            end
          end else begin
            // Registered read: the low word was addressed in S_IDLE and is
            // valid now. Move to the high word and assert its write here, so
            // the address and the write enable arrive together.
            r_rdata[15:0] <= (tgt == T_TRAM) ? oc_tram_q : oc_pal_q;
            half          <= 1'b1;
            oc_tram_we    <= r_we && (tgt == T_TRAM);
            oc_pal_we     <= r_we && (tgt == T_PAL);
            st            <= S_HI;
          end
        end

        // Ack has fallen: the high half is safe to issue.
        S_LO_W: if (!sd_ack) begin
          half    <= 1'b1;
          sd_addr <= sd_word + AW'(1);
          sd_din  <= r_wdata[31:16];
          sd_be   <= r_be[3:2];
          sd_req  <= 1'b1;
          st      <= S_HI;
        end

        S_HI: begin
          if (tgt == T_SDRAM) begin
            if (sd_ack) begin
              sd_req <= 1'b0;
              if (!r_we) r_rdata[31:16] <= sd_dout[15:0];
              st <= S_HI_W;
            end
          end else begin
            r_rdata[31:16] <= (tgt == T_TRAM) ? oc_tram_q : oc_pal_q;
            ack_mem        <= 1'b1;
            st             <= S_DONE;
          end
        end

        // A burst read: both halves arrive together in p_dout[31:0].
        S_RDB: if (sd_ack) begin
          sd_req        <= 1'b0;
          r_rdata       <= sd_dout[31:0];
          dbg_last_addr <= {7'd0, sd_addr};
          dbg_last_dout <= sd_dout[31:0];
          // EEEEEEEE means the address was never read at all, which is a
          // different fault from reading it and getting zero.
          if (sd_addr == AW'(6)) dbg_probe6 <= sd_dout[31:0];
          if (sd_addr == AW'(2)) dbg_probe2 <= sd_dout[31:0];
          st            <= S_HI_W;      // still let the ack fall before answering
        end

        // Both halves are in. Wait for the second ack to fall before answering,
        // so the next access cannot start into a held ack either.
        //
        // DEFENSIVE, and honestly labelled: unlike S_LO_W, this wait and the
        // !sd_ack guard in S_IDLE are NOT proven necessary by the testbench --
        // removing either still passes. They are kept because the next access
        // is separated from this one only by the CPU-domain crossing, whose
        // length is a clock ratio rather than a guarantee, and this is the
        // exact hazard that put a wrong boot vector on the board.
        S_HI_W: if (!sd_ack) begin
          ack_mem <= 1'b1;
          st      <= S_DONE;
        end

        // Hold ack until the requester has seen it and dropped req. Without
        // this the crossing can fire twice for one access, which is the
        // req-versus-req-and-ack fault named at the top.
        S_DONE: if (!req_mem) begin
          ack_mem <= 1'b0;
          st      <= S_IDLE;
        end

        // Six named states in a three-bit type leaves two unreachable
        // encodings. Naming them costs nothing and means a glitch into one is
        // recoverable rather than a permanent stall.
        default: st <= S_IDLE;
      endcase
    end
  end

  assign io_addr  = r_addr;
  assign io_wdata = r_wdata;

endmodule
