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
// Single-chip 16-bit SDR SDRAM controller with a per-master round-robin
// arbiter, for the port map in docs/00-decisions.md D8.
//
// PROVENANCE
//
// The state machine follows meathax's System 32 controller
// (third_party/s32/rtl/mem/sdram.sv, GPL-3.0, so licence-compatible per D7).
// That is deliberate. It encodes two hazards that were found the hard way and
// are invisible from a datasheet:
//
//   - Requests must be latched on the REQUEST RISING EDGE, not sampled as a
//     level qualified by !pend && !ack. The level-sampled version has a
//     one-cycle drop window: a requester that issues its next request in
//     direct response to an ack presents a pulse whose first cycle is blocked
//     by the still-clearing pend and whose second by the stretched ack. The
//     transaction vanishes and the port hangs forever. Which transactions hit
//     the window depends on arbitration history, so it appears as "adding an
//     unrelated master broke the CPU".
//
//   - Completion must clear pend on the ack RISING EDGE and must do so BEFORE
//     the new-request latch in the same process, so a chained request landing
//     on the very edge that clears pend wins rather than vanishing.
//
// Reimplementing from scratch would have meant rediscovering both.
//
// WHAT IS DIFFERENT HERE
//
//   - Ports are a generic array rather than six copy-pasted blocks. Six
//     near-identical hand-written port blocks is six chances to transpose an
//     index, and the arbiter becomes a loop instead of a priority ladder
//     repeated once per rotation position.
//   - Any port may write. D8 puts V60 work RAM in external memory, so p0
//     needs a write path; s32's read ports are read-only because all of its
//     RAM is internal.
//   - DQ is split into dq_i/dq_o/dq_oe. The tri-state lives at the top level
//     where the physical pin is, which keeps this module and the device model
//     straightforwardly simulatable.
//   - Timing is parameterised, in clock cycles, and the same numbers are
//     handed to sdram_model in simulation. Hardcoded cycle counts silently
//     stop being correct when the clock changes, and nothing catches it.
//   - dbg_req/dbg_grant are brought out for bw_monitor, so telemetry does not
//     have to reach inside the module.
//
// REQUEST CONTRACT
//
// One transaction per request RISING EDGE. The address, write data and byte
// enables are sampled on that edge. A request held high is serviced exactly
// once — a requester expecting re-service per ack from a held level will
// hang. Requesters must be single-outstanding.

