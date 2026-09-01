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

// DCACHE_EN LETS THE CACHE BE TAKEN OUT OF THE PATH ENTIRELY.
//
// Every observation of the byte smear at 0x501084 comes from a build that
// already had the data cache, so it has never been excluded as the CAUSE. With
// this at 0 the read path is exactly what it was before the cache existed --
// unaligned single burst, r_addr[1] halfword selection -- and the board can say
// whether the smear survives without it. Simulation cannot answer this: it
// reads the value correctly either way.
// BUFFERRAM IS OFF, AND THAT IS A FINDING RATHER THAN AN OMISSION (R129).
//
// The mapping below is correct and was verified live -- the boot profile
// shifts measurably when it is on. It is disabled because IT CANNOT LAND
// ALONE. 0x00900000 is the GEOMETRIZER'S WORKSPACE: the game writes a
// structure there, reads it back and follows it. Unmapped, the reads
// returned 0 and the machine took a safe path (21,325 TGP retires, attract
// cycling). Mapped, the writes LAND, the game follows its own pointer, and
// with no geometrizer behind it the i960 livelocks at IP 0x0E00-0x0E10
// walking an unmapped 0x0163FBxx (1,367 retires, attract stopped).
//
// Initialising the RAM to the reference's 0x07800f0f changed NOTHING --
// byte-identical telemetry -- which is what rules out the contents and
// names the writes landing as the cause. Turn this on in the same change
// that brings up the geometrizer, not before.
module m2_cpu_bridge #(
  parameter bit DCACHE_EN = 1'b1,
  parameter bit BUFFERRAM = 1'b0,
  parameter bit BUFFERRAM_WRONLY = 1'b0,   // writes land, reads still read 0
  parameter bit BUFFER_NOCACHE   = 1'b1,   // buffer-RAM lines are never retained
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
  // THE SHARED BUFFER, 0x00900000, AND IT WAS NOT MAPPED AT ALL.
  //
  // `map(0x00900000,0x0091ffff).mirror(0x60000).ram().share("bufferram")` --
  // 128 KB of plain RAM, and the region this core routed to T_IO, whose read
  // mux ends in 32'd0. So every read returned zero and every write vanished.
  // Measured in MAME over 900 attract frames: 33,554 writes and 12,269 reads.
  // It is not only the i960's: the coprocessor reads the same memory through
  // its bank at 0x400000, so this is how the two SHARE DATA, and neither side
  // could see it. 128 KB will not fit in M10K here (~103 blocks against 40
  // free after the band buffers), so it lives in SDRAM.
  input  logic [AW:1] base_buffer,       // bufferram,     0x00900000

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
  // A WRITE LANDED IN THE CHAR REGION, so the glyph cache in front of it must
  // drop what it holds. Without this it serves pre-upload zeros forever.
  output logic        char_wr,
  // Which glyph word, so the cache drops ONE line instead of everything. The
  // same [18:1] slice the SDRAM address is formed from, so the two cannot
  // disagree about which word was written.
  output logic [17:0] char_wr_addr,
  output logic        oc_xlat_we,
  output logic  [6:0] oc_xlat_addr,
  output logic  [7:0] oc_xlat_din,

  // I/O the core answers itself.
  input  logic [31:0] io_rdata,
  // AN I/O TARGET MAY REFUSE TO COMPLETE, AND THE CPU MUST WAIT FOR IT.
  //
  // Every peripheral before this one answered in the cycle it was selected, so
  // the sequencer never had to ask. The coprocessor's input FIFO is different:
  // it is EIGHT DEEP AND IT IS THE FLOW CONTROL. MAME's generic_fifo never
  // drops -- push() into a full FIFO queues the value and HALTS THE SOURCE --
  // and this core dropped 429,406 of the i960's commands in one boot because a
  // full FIFO looked like an overflow to guard against rather than a brake to
  // obey.
  //
  // While io_stall is high the access is held: io_sel stays asserted, no
  // acknowledge is returned, and the i960 waits exactly as it would on a real
  // bus that is not ready. It costs nothing when nothing stalls.
  input  logic        io_stall,
  output logic        io_sel,
  output logic        io_we,
  output logic [31:0] io_addr,
  output logic [31:0] io_wdata,
  // THE BYTE LANES, forwarded rather than dropped. The I/O board's dual-port
  // RAM is eight bits wide at bytes 0 and 2 of each dword, so a `stob` to
  // 0x01c00040 must not disturb the status byte at 0x01c00042 -- and without
  // these an I/O write is all four lanes, which would have the CPU clearing
  // the board's own reply every time it raised a command.
  output logic  [3:0] io_be,

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

  // WHAT THIS BRIDGE GETS FOR WORDS 6 AND 2, latched the first time each is
  // read. The ROM readback reads word 6 through the same controller and gets
  // 00000860; this bridge gets zero. Same address, two readers, one number
  // each -- the only way left to tell a bad read from a bad address.
  // EEEEEEEE means the address was never read at all, which is a different
  // fault from reading it and getting zero.
  output logic [31:0] dbg_probe6,
  output logic [31:0] dbg_probe2,
  // Writes the CPU has made to TILE RAM and to the palette. The probes
  // above proved the read path; these say whether anything is being drawn
  // at all, which a screenful of noise cannot distinguish from drawing to
  // the wrong place.
  output logic [31:0] dbg_tram_wr,
  output logic [31:0] dbg_pal_wr,
  // The memory side's own view: its state, and the three signals the
  // handshake turns on. Inferring these from the CPU side is what has been
  // failing.
  output logic  [7:0] dbg_mstate,
  // The data cache's own telemetry. Modelled at 97.86% before it was built;
  // the board must be able to say whether it agrees, because a simulated hit
  // rate that hardware did not share is exactly what the glyph cache did
  // (96.7% modelled against 51.8% measured).
  output logic [31:0] dbg_dc_hits,
  output logic [31:0] dbg_dc_miss
);

  // ------------------------------------------------------------ CDC: request
  //
  // The payload registers are written in the CPU domain while `req_cpu` is low
  // and read in the memory domain only after `req_mem` has been high for two
  // flops, so they are stable for far longer than the crossing takes. That is
  // the standard condition for not synchronising a data bus, and it is the
  // reason this is a handshake rather than a FIFO.
  logic        req_cpu;
  typedef enum logic [1:0] { C_IDLE, C_WAIT, C_CLR } cph_e;
  cph_e cph;
  logic        req_mem, ack_mem;
  logic        ack_cpu;          // ack_mem, one CPU flop later

  logic        r_we;
  logic [31:0] r_addr, r_wdata;
  logic  [3:0] r_be;
  logic [31:0] r_rdata;

  always_ff @(posedge clk_cpu or negedge rst_n_cpu) begin
    if (!rst_n_cpu) begin
      req_cpu <= 1'b0; bus_ack <= 1'b0; cph <= C_IDLE; ack_cpu <= 1'b0;
      r_we <= 1'b0; r_addr <= 32'd0; r_wdata <= 32'd0; r_be <= 4'd0;
    end else begin
      // The same single flop in the other direction, for the same reason: one
      // stage of settling, not two of synchronising.
      ack_cpu <= ack_mem;
      bus_ack  <= 1'b0;
      // AN EXPLICIT FOUR-PHASE HANDSHAKE, because the condition-by-condition
      // version kept racing. The phases are req-up, ack-up, req-down, ACK-DOWN,
      // and the last one is the one that is easy to leave out: without it the
      // next access starts while the previous acknowledge is still working its
      // way back through the synchroniser and completes IMMEDIATELY on stale
      // data, having never reached memory at all.
      //
      // The i960 makes this unforgiving. It HOLDS bus_req high across a run of
      // accesses and moves bus_addr ON THE ACK -- its boot walk reads mem[0],
      // mem[4] and mem[12] without ever dropping the request -- so "a new
      // request is present" is true continuously and cannot be used to separate
      // one access from the next. Only the acknowledge can.
      //
      // On hardware this read word 0 three times: SAT was right by luck, PRCB
      // came back 0 and the boot took a zero IP.
      case (cph)
        C_IDLE: if (bus_req && !ack_cpu) begin
          r_we    <= bus_we;
          r_addr  <= bus_addr;
          r_wdata <= bus_wdata;
          r_be    <= bus_be;
          req_cpu <= 1'b1;
          cph     <= C_WAIT;
        end
        C_WAIT: if (ack_cpu) begin
          req_cpu   <= 1'b0;
          bus_rdata <= r_rdata;
          bus_ack   <= 1'b1;       // one cycle, which is what the i960 expects
          cph       <= C_CLR;
        end

        // The fourth phase. Nothing starts until the acknowledge has gone away.
        default: if (!ack_cpu) cph <= C_IDLE;
      endcase
    end
  end

  // NOT A CLOCK-DOMAIN CROSSING, AND THE DISTINCTION IS WORTH ~7 CYCLES AN
  // ACCESS.
  //
  // clk_cpu and clk_mem come from ONE PLL at an exact 2:1 ratio -- 24 and 48
  // MHz off the same VCO with integer dividers -- so their edges are aligned
  // and every CPU-domain signal is stable across two memory cycles. There is
  // no metastability here to synchronise away. m2_sdram_x2 makes exactly this
  // argument for the 96/48 pair and carries no synchroniser for the same
  // reason; this pair simply never had the argument applied to it.
  //
  // What the two flops cost: a four-phase handshake pays the synchroniser
  // latency FOUR times -- req up, ack up, req down, ack down -- and the state
  // histogram measured it as 7.12 cycles per transaction in S_DONE alone,
  // against 4.42 for the SDRAM access it is wrapped around. With the data
  // cache in front, protocol is essentially the whole cost of a memory access.
  //
  // The two hazards m2_sdram_x2 records still apply and are still handled:
  // the acknowledge spans at least one slow cycle because S_DONE holds it
  // until the request drops, and the request stays high for up to two fast
  // cycles after the CPU sees the acknowledge, which is precisely what S_DONE
  // is waiting out.
  //
  // ONE FLOP, NOT ZERO, AND THE TESTBENCH SAID SO.
  //
  // Sampling req_cpu directly broke two I/O reads, which came back holding the
  // PREVIOUS transaction's value. The reason is in the original note above: the
  // two flops were not only about metastability, they gave the PAYLOAD time to
  // settle. r_addr is written in the CPU domain on the same edge req_cpu rises,
  // so a memory domain that believes the request immediately can decode an
  // address that has not arrived.
  //
  // One flop restores that guarantee -- the memory side sees the request half a
  // CPU cycle later, by which time the payload is settled -- and still returns
  // half the latency. Measured: S_DONE fell from 7.12 cycles per transaction to
  // 1.14.
  //
  // This REQUIRES the two clocks to be declared related in Model2.sdc; they were
  // in separate -asynchronous groups, which would leave these paths unchecked.
  logic req_mem_r;
  always_ff @(posedge clk_mem or negedge rst_n_mem) begin
    if (!rst_n_mem) req_mem_r <= 1'b0;
    else            req_mem_r <= req_cpu;
  end
  assign req_mem = req_mem_r;

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

  // NEVER RETAIN A BUFFER-RAM LINE. Three reasons, each sufficient:
  //
  //   * the region has writers the cache cannot see -- the geo DMA and the
  //     bi_ initialiser write it straight to SDRAM, so a retained line goes
  //     stale with no invalidation. The DPRAM is kept out of the cache for
  //     exactly this ("never cached... keeps the I/O board's side correct").
  //   * the reference mirrors it (.mirror(0x60000)). The cache tags the CPU
  //     address, so 0x900010 and 0x960010 are DIFFERENT lines naming the SAME
  //     word -- a write through one alias invalidates only its own line, and
  //     per-line invalidation can therefore never be coherent here, even with
  //     the CPU as the only writer.
  //   * the d-cache is this project's own addition, not the i960's. Excluding
  //     a shared region is faithful by default.
  //
  // Implemented as FILL SUPPRESSION, not as a route down the plain read path:
  // that path is dead code behind the cache, works in both simulations, and
  // hung real hardware at the fourth boot-record read when DCACHE_EN=0 ran it
  // (its second-half read is not burst-aligned, which the controller's port
  // contract requires). The read still takes the proven aligned-burst route;
  // the line is simply never written back into the cache, so every read
  // misses and refetches. Slower, coherent, and one variable against the
  // livelocked build.
  logic nocache;

  always_comb begin
    tgt     = T_NONE;
    sd_word = '0;
    is_rom  = 1'b0;
    nocache = 1'b0;
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
    // BISECTED: writes only. This region does TWO things when it is enabled --
    // writes start landing where they used to vanish, and reads start
    // returning real data where they used to return the T_IO default of 0.
    // Enabling both at once breaks the machine and four theories have died on
    // it. `r_we` in the condition lets WRITES land while READS still fall
    // through to T_IO and read 0, exactly as before, which splits the change
    // in half: if this boots, the fault is in what the reads return.
    end else if (BUFFERRAM && (r_we || !BUFFERRAM_WRONLY)
                 && r_addr >= 32'h0090_0000 && r_addr < 32'h0098_0000) begin
      // 128 KB, and the mirror is free: [16:1] simply ignores the repeat.
      tgt = T_SDRAM;
      nocache = BUFFER_NOCACHE;
      sd_word = base_buffer + AW'(r_addr[16:1]);
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
  // WHICH HALVES OF THE DWORD THIS ACCESS ACTUALLY OWNS.
  //
  // half_be: the word addressed by r_addr[15:1] -- the one written in S_IDLE.
  // hi_be:   the word after it, which only a 32-bit aligned store reaches.
  //
  // The i960 replicates sub-word store data across the bus, which is why
  // oc_din can keep taking r_wdata[15:0] for the first word regardless of
  // r_addr[1]: a store to 0x01800002 with be=c was observed writing 9090
  // correctly through that path. Only the ENABLES were wrong.
  wire half_be = r_addr[1] ? (|r_be[3:2]) : (|r_be[1:0]);
  wire hi_be   = ~r_addr[1] & (|r_be[3:2]);

  assign oc_addr      = r_addr[15:1] + {14'd0, half};
  assign oc_din       = half ? r_wdata[31:16] : r_wdata[15:0];
  // THE COLOUR-TRANSLATION TABLE IS STRIDED, NOT PACKED.
  //
  // This was `r_addr[7:1]`, which keeps the low eight bits of the byte address
  // and throws away everything that identifies the entry. model2.cpp reads it:
  //
  //   r = m_colorxlat[(0x0080 >> 1) + (((palcolor >> 0) & 0x1f) << 8)];
  //   g = m_colorxlat[(0x4080 >> 1) + ...];
  //   b = m_colorxlat[(0x8080 >> 1) + ...];
  //
  // so the entries this core keeps are at BYTE offsets 0x0080 + v*512 for red,
  // 0x4080 + v*512 for green and 0x8080 + v*512 for blue, v = 0..31. The stride
  // is 512 and the channel is bits 15:14. `r_addr[7:1]` sees neither: every one
  // of the game's writes landed on the same few table entries, and the rest kept
  // the pal5bit values the table powers up with.
  //
  // Only 96 of 24,576 entries are ever read -- 32 per channel -- which is why
  // this is a 96-byte table and not 48 KB (study R27). That economy is exactly
  // what makes the indexing load-bearing.
  //
  // Found from the board: the CPU builds a correct palette (4,036 of 4,096 words
  // matching MAME) and a correct tilemap (32,340 of 32,768), and the screen was
  // still white.
  assign oc_xlat_addr = {r_addr[15:14], r_addr[13:9]};

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
  // S_DCK joins them, so the encoding needs a fourth bit.
  typedef enum logic [3:0] { S_IDLE, S_LO, S_LO_W, S_HI, S_HI_W, S_RDB, S_IOW, S_DONE,
                             S_DCK, S_RMW, S_RMW_W } st_e;

  // READ-MODIFY-WRITE FOR SUB-WORD WRITES, because byte enables do not reach
  // the memory on this board.
  //
  // Measured: the CPU issues a byte store (data 0x27272727, be=0001 -- correct
  // i960 behaviour, it replicates the byte and relies on the enables), the
  // bridge forwards be=01 (verified on hardware), and every lane still lands.
  // The x2 adapter passes be through combinationally, the controller captures
  // it on the request edge and drives sd_dqm = ~be, the pins are assigned and
  // constrained, and simulation gets all four lanes right against the device
  // model. Bypassing the data cache changes nothing, so it is not that either.
  //
  // Every hop verifies and the result is still wrong, which leaves the SDRAM
  // module: DQM tied low is common on these boards, and it would make every
  // byte write land in all four lanes exactly as observed -- invisible to every
  // test we own, because they all test the FPGA.
  //
  // So stop depending on it. A partial write READS the word, merges the enabled
  // bytes here, and writes back FULL WIDTH. No mask reaches the device.
  logic [31:0] rmw_dat;
  logic        rmw_done;
  wire         needs_rmw = r_we && (r_be != 4'b1111);
  st_e  st;
  logic half;

  // ----------------------------------------------------------- DATA CACHE
  //
  // MEASURED BEFORE IT WAS BUILT. An 813,751-address read trace from the boot
  // harness, modelled offline exactly as the instruction cache was:
  //
  //     size   ways   hit%     M10K
  //     2KB      1    97.86     2.1
  //    16KB      1    97.89    16.4
  //
  // 2 KB takes the whole prize; sixteen buys 0.03 points. The working set is
  // 16,910 distinct lines and heavily reused, which is why so little goes so
  // far. Reads are 83.5% of the CPU's memory traffic and carry ~19.7 of the
  // 32.45 CPI, so removing 97.9% of them is the largest lever this core has.
  //
  // EIGHT-BYTE LINES, because that is exactly one burst. Every port returns
  // four 16-bit words in a 64-bit p_dout, so a line fill costs ONE transaction
  // and discards nothing -- where today a 32-bit read uses half of what it
  // fetches and throws the rest away.
  //
  // TAGS IN M10K, READ REGISTERED, and this is the i960_icache lesson paid
  // forward: that file pins its tags to logic because `hit` compares them
  // combinationally, which cost 736 bits of flip-flops there and would cost
  // 5,632 here. A registered tag costs ONE cycle in S_DCK, against the ~19 a
  // miss costs, so the trade is not close.
  //
  // WRITE-THROUGH, INVALIDATE, NO ALLOCATE. Writes already go to SDRAM and
  // simply drop the line they land on. Every T_SDRAM region is written by the
  // CPU alone once it is running -- work RAM, char RAM and backup are CPU-only,
  // ROM is read-only, and the ROM loader finishes before the CPU starts -- so
  // there is no other master to be coherent with. The DPRAM is T_IO and is
  // never cached, which is what keeps the I/O board's side correct.
  // 2 KB WAS NOT ENOUGH, MEASURED ON THE BOARD. The hit rate on the code the
  // first three minutes run is 55 per cent -- two of every three accesses miss,
  // 651,000 SDRAM round trips a second at one million instructions a second, so
  // roughly two thirds of an instruction is a memory stall. That IS the 24
  // cycles per instruction; nothing else needs to explain it.
  //
  // An earlier session measured this same cache at 99.57% on the boot path, so
  // it is not the cache being wrong, it is this working set not fitting: 55% on
  // a DIRECT-MAPPED cache is the signature of conflict thrashing rather than
  // capacity alone.
  //
  // 2048 lines x 8 B = 16 KB, eight times the size, which is affordable now
  // that R96 and R97 returned 95 M10K blocks. The tag narrows by three bits as
  // the index widens, so the tag array barely grows.
  localparam int unsigned DC_LINES = 2048;                // x 8 B = 16 KB
  localparam int unsigned DC_IDXW  = $clog2(DC_LINES);    // 11
  localparam int unsigned DC_TAGW  = 32 - DC_IDXW - 3;    // 18

  (* ramstyle = "M10K" *) logic [63:0]          dc_data [DC_LINES];
  (* ramstyle = "M10K" *) logic [DC_TAGW:0]     dc_tag  [DC_LINES];   // {valid,tag}

  logic [63:0]        dc_q;
  logic [DC_TAGW:0]   dc_tq;
  logic [DC_IDXW-1:0] dc_a;
  logic               dc_dwe, dc_twe;
  logic [63:0]        dc_din;
  logic [DC_TAGW:0]   dc_tin;

  wire [DC_IDXW-1:0] dc_idx  = r_addr[DC_IDXW+2:3];
  wire [DC_TAGW-1:0] dc_tagv = r_addr[31:DC_IDXW+3];
  logic [DC_TAGW-1:0] dc_tag_r;
  logic               dc_sweeping;
  logic [DC_IDXW-1:0] dc_sweep;
  logic               dc_inval;     // a write is dropping this line

  always_ff @(posedge clk_mem) begin
    dc_q  <= dc_data[dc_a];
    dc_tq <= dc_tag [dc_a];
    if (dc_dwe) dc_data[dc_a] <= dc_din;
    if (dc_twe) dc_tag [dc_a] <= dc_tin;
  end

  wire dc_hit = dc_tq[DC_TAGW] && (dc_tq[DC_TAGW-1:0] == dc_tag_r);

  // The array port, one owner per cycle. The reset sweep outranks everything --
  // nothing may be served from a cache whose valid bits are still uninitialised
  // -- then a fill, then a write's invalidate, and otherwise the lookup.
  always_comb begin
    dc_a   = dc_idx;
    dc_dwe = 1'b0;
    dc_twe = 1'b0;
    dc_din = sd_dout[63:0];
    dc_tin = {1'b1, dc_tag_r};
    if (dc_sweeping) begin
      dc_a   = dc_sweep;
      dc_twe = 1'b1;
      dc_tin = '0;
    end else if (st == S_RDB && sd_ack) begin
      dc_dwe = !nocache;                   // fill: ROM and RAM alike -- but a
      dc_twe = !nocache;                   // nocache region is never retained
    end else if (dc_inval) begin
      dc_twe = 1'b1;
      dc_tin = '0;
    end
  end

  always_ff @(posedge clk_mem or negedge rst_n_mem) begin
    if (!rst_n_mem) begin
      st <= S_IDLE; ack_mem <= 1'b0; half <= 1'b0;
      sd_req <= 1'b0; sd_we <= 1'b0; sd_addr <= '0; sd_din <= 16'd0; sd_be <= 2'b11;
      oc_tram_we <= 1'b0; oc_pal_we <= 1'b0; oc_xlat_we <= 1'b0;
      io_sel <= 1'b0; io_we <= 1'b0;
      r_rdata <= 32'd0;
      dbg_cpu_reads <= 32'd0; dbg_cpu_writes <= 32'd0; dbg_unmapped <= 32'd0;
      // Nothing may be served from valid bits that were never initialised.
      dc_sweeping <= 1'b1; dc_sweep <= '0; dc_inval <= 1'b0; dc_tag_r <= '0;
      rmw_dat <= 32'd0; rmw_done <= 1'b0;
      dbg_dc_hits <= 32'd0; dbg_dc_miss <= 32'd0;
      dbg_last_addr <= 32'd0; dbg_last_dout <= 32'd0;
      dbg_probe6 <= 32'hEEEE_EEEE; dbg_probe2 <= 32'hEEEE_EEEE;
      dbg_tram_wr <= 32'd0; dbg_pal_wr <= 32'd0;
    end else begin
      oc_tram_we <= 1'b0; oc_pal_we <= 1'b0; oc_xlat_we <= 1'b0;
      io_sel     <= 1'b0;

      // The cache's own housekeeping, before any state runs.
      dc_inval <= 1'b0;
      if (dc_sweeping) begin
        dc_sweep <= dc_sweep + 1'b1;
        if (dc_sweep == DC_IDXW'(DC_LINES - 1)) dc_sweeping <= 1'b0;
      end

      case (st)
        // !sd_ack as well as req_mem: the previous access's ack may still be
        // held when the next request arrives, and issuing into it has exactly
        // the same effect as issuing into it below.
        S_IDLE: if (req_mem && !ack_mem && !sd_ack && !dc_sweeping) begin
          if (r_we) dbg_cpu_writes <= dbg_cpu_writes + 32'd1;
          else      dbg_cpu_reads  <= dbg_cpu_reads  + 32'd1;
          half <= 1'b0;
          case (tgt)
            T_SDRAM: begin
              if (r_we && is_rom) begin
                ack_mem <= 1'b1; st <= S_DONE;    // .rom().nopw()
              end else if (!r_we && DCACHE_EN) begin
                // ASK THE CACHE FIRST. The arrays were addressed with dc_idx
                // combinationally this cycle, so S_DCK can compare next cycle.
                // 97.9% of reads end there and never reach the memory at all.
                dc_tag_r <= dc_tagv;
                st       <= S_DCK;
              end else if (!r_we) begin
                // Cache bypassed: the pre-cache path, byte for byte.
                sd_addr <= sd_word;
                sd_we   <= 1'b0;
                sd_be   <= 2'b11;
                sd_req  <= 1'b1;
                st      <= S_RDB;
              end else if (needs_rmw && !rmw_done) begin
                dc_inval <= 1'b1;
                sd_addr  <= {sd_word[AW:3], 2'b00};
                sd_we    <= 1'b0;
                sd_be    <= 2'b11;
                sd_req   <= 1'b1;
                st       <= S_RMW;
              end else begin
                // WRITE-THROUGH, INVALIDATE, NO ALLOCATE. The write reaches
                // memory exactly as before and drops whatever line it lands on.
                // That is the whole coherency story for a cache no other master
                // can get behind: work RAM, char RAM and backup are CPU-only,
                // ROM is read-only, and the ROM loader finishes before the CPU
                // starts. The DPRAM is T_IO and is never cached, which is what
                // keeps the I/O board's side correct.
                dc_inval <= 1'b1;
                sd_addr <= sd_word;
                sd_we   <= r_we;
                // THE HALF THAT BELONGS AT THIS WORD, NOT ALWAYS THE LOW ONE.
                //
                // SDRAM word r_addr[18:1] holds bytes r_addr and r_addr+1, and
                // those are the CPU dword's bytes r_addr[1:0] and r_addr[1:0]+1.
                // For an ALIGNED access that is the low half; for one with
                // r_addr[1] set it is the high half.
                //
                // This always sent r_wdata[15:0] with r_be[1:0], so an unaligned
                // access sent the wrong half AND the byte enables that go with
                // it -- 2'b00 -- which drops the write entirely. The i960
                // splits an unaligned 32-bit store into two transactions, and
                // one of the two was silently lost every time.
                //
                // Aligned accesses are unaffected, which is why the boot's own
                // 128 KB copy matched 65,536 of 65,536 words while character
                // data came out half written.
                sd_din  <= rmw_done ? (r_addr[1] ? rmw_dat[31:16] : rmw_dat[15:0])
                                    : (r_addr[1] ? r_wdata[31:16] : r_wdata[15:0]);
                sd_be   <= rmw_done ? 2'b11
                                    : (r_addr[1] ? r_be[3:2] : r_be[1:0]);
                sd_req  <= 1'b1;
                st      <= S_LO;
              end
            end
            T_TRAM, T_PAL: begin
              // `half` is already 0 here, so oc_addr and oc_din name the low
              // word this cycle.
              //
              // GATED ON THE BYTE ENABLES, WHICH THIS DID NOT DO (study R56).
              // Both halves were written for EVERY store, which is right for a
              // 32-bit one and destroys the neighbouring halfword for a 16-bit
              // one. Daytona's `stis g0,0x1800000(g4)` at 0x2784 is a HALFWORD
              // store: MAME clears palette entry 0 and leaves entry 1 holding
              // ffff, and we cleared both -- which is precisely why its test
              // menu drew green values and no white labels.
              //
              // `half_be` is the enable for the word this state writes. When
              // r_addr[1] is set the access names the dword's UPPER half, and
              // oc_addr is already r_addr[15:1], so the relevant enables are
              // r_be[3:2] -- observed as be=c on stores to 0x01800002.
              oc_tram_we <= r_we && (tgt == T_TRAM) && half_be;
              oc_pal_we  <= r_we && (tgt == T_PAL)  && half_be;
              if (r_we && (tgt == T_TRAM)) dbg_tram_wr <= dbg_tram_wr + 32'd1;
              if (r_we && (tgt == T_PAL))  dbg_pal_wr  <= dbg_pal_wr  + 32'd1;
              st         <= S_LO;
            end
            T_XLAT: begin
              oc_xlat_din <= r_wdata[7:0];
              // ONLY THE 96 ENTRIES THAT ARE EVER READ. Every entry in this
              // 48 KB region shares the low nine bits 0x080 exactly when it is
              // one of them; the other 24,480 writes are real and go nowhere,
              // which is the whole point of keeping 96 bytes instead of 48 KB.
              // Without this gate the last write to any address in a 512-byte
              // span overwrites the entry that span belongs to.
              oc_xlat_we  <= r_we && (r_addr[8:0] == 9'h080);
              ack_mem     <= 1'b1;
              st          <= S_DONE;
            end
            // ONE CYCLE BETWEEN ASSERTING io_sel AND SAMPLING io_rdata.
            //
            // This used to do both on the same edge, which captures whatever
            // the I/O side was presenting BEFORE the address it is being asked
            // about had been clocked into it. That is correct for a
            // combinational peripheral and one cycle early for a registered
            // one, and m2_ioboard and m2_backup are both registered -- they
            // have to be, because an asynchronously read array is not an MLAB
            // on this part, it is flip-flops and 7,899 ALM.
            //
            // R34 IS WHY IT BITES. The i960 holds bus_req across a run of
            // accesses and moves the address on the acknowledge, so on
            // back-to-back accesses r_addr changes and this state is entered
            // immediately, with the peripheral's registered output still
            // showing the PREVIOUS address.
            //
            // On hardware that read as a boot stuck in a poll whose value was
            // correct: the I/O board returned 00400000 for 0x01c00042 -- its
            // own debug tap said so -- and the i960 was handed 00000000.
            // Overlay rows 14 and 17 both reported healthy because both are on
            // the far side of this sample.
            T_IO: begin
              io_sel <= 1'b1;
              io_we  <= r_we;
              st     <= S_IOW;
            end
            default: begin
              dbg_unmapped <= dbg_unmapped + 32'd1;
              r_rdata      <= 32'd0;
              ack_mem      <= 1'b1;
              st           <= S_DONE;
            end
          endcase
        end

        // The registered I/O read, one cycle after the select. io_sel has
        // already fallen by here -- it is cleared at the top of this block --
        // which is right: a write lands on the cycle it is asserted, and a read
        // only needs the address, which r_addr holds for the whole transaction.
        S_IOW: begin
          if (io_stall) begin
            // Hold the access. io_sel is cleared at the top of this block every
            // cycle, so re-assert it: the target must keep seeing a live select
            // or it cannot tell when it becomes able to accept.
            io_sel <= 1'b1;
            io_we  <= r_we;
          end else begin
            r_rdata <= io_rdata;
            ack_mem <= 1'b1;
            st      <= S_DONE;
          end
        end

        // SDRAM low half, then high. The on-chip arrays answer in one cycle and
        // reuse the same two states, which is why S_LO tests `tgt`.
        S_LO: begin
          if (tgt == T_SDRAM) begin
            if (sd_ack) begin
              sd_req <= 1'b0;
              // Read back into the half this word belongs to, for the same
              // reason the write picks a half: the CPU expects a byte at dword
              // position r_addr[1:0], not always at position 0.
              if (!r_we) begin
                if (r_addr[1]) r_rdata[31:16] <= sd_dout[15:0];
                else           r_rdata[15:0]  <= sd_dout[15:0];
              end
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
            // The SECOND halfword exists only for a full 32-bit aligned store.
            // A halfword store has already written everything it owns, and
            // writing here is what corrupted the entry next door.
            oc_tram_we    <= r_we && (tgt == T_TRAM) && hi_be;
            oc_pal_we     <= r_we && (tgt == T_PAL)  && hi_be;
            st            <= S_HI;
          end
        end

        // Ack has fallen: the high half is safe to issue.
        S_LO_W: if (!sd_ack) begin
          half    <= 1'b1;
          sd_addr <= sd_word + AW'(1);
          // The second word holds bytes r_addr+2 and r_addr+3. When r_addr[1]
          // is set those belong to the NEXT dword and are not part of this
          // transaction at all, so nothing is enabled -- the i960 will issue
          // them separately.
          sd_din  <= r_addr[1] ? 16'd0
                     : (rmw_done ? rmw_dat[31:16] : r_wdata[31:16]);
          sd_be   <= r_addr[1] ? 2'b00 : (rmw_done ? 2'b11 : r_be[3:2]);
          sd_req  <= 1'b1;
          st      <= S_HI;
        end

        S_HI: begin
          if (tgt == T_SDRAM) begin
            if (sd_ack) begin
              sd_req <= 1'b0;
              if (!r_we && !r_addr[1]) r_rdata[31:16] <= sd_dout[15:0];
              st <= S_HI_W;
            end
          end else begin
            r_rdata[31:16] <= (tgt == T_TRAM) ? oc_tram_q : oc_pal_q;
            ack_mem        <= 1'b1;
            st             <= S_DONE;
          end
        end

        // THE LOOKUP. One cycle, because the tags are in M10K and read
        // registered -- see the note on the storage above for why that trade is
        // not close.
        S_DCK: begin
          if (dc_hit) begin
            r_rdata <= r_addr[2] ? dc_q[63:32] : dc_q[31:0];
            ack_mem <= 1'b1;
            dbg_dc_hits <= dbg_dc_hits + 32'd1;
            st      <= S_DONE;
          end else begin
            // LINE-ALIGNED, so one four-word burst fills the whole line and
            // nothing is discarded. It also restores natural dword alignment:
            // the burst used to start at the requested HALFWORD, which is why
            // the fixup below had to exist.
            // sd_word is [AW:1], so the line's low two WORD bits are [2:1].
            sd_addr <= {sd_word[AW:3], 2'b00};
            sd_we   <= 1'b0;
            sd_be   <= 2'b11;
            sd_req  <= 1'b1;
            dbg_dc_miss <= dbg_dc_miss + 32'd1;
            st      <= S_RDB;
          end
        end

        // The read half of a read-modify-write. WAIT FOR THE ACK TO FALL
        // before re-dispatching: returning straight to S_IDLE walks into the
        // held-acknowledge hazard S_LO_W and S_HI_W exist to avoid, which is
        // R32's wrong boot vector.
        S_RMW: if (sd_ack) begin
          sd_req <= 1'b0;
          rmw_dat[7:0]   <= r_be[0] ? r_wdata[7:0]
                            : (r_addr[2] ? sd_dout[39:32] : sd_dout[7:0]);
          rmw_dat[15:8]  <= r_be[1] ? r_wdata[15:8]
                            : (r_addr[2] ? sd_dout[47:40] : sd_dout[15:8]);
          rmw_dat[23:16] <= r_be[2] ? r_wdata[23:16]
                            : (r_addr[2] ? sd_dout[55:48] : sd_dout[23:16]);
          rmw_dat[31:24] <= r_be[3] ? r_wdata[31:24]
                            : (r_addr[2] ? sd_dout[63:56] : sd_dout[31:24]);
          rmw_done <= 1'b1;
          st       <= S_RMW_W;
        end

        // The ack has fallen; now the write may be issued.
        S_RMW_W: if (!sd_ack) st <= S_IDLE;

        // A burst read: both halves arrive together in p_dout[31:0].
        S_RDB: if (sd_ack) begin
          sd_req        <= 1'b0;
          // THE BURST STARTS AT THE REQUESTED WORD, WHICH IS NOT ALWAYS THE
          // DWORD'S LOW HALF.
          //
          // sd_addr is sd_word = r_addr[..:1], so sd_dout[15:0] holds the bytes
          // at r_addr itself. For an aligned access those are the dword's bytes
          // 0 and 1 and this is right. When r_addr[1] is set they are bytes 2
          // and 3, and the i960 looks for them in the HIGH half -- the LSU's
          // `rd_half = cur_addr[1] ? bus_rdata[31:16] : bus_rdata[15:0]`.
          //
          // Taking sd_dout[31:0] unconditionally handed it the two words
          // starting at r_addr with the halves the wrong way round, so every
          // unaligned halfword read returned its NEIGHBOUR. The boot's
          // character copy is a halfword loop -- ldos/stos with both pointers
          // advancing by 2 -- so every other load was wrong: 52,375 of 140,864
          // in a single boot, every one of them with be=c.
          //
          // Nothing caught it because every read in the suite was full-width
          // and dword-aligned, and because ALL SDRAM reads come through here --
          // S_LO and S_HI are the write path. An earlier attempt at this fix
          // was made in S_LO, where reads never go.
          // THE BURST IS NOW LINE-ALIGNED, so the halfword fixup this comment
          // describes is GONE: sd_dout holds the whole eight-byte line in
          // natural order, and the dword the CPU asked for is picked by
          // r_addr[2]. The LSU still selects its halfword with cur_addr[1],
          // which is what it expects to do.
          r_rdata       <= DCACHE_EN ? (r_addr[2] ? sd_dout[63:32] : sd_dout[31:0])
                                     : (r_addr[1] ? {sd_dout[15:0], 16'd0}
                                                  : sd_dout[31:0]);
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
          ack_mem  <= 1'b0;
          rmw_done <= 1'b0;
          st      <= S_IDLE;
        end

        // Six named states in a three-bit type leaves two unreachable
        // encodings. Naming them costs nothing and means a glitch into one is
        // recoverable rather than a permanent stall.
        default: st <= S_IDLE;
      endcase
    end
  end

  // r_we/r_addr are the LATCHED request, so this is registered by construction
  // rather than a tap on a live bus.
  assign char_wr = r_we && (r_addr >= 32'h0108_0000) && (r_addr < 32'h0110_0000)
                   && (st == S_LO);
  assign char_wr_addr = r_addr[18:1];

  assign dbg_mstate = {2'd0, sd_ack, ack_mem, req_mem, st[2:0]};

  assign io_addr  = r_addr;
  assign io_wdata = r_wdata;
  assign io_be    = r_be;

endmodule