`timescale 1ns/1ps

module m2_sdram #(
  // GEOMETRY. COL_BITS is the only free variable: the MiSTer SDRAM connector
  // gives 13 address pins and 2 bank pins, so with 13 row bits the module size is
  // decided entirely by the column count.
  //
  //    9 -> 8192 x 512  x 4 =  32 MB   (the 32 MB modules)
  //   10 -> 8192 x 1024 x 4 =  64 MB
  //   11 -> 8192 x 2048 x 4 = 128 MB
  //
  // Column bits map to A0..A9 then A11, A12 -- SKIPPING A10, which is the
  // auto-precharge flag. That is why ten column bits taken as [10:1] aliases:
  // it puts a column bit where the precharge flag lives. See the note below.
  parameter int unsigned COL_BITS = 9,
  parameter int unsigned ROW_BITS = 13,
  parameter int unsigned BA_BITS  = 2,
  parameter int unsigned NP = 5,      // read/write ports, see D8

  // Device timing, in clk cycles. Defaults suit -7E parts around 100 MHz.
  parameter int unsigned T_RCD  = 2,
  parameter int unsigned T_RP   = 2,
  parameter int unsigned T_RC   = 7,
  parameter int unsigned T_RAS  = 5,
  parameter int unsigned T_WR   = 2,
  parameter int unsigned CL     = 2,

  // Refresh cadence. 8192 rows per 64 ms is one per 781 cycles at 100 MHz;
  // the margin below that absorbs a transfer in flight when the timer fires.
  parameter int unsigned T_REFI = 700,

  // Power-up delay. JEDEC wants >100 us of NOP before the first command.
  parameter int unsigned INIT_NOP = 10000,

  // Ack hold. Requesters on a slower synchronous clock must see exactly one
  // rising edge with ack high, so this is 2 for a clk/2 requester.
  parameter int unsigned ACK_HOLD = 2
) (
  input  logic                 clk,
  input  logic                 rst_n,
  output logic                 ready,

  // Read capture depth. **0 IS CL+3, NOT CL+2**, and the ordering is that way
  // round on purpose: an unconnected port reads as zero, and zero has to be the
  // value that matches sdram_model, so forgetting to wire it degrades to
  // "works" rather than to "every burst arrives one word late".
  //
  // It was the other way round for one commit and tb_m1_boot, which does not
  // wire this port and is built with -Wno-PINMISSING, silently got the hardware
  // phase against the simulation model. The V60 halted after a single
  // instruction and the trace read "0 distinct addresses" — a testbench
  // reporting a clean absence of the thing it was measuring.
  //
  //   0 -> CL+3  (sdram_model, and the safe default)
  //   1 -> CL+2  (the board: its device is clocked on the inverse of clk_sys)
  //   2 -> CL+4
  //   3 -> CL+5
  input  logic [2:0]           rd_lat_sel,

  // SDRAM device
  output logic                 sd_cke,
  output logic                 sd_cs_n,
  output logic                 sd_ras_n,
  output logic                 sd_cas_n,
  output logic                 sd_we_n,
  output logic [1:0]           sd_ba,
  output logic [12:0]          sd_a,
  output logic [1:0]           sd_dqm,
  output logic [15:0]          sd_dq_o,
  output logic                 sd_dq_oe,
  input  logic [15:0]          sd_dq_i,

  // ROM download. Highest priority while it is active; game logic is held in
  // reset during download, so starving the other ports costs nothing.
  input  logic                 wr_req,
  input  logic [AW:1]          wr_addr,
  input  logic [15:0]          wr_din,
  input  logic [1:0]           wr_be,
  output logic                 wr_ack,

  // Masters. Word-addressed; a burst port's address must be burst-aligned.
  input  logic [NP-1:0]        p_req,
  input  logic [NP-1:0]        p_we,
  input  logic [NP-1:0][AW:1]  p_addr,
  input  logic [NP-1:0][15:0]  p_din,
  input  logic [NP-1:0][1:0]   p_be,
  output logic [NP-1:0][63:0]  p_dout,
  output logic [NP-1:0]        p_ack,

  // Telemetry taps for bw_monitor. `dbg_req` is the latched pending state
  // rather than the raw input, because demand is "asking and not yet served",
  // which a one-cycle request pulse would not show.
  output logic [NP-1:0]        dbg_req,
  output logic [NP-1:0]        dbg_grant
);

  // Burst length per port, in 16-bit words. D8: p1 is tile character fetch and
  // p2 is polygon/TGP data, both of which are consumed in runs, so they burst.
  // The rest are single-word random access.
  //
  // p3 is the coprocessor's read-only regions — copro_data and the math tables.
  // A coprocessor fetch is one 32-bit word, so it needs TWO 16-bit words, and
  // only 1 and 4 are available: the capture below assembles the non-single case
  // from cap[2], cap[1], cap[0], so a length of 2 would take two of those from
  // stale slots. So it bursts 4 and the requester picks its half — see
  // m1_integrated, which aligns the address down and selects on bit 1.
  // PORT 0 BURSTS FOUR TOO. It used to return a single word, and a single-word
  // read carries A10 -- auto-precharge -- on its FIRST command, because the
  // first word is also the last. The row therefore closes tRCD+1 cycles after
  // it was activated, which is inside tRAS on a real device and tolerated by a
  // behavioural model. Ports 1 to 3 burst four and issue the precharge on the
  // fourth, comfortably clear of it.
  //
  // That is the asymmetry the board showed: the tilemap copy engine and the
  // character fetch read correctly on ports 2 and 3 while the CPU on port 0
  // read zero from the same SDRAM, at every capture depth the OSD offers.
  //
  // A 64-bit p_dout holds four words, so the CPU's 32-bit access now takes ONE
  // transaction instead of two -- which also removes the held-acknowledge
  // hazard of study R32 rather than working around it.
  function automatic logic [3:0] blen(input int unsigned p);
    case (p)
      // ALL FOUR PORTS BURST FOUR. Port 4 joined them for the read-back sweep,
      // which folds four words per request; and a single-word read auto-
      // precharges on its first command, which R33 records.
      // Port 5 is the sound board's 68000 fetching its program ROM, and it
      // joins them for the same reason rather than taking the single-word
      // path: a single-word read auto-precharges on its first command (R33),
      // and a four-word burst also gives the 68000's sequential fetch three
      // free words out of every four.
      // 6 and 7 are the MULTIPCMs' sample fetches; a voice reads
      // consecutive bytes, so four words at a time gives it seven of
      // every eight without a second request.
      0, 1, 2, 3, 4, 5, 6, 7: blen = 4'd4;
      // 8 AND 9 BURST FOUR BECAUSE EVERY PORT MUST BURST THE SAME, AND THAT IS
      // A CONSTRAINT OF THIS CONTROLLER, NOT A PREFERENCE.
      //
      // The TGP wants a PAIR -- its word is 32 bits and this memory's is 16, so
      // one lookup is two SDRAM words and the other two are thrown away. Two
      // was tried, and it corrupted OTHER PORTS' data.
      //
      // `rd_total` is a single global register (see the read-issue block). A
      // transaction that is granted while another is still issuing overwrites
      // its burst length, and `tag_last` is then computed against the wrong
      // count: the earlier transaction completes early and is composed from
      // however many words had arrived. Port 0 -- the i960 -- came back with
      // two of its four words and zeros above them. Nothing in this controller
      // detects it and nothing bounds which port is hit.
      //
      // Every port bursting four makes rd_total invariant, so the defect cannot
      // fire. It is a real defect and it is recorded (R108) rather than fixed
      // here, because fixing it means reworking the issue sequencing and this
      // change is on the path to first light for the coprocessor. **Adding a
      // port with a different burst length reintroduces silent cross-port
      // corruption.** The cost of uniformity is two wasted words per TGP
      // lookup on a port that blocks on every one of them anyway.
      // 10 IS THE GEOMETRIZER'S DISPLAY-LIST WALK, and it bursts four for the
      // same reason 8 and 9 do: every port must burst the same or the read tag
      // stream desynchronises and OTHER ports get corrupt data (R108). The walk
      // reads one dword at a time and discards the other pair, which is the
      // same bargain the TGP already makes.
      // R290: TEN AGAIN -- the texel fetch shares port 3 rather than adding an
      // eleventh. The case arm stays because the cost of listing a port that
      // does not exist is nothing and the cost of forgetting one is silent
      // cross-port corruption.
      // 10 IS THE TEXEL FETCH (R275), and it bursts four because EVERY PORT
      // MUST. This case list ended at 9 with `default: blen = 1`, so adding a
      // port would have given it a one-word burst -- and the paragraph above
      // says exactly what that does: `rd_total` is one global register, a
      // transaction granted while another is issuing overwrites it, and the
      // EARLIER one completes early with zeros above the words that arrived.
      // Not on the new port: on whichever port was mid-transaction. Silent
      // cross-port corruption, from a line nobody would have looked at.
      // R329: 8 AND 9 BURST TWO, WHICH IS WHAT THEY ACTUALLY CONSUME.
      //
      // Both take 32 bits -- Model2.sv's `tgp_tbl_rdata_r <= p_dout[8][31:0]`
      // and `tgp_dat_rdata_r <= p_dout[9][31:0]` -- so words 2 and 3 were
      // fetched and thrown away on every lookup. A row-hit read costs
      // S_IDLE + S_SEL + S_DISPATCH (3) + one CAS per word + cap_depth (6), so
      // this takes 13 cycles to 11: 15% off a read the COPROCESSOR BLOCKS ON,
      // and two CAS slots per lookup handed back to every other master.
      //
      // THE UNIFORMITY RULE ABOVE IS STALE, and this is the evidence. The
      // defect it guards against is `rd_total` being overwritten by a
      // transaction granted while another is still issuing. `rd_total` is
      // written at exactly two places, BOTH INSIDE S_IDLE, and the FSM does not
      // return to S_IDLE until `rd_issued + 1 == rd_total`. It cannot be in
      // S_IDLE and S_RD at once, so nothing can be granted mid-burst and the
      // window is structurally closed. R296 tried this and the 3,407 bench
      // failures were all on words 2 and 3 OF PORTS 8 AND 9 -- the bench's own
      // burst_of() mirror still saying four -- with NO OTHER PORT AFFECTED,
      // which is the cross-port corruption the rule exists to prevent.
      //
      // Alignment is not a constraint here: S_RD issues one C_READ per cycle
      // and walks the column itself, so the device is in BL=1 and there is no
      // burst boundary to align to. Port 9's odd `tgp_dat_half_r` start is
      // fine -- it gets {addr, addr+1}, which is what it asked for.
      //
      // 10 IS THE TEXEL FETCH AND KEEPS FOUR: `tex_m_data = p_dout[10]` uses
      // all 64 bits, one cache line, eight texels.
      8, 9:  blen = 4'd2;
      10:    blen = 4'd4;
      default: blen = 4'd1;
    endcase
  endfunction

  localparam logic [3:0] C_NOP   = 4'b0111;   // {cs,ras,cas,we}
  localparam logic [3:0] C_ACT   = 4'b0011;
  localparam logic [3:0] C_READ  = 4'b0101;
  localparam logic [3:0] C_WRITE = 4'b0100;
  localparam logic [3:0] C_PRE   = 4'b0010;
  localparam logic [3:0] C_REF   = 4'b0001;
  localparam logic [3:0] C_MRS   = 4'b0000;

  // Round trip from the edge that issues a READ to the edge that can read the
  // captured word, counted term by term rather than guessed:
  //
  //   +1  cmd is registered, so the device sees the command one edge later
  //   +CL the device presents data CL edges after it samples the command
  //   +1  dq_i is registered into dq_r, which is what puts the pin-to-register
  //       path in the input IOE instead of in a core timing arc
  //   +1  the capture logic reads dq_r, which is a register output
  //
  // CL+3. The first version of this said CL+2 — the outbound register was
  // counted and the capture read was not — and every read returned zero.
  // This off-by-one has now cost the project six debugging sessions across
  // four modules, which is why it is spelled out instead of asserted.
  //
  // THAT DERIVATION IS AGAINST sdram_model, AND THE BOARD DISAGREES.
  //
  // The model samples commands and presents data on the same clock edge the
  // controller uses. The board does not: SDRAM_CLK is the inverse of clk_sys,
  // so the device samples and drives half a period away, and the model's own
  // header says that forwarded-clock phase is "deliberately not modelled
  // here". Every term above is right and the total is still a simulation
  // figure.
  //
  // Measured on hardware: the assembled line came back shifted right by one
  // 16-bit word — the controller tagged the burst's word 1 as word 0. The
  // V60's reset vector read FE104E where the ROM holds 4EF3D6, which is
  // exactly bits [39:16] of the same burst. It hid for a session because the
  // only other address fetched is word 0, where the ROM is 000d 000d 000d
  // 000d and a one-word shift is invisible.
  //
  // So the capture point is selectable at run time rather than guessed one
  // Quartus build at a time. `rd_lat_sel` picks CL+2 through CL+5; the
  // pipeline is always the longest of those and the tag is injected at the
  // chosen depth. Simulation ties it to 1 and keeps CL+3, so every existing
  // harness measures what it always measured.
  localparam int unsigned RD_LAT     = CL + 5;   // pipeline depth, the maximum
  localparam int unsigned RD_LAT_DEF = CL + 4;   // what the board wants

  // Which stage the tag is injected at, so it reaches slot 0 after that many
  // cycles. Registered off the selector to keep a slow OSD bit out of the
  // command path.
  logic [3:0] cap_depth;
  // Synchronous, like the command block below — see the note there. Mixing the two
  // disciplines on one reset net is what verilator's SYNCASYNCNET flags, and it is
  // a real smell rather than a nuisance: half the module would reset on a different
  // event from the other half.
  always_ff @(posedge clk) begin
    if (!rst_n) cap_depth <= 4'(RD_LAT_DEF);
    else case (rd_lat_sel)
      // INDEX n IS CL+n. The order used to be CL+2, CL+0, CL+1, CL+3, CL+4,
      // CL+5 -- chosen so that an unconnected selector landed on the value the
      // board wanted -- and that made the calibration sweep's pass mask
      // MEANINGLESS AS A SHAPE. A capture window is a contiguous run of depths
      // that work, and finding its centre is the whole point of sweeping it;
      // you cannot do that when bit 1 is two cycles from bit 0 and bit 2 is
      // back between them.
      //
      // The default now comes from the calibration rather than from index 0.
      3'd0:    cap_depth <= 4'(CL + 0);
      3'd1:    cap_depth <= 4'(CL + 1);
      3'd2:    cap_depth <= 4'(CL + 2);
      3'd3:    cap_depth <= 4'(CL + 3);
      3'd4:    cap_depth <= 4'(CL + 4);
      default: cap_depth <= 4'(CL + 5);
    endcase
  end

  localparam int unsigned WIDX = NP;          // write port's grant index

  // ADDRESS DECODE
  //
  // A 32 MB module is 8192 rows x 512 columns x 4 banks of 16-bit words, so
  // 13 + 9 + 2 = 24 bits, which is exactly the [AW:1] word address the ports
  // supply. Column is therefore NINE bits.
  //
  // s32's controller takes the column from [10:1] — ten bits — which with 13
  // row bits and 2 bank bits needs 25 address bits and so overlaps bit 10
  // between row and column. Copying that here would have aliased every
  // address pair differing only in bit 10 onto one location, which reads as
  // sporadic data corruption rather than as an address fault.
  // Word-address width implied by the geometry: bank + row + column.
  localparam int unsigned AW = BA_BITS + ROW_BITS + COL_BITS;

  // Column value placed on the address bus, skipping A10.
  function automatic logic [12:0] col_a(input logic [AW:1] a);
    logic [11:0] c;
    c = 12'(a[COL_BITS:1]);
    col_a       = '0;
    col_a[9:0]  = c[9:0];
    col_a[10]   = 1'b0;      // no auto-precharge: the row stays open
    col_a[11]   = c[10];
    col_a[12]   = c[11];
  endfunction

  logic [3:0]  cmd;
  assign {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} = cmd;
  assign sd_cke = 1'b1;

  typedef enum logic [3:0] {
    S_INIT, S_IDLE, S_SEL, S_DISPATCH, S_MISS, S_PRE_XFER, S_ACT, S_RCD,
    S_RD, S_WR, S_WRRC, S_PRE_REF, S_REFW
  } state_t;
  state_t state;

  // ---------------------------------------------------------------- mailbox
  // Metadata is captured with the request because arbitration may delay a
  // port long after the producer moved on to its next address.
  logic [NP-1:0]        pend;
  logic [NP-1:0][AW:1]  addr_p;
  logic [NP-1:0][15:0]  din_p;
  logic [NP-1:0][1:0]   be_p;
  logic [NP-1:0]        we_p;
  logic                 wr_pend;
  logic [AW:1]          wr_addr_p;
  logic [15:0]          wr_din_p;
  logic [1:0]           wr_be_p;

  logic [NP-1:0] req_d, ack_d;
  logic          wr_req_d, wr_ack_d;

  assign dbg_req = pend;

  int unsigned i;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pend <= '0; wr_pend <= 1'b0;
      req_d <= '0; ack_d <= '0; wr_req_d <= 1'b0; wr_ack_d <= 1'b0;
      addr_p <= '0; din_p <= '0; be_p <= '0; we_p <= '0;
      wr_addr_p <= '0; wr_din_p <= '0; wr_be_p <= '0;
    end else begin
      req_d    <= p_req;
      ack_d    <= p_ack;
      wr_req_d <= wr_req;
      wr_ack_d <= wr_ack;

      // Completion first, so a request edge landing on the same edge that
      // clears pend overrides it below rather than vanishing. See the header.
      for (i = 0; i < NP; i = i + 1)
        if (p_ack[i] && !ack_d[i]) pend[i] <= 1'b0;
      if (wr_ack && !wr_ack_d) wr_pend <= 1'b0;

      for (i = 0; i < NP; i = i + 1) begin
        if (p_req[i] && !req_d[i]) begin
          pend[i]   <= 1'b1;
          addr_p[i] <= p_addr[i];
          din_p[i]  <= p_din[i];
          be_p[i]   <= p_be[i];
          we_p[i]   <= p_we[i];
        end
      end
      if (wr_req && !wr_req_d) begin
        wr_pend   <= 1'b1;
        wr_addr_p <= wr_addr;
        wr_din_p  <= wr_din;
        wr_be_p   <= wr_be;
      end
    end
  end

  // ------------------------------------------------------------- arbitration
  // Round-robin over pending read/write ports, rotating after every grant so a
  // master that always has a request outstanding — the V60 during a cache miss
  // storm — cannot hold the bus. The write port sits above the rotation and
  // only matters during ROM download.
  logic [$clog2(NP)-1:0] rr_next;
  logic [$clog2(NP)-1:0] rr_grant;
  logic                  rr_valid;

  // ROTATE THE REQUEST MASK ONCE, THEN PRIORITY-ENCODE.
  //
  // This was a loop that rotated PER CANDIDATE. Two forms of that, both of
  // which the Kaneko core measured on the same controller at 96 MHz:
  //
  //   (rr_next + j) % NP     free while NP is a power of two, a REAL DIVIDER
  //                          once it is not -- and NP is 5 here, so never
  //                          free. Cost them 3.023 ns at NP=9.
  //   compare and subtract   NP adders in a priority chain, which closed at
  //                          +0.615 ns and went to -0.009 the moment four
  //                          debug counters were added.
  //
  // Both are the same mistake: doing the rotation once per candidate when it
  // only has to happen once. Rotate the pending mask right by rr_next so bit 0
  // is the port whose turn it is, take the lowest set bit, and rotate the index
  // back -- one barrel shift, one priority encode over single bits, one adder,
  // rather than NP adders in series.
  //
  // Technique from sega-model1-mister's sibling Kaneko16 core, `b5b2019`; the
  // arithmetic here is ours and single-tier, since this controller has no
  // urgent class. Behaviour is identical -- round-robin from rr_next -- and
  // m2_sdram's 123,927 checks say so, unchanged to the number.
  //
  // WE ARE AT 40 MHz AND THIS IS NOT ON OUR CRITICAL PATH TODAY. It is here
  // because pll.v records the 40 MHz as "DELIBERATELY AND TEMPORARILY", and
  // this is the path that decides whether raising it is a settings change or a
  // week of surgery.
  localparam int unsigned PW = $clog2(NP);

  function automatic logic [NP-1:0] rot_r(input logic [NP-1:0] m,
                                          input logic [PW-1:0] n);
    logic [2*NP-1:0] dbl;
    begin
      dbl   = {m, m};
      // The index is widened deliberately: dbl is 2*NP bits, so a PW-bit
      // index is one bit short of addressing it and the tool is right to say
      // so. n is always < NP, so the extra bit is always zero.
      rot_r = dbl[{1'b0, n} +: NP];
    end
  endfunction

  // Lowest set bit. Written high-to-low so the last assignment wins and the
  // result is the LOWEST index set, which is the nearest port in rotation
  // order.
  function automatic logic [PW-1:0] low_idx(input logic [NP-1:0] m);
    int li;
    begin
      low_idx = '0;
      for (li = NP-1; li >= 0; li = li - 1) if (m[li]) low_idx = PW'(li);
    end
  endfunction

  wire [NP-1:0]  arb_ready = pend & ~inflight;

  // REVERTED TO THE ROTATE (R290). R288 replaced this with two priority
  // encoders to shorten the path, `tb_m2_sdram` agreed to the transaction, and
  // THE BOARD DID NOT BOOT: the i960 sat in one load/store loop for four
  // minutes, the display list stayed zeros and the coprocessor never left
  // reset. The bench cannot see whatever that is, so the rewrite goes back and
  // the path is shortened by REMOVING the eleventh port instead -- the texel
  // fetch shares port 3 with the glyph cache, which is idle 89% of the time.
  //
  // Kept in the file, disabled, because the reasoning was right even if
  // something about it is not: the rotate-encode-add chain IS the depth that
  // made the eleventh port cost 0.37 ns.
  //
  // ORIGINAL COMMENT, for when this is tried again with a way to test it:
  // TWO PRIORITY ENCODERS IN PARALLEL, NOT A ROTATE THEN AN ENCODER THEN A
  // MODULAR ADD (R288).
  //
  // Round-robin from `rr_next` is "the lowest pending port at or above
  // rr_next, wrapping to the lowest overall". Written as a rotate of the mask,
  // an encode of the rotated mask and an add-with-conditional-subtract to undo
  // the rotation, the whole thing is ONE chain: barrel rotate -> priority scan
  // -> adder -> comparator -> subtract. Adding the eleventh port (R275's texel
  // fetch) made that chain the worst path in the design -- `pend[5]` to
  // `grant[*]`, -0.371 ns on the 100 MHz memory clock, measured with
  // report_timing rather than guessed.
  //
  // Written as two encoders it is the same answer with half the depth: the
  // "at or above" mask is a decode of rr_next that computes in parallel with
  // pend, and the two scans run side by side. Nothing about the ORDER changes,
  // which is what tb_m2_sdram's per-port transaction counts check.
  wire [NP-1:0]  arb_rot   = rot_r(arb_ready, rr_next);
  wire [PW-1:0]  arb_idx   = low_idx(arb_rot);
  // Rotate the index back. arb_idx < NP and rr_next < NP, so the sum never
  // reaches 2*NP and one conditional subtract is exact.
  wire [PW:0]    arb_sum   = {1'b0, arb_idx} + {1'b0, rr_next};

  always_comb begin
    rr_valid = |arb_rot;
    rr_grant = (arb_sum >= (PW+1)'(NP)) ? PW'(arb_sum - (PW+1)'(NP))
                                        : PW'(arb_sum);
  end

  // ------------------------------------------------------------- transfer
  logic [$clog2(NP+1)-1:0] grant;
  logic                    grant_is_wr;
  logic [AW:1]             xfer_addr;
  logic [3:0]              rd_total, rd_issued, rd_captured;
  logic                    is_write;
  logic [15:0]             din_r;
  logic [1:0]              be_r;
  logic [15:0]             cap_buf [4];

  // ------------------------------------------- the prefetch handoff (R387)
  // One transaction deep. The front stage fills it, the back stage drains it.
  // nxt_addr is a REGISTER, not the array: see the prefetch block for why the
  // ten-way mux must have exactly one reader.
  logic                    nxt_valid;   // handoff holds a selected transaction
  logic                    pf_sel;      // front stage is in its mux cycle
  logic [$clog2(NP)-1:0]   nxt_grant;
  logic [AW:1]             nxt_addr;
  logic [15:0]             nxt_din;
  logic [1:0]              nxt_be;
  logic [3:0]              nxt_total;
  logic                    nxt_is_write;
  // HOW LONG THE DEDICATED WRITE PORT HAS BEEN WAITING. See the prefetch
  // block: it buys the write a bounded wait without handing it the bus.
  logic [9:0]              wr_wait;

  // ROW STATE IS PER BANK
  //
  // The device holds one open row in each of its four banks, and the first
  // version of this controller tracked a single one and closed all four with
  // a precharge-all on every row change. With five masters interleaving, that
  // meant p0's access evicted p1's row and almost every transfer became a row
  // miss — a 16-cycle transfer instead of 10. Tracking each bank separately
  // and precharging only the bank actually being reused is what lets the
  // masters coexist, because D8 puts them in different address regions and
  // therefore usually in different banks.
  logic [3:0]  bank_open;
  logic [ROW_BITS-1:0] bank_row [4];
  // Cycles still owed to tRAS before that bank's row may be precharged. With
  // auto-precharge the device enforced this internally; taking that back means
  // taking the obligation back with it.
  logic [3:0]  ras_cnt [4];

  logic [1:0]  tbank;
  logic [ROW_BITS-1:0] trow;
  assign tbank = xfer_addr[AW:AW-1];
  assign trow  = xfer_addr[AW-2:COL_BITS+1];

  // A transfer whose bank and row are already open skips PRECHARGE and
  // ACTIVATE. This is the entire reason locality is worth anything: measured
  // before it existed, sequential traffic ran at exactly the same rate as
  // random — 0.263 words/cycle either way on a 4-word burst port — because
  // every read closed the row behind itself.
  logic        row_hit;
  assign row_hit = bank_open[tbank] && (bank_row[tbank] == trow);

  // THE ROW COMPARATOR MUST NOT REACH cmd. S_DISPATCH was added to keep the
  // port mux out of the command cone, and it does, but row_hit was still
  // computed and acted on in the same cycle -- so xfer_addr's bank and row
  // bits ran through four 4:1 muxes and a 13-bit compare into cmd, and that
  // was the critical path of the whole design (xfer_addr[25]->cmd[0]).
  //
  // The hit leg is left alone: it writes state and never cmd, so it costs
  // nothing to leave combinational, and a row hit is the case worth being
  // fast. Only a MISS pays the extra cycle, and a miss is already buying
  // tRP + tRCD, so one cycle is inside the noise.
  logic [1:0]  dsp_bank;

  // Refresh needs every bank closed, so it must wait for the longest
  // outstanding tRAS rather than just the one it happens to look at.
  logic ras_any;
  assign ras_any = (ras_cnt[0] != 0) || (ras_cnt[1] != 0)
                || (ras_cnt[2] != 0) || (ras_cnt[3] != 0);

  logic [15:0]              init_cnt;
  logic [$clog2(T_REFI+1)-1:0] ref_cnt;
  logic                     ref_pend;
  logic [3:0]               wait_cnt;
  logic [15:0]              dq_r;

  // TAGGED READ CAPTURE
  //
  // The first version had one shared capture buffer and stalled each transfer
  // until its own data had drained — S_RDW waiting for the pipeline to empty.
  // That is five dead cycles on a ten-cycle row-hit burst, 40% of the
  // transfer, spent idle waiting for words already in flight.
  //
  // Instead every CAS carries a tag naming the port it belongs to and which
  // word of that port's burst it is. Capture then depends only on the tag, so
  // the issue side never waits: it can activate a row or issue the next
  // transfer's CAS while earlier data is still on its way back. Per-port
  // buffers are what make that safe — a shared one would interleave two
  // masters' words into the same array.
  logic [RD_LAT-1:0]        tag_v;
  // PW BITS, NOT THREE. This was `[2:0]` while PW = $clog2(NP) is 4 for the
  // ten ports the core instantiates, so ports 8 and 9 ALIASED ONTO 0 AND 1 in
  // the read-tag pipeline: their data was delivered into p_dout[0]/p_dout[1]
  // and acknowledged there, corrupting the i960's own reads with the
  // coprocessor's table fetches.
  //
  // It was latent only because nothing drove ports 8 and 9 -- the undriven
  // signals lint_top could not see (R107) were the only thing holding it off.
  // Wiring the coprocessor would have fired it on the first table lookup, and
  // the symptom would have been random CPU data corruption with a perfectly
  // healthy-looking coprocessor.
  logic [RD_LAT-1:0][PW-1:0] tag_p;      // port index
  logic [RD_LAT-1:0][1:0]   tag_w;      // word index within the burst
  logic [RD_LAT-1:0]        tag_last;
  // ONE SET OF CAPTURE SLOTS, NOT ONE PER PORT, because two ports' words can
  // never interleave in this pipeline and the per-port index was costing both
  // area and the third-worst path on clk_mem.
  //
  // THE FSM IS SINGLE-THREADED AND S_RD ISSUES ONE READ PER CYCLE for the
  // whole burst, injecting every tag at the same cap_depth and only returning
  // to S_IDLE after the last of them. So a burst's tags occupy CONSECUTIVE
  // slots and reach slot 0 on consecutive cycles, and the state machine cannot
  // be in S_RD for two ports at once. The next burst's first tag is at least
  // S_IDLE -> S_SEL -> S_DISPATCH -> S_RD behind the previous burst's last --
  // three cycles, and one would have been enough.
  //
  // WHAT IT COST AS AN ARRAY: tag_p[0] selected a 48-bit NP-way read mux AND
  // the p_dout write decode in the same cycle as the final burst word, four
  // logic levels and 9.910 ns of a 10 ns period at -0.148. The write decode
  // stays -- it has to, p_dout really is per port -- but a decode is far
  // cheaper than a data mux. The registers go from NP*64 to 64.
  logic [3:0][15:0] cap;

  // ------------------------------- R396: the read return, split in two
  // `dq_r` reached `p_dout[port]` through the burst-assembly mux AND the
  // NP-way write decode in ONE cycle, and after R394 cleared the arbitration
  // chain that became the worst path in the design:
  //     dq_r[11] -> p_dout[4][59]   -0.311
  // These stage the assembled word for a cycle so the mux and the decode sit
  // either side of a register. One extra cycle of read latency, which the
  // requesters absorb because they wait for ack -- the same trade S_SEL
  // already makes in this file: "this costs latency, not semantics".
  //
  // One deep is enough. A delivery is consumed the cycle after it is staged,
  // so back-to-back deliveries pipeline rather than collide.
  logic            rd_v;
  logic [PW-1:0]   rd_port;
  logic [63:0]     rd_word;

  // Acks are per port now. A single shared hold counter was fine when only one
  // transfer existed at a time; with two ports in flight it would clear the
  // other port's ack early.
  logic [NP-1:0][1:0]       ack_cnt;
  logic [1:0]               wack_cnt;

  // Cycles until this bank's last outstanding read data has landed. A bank may
  // not be precharged while its own read is still returning, but other banks
  // are free — which is the entire point of overlapping.
  logic [3:0]               rd_bank_cnt [4];

  // Ports with a transfer issued but not yet acknowledged.
  //
  // `pend` alone cannot serve this purpose. It means "wants service" and only
  // clears on the ack, which used to be safe only because each transfer
  // stalled until its own data had drained. Once the pipeline removed that
  // stall, the FSM returned to arbitration while the data was still in flight,
  // saw pend still set, and dispatched the very same transaction again —
  // duplicate CAS commands, duplicate acks, and every port reading one
  // delivery behind. The arbiter must therefore skip a port that is already
  // being served, which is what this is.
  logic [NP-1:0]            inflight;
  logic                     wr_inflight;

  logic pipe_busy;
  assign pipe_busy = |tag_v;

  // The dedicated write port is ready to go: it drives DQ, so it may not be
  // issued while read data is still returning on the same wires.
  wire wr_ready = wr_pend && !wr_inflight && !pipe_busy;

  // THE WRITE PORT IS NOT ONE WRITER. Model2.sv muxes FIVE onto it -- the ROM
  // loader, the geometry SDRAM writes, the TGP buffer writes and two more --
  // so wr_pend is asserted constantly while the scene is being built, not just
  // during download. R387's first version stopped ALL read prefetching
  // whenever wr_pend was set, which starved the renderer of the very reads it
  // needed: on the board, 3D went missing and the core hung.
  //
  // wr_ready needs !pipe_busy, and reads keep the pipeline busy, so the write
  // cannot simply outrank them either -- that is a livelock the other way.
  // What works is a BOUNDED wait: reads prefetch freely, and only once the
  // write has been held off this long does the front stage stand down so the
  // pipeline can drain and the write go in. The old FSM got this for free from
  // its three idle cycles per transaction; pipelining removed them, so the
  // fairness it was relying on has to be made explicit.
  // THE THRESHOLD IS HIGH ON PURPOSE. Reads are the renderer's critical path
  // and writes are not, so the write may not simply take its turn: MEASURED at
  // one write per 32 cycles against saturated reads, a 31-cycle threshold gave
  // writes 752 grants and cost reads 17% of their bandwidth. The controller
  // that ran correctly on the board let reads dominate -- 94 writes, worst
  // write wait 736 cycles -- so that, not fairness, is the behaviour to match.
  // 511 keeps read priority and still bounds the write, which the old FSM
  // never did at all.
  wire wr_starved = wr_pend && !wr_inflight && (wr_wait == 10'd511);

  // The prefetched transaction may be taken. Refresh outranks it -- a refresh
  // needs every bank precharged and the pipeline empty, and under continuous
  // traffic it would otherwise wait forever (the device model caught that; on
  // hardware it is silent data decay). A prefetched port WRITE waits for the
  // pipeline for the same DQ reason as wr_ready.
  wire pf_take  = nxt_valid && !ref_pend && !(nxt_is_write && pipe_busy);

  // THE TEN-WAY MUX, NAMED ONCE. Both readers -- the prefetch register and
  // the S_IDLE bypass -- use these wires and never index the arrays
  // themselves, so the synthesiser cannot build a second copy of the mux that
  // the S_SEL split was added to remove.
  wire [AW:1] pf_addr = addr_p[nxt_grant];
  wire [15:0] pf_din  = din_p[nxt_grant];
  wire [1:0]  pf_be   = be_p[nxt_grant];

  // A port is "granted" for telemetry while its transfer is in flight, not
  // merely on the cycle it was selected. Bandwidth is a question about
  // occupancy, and counting selection edges would report a fraction of it.
  // With the pipeline this is genuinely several ports at once, which is what
  // the telemetry is there to show.
  assign dbg_grant = inflight;

  // SYNCHRONOUS RESET, DELIBERATELY, and it is about the pins rather than style.
  //
  // Template.qsf asks for `Fast Output Register=ON` on `SDRAM_*` so the command and
  // address registers sit in the I/O cells, where clock-to-output is short and
  // fixed. With an ASYNC reset the fitter refuses, sixteen times:
  //
  //   Warning (176279): Can't pack register node "sd_a[8]" into I/O pin
  //     "SDRAM_A[8]". The node cannot simultaneously use clear and load signals.
  //
  // A Cyclone V I/O register has one or the other. `sd_a` needs the load, so the
  // asynchronous clear is what has to go — as a synchronous reset it becomes part
  // of the D-side logic and the register itself can live in the pin.
  //
  // Safe here because clk_sys free-runs from the PLL and rst_n is held through
  // lock, so the first clocked edges after lock perform the reset. Nothing in this
  // controller needs to be reset while its clock is stopped.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      // cmd IS RESET AND THE OTHERS ARE NOT, deliberately.
      //
      // A synchronous reset did not let these pack into the I/O cells either —
      // Quartus counts it as a clear just the same, and the warning stayed at
      // sixteen. The clear has to be gone, not merely synchronous.
      //
      // cmd keeps its reset because a garbage command at power-up would be issued
      // to the device. sd_a, sd_ba and sd_dqm are don't-care whenever cmd is NOP,
      // and the init sequence writes all three before the first real command, so
      // their power-up value is unobservable.
      cmd <= C_NOP;
      sd_dq_o <= '0; sd_dq_oe <= 1'b0;
      state <= S_INIT; ready <= 1'b0;
      init_cnt <= 16'(INIT_NOP);
      ref_cnt <= '0; ref_pend <= 1'b0;
      bank_open <= '0;
      for (int b = 0; b < 4; b++) begin bank_row[b] <= '0; ras_cnt[b] <= '0; end
      tag_v <= '0; tag_p <= '0; tag_w <= '0; tag_last <= '0; cap <= '0;
      ack_cnt <= '0; wack_cnt <= '0; inflight <= '0; wr_inflight <= 1'b0;
      for (int b = 0; b < 4; b++) rd_bank_cnt[b] <= '0;
      p_ack <= '0; wr_ack <= 1'b0; p_dout <= '0;
      rd_v <= 1'b0; rd_port <= '0; rd_word <= '0;
      grant <= '0; grant_is_wr <= 1'b0; rr_next <= '0;
      rd_total <= 4'd1; rd_issued <= '0; rd_captured <= '0;
      is_write <= 1'b0; xfer_addr <= '0; din_r <= '0; be_r <= '0;
      wait_cnt <= '0; dq_r <= '0;
      nxt_valid <= 1'b0; pf_sel <= 1'b0; nxt_grant <= '0; nxt_addr <= '0;
      nxt_din <= '0; nxt_be <= '0; nxt_total <= 4'd1; nxt_is_write <= 1'b0;
      wr_wait <= '0;
    end else begin
      cmd      <= C_NOP;
      sd_dq_oe <= 1'b0;
      dq_r     <= sd_dq_i;

      for (int q = 0; q < NP; q++) begin
        if (ack_cnt[q] != 0) ack_cnt[q] <= ack_cnt[q] - 1'b1;
        else p_ack[q] <= 1'b0;
        // inflight must clear on the SAME edge as pend, not on the delivery
        // edge one cycle earlier. The mailbox clears pend when it observes the
        // ack rising, so clearing inflight at delivery opens a one-cycle window
        // where pend still holds the finished transaction and inflight no
        // longer blocks it — and the arbiter re-dispatches the completed
        // transaction's stale address. That returned the previous word for
        // every read, which looks like a broken data path and is not one.
        if (p_ack[q] && !ack_d[q]) inflight[q] <= 1'b0;
      end
      if (wr_ack && !wr_ack_d) wr_inflight <= 1'b0;
      if (wack_cnt != 0) wack_cnt <= wack_cnt - 1'b1;
      else wr_ack <= 1'b0;

      if (state == S_INIT) begin
        sd_dqm <= 2'b11;
        init_cnt <= init_cnt - 1'b1;
        // JEDEC bring-up: NOPs, precharge all, eight refreshes, mode register.
        // Spacing is generous rather than minimal; this runs once.
        case (init_cnt)
          16'd400: begin cmd <= C_PRE; sd_a <= 13'h400; end
          16'd360, 16'd350, 16'd340, 16'd330,
          16'd320, 16'd310, 16'd300, 16'd290: cmd <= C_REF;
          16'd200: begin
            cmd   <= C_MRS;
            sd_ba <= 2'b00;
            // CAS LATENCY FROM THE PARAMETER, NOT A LITERAL. This was
            // 13'b000_0_00_010_0_000 -- CL2 hard-coded -- while `CL` was a
            // parameter used for every latency calculation in the file. Two
            // sources of truth for one number, and changing the parameter moved
            // the capture window without telling the device.
            sd_a  <= {3'b000, 1'b0, 2'b00, 3'(CL), 1'b0, 3'b000};
          end
          16'd1: begin ready <= 1'b1; state <= S_IDLE; end
          default: ;
        endcase
      end else begin
        sd_dqm <= 2'b00;

        for (int b = 0; b < 4; b++)
          if (ras_cnt[b] != 0) ras_cnt[b] <= ras_cnt[b] - 1'b1;

        ref_cnt <= ref_cnt + 1'b1;
        if (ref_cnt == ($clog2(T_REFI+1))'(T_REFI)) begin
          ref_cnt  <= '0;
          ref_pend <= 1'b1;
        end

        for (int b = 0; b < 4; b++)
          if (rd_bank_cnt[b] != 0) rd_bank_cnt[b] <= rd_bank_cnt[b] - 1'b1;

        // Saturating: it only has to say "long enough", not how long.
        if (!wr_pend || wr_inflight)  wr_wait <= '0;
        else if (wr_wait != 10'd511)  wr_wait <= wr_wait + 1'b1;

        // Read capture, driven entirely by the tag that travelled with the CAS.
        tag_v    <= {1'b0, tag_v[RD_LAT-1:1]};
        tag_p    <= {PW'(0), tag_p[RD_LAT-1:1]};
        tag_w    <= {2'd0, tag_w[RD_LAT-1:1]};
        tag_last <= {1'b0, tag_last[RD_LAT-1:1]};
        // The staged delivery, one cycle behind the capture. This is the
        // second half of the split: the NP-way write decode runs here, from a
        // REGISTER, with no mux in front of it.
        rd_v <= 1'b0;
        if (rd_v) begin
          p_dout[rd_port]   <= rd_word;
          p_ack[rd_port]    <= 1'b1;
          ack_cnt[rd_port]  <= 2'(ACK_HOLD - 1);
        end

        if (tag_v[0]) begin
          cap[tag_w[0]] <= dq_r;
          if (tag_last[0]) begin
            // The final word and its buffer write share an edge, so deliver
            // the staged word directly rather than reading back a stale slot.
            // The LAST word's index identifies the burst length, because a
            // burst of N always ends at index N-1: 0 is a single word, 1 is a
            // pair, 3 is the full four.
            //
            // The pair case exists for the TGP. It reads 32-bit words out of a
            // 16-bit memory, so one logical fetch is two SDRAM words, and
            // before this the `else` composed every non-single transfer from
            // FOUR capture slots -- a 2-word burst would have taken cap[1] and
            // cap[2] from whatever the previous transfer left there. Silent,
            // and wrong only in the upper half, which is the exponent and sign
            // of a float. Unused lanes are zeroed rather than left stale so a
            // consumer reading past what it asked for sees zero, not history.
            case (tag_w[0])
              2'd0:    rd_word <= {48'd0, dq_r};
              2'd1:    rd_word <= {32'd0, dq_r, cap[0]};
              default: rd_word <= {dq_r, cap[2], cap[1], cap[0]};
            endcase
            rd_port <= tag_p[0];
            rd_v    <= 1'b1;
          end
        end

        // ------------------------------------------------- PREFETCH (R387)
        // THE FRONT OF A TWO-STAGE PIPELINE, AND IT RUNS CONCURRENTLY WITH
        // THE BACK. Arbitration used to sit in front of every transaction as
        // S_IDLE -> S_SEL -> S_DISPATCH: three cycles that issue no command
        // and move no data. On a four-word row hit that is 3 of 7 cycles; on a
        // conflict miss, 3 of 13. Doing them here, while the back stage is
        // still bursting the PREVIOUS transaction, hides all three.
        //
        // THE TEN-WAY MUX IS NOT DUPLICATED, AND THAT IS THE WHOLE
        // CONSTRAINT. addr_p[] is read in exactly one place -- the pf_sel
        // cycle below -- because S_SEL's comment records that every one of the
        // six worst setup paths in the design ran between two muxes inside
        // this module, and that splitting the mux into a cycle of its own is
        // what fixed them. A second reader of addr_p[] puts that path back.
        // The back stage is handed a settled register and never the array.
        //
        // The DEDICATED write port is deliberately not prefetched: wr_addr_p
        // is a plain register, not a mux, so selecting it in S_IDLE costs
        // nothing and the download path is left exactly as it was.
        if (!nxt_valid && !pf_sel && !ref_pend && !wr_starved && rr_valid) begin
          // The grant index alone, as S_IDLE did it. Reserving the port here
          // rather than at issue is what lets the back stage consume without
          // re-arbitrating; inflight[] stops it being selected twice.
          nxt_grant          <= rr_grant;
          nxt_is_write       <= we_p[rr_grant];
          nxt_total          <= we_p[rr_grant] ? 4'd1 : blen(rr_grant);
          inflight[rr_grant] <= 1'b1;
          rr_next            <= (rr_grant == ($clog2(NP))'(NP-1))
                                  ? '0 : rr_grant + 1'b1;
          pf_sel             <= 1'b1;
        end else if (pf_sel) begin
          // The mux, alone in a cycle. This is S_SEL, moved.
          nxt_addr  <= pf_addr;
          nxt_din   <= pf_din;
          nxt_be    <= pf_be;
          nxt_valid <= 1'b1;
          pf_sel    <= 1'b0;
        end

        case (state)
          S_IDLE: begin
            if (ref_pend && !pipe_busy && !ras_any) begin
              cmd       <= C_PRE;
              sd_a      <= 13'h400;             // A10: precharge all
              bank_open <= '0;
              wait_cnt <= 4'(T_RP - 1);
              state    <= S_PRE_REF;
            end else if (wr_ready) begin
              // THE DEDICATED WRITE PORT, ON ITS ORIGINAL PATH. WIDX is
              // selected here and S_SEL reads wr_addr_p, which is a plain
              // register and not the ten-way mux -- so this leg carries none
              // of the timing that the mux split was there to fix, and the
              // download stream behaves exactly as it did.
              grant       <= ($clog2(NP+1))'(WIDX);
              grant_is_wr <= 1'b1;
              wr_inflight <= 1'b1;
              is_write    <= 1'b1;
              rd_total    <= 4'd1;
              rd_issued   <= '0;
              rd_captured <= '0;
              state       <= S_SEL;
            end else if (pf_take) begin
              // THE HANDOFF: already arbitrated, already muxed. S_IDLE's
              // priority encoder and S_SEL's mux were run by the front stage
              // behind the previous burst, so this cycle only moves settled
              // registers. Refresh still outranks it -- pf_take carries the
              // !ref_pend that used to sit in this condition, and without it
              // the refresh waits forever under continuous traffic.
              grant       <= ($clog2(NP+1))'(nxt_grant);
              grant_is_wr <= 1'b0;
              is_write    <= nxt_is_write;
              rd_total    <= nxt_total;
              xfer_addr   <= nxt_addr;
              din_r       <= nxt_din;
              be_r        <= nxt_be;
              rd_issued   <= '0;
              rd_captured <= '0;
              nxt_valid   <= 1'b0;
              // S_DISPATCH still sees a SETTLED xfer_addr for its row
              // comparator. That is the invariant S_SEL existed to protect and
              // it is preserved: the mux ran a cycle ago, in the front stage.
              state       <= S_DISPATCH;
            end else if (pf_sel && !ref_pend && !(nxt_is_write && pipe_busy)) begin
              // THE IDLE BYPASS, AND IT EXISTS TO PAY A MEASURED DEBT.
              // Pipelining costs a cycle when there is nothing to hide it
              // behind: with one master running alone the front stage cannot
              // get ahead, so grant -> mux -> handoff -> dispatch is one cycle
              // longer than the S_IDLE -> S_SEL -> S_DISPATCH it replaced.
              // MEASURED, tb_m2_sdram, p0 alone: 0.301 -> 0.281 words/cyc
              // sequential, 0.212 -> 0.202 random. That is the i960's own port
              // when nothing else is asking, so it is not a corner case.
              //
              // pf_sel means the front stage is doing its mux cycle RIGHT NOW,
              // and pf_addr is therefore already valid combinationally --
              // nxt_grant was registered last cycle. So take it directly and
              // skip the handoff. nxt_valid was set by the front stage a few
              // lines above; clearing it here wins, because this assignment is
              // later in the same block.
              grant       <= ($clog2(NP+1))'(nxt_grant);
              grant_is_wr <= 1'b0;
              is_write    <= nxt_is_write;
              rd_total    <= nxt_total;
              xfer_addr   <= pf_addr;
              din_r       <= pf_din;
              be_r        <= pf_be;
              rd_issued   <= '0;
              rd_captured <= '0;
              nxt_valid   <= 1'b0;
              state       <= S_DISPATCH;
            end
          end

          // THE ADDRESS SELECT, IN A CYCLE OF ITS OWN.
          //
          // Every one of the six worst setup paths in the design ran between
          // two muxes inside this module -- Mux5~0 to Mux3~0, -1.353 ns -- and
          // they are this: the arbitration cycle computed the round-robin
          // priority encoder AND then read a ten-way 25-bit address mux with
          // its result, into xfer_addr, in one clock. The Model 1 project met
          // the identical failure and wrote down the remedy: "the state machine
          // computing its address mux in the same cycle it drives the pins.
          // Registering the address select one cycle earlier removes most of
          // them", and recorded that the area lever is "a lottery ticket, not a
          // fix" -- which is exactly what five seed sweeps here had been.
          //
          // grant is now a registered index, so this cycle does the mux alone
          // and S_DISPATCH still sees a settled xfer_addr for its row
          // comparator.
          //
          // IT COSTS ONE CYCLE PER TRANSACTION AND THAT IS AFFORDABLE. The
          // 0.0797 transactions/cycle in tb_m2_sdram is the controller's
          // CEILING under a saturated fuzz bench, not the demand: the core runs
          // attract at ~95% speed and what throttles it is the i960's poll
          // loop, not memory. Trading a few percent of a ceiling we do not
          // approach for a timing violation on the clock everything depends on
          // is the right way round; the reverse is not.
          // REACHED ONLY BY THE DEDICATED WRITE PORT NOW. The port array's
          // ten-way mux moved to the prefetch stage; what is left here reads
          // three plain registers, so this path holds no mux at all.
          S_SEL: begin
            xfer_addr <= wr_addr_p;
            din_r     <= wr_din_p;
            be_r      <= wr_be_p;
            state     <= S_DISPATCH;
          end

          S_DISPATCH: begin
            // Writes NO cmd, by construction: that is the whole point. Both
            // fast legs settle only `state`, which is a register boundary, so
            // the row comparator reaches a flop and not the command pins.
            dsp_bank <= tbank;
            if (row_hit)                state <= is_write ? S_WR : S_RD;
            else if (!bank_open[tbank]) state <= S_ACT;
            else                        state <= S_MISS;
          end

          // Only a CONFLICT miss lands here -- bank open on the wrong row, the
          // one case that must issue PRECHARGE. A bank-closed miss goes
          // straight to S_ACT and pays nothing.
          //
          // MEASURED, tb_m2_sdram, transactions per cycle:
          //   0.079689  before the split
          //   0.077029  deferring every miss      -3.34%
          //   0.077531  deferring conflicts only  -2.66%
          // Splitting the bank-closed leg back out buys only half a point,
          // because with ten ports over four banks most misses ARE conflict
          // misses. The honest price of getting the row comparator off the
          // command path is ~2.7% of SDRAM throughput.
          S_MISS: begin
            // Precharge only the bank being reused: A10 low with the bank
            // address, not the precharge-all the first version used. tRAS is
            // owed from the ACTIVATE that opened this bank's row.
            // rd_bank_cnt IS REACHED NOW, AND IT WAS NOT BEFORE R387. This
            // comment used to say "defensive and, at this FSM's spacing, not
            // currently reachable", because the earliest a precharge could
            // follow that bank's last CAS was CAS -> S_IDLE -> S_DISPATCH ->
            // S_MISS. It was kept because "any future shortening of the
            // dispatch path would start truncating read bursts silently".
            //
            // R387 IS THAT SHORTENING: S_RD enters S_DISPATCH directly on the
            // last READ, so a following transaction to the SAME bank on a
            // different row reaches S_MISS while that bank's data is still in
            // flight. MEASURED: 24,542 blocked cycles in tb_m2_sdram, against
            // zero before.
            //
            // WHAT IT BUYS IS MARGIN, NOT JEDEC COMPLIANCE, and the difference
            // is the whole reason to write this down. Delete the rd_bank_cnt
            // term and the bench stays COMPLETELY GREEN -- 0 fails, 0
            // violations, and marginally faster -- because the device model
            // truncates only when a precharge lands INSIDE CL, and without the
            // guard it lands exactly AT CL. The guard holds it off for
            // cap_depth instead: CL plus the board round trip that rd_lat_sel
            // calibrates at boot. So the exposure is hardware-only, the same
            // class as R377 and R381, and no amount of simulation will show
            // it. That is precisely why it stays.
            if (ras_cnt[dsp_bank] == 0 && rd_bank_cnt[dsp_bank] == 0) begin
              cmd                 <= C_PRE;
              sd_ba               <= dsp_bank;
              sd_a                <= 13'h000;
              bank_open[dsp_bank] <= 1'b0;
              wait_cnt            <= 4'(T_RP - 1);
              state               <= S_PRE_XFER;
            end
          end

          S_PRE_XFER: begin
            if (wait_cnt == 0) state <= S_ACT;
            else wait_cnt <= wait_cnt - 1'b1;
          end

          S_ACT: begin
            cmd       <= C_ACT;
            sd_ba     <= xfer_addr[AW:AW-1];
            sd_a      <= 13'(xfer_addr[AW-2:COL_BITS+1]);
            bank_row[tbank]  <= trow;
            bank_open[tbank] <= 1'b1;
            ras_cnt[tbank]   <= 4'(T_RAS - 1);
            wait_cnt  <= 4'(T_RCD - 1);
            state     <= S_RCD;
          end

          S_RCD: begin
            if (wait_cnt == 0) state <= is_write ? S_WR : S_RD;
            else wait_cnt <= wait_cnt - 1'b1;
          end

          S_WR: begin
            cmd      <= C_WRITE;
            sd_ba    <= xfer_addr[AW:AW-1];
            sd_a     <= col_a(xfer_addr);   // A10 low inside col_a: keep row open
            sd_dq_o  <= din_r;
            sd_dq_oe <= 1'b1;
            sd_dqm   <= ~be_r;
            // Hold past tWR and tRAS before anything can precharge this row.
            // The row is left open on purpose: a download write stream is
            // sequential and the next word usually hits the same row.
            wait_cnt <= 4'((T_WR > T_RAS - T_RCD) ? T_WR : T_RAS - T_RCD);
            state    <= S_WRRC;
          end

          S_WRRC: begin
            if (wait_cnt == 4'((T_WR > T_RAS - T_RCD) ? T_WR : T_RAS - T_RCD)) begin
              if (grant_is_wr) begin
                wr_ack   <= 1'b1;
                wack_cnt <= 2'(ACK_HOLD - 1);
              end else begin
                p_ack[grant]    <= 1'b1;
                ack_cnt[grant]  <= 2'(ACK_HOLD - 1);
              end
            end
            if (wait_cnt == 0) state <= S_IDLE;
            else wait_cnt <= wait_cnt - 1'b1;
          end

          S_RD: begin
            // One READ per cycle. The last one carries A10, requesting
            // auto-precharge, so the row closes without a separate command.
            cmd        <= C_READ;
            sd_ba      <= xfer_addr[AW:AW-1];
            // A10 low: the row stays open so the next transfer to it can skip
            // PRECHARGE and ACTIVATE entirely. A10 is the auto-precharge bit
            // and the column is nine bits, so A9 is padded explicitly — a
            // packing of {3'b000, x, col} would land x on A9, which the device
            // ignores.
            sd_a       <= col_a(xfer_addr);
            // Injected at the selected depth, not at the top of the
            // pipeline: the tag reaches slot 0 after cap_depth cycles, which
            // is what decides which bus word is called word 0.
            tag_v[cap_depth-1]    <= 1'b1;
            // PW BITS. This took grant[2:0] -- three bits for a ten-port
            // controller -- so ports 8 and 9 were tagged as 0 and 1 and their
            // read data was delivered to, and acknowledged on, the i960's own
            // port. Widening the tag's DECLARATION is not enough; this is the
            // assignment that did the truncating.
            tag_p[cap_depth-1]    <= PW'(grant);
            tag_w[cap_depth-1]    <= rd_issued[1:0];
            tag_last[cap_depth-1] <= (rd_issued + 1'b1 == rd_total);
            rd_bank_cnt[tbank]    <= cap_depth;
            rd_issued  <= rd_issued + 1'b1;
            if (rd_issued + 1'b1 == rd_total) begin
              // R387: STRAIGHT INTO THE NEXT TRANSACTION, NOT BACK TO
              // ARBITRATION. The row stays open, the data still in flight is
              // the tag pipeline's problem, and the front stage has already
              // arbitrated and muxed the next transaction -- so S_IDLE and
              // S_SEL have nothing left to do and are skipped entirely. This
              // is where the three hidden cycles are actually cashed in.
              //
              // wr_ready is checked so the dedicated write port keeps the
              // priority it has in S_IDLE; in practice it is false here,
              // because the burst just issued leaves the pipeline busy.
              // R391: BACK TO S_IDLE, NOT STRAIGHT INTO S_DISPATCH.
              //
              // R387 jumped from here into the next transaction on the last
              // READ, saving a third cycle and cutting the gap between two
              // bursts' read tags to ONE -- the documented minimum, with the
              // file's own note saying "one would have been enough". It also
              // put the next transaction's S_MISS one cycle closer to the
              // previous bank's last CAS.
              //
              // IT HUNG THE CORE ON HARDWARE, TWICE (s62, s71), and simulation
              // cannot see why: 4M cycles with a deadlock watchdog shows no
              // stall over 51 cycles, and a 2M-cycle read-only integrity soak
              // under full contention returns the written image exactly. No
              // deadlock, no corruption, a dead board. That is the R377/R381
              // signature.
              //
              // So the fast path goes and the prefetch stays. S_IDLE is back in
              // the dispatch path, the tag gap is two, and the pipeline still
              // hides S_SEL: 0.420 -> 0.476 words/cyc, +13.3% of the +28.6%.
              // If the board is well with this, the fast path is what broke it
              // and comes back under its own test; if it still hangs, the
              // prefetch itself is at fault and this narrows it to that.
              state <= S_IDLE;

            end else begin
              // Bursts wrap inside the open row: incrementing the full address
              // would walk off the end of the row on the last column and read
              // from a row that was never activated.
              //
              // The increment is skipped on the LAST read so it cannot fight
              // the xfer_addr load above -- the incremented value was never
              // read by anything, and leaving both assignments live would make
              // the burst address depend on statement order in this block.
              xfer_addr[COL_BITS:1] <= xfer_addr[COL_BITS:1] + 1'b1;
            end
          end

          S_PRE_REF: begin
            if (wait_cnt == 0) begin
              cmd       <= C_REF;
              bank_open <= '0;
              ref_pend  <= 1'b0;
              wait_cnt <= 4'(T_RC - 1);
              state    <= S_REFW;
            end else wait_cnt <= wait_cnt - 1'b1;
          end

          S_REFW: begin
            if (wait_cnt == 0) state <= S_IDLE;
            else wait_cnt <= wait_cnt - 1'b1;
          end

          default: state <= S_IDLE;
        endcase
      end
    end
  end

endmodule
