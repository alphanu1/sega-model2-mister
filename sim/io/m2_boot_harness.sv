// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// THE COMPOSITION: the i960 through the real bridge into the real peripherals.
//
// This exists because `tb_i960_rom` drives `i960_top` DIRECTLY, with a C++
// memory answering its bus. Every one of the 803,355 instructions verified
// against MAME went through that path, and none of them went through
// `m2_cpu_bridge`. So the boot runs clean in simulation and stops on hardware,
// and the link nothing covered is the one between them.
//
// The specific failure this is built to reproduce: on the board the i960 reads
// the I/O board's flag and status correctly -- overlay row 17 returns 4000,
// row 18 the address 01C00042, row 19 the word 00400000 -- satisfies all three
// polls at 0x22824x-0x228270, and never reaches the copy loop eight
// instructions later at 0x22827C. Rows 15 and 16 read zero: no window reads, no
// backup-SRAM writes.
//
// WHAT IS REAL HERE AND WHAT IS NOT.
//
// Real: i960_top, m2_cpu_bridge with its two clock domains, m2_ioboard,
// m2_backup, and the I/O read mux copied from Model2.sv. Those are the parts
// under suspicion.
//
// Modelled in C++: the SDRAM behind the bridge's sd_* port. m2_sdram has
// 123,927 checks of its own and is not what this is asking about; putting the
// whole memory stack in RTL would make a fourteen-million-instruction boot take
// hours to answer a question about a handshake.
//
// The tile RAM, palette and colour-translation arrays are modelled too, for the
// same reason: the CPU writes them and never reads them back in this phase.

`timescale 1ns/1ps

module m2_boot_harness #(
  parameter int unsigned AW = 25,
  // Small enough to reach in simulation. The real ones are 5,843,478 and
  // 145,252,176 -- three seconds of a 48 MHz clock -- and what is under test
  // here is the sequence, not the constants.
  parameter int          STATUS_CYCLES   = 20_000,
  parameter int          SELFTEST_CYCLES = 200_000,
  // See the clk96 port comment: 1 swaps the C++ SDRAM for the real stack.
  parameter bit          REAL_MEM        = 1'b0,
  // BUFFERRAM WAS NEVER SIMULATED. The bridge defaults it OFF and this harness
  // never overrode it, so every boot-bench pass has been a pass for the
  // configuration that WORKS on hardware -- while the board has been running
  // the other one since a9ace86 and spinning. Exposed here so the failing
  // configuration can be reproduced in seconds instead of a 25-minute fit.
  parameter bit          BUFFERRAM_EN    = 1'b0,
  parameter int unsigned RD_LAT_SEL      = 3      // REAL_MEM only: the controller's read-capture selector (-G friendly)
) (
  // REAL_MEM=1 replaces the C++ SDRAM with the genuine stack -- m2_sdram_x2 +
  // m2_sdram + sdram_model, lifted whole from sim/mem/m2_sdram_x2_harness.sv.
  // The game side then runs at TRUE memory latency, which is the variable the
  // digit race (study R63) turns on: the C++ array shortens the game's
  // critical section and wins a race the board loses. clk96 drives the fast
  // domain; the memory clock the rest of the harness runs on becomes the
  // stack's own clk_slow, exported on clk_slow_o for the testbench's edge
  // accounting. The ROM image streams through rl_* into the DEVICE MODEL the
  // way the loader streams it on hardware.
  input  logic        clk96,
  // Holds the i960 (only) in reset while the ROM streams into the device
  // model -- the loader's job on hardware, the testbench's here.
  input  logic        cpu_hold,
  // Cabinet switches, active low, MAME's IN0 order: bit2 is the TEST switch
  // (MAME calls it Service Mode) and FB is that switch held.
  input  logic  [7:0] cab_in0,
  // DO THE TWO SIDES ACTUALLY COLLIDE? Testable rather than assertable: count
  // cycles where the game is inside the block window AND the Z80 is writing it.
  // Zero collisions would mean the BUSY fix addresses nothing.
  output logic [31:0] dbg_collide_o, dbg_win_game_o, dbg_win_z80_o,
  // LINE OVERRUNS: a scanline whose character fetches did not finish before
  // the next line began. m2_video has counted them all along and the harness
  // never looked. Whole rows of text going missing is exactly what they do.
  output logic  [7:0] dbg_fetches_o,
  output logic [15:0] dbg_overruns_o,
  output logic        clk_slow_o,
  input  logic        rl_req,
  input  logic [25:1] rl_addr,
  input  logic [15:0] rl_din,
  output logic        rl_ack,
  output logic        mem_ready_o,

  input  logic        clk_cpu,
  input  logic        clk_mem,
  // THE RENDERER'S CLOCK. Adding it is the whole point of this harness now:
  // every isolated test passes and the board still misbehaves, so the one
  // configuration never simulated -- the CPU writing the tilemap WHILE the
  // renderer reads it, with character fetches crossing clk_vid/clk_sys through
  // the real m2_char_cdc -- is where the fault has to be.
  input  logic        clk_vid,
  input  logic        ce_pix,
  input  logic        rst_n,
  input  logic  [3:0] irq,
  // I/O firmware load; fw_ready gates the Z80 out of reset.
  input  logic        fw_we,
  input  logic [12:0] fw_addr,
  input  logic [15:0] fw_data,
  input  logic        fw_ready,

  // ---- the renderer's own SDRAM port, answered in C++ like the CPU's.
  // m2_sdram gives the character fetch a separate port; modelling it as one
  // shared with the bridge would invent contention the hardware does not have.
  output logic        sd2_req,
  output logic [AW:1] sd2_addr,
  input  logic        sd2_ack,
  input  logic [31:0] sd2_dout,

  // ---- the picture
  output logic  [7:0] vid_r, vid_g, vid_b,
  output logic        vid_hb, vid_vb,

  // ---- the SDRAM port, answered in C++
  output logic        sd_req,
  output logic        sd_we,
  output logic [AW:1] sd_addr,
  output logic [15:0] sd_din,
  output logic  [1:0] sd_be,
  input  logic [63:0] sd_dout,
  input  logic        sd_ack,

  // ---- what the test asks about
  // THE DISPLAY-LIST WALK, IN SIMULATION, DRIVEN BY THE REAL GAME.
  //
  // On hardware the walk completes exactly one frame and never runs again --
  // walk_frames=1, objs=0, unknown=0 -- and each guess at why costs a
  // 40-minute build. The i960 in this bench writes the same display list to
  // the same registers, so the walker can be asked the question here in
  // seconds instead.
  output logic        geo_rd_req,
  output logic [18:0] geo_rd_addr,
  input  logic [31:0] geo_rd_data,
  input  logic        geo_rd_ack,
  output logic        geo_sd_req,
  output logic [AW:1] geo_sd_addr,
  output logic [15:0] geo_sd_din,
  input  logic        geo_sd_ack,
  // and the geometry engine behind it, so the walk's object_data is actually
  // consumed and the pipeline can be watched end to end against the real game.
  output logic        eng_mem_req,
  output logic [23:0] eng_mem_addr,
  input  logic [31:0] eng_mem_data,
  input  logic        eng_mem_ack,
  output logic [15:0] eng_polys, eng_objects, eng_capped, eng_nonfinite,
  output logic [15:0] eng_clip_in, eng_clip_out, eng_clip_drop,
  output logic        eng_q_valid,
  // THE ENGINE'S POLYGON IN VIEW SPACE, before focus, clip and divide, with
  // the focus and the matrix corners in force: the bench's quads land on the
  // right screen edge and this says whether the collapse is in the input.
  output logic        obs_poly_valid,
  output logic [31:0] obs_v0x, obs_v0y, obs_v0z, obs_v1x, obs_v1y, obs_v1z,
  output logic [31:0] obs_v2x, obs_v2y, obs_v2z, obs_v3x, obs_v3y, obs_v3z,
  output logic [31:0] obs_poly_attr,
  output logic [31:0] obs_foc_x, obs_foc_y, obs_mtx0, obs_mtx4, obs_mtx8, obs_mtx11,
  // The raw object-space point entering the transform, and the whole matrix,
  // so the transform can be checked by hand against the reference's formula.
  // INSIDE THE COPROCESSOR: a, d, data-RAM 0x69/0x6a and the retire strobe,
  // to watch the record-base arithmetic of the track lookup (study R204).
  output logic        obs_eng_busy,
  output logic [4:0]  obs_eng_state,       // m2_geo_engine.st, for the per-stage cost (R215)
  output logic        obs_pj_busy,
  output logic        obs_pj_owner,        // 1 = the clipper's projection
  output logic        obs_w_granted, obs_k_granted,
  output logic        obs_pj_hit,          // R217: a vertex served from the last polygon's pixels
  output logic        obs_tgp_retire,
  output logic [15:0] obs_tgp_rpc,
  output logic [31:0] obs_tgpx_a, obs_tgpx_d, obs_tgp_ram69, obs_tgp_ram6a,
  output logic        obs_xf_valid,
  output logic [31:0] obs_xf_x, obs_xf_y, obs_xf_z,
  output logic [31:0] obs_mtx [12],
  output logic signed [15:0] eng_q_x0, eng_q_y0, eng_q_x1, eng_q_y1,
  output logic signed [15:0] eng_q_x2, eng_q_y2, eng_q_x3, eng_q_y3,
  // WHICH INSTRUCTION EMITS THE GEOMETRY. The board and the bench disagree about
  // whether the game sends matrices at all (R178, R181, R184), and every
  // measurement downstream of the front door has been eliminated. What is left
  // is the i960's own execution, so capture the PC at the moment a matrix write
  // is pushed -- that names the code that does it, and the board's cpu_ip
  // histogram says whether it ever gets there.
  output logic [31:0] geo_mtx_pc,
  output logic [15:0] geo_mtx_pushes,
  output logic [15:0] geo_obj_pushes,
  output logic [15:0] geo_mtx_n, geo_foc_n,
  output logic [31:0] geo_oba_last, geo_obc_last,
  output logic [31:0] geo_tha_last, geo_tpa_last,   // the last object's texture addresses
  output logic [15:0] geo_frames, geo_objs, geo_ops, geo_pdcmds, geo_pdwords,
  output logic  [7:0] geo_unknown,
  output logic  [3:0] geo_state,
  output logic [31:0] geo_rp_o, geo_wp_o,

  output logic [31:0] dbg_pc,
  output logic [31:0] dbg_acc,
  output logic [15:0] iob_win_rd,     // reads of DPRAM 0x100-0x17f
  output logic [15:0] iob_flag_rd,
  output logic [15:0] iob_seen,
  output logic [31:0] bak_w0,         // "SEGA" if the copy landed
  output logic [15:0] bak_writes,
  output logic [31:0] iob_dbg,
  output logic [31:0] dbg_tram_wr,
  output logic [31:0] dbg_ip,
  output logic [31:0] obs_prcb,
  output logic        obs_xlat_we,
  output logic        obs_pal_we,
  output logic        obs_tram_we,
  output logic [14:0] obs_oc_addr,
  output logic [15:0] obs_oc_din,
  output logic  [6:0] obs_xlat_addr,
  output logic  [7:0] obs_xlat_din,
  output logic        cpu_trap,
  output logic        cpu_halt,

  // THE CPU'S OWN BUS, which is the one thing the overlay cannot show. The
  // board proves what the I/O board returned; this proves what the i960 was
  // handed.
  output logic [31:0] obs_bus_addr,
  output logic [31:0] obs_bus_rdata,
  output logic        obs_bus_ack,
  output logic  [3:0] obs_bus_be,
  output logic        obs_bus_we,
  output logic [31:0] obs_bus_wdata,
  output logic        obs_bus_req,
  // The address moving while a request is outstanding. NOT A FAULT, and this
  // counter is kept only so the next person does not spend an afternoon
  // deciding that it is.
  //
  // It reads ~765,000 in a 474,490-instruction boot, and reads EXACTLY THE SAME
  // with i960_top's bus arbiter left combinational or given a locked grant. It
  // is normal traffic: study R34 established that the i960 holds bus_req across
  // a run of accesses and that m2_cpu_bridge LATCHES the address rather than
  // sampling it live, so movement after the latch is expected and harmless.
  // DOES THE COPROCESSOR EVER ATTEMPT THE MAILBOX WRITE? R142: the game polls
  // buffer-RAM dword 0x7FFC for zero and the TGP is what clears it. These
  // writes were discarded here -- bufw_req() unconnected, bufw_ack tied high --
  // so simulation could never say whether the TGP tries. Word address 0xFFF8 /
  // 0xFFF9 are the two halves of dword 0x7FFC.
  output logic [31:0] obs_bufw_count,
  output logic [31:0] obs_bufw_last,
  output logic [31:0] obs_bufw_7ffc,
  // THE WRITE ITSELF, SO THE TESTBENCH CAN APPLY IT. Counting the writes was
  // never enough: `bufw_data` was connected and then used by nothing, so the
  // coprocessor's writes went nowhere while the CPU read buffer RAM out of
  // SDRAM through the bridge. The mailbox therefore COULD NOT clear in
  // simulation whatever the coprocessor did, and "still parked at 0x1166c" was
  // a property of this harness rather than a result about the core.
  // One-cycle pulse, with the address and data held beside it.
  output logic        obs_bufw_wr,
  output logic [18:0] obs_bufw_waddr,
  output logic [15:0] obs_bufw_wdata,
  // The assembled mailbox, as Model2.sv's `tgp_mbox` does it on hardware:
  // word 0xFFF8 is the low half of dword 0x7FFC and 0xFFF9 the high half.
  // The game writes 0xFFFFFFFF and polls for zero (R142).
  output logic [31:0] obs_mbox,
  output logic [31:0] obs_addr_moved,
  output logic [31:0] dbg_rip,
  output logic [31:0] dbg_pfp,
  output logic signed [31:0] dbg_rcache_pos,
  output logic        dbg_to_memory,
  output logic        dbg_rf_req,
  output logic        dbg_rf_ack,
  output logic [31:0] dbg_rf_addr,
  output logic        dbg_rf_we,
  output logic [31:0] dbg_rf_wdata,
  output logic [31:0] obs_dc_hits,
  output logic [31:0] obs_dc_miss,
  output logic  [7:0] obs_mstate,     // {0,0,sd_ack,ack_mem,req_mem,st[2:0]}
  // THE i960's OWN SEQUENCER STATE. Core sequencing is 10.30 of the 17.12 CPI
  // -- the largest single term in the design and bigger than every memory stall
  // put together -- and nothing has ever looked at where inside the core those
  // cycles go. The CPU is a multi-cycle state machine, T_FETCH -> T_FETCH_W ->
  // T_EXEC -> T_WB with more states for memory and two-word instructions, so
  // the histogram of this signal IS the breakdown. Taken by hierarchical
  // reference so the CPU is not modified to be measured.
  output logic  [4:0] obs_ts,
  // The scroll registers the renderer used, per layer. The board reports the
  // grass and sky standing still; this says whether the game writes zero.
  output logic [15:0] obs_hscr [4],
  output logic [15:0] obs_vscr [4],
  // WHY the prefetch misses, which needs different fixes depending on the
  // answer: a wrong prediction is a branch and is unavoidable, whereas a right
  // prediction whose data has not arrived is a scheduling problem and is fixable.
  output logic        obs_pf_valid,
  output logic        obs_pf_armed,
  output logic        obs_pf_match,   // pf_ip == ip: the prediction was right
  output logic        obs_ic_valid,
  output logic [31:0] obs_pf_ip,
  output logic [31:0] obs_ip,
  // Readable so the testbench can dump what the CPU actually built and compare
  // it against MAME's tilemap and palette rather than against a hope.
  input  logic [14:0] dump_addr,
  output logic [15:0] dump_tram,
  output logic [15:0] dump_pal,

  // ---- THE COPROCESSOR, and its two read-only SDRAM windows.
  // Served by the testbench out of the same modelled memory the CPU reads, so
  // the math tables are the real ones from the ROMs rather than a pattern.
  output logic        tgp_tbl_req,
  output logic [15:0] tgp_tbl_addr,
  input  logic [31:0] tgp_tbl_rdata,
  input  logic        tgp_tbl_ack,
  output logic        tgp_dat_req,
  // TWENTY BITS, NOT NINETEEN. m2_copro widened `dat_addr` when the data ROM
  // went from 2 MB to its full 4 MB; this port was left at 19 and silently
  // truncated the top bit.
  output logic [19:0] tgp_dat_addr,
  // WHICH MEMORY THE READ IS FOR, AND IT WAS NOT CONNECTED. Model2.sv picks
  // the base with it -- `(dat_is_buf ? GAME_BUFFER : GAME_COPRO)` -- and this
  // harness served EVERY copro read from the data ROM. The TGP reads its
  // display list, and the loop count at 0x47C, out of BUFFER RAM, so it was
  // handed ROM bytes and looped on a garbage count.
  output logic        tgp_dat_is_buf,
  input  logic [31:0] tgp_dat_rdata,
  input  logic        tgp_dat_ack,
  // Telemetry. `retires` moving is the whole question; `unimpl` is the one
  // failure that looks identical to a hang from outside.
  output logic [15:0] obs_tgp_retires,
  output logic [15:0] obs_tgp_pc,
  output logic [31:0] obs_tgp_op,
  output logic [31:0] obs_tgp_hold,
  output logic [31:0] obs_tgp_wr_n,
  output logic [16:0] obs_tgp_wr_addr,
  output logic [31:0] obs_tgp_wr_data,
  output logic [31:0] obs_tgp_st,
  output logic [31:0] obs_tgp_a,
  output logic [31:0] obs_tgp_b,
  output logic [31:0] obs_tgp_d,
  output logic        obs_uc_we,
  output logic [11:0] obs_uc_addr,
  output logic [31:0] obs_uc_data,
  output logic        obs_tgp_unimpl,
  output logic [31:0] obs_copro_ctl,
  output logic [15:0] obs_copro_prog,
  output logic [15:0] obs_copro_in,
  output logic [15:0] obs_copro_out,
  output logic [31:0] obs_fctl_reads,
  output logic [31:0] obs_in_popped,
  output logic [31:0] obs_pop_data,
  output logic [31:0] obs_push_data,
  output logic [31:0] obs_out_data,
  output logic [31:0] obs_out_pushed,
  output logic        obs_copro_stall,
  // THE COPROCESSOR CONVERSATION, event by event. The reference can be tapped
  // at the same four windows with a Lua memory tap, so logging the i960's bus
  // cycles here makes the two traces directly diffable: same microcode upload,
  // same function-port commands, same FIFO pushes -- and then the first output
  // word that differs is the coprocessor's arithmetic, which nothing has ever
  // checked against the reference.
  output logic        obs_io_sel,
  output logic        obs_io_we,
  output logic [23:0] obs_io_addr,
  output logic [31:0] obs_io_wdata,
  output logic [31:0] obs_io_rdata,
  output logic [31:0] obs_in_dropped,
  output logic [31:0] obs_out_dropped,
  output logic [15:0] obs_tgp_io_addr,
  output logic        obs_tgp_io_rd,
  output logic        obs_tgp_io_wr,
  output logic        obs_tgp_io_ack,
  output logic        obs_tgp_fifo_rd,
  output logic        obs_tgp_fifo_wr,
  output logic        obs_tgp_ram_req
);

  logic        bus_req, bus_we, bus_ack;
  logic [31:0] bus_addr, bus_wdata, bus_rdata;
  logic  [3:0] bus_be;

  // [31:24] is unread: every decode below is on the low 24 bits, which is what
  // the top level does too.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] cpu_io_addr;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] cpu_io_wdata, cpu_io_rdata;
  logic        cpu_io_sel, cpu_io_we;
  logic  [3:0] cpu_io_be;

  // TILE RAM AND PALETTE, MODELLED RATHER THAN TIED TO 0xFFFF.
  //
  // These were both tied high, which is a peripheral that answers every read
  // with all-ones. A game that read-modify-writes its palette would then write
  // white everywhere, and this harness could not have shown it -- the very
  // symptom the board is displaying. They are real arrays now, registered like
  // the M10K they become, and the testbench can read them out to compare
  // against MAME's own dump.
  //
  // Powering up at zero, which is what an M10K does; the standing 0xFFFF rule
  // is about UNWRITTEN SDRAM, not about on-chip arrays.
  (* ramstyle = "M10K" *) logic [15:0] tram [32768];
  // 8192, MATCHING Model2.sv. This was 4096 while the core was 8192, so the
  // harness kept the aliasing R53 fixed: writes above entry 4095 wrapped onto
  // the low half, and the CPU READ THAT BACK through oc_pal_q. The dumps looked
  // clean because the testbench shadows the write STREAM at the full 13-bit
  // address rather than this array, so the divergence was invisible in every
  // result it produced. A harness that does not match the core is a statement
  // about a different machine.
  (* ramstyle = "M10K" *) logic [15:0] pal  [8192];
  logic [15:0] oc_tram_q, oc_pal_q;

  always_ff @(posedge clk_m) begin
    if (oc_tram_we) tram[oc_addr]        <= oc_din;
    if (oc_pal_we)  pal[oc_addr[12:0]]   <= oc_din;
    oc_tram_q <= tram[oc_addr];
    oc_pal_q  <= pal[oc_addr[12:0]];
  end

  // A second read port purely for the dump. Costs a duplicated array in
  // synthesis and nothing here, because this module is never synthesised.
  // PORT A, the renderer's, on clk_vid and read-only -- exactly as Model2.sv
  // wires it. This is the port that has never coexisted with a live CPU on
  // port B in any simulation.
  wire [14:0] tram_addr;
  wire [11:0] pal_addr;
  logic [15:0] tram_data, pal_data;
  always_ff @(posedge clk_vid) begin
    tram_data <= tram[tram_addr];
    pal_data  <= pal[{1'b0, pal_addr}];
  end

  wire        char_req, char_ack;
  wire [17:0] char_addr;
  wire [31:0] char_data;
  wire [17:0] cc_addr;

  m2_char_cdc u_char_cdc (
    .clk_vid(clk_vid), .vid_rst_n(rst_n),
    .v_req(char_req), .v_addr(char_addr),
    .v_ack(char_ack), .v_data(char_data),
    .clk_sys(clk_m), .sys_rst_n(rst_n),
    .s_req(sd2_req), .s_addr(cc_addr),
    .s_ack(sd2_ack_i), .s_data(sd2_dout_i)
  );
  // GAME_CHAR, the same base Model2.sv uses for a game image.
  assign sd2_addr = AW'(32'h1690000) + AW'(cc_addr);

  m2_video u_video (
    .clk(clk_vid), .ce_pix(ce_pix), .rst_n(rst_n),
    .tile_mask(14'h3FFF),
    .xlat_we(oc_xlat_we), .xlat_addr(oc_xlat_addr), .xlat_din(oc_xlat_din),
    .tram_addr(tram_addr), .tram_data(tram_data),
    .char_req(char_req), .char_addr(char_addr),
    .char_data(char_data), .char_ack(char_ack),
    .pal_addr(pal_addr), .pal_data(pal_data),
    .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
    .vid_hs(), .vid_vs(), .vid_hb(vid_hb), .vid_vb(vid_vb),
    .vblank_irq(), .dbg_fetches(dbg_fetches_o), .dbg_overruns(dbg_overruns_o),
    .dbg_ovr_frame(), .dbg_hscr(obs_hscr), .dbg_vscr(obs_vscr),
    .vid_x(), .vid_y(),
    .dbg_layer_px(), .dbg_ctrl(), .dbg_layer_have()
  );

  assign dump_tram = tram[dump_addr];
  assign dump_pal  = pal[dump_addr[12:0]];

  logic        oc_tram_we, oc_pal_we, oc_xlat_we;
  logic [14:0] oc_addr;
  logic [15:0] oc_din;
  logic  [6:0] oc_xlat_addr;
  logic  [7:0] oc_xlat_din;

  assign obs_bus_addr  = bus_addr;
  assign obs_bus_rdata = bus_rdata;
  assign obs_bus_ack   = bus_ack;
  assign obs_bus_be    = bus_be;
  assign obs_bus_we    = bus_we;
  assign obs_bus_wdata = bus_wdata;
  assign obs_bus_req   = bus_req;

  // A CORRECT DETECTOR THIS TIME. The first version counted
  //
  //   bus_req && prev_req && !bus_ack && bus_addr != prev_addr
  //
  // and reported 340,934 hits, which is a meaningless number: the i960 HOLDS
  // bus_req across a run of accesses (study R34), so between two accesses the
  // address changes legitimately in a cycle where there is no acknowledge. It
  // was counting normal traffic, and it "did not improve" when the arbiter was
  // changed because it was never measuring the arbiter.
  //
  // What is actually illegal is the address moving while ONE transaction is
  // outstanding -- after the request was taken and before it was acknowledged.
  logic [31:0] xact_addr;
  logic        in_flight;
  always_ff @(posedge clk_cpu or negedge rst_n) begin
    if (!rst_n) begin
      in_flight <= 1'b0; xact_addr <= 32'd0; obs_addr_moved <= 32'd0;
    end else begin
      // NOT ON THE ACKNOWLEDGE CYCLE. The i960 moves bus_addr ON the
      // acknowledge, so a change in that cycle is the next access starting,
      // not this one being corrupted. Excluding it is the difference between
      // measuring the arbiter and measuring normal traffic -- which the two
      // previous versions of this counter both got wrong, in different ways.
      if (in_flight && !bus_ack && bus_addr != xact_addr)
        obs_addr_moved <= obs_addr_moved + 32'd1;

      if (bus_ack)      in_flight <= 1'b0;
      else if (bus_req && !in_flight) begin
        in_flight <= 1'b1;
        xact_addr <= bus_addr;
      end
    end
  end

  i960_top u_cpu (
    .clk(clk_cpu), .rst_n(rst_n & ~cpu_hold),
    .bus_req(bus_req), .bus_we(bus_we), .bus_addr(bus_addr), .bus_be(bus_be),
    .bus_wdata(bus_wdata), .bus_rdata(bus_rdata), .bus_ack(bus_ack),
    .irq(irq),
    .dbg_pc(dbg_pc), .dbg_sat(), .dbg_prcb(obs_prcb), .dbg_icr(),
    .dbg_intr_cnt(), .dbg_intr_work(), .dbg_acc_cnt(dbg_acc),
    .dbg_ip(dbg_ip), .dbg_insn(),
    .trap(cpu_trap), .trap_op(), .halted(cpu_halt),
    .dbg_rip(dbg_rip), .dbg_pfp(dbg_pfp),
    .dbg_rcache_pos(dbg_rcache_pos), .dbg_to_memory(dbg_to_memory),
    .dbg_rf_req(dbg_rf_req), .dbg_rf_ack(dbg_rf_ack), .dbg_rf_addr(dbg_rf_addr),
    .dbg_rf_we(dbg_rf_we), .dbg_rf_wdata(dbg_rf_wdata)
  );

  // ---------------------------------------------------------- memory stack
  // One clock name serves both worlds: clk_m is the tb's clk_mem when the
  // memory is C++, and the real stack's own /2 of clk96 when it is not.
  logic clk_slow_int;
  wire  clk_m = REAL_MEM ? clk_slow_int : clk_mem;
  assign clk_slow_o = clk_slow_int;

  logic        rm_p1_ack, rm_p3_ack, rm_ready;
  logic [63:0] rm_p1_dout, rm_p3_dout;

  generate if (REAL_MEM) begin : g_realmem
    m2_sdram_x2_harness #(.COL_BITS(10), .RD_LAT_SEL(3'(RD_LAT_SEL))) u_mem (
      .clk(clk96), .rst_n(rst_n), .clk_slow(clk_slow_int), .ready(rm_ready),
      .wr_req(rl_req), .wr_addr(rl_addr), .wr_din(rl_din),
      .wr_be(2'b11), .wr_ack(rl_ack),
      // p0 is the ONE read/write slow port -- the CPU goes there. The first
      // composition put the CPU on read-only p1 and every RAM write vanished:
      // the game ran 686K instructions on ROM and on-chip state alone, then
      // died fetching an interrupt vector from RAM nothing had ever written.
      .p0_req(sd_req), .p0_we(sd_we), .p0_addr(sd_addr),
      .p0_din(sd_din), .p0_be(sd_be),
      .p1_req(1'b0), .p1_addr('0),
      .p2_req(1'b0), .p2_addr('0),
      .p3_req(sd2_req), .p3_addr(sd2_addr),
      .p4_req(1'b0), .p4_addr('0),
      .p0_dout(rm_p1_dout), .p1_dout(), .p2_dout(),
      .p3_dout(rm_p3_dout), .p4_dout(),
      .p0_ack(rm_p1_ack), .p1_ack(), .p2_ack(), .p3_ack(rm_p3_ack), .p4_ack(),
      .violations(), .v_flags(), .reads_served(), .writes_served()
    );
  end else begin : g_cxxmem
    assign clk_slow_int = clk_mem;
    assign rl_ack = 1'b1;
    assign rm_ready = 1'b1;
    assign rm_p1_ack = 1'b0; assign rm_p3_ack = 1'b0;
    assign rm_p1_dout = '0;  assign rm_p3_dout = '0;
  end endgenerate
  assign mem_ready_o = rm_ready;

  // In REAL_MEM the C++ answers are ignored and the stack's stand in.
  wire        sd_ack_i  = REAL_MEM ? rm_p1_ack  : sd_ack;
  wire [63:0] sd_dout_i = REAL_MEM ? rm_p1_dout : sd_dout;
  wire        sd2_ack_i  = REAL_MEM ? rm_p3_ack        : sd2_ack;
  wire [31:0] sd2_dout_i = REAL_MEM ? rm_p3_dout[31:0] : sd2_dout;

  m2_cpu_bridge #(.AW(AW), .BOARD_2A(1'b0), .BUFFERRAM(BUFFERRAM_EN)) u_bridge (
    .dbg_dc_hits(obs_dc_hits), .dbg_dc_miss(obs_dc_miss),
    .char_wr(), .char_wr_addr(),
    .clk_cpu(clk_cpu), .rst_n_cpu(rst_n),
    .bus_req(bus_req), .bus_we(bus_we), .bus_addr(bus_addr), .bus_be(bus_be),
    .bus_wdata(bus_wdata), .bus_rdata(bus_rdata), .bus_ack(bus_ack),
    .clk_mem(clk_m), .rst_n_mem(rst_n),
    // The bases the top level uses for a game image.
    // The top level's own bases for a game image (Model2.sv GAME_*), so the
    // address arithmetic under test is the arithmetic that runs on the board.
    .base_prog (AW'(32'h0000000)), .base_data (AW'(32'h0020000)),
    .base_work (AW'(32'h1600000)), .base_board(AW'(32'h1680000)),
    .base_char (AW'(32'h1690000)), .base_buffer(AW'(32'h16d0000)),
    .sd_req(sd_req), .sd_we(sd_we), .sd_addr(sd_addr), .sd_din(sd_din),
    .sd_be(sd_be), .sd_dout(sd_dout_i), .sd_ack(sd_ack_i),
    .oc_tram_we(oc_tram_we), .oc_pal_we(oc_pal_we), .oc_addr(oc_addr),
    .oc_din(oc_din), .oc_tram_q(oc_tram_q), .oc_pal_q(oc_pal_q),
    .oc_xlat_we(oc_xlat_we), .oc_xlat_addr(oc_xlat_addr), .oc_xlat_din(oc_xlat_din),
// TAPPED: the colour translation table as Daytona programs it. The board counts
// 32 writes per channel, which proves the ADDRESSES land; it says nothing about
// the VALUES, and a table whose R and B ramps are wrong renders white as green.
    .io_rdata(cpu_io_rdata), .io_sel(cpu_io_sel), .io_we(cpu_io_we),
    .io_stall(copro_stall),
    .io_addr(cpu_io_addr), .io_wdata(cpu_io_wdata), .io_be(cpu_io_be),
    .dbg_cpu_reads(), .dbg_cpu_writes(), .dbg_unmapped(),
    .dbg_last_addr(), .dbg_last_dout(), .dbg_probe6(), .dbg_probe2(),
    .dbg_tram_wr(dbg_tram_wr), .dbg_pal_wr(), .dbg_mstate(obs_mstate)
  );

  // ---- the peripherals, real
  wire        iob_sel = cpu_io_sel && (cpu_io_addr[23:12] == 12'hc00);
  wire [31:0] iob_rdata;

  // THE REAL BOARD, WHEN ITS FIRMWARE IS OFFERED. USE_Z80 follows the fw
  // load port: the tb that loads EPR-14869C gets the firmware board; a tb
  // that loads nothing keeps R37-R41's imitation, so every older test stands.
  wire game_in_win = cpu_io_sel && (cpu_io_addr[23:12] == 12'hc00)
                     && (cpu_io_addr[11:2] >= 10'h080)
                     && (cpu_io_addr[11:2] <= 10'h0bf);
  wire z80_in_win  = zio_we && (zio_addr >= 11'h100) && (zio_addr < 11'h180);
  always_ff @(posedge clk_m or negedge rst_n) begin
    if (!rst_n) begin
      dbg_collide_o <= '0; dbg_win_game_o <= '0; dbg_win_z80_o <= '0;
    end else begin
      if (game_in_win)               dbg_win_game_o <= dbg_win_game_o + 1;
      if (z80_in_win)                dbg_win_z80_o  <= dbg_win_z80_o  + 1;
      if (game_in_win && z80_in_win) dbg_collide_o  <= dbg_collide_o  + 1;
    end
  end

  logic        dp_busy_s;
  logic        zio_we;
  logic [10:0] zio_addr;
  logic  [7:0] zio_wdata, zio_rdata;

  m2_ioz80 #(.TICK_NUM(4), .TICK_DEN(50)) u_ioz80 (
    .clk(clk_m), .rst_n(rst_n & fw_ready),
    .fw_we(fw_we), .fw_addr(fw_addr), .fw_data(fw_data),
    .in0(cab_in0), .in1(8'h8f), .in2(8'hff), .dp_busy(dp_busy_s),
    // The board's own DIP banks. Daytona defines all 24 bits PORT_DIPUNUSED
    // with the default equal to the mask, so each bank reads 0xFF.
    .dsw1(8'hFF), .dsw2(8'hFF), .dsw3(8'hFF),
    .adc0(8'h80), .adc1(8'h20), .adc2(8'h20), .adc3(8'h80),
    .z_we(zio_we), .z_addr(zio_addr), .z_wdata(zio_wdata), .z_rdata(zio_rdata),
    .dbg_ee(), .dbg_wrcnt(), .dbg_wr_stb(), .dbg_dout(), .dbg_di(),
    .dbg_rd_end(), .dbg_ra(), .dbg_rdat(),
    .dbg_m1_n(), .dbg_a(), .dbg_last_wr(), .dbg_pf(), .dbg_pa(), .dbg_seccnt()
  );

  // ---------------------------------------------------------- COPROCESSOR
  // Same decode as Model2.sv. It replaces the fifo_control stub that answered
  // 0x980004 with a constant 1 -- "the output FIFO is empty", true of a copro
  // that never starts and a lie about one that has.
  wire        copro_fifo_sel = cpu_io_sel && (cpu_io_addr[23:14] == 10'h221);
  wire        copro_fn_sel   = cpu_io_sel && (cpu_io_addr[23:14] == 10'h220);
  wire        copro_ctl_sel  = cpu_io_sel && (cpu_io_addr[23:0]  == 24'h980000);
  wire        copro_fctl_sel = cpu_io_sel && (cpu_io_addr[23:0]  == 24'h980004);
  wire        copro_sel      = copro_fifo_sel | copro_ctl_sel | copro_fctl_sel;
  wire [31:0] copro_rdata;
  wire        copro_stall;
  assign obs_copro_stall = copro_stall;

  wire        cop_bufw_req;
  wire [18:0] cop_bufw_addr;
  wire [15:0] cop_bufw_data;
  logic       cop_bufw_req_d;
  always_ff @(posedge clk_m or negedge rst_n) begin
    if (!rst_n) begin
      obs_bufw_count <= 32'd0; obs_bufw_last <= 32'hEEEEEEEE;
      obs_bufw_7ffc  <= 32'd0; cop_bufw_req_d <= 1'b0;
      obs_bufw_wr    <= 1'b0;  obs_bufw_waddr <= 19'd0; obs_bufw_wdata <= 16'd0;
      // NOT ZERO AT RESET. The game writes 0xFFFFFFFF and waits for zero, so a
      // mailbox that powers up at zero is indistinguishable from one the
      // coprocessor has cleared. 0xEEEEEEEE is "never written".
      obs_mbox       <= 32'hEEEEEEEE;
    end else begin
      cop_bufw_req_d <= cop_bufw_req;
      obs_bufw_wr    <= 1'b0;
      if (cop_bufw_req && !cop_bufw_req_d) begin   // rising edge: one write
        obs_bufw_count <= obs_bufw_count + 32'd1;
        obs_bufw_last  <= {13'd0, cop_bufw_addr};
        obs_bufw_wr    <= 1'b1;
        obs_bufw_waddr <= cop_bufw_addr;
        obs_bufw_wdata <= cop_bufw_data;
        if (cop_bufw_addr[18:1] == 18'h07FFC) obs_bufw_7ffc <= obs_bufw_7ffc + 32'd1;
        if (cop_bufw_addr == 19'h0FFF8) obs_mbox[15:0]  <= cop_bufw_data;
        if (cop_bufw_addr == 19'h0FFF9) obs_mbox[31:16] <= cop_bufw_data;
      end
    end
  end

  m2_copro u_copro (
    .clk(clk_m), .rst_n(rst_n),
    .sel_ctl(copro_ctl_sel), .sel_fifo(copro_fifo_sel),
    .sel_fifoctl(copro_fctl_sel),
    .sel_fn(copro_fn_sel), .fn_code(cpu_io_addr[11:4]),
    .we(cpu_io_we), .wdata(cpu_io_wdata), .rdata(copro_rdata),
    .stall(copro_stall),
    .tbl_req(tgp_tbl_req), .tbl_addr(tgp_tbl_addr),
    .tbl_rdata(tgp_tbl_rdata), .tbl_ack(tgp_tbl_ack),
    .dat_req(tgp_dat_req), .dat_addr(tgp_dat_addr),
    // The banked window writes bufferram as well as reading the data ROM
    // (R133). This harness models neither region, so the write side is
    // observed and dropped -- the reads it does model are unaffected.
    .dat_we(), .dat_wdata(), .dat_is_buf(tgp_dat_is_buf), .dat_half(),
    // Buffer-RAM writes leave on their own port; this harness models neither
    // bufferram nor the shared write port, so the request is acked at once.
    .bufw_req(cop_bufw_req), .bufw_addr(cop_bufw_addr), .bufw_data(cop_bufw_data), .bufw_ack(1'b1),
    .dbg_tgp_bank(),
    .dat_rdata(tgp_dat_rdata), .dat_ack(tgp_dat_ack),
    .dbg_ff_math(), .dbg_ff_rom(), .dbg_ff_buf(), .dbg_rd_total(),
    .dbg_ctl(obs_copro_ctl), .dbg_prog_words(obs_copro_prog),
    .dbg_in_pushed(obs_copro_in), .dbg_out_popped(obs_copro_out),
    .dbg_fctl_reads(obs_fctl_reads),
    .dbg_in_popped(obs_in_popped), .dbg_pop_data(obs_pop_data), .dbg_push_data(obs_push_data), .dbg_out_data(obs_out_data), .dbg_out_pushed(obs_out_pushed),
    .dbg_in_dropped(obs_in_dropped), .dbg_out_dropped(obs_out_dropped),
    .dbg_ram_req(obs_tgp_ram_req),
    .dbg_tgp_retires(obs_tgp_retires), .dbg_tgp_pc(obs_tgp_pc),
    .dbg_tgp_op(obs_tgp_op), .dbg_tgp_hold(obs_tgp_hold), .dbg_tgp_wr_n(obs_tgp_wr_n), .dbg_tgp_wr_addr(obs_tgp_wr_addr), .dbg_tgp_wr_data(obs_tgp_wr_data), .dbg_tgp_st(obs_tgp_st), .dbg_tgp_a(obs_tgp_a), .dbg_tgp_b(obs_tgp_b), .dbg_tgp_d(obs_tgp_d),
    .dbg_uc_we(obs_uc_we), .dbg_uc_addr(obs_uc_addr), .dbg_uc_data(obs_uc_data),
    .dbg_tgp_unimpl(obs_tgp_unimpl),
    .dbg_tgp_io_addr(obs_tgp_io_addr), .dbg_tgp_io_rd(obs_tgp_io_rd),
    .dbg_tgp_io_wr(obs_tgp_io_wr), .dbg_tgp_io_ack(obs_tgp_io_ack),
    .dbg_tgp_fifo_rd(obs_tgp_fifo_rd), .dbg_tgp_fifo_wr(obs_tgp_fifo_wr)
  );

  m2_ioboard #(
    .USE_Z80(1'b1),
    .STATUS_CYCLES(STATUS_CYCLES), .SELFTEST_CYCLES(SELFTEST_CYCLES)
  ) u_ioboard (
    .clk(clk_m), .rst_n(rst_n),
    .sel(iob_sel), .we(cpu_io_we), .word(cpu_io_addr[11:2]),
    .be(cpu_io_be), .wdata(cpu_io_wdata),
    .z_we(zio_we && fw_ready), .z_addr(zio_addr), .z_wdata(zio_wdata),
    .z_rdata(zio_rdata),
    .rdata(iob_rdata),
    .dbg(iob_dbg), .dbg_win_rd(iob_win_rd),
    .dbg_flag_rd(iob_flag_rd), .dbg_seen(iob_seen)
  ,
    .win_busy(dp_busy_s),
    .dbg_word4());

  // WARM-STATE PRELOAD. +bakinit=PREFIX loads PREFIX0..3.hex (from
  // tools/nvm_split.py on a board's .nvm save) into the backup lanes before
  // reset releases, so the simulation boots with the board's REAL persisted
  // state rather than a synthesized one.
  initial begin : bak_preload
    string pfx;
    if ($value$plusargs("bakinit=%s", pfx)) begin
      // The four lanes moved inside m2_tdp_ram in R97 -- they were b0..b3
      // here, and are the simulation array of each instance now. This
      // harness is not in `make test`, so the rename broke it silently.
      $readmemh({pfx, "0.hex"}, u_backup.u_b0.mem);
      $readmemh({pfx, "1.hex"}, u_backup.u_b1.mem);
      $readmemh({pfx, "2.hex"}, u_backup.u_b2.mem);
      $readmemh({pfx, "3.hex"}, u_backup.u_b3.mem);
      $display("  backup SRAM preloaded from %s0..3.hex", pfx);
    end
  end

  wire        bak_sel = cpu_io_sel && (cpu_io_addr[23:14] == 10'b11_0100_0000);
  wire [31:0] bak_rdata;

  // ---- the geometrizer's front door and its walk, wired as Model2.sv wires it
  wire geo_wr_ctl   = cpu_io_sel && cpu_io_we && (cpu_io_addr[23:0] == 24'h980008);
  wire geo_wr_setwp = cpu_io_sel && cpu_io_we && (cpu_io_addr[23:0] == 24'h801008);
  wire geo_wr_setrp = cpu_io_sel && cpu_io_we && (cpu_io_addr[23:0] == 24'h803008);
  // The command opcode is reconstructed from the WRITE ADDRESS, exactly as
  // geo_w does it -- see Model2.sv for the full rule and the MAME comparison
  // that found it.
  wire        geo_fn_win  = (cpu_io_addr[23:12] == 12'h800);
  wire        geo_prg_win = (cpu_io_addr[23:14] == 10'h201);
  wire [11:0] geo_fa      = cpu_io_addr[11:0];
  wire  [5:0] geo_func    = geo_fa[9:4];
  wire        geo_hi      = cpu_io_wdata[31];
  wire  [1:0] geo_eye     = geo_fa[11:10];
  wire        geo_eye_en  = (|geo_eye) && (geo_func == 6'd1);
  wire [31:0] geo_push_word =
        geo_prg_win ? cpu_io_wdata
      : geo_hi      ? ((cpu_io_wdata & 32'h800fffff) | ({26'd0, geo_func} << 23))
                    : ((cpu_io_wdata & 32'h000fffff) | ({26'd0, geo_func} << 23)
                       | (geo_eye_en ? ({30'd0, geo_eye} << 29) : 32'd0));
  wire geo_wr_push  = cpu_io_sel && cpu_io_we &&
                      (geo_prg_win ||
                       (geo_fn_win && (geo_hi || (geo_fa[3:0] == 4'd0))));

  // frame_start is the vblank edge, as geo_walk_start is on the board.
  logic vb_d, vb_dd;
  always_ff @(posedge clk_mem) begin vb_d <= vid_vb; vb_dd <= vb_d; end
  wire geo_frame_start = vb_d && !vb_dd;

  // The reconstructed opcode of whatever is being pushed this cycle.
  wire [4:0] geo_push_op = geo_push_word[27:23];
  always_ff @(posedge clk_mem or negedge rst_n) begin
    if (!rst_n) begin
      geo_mtx_pc <= 32'd0; geo_mtx_pushes <= 16'd0; geo_obj_pushes <= 16'd0;
    end else if (geo_wr_push) begin
      if (geo_push_op[3:0] == 4'hb) begin
        geo_mtx_pc     <= dbg_ip;          // the instruction that wrote it
        if (!(&geo_mtx_pushes)) geo_mtx_pushes <= geo_mtx_pushes + 16'd1;
      end
      if ((geo_push_op[3:0] == 4'h1) && !(&geo_obj_pushes))
        geo_obj_pushes <= geo_obj_pushes + 16'd1;
    end
  end

  m2_geo #(.AW(AW), .DEPTH(128)) u_geo (
    .clk(clk_mem), .rst_n(rst_n),
    .wr_ctl(geo_wr_ctl), .wr_setwp(geo_wr_setwp), .wr_setrp(geo_wr_setrp),
    .wr_push(geo_wr_push), .wdata(geo_push_word),
    .rd_wp(geo_wp_o), .rd_rp(geo_rp_o),
    .base_buffer(AW'(32'h16f0000)),
    .base_pram0(AW'(32'h1710000)), .base_pram1(AW'(32'h1720000)),
    .sd_wr_req(geo_sd_req), .sd_wr_addr(geo_sd_addr), .sd_wr_din(geo_sd_din),
    .sd_wr_ack(geo_sd_ack), .sd_busy(),
    .dbg_pushes(), .dbg_dropped(), .dbg_geocnt(), .dbg_geoctl(),
    .frame_start(geo_frame_start),
    .rd_req(geo_rd_req), .rd_addr(geo_rd_addr),
    .rd_data(geo_rd_data), .rd_ack(geo_rd_ack),
    .mtx0(obs_mtx0), .mtx4(obs_mtx4), .mtx8(obs_mtx8), .mtx11(obs_mtx11),
    .mat_we(geo_mat_we), .mat_idx(geo_mat_idx), .mat_data(geo_mat_data),
    .eng_busy(geo_eng_busy),
    .foc_x(geo_foc_x), .foc_y(geo_foc_y),
    .lit_x(), .lit_y(), .lit_z(), .dbg_lit_n(),
    .tp_we(), .tp_idx(), .tp_diffuse(), .tp_ambient(), .dbg_tp_n(),
    .obj_tpa(geo_obj_tpa), .obj_tha(geo_obj_tha), .obj_oba(geo_obj_oba), .obj_obc(geo_obj_obc),
    .obj_valid(geo_obj_valid),
    .dbg_mtx_n(geo_mtx_n), .dbg_foc_n(geo_foc_n),
    .dbg_pd_words(geo_pdwords), .dbg_pd_cmds(geo_pdcmds),
    .dbg_walk_ops(geo_ops), .dbg_walk_objs(geo_objs),
    .dbg_walk_frames(geo_frames), .dbg_walk_unknown(geo_unknown),
    .dbg_walk_state()
  );
  assign geo_state = u_geo.wst;
  // The last object's address and count -- which memory it points at, and how
  // many polygons it claims. A degenerate quad at the projection centre means
  // every transformed point was (0,0), which is what a ZERO MATRIX gives.
  always_ff @(posedge clk_mem or negedge rst_n) begin
    if (!rst_n) begin geo_oba_last <= 32'd0; geo_obc_last <= 32'd0; geo_tha_last <= 32'd0; geo_tpa_last <= 32'd0; end
    else if (geo_obj_valid) begin
      geo_oba_last <= geo_obj_oba; geo_obc_last <= geo_obj_obc;
      geo_tha_last <= geo_obj_tha; geo_tpa_last <= geo_obj_tpa;
    end
  end

  // ---- the geometry pipeline, so object_data is actually consumed
  wire        geo_mat_we, geo_obj_valid, geo_eng_busy;
  wire [3:0]  geo_mat_idx;
  wire [31:0] geo_mat_data, geo_foc_x, geo_foc_y, geo_obj_oba, geo_obj_obc;
  wire [31:0] geo_obj_tha, geo_obj_tpa;

  m2_geometry u_geometry (
    .clk(clk_mem), .rst_n(rst_n),
    .start(geo_obj_valid), .oba(geo_obj_oba), .obc(geo_obj_obc),
    .busy(geo_eng_busy),
    .mat_we(geo_mat_we), .mat_idx(geo_mat_idx), .mat_data(geo_mat_data),
    .foc_x(geo_foc_x), .foc_y(geo_foc_y),
    .mem_req(eng_mem_req), .mem_addr(eng_mem_addr),
    .mem_data(eng_mem_data), .mem_ack(eng_mem_ack),
    .xc(32'h43780000), .yc(32'h43400000),          // 248.0, 192.0
    .a_left(32'hC3780000), .a_right(32'h43780000), // -248, +248
    .a_bottom(32'h43400000), .a_top(32'hC3400000), // +192, -192
    .flat_col(24'hC0C0C0),
    .q_valid(eng_q_valid), .q_ready(1'b1),
    .q_x0(eng_q_x0), .q_y0(eng_q_y0), .q_x1(eng_q_x1), .q_y1(eng_q_y1),
    .q_x2(eng_q_x2), .q_y2(eng_q_y2), .q_x3(eng_q_x3), .q_y3(eng_q_y3),
    .q_col(), .q_z(),
    .dbg_polys(eng_polys), .dbg_objects(eng_objects), .dbg_capped(eng_capped),
    .dbg_clip_in(eng_clip_in), .dbg_clip_out(eng_clip_out),
    .dbg_clip_dropped(eng_clip_drop), .dbg_nonfinite(eng_nonfinite),
    .dbg_pj_lost(), .dbg_eng_state(), .dbg_qst(), .dbg_clip_state()
  );
  assign obs_poly_valid = u_geometry.poly_valid & u_geometry.poly_ready;
  assign obs_v0x = u_geometry.u_engine.v0x; assign obs_v0y = u_geometry.u_engine.v0y; assign obs_v0z = u_geometry.u_engine.v0z;
  assign obs_v1x = u_geometry.u_engine.v1x; assign obs_v1y = u_geometry.u_engine.v1y; assign obs_v1z = u_geometry.u_engine.v1z;
  assign obs_v2x = u_geometry.u_engine.v2x; assign obs_v2y = u_geometry.u_engine.v2y; assign obs_v2z = u_geometry.u_engine.v2z;
  assign obs_v3x = u_geometry.u_engine.v3x; assign obs_v3y = u_geometry.u_engine.v3y; assign obs_v3z = u_geometry.u_engine.v3z;
  assign obs_poly_attr = u_geometry.u_engine.poly_attr;
  assign obs_foc_x = geo_foc_x; assign obs_foc_y = geo_foc_y;
  assign obs_eng_busy = geo_eng_busy;
  assign obs_eng_state = u_geometry.u_engine.st;
  assign obs_pj_busy = u_geometry.pj_busy;
  assign obs_pj_owner = u_geometry.pj_owner;
  assign obs_w_granted = u_geometry.w_granted;
  assign obs_pj_hit = (u_geometry.qst == 2'd1) && u_geometry.skip_here;
  assign obs_k_granted = u_geometry.k_granted;
  assign obs_tgp_retire = u_copro.u_tgp.core.retire;
  assign obs_tgp_rpc    = u_copro.u_tgp.core.retire_pc;
  assign obs_tgpx_a     = u_copro.u_tgp.core.u_regs.reg_a;
  assign obs_tgpx_d     = u_copro.u_tgp.core.u_regs.reg_d;
  assign obs_tgp_ram69  = u_copro.u_tgp.core.u_mem.ram0[8'h69];
  assign obs_tgp_ram6a  = u_copro.u_tgp.core.u_mem.ram0[8'h6a];
  assign obs_xf_valid = u_geometry.u_engine.xf_in_valid & u_geometry.u_engine.xf_translate;
  assign obs_xf_x = u_geometry.u_engine.xf_in_x; assign obs_xf_y = u_geometry.u_engine.xf_in_y; assign obs_xf_z = u_geometry.u_engine.xf_in_z;
  assign obs_mtx = u_geo.mtx;


  m2_backup u_backup (
    .clk(clk_m), .sel(bak_sel), .we(cpu_io_we),
    .word(cpu_io_addr[13:2]), .be(cpu_io_be), .wdata(cpu_io_wdata),
    .rdata(bak_rdata),
    .rst_n(rst_n), .hps_we(1'b0), .hps_word(12'd0), .hps_be(4'd0), .hps_wdata(32'd0),
    .dbg_word(12'd5), .dbg_rd_sel(4'd0), .dbg_q(), .dbg_first(), .dbg_w0(bak_w0), .dbg_writes(bak_writes)
  );

  // The I/O read mux, copied from Model2.sv. If these two ever disagree the
  // harness stops being about the same machine, so it is worth diffing when
  // either changes.
  wire [7:0] tgpid_b =
    (cpu_io_addr[3:0] == 4'h1) ? 8'h54 : (cpu_io_addr[3:0] == 4'h2) ? 8'h41 :
    (cpu_io_addr[3:0] == 4'h3) ? 8'h48 : (cpu_io_addr[3:0] == 4'h5) ? 8'h41 :
    (cpu_io_addr[3:0] == 4'h6) ? 8'h4B : (cpu_io_addr[3:0] == 4'h7) ? 8'h4F :
    (cpu_io_addr[3:0] == 4'h9) ? 8'h5A : (cpu_io_addr[3:0] == 4'hA) ? 8'h41 :
    (cpu_io_addr[3:0] == 4'hB) ? 8'h4B : (cpu_io_addr[3:0] == 4'hD) ? 8'h4D :
    (cpu_io_addr[3:0] == 4'hE) ? 8'h54 : (cpu_io_addr[3:0] == 4'hF) ? 8'h4B : 8'h00;

  logic [11:0] io_intreq, io_intena;
  // Only the low bits are read, exactly as in Model2.sv -- videoctl's mode bit
  // and the frame counter's parity. Kept full width so the shapes match the top
  // level rather than quietly diverging from it.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] io_videoctl;
  logic [31:0] io_framenum;
  /* verilator lint_on UNUSEDSIGNAL */

  assign obs_io_sel   = cpu_io_sel;
  assign obs_io_we    = cpu_io_we;
  assign obs_io_addr  = cpu_io_addr[23:0];
  assign obs_io_wdata = cpu_io_wdata;
  assign obs_io_rdata = cpu_io_rdata;

  assign cpu_io_rdata =
    iob_sel                           ? iob_rdata :
    bak_sel                           ? bak_rdata :
    (cpu_io_addr[23:4] == 20'h98003)  ? {4{tgpid_b}} :
    copro_sel                         ? copro_rdata :
    (cpu_io_addr[23:0] == 24'h98000c) ? (io_videoctl[0]
                                          ? {29'd0, io_framenum[0], io_videoctl[1:0]}
                                          : {28'd0, io_framenum[1], 1'b0, io_videoctl[1:0]}) :
    (cpu_io_addr[23:0] == 24'he80000) ? {20'd0, io_intreq} :
    (cpu_io_addr[23:0] == 24'he80004) ? {20'd0, io_intena} :
    32'd0;

  always_ff @(posedge clk_m or negedge rst_n) begin
    if (!rst_n) begin
      io_intreq <= '0; io_intena <= '0; io_videoctl <= '0; io_framenum <= '0;
    end else if (cpu_io_sel && cpu_io_we) begin
      if (cpu_io_addr[23:0] == 24'he80000) io_intreq   <= io_intreq & cpu_io_wdata[11:0];
      if (cpu_io_addr[23:0] == 24'he80004) io_intena   <= cpu_io_wdata[11:0];
      if (cpu_io_addr[23:0] == 24'h98000c) io_videoctl <= cpu_io_wdata;
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, oc_tram_we, oc_pal_we, oc_addr, oc_din,
                   oc_xlat_we, oc_xlat_addr, oc_xlat_din, sd_we, sd_din, sd_be};
  /* verilator lint_on UNUSEDSIGNAL */

// THE PALETTE AS THE CPU BUILDS IT. The captured fixture renders white labels
// correctly on this same renderer; the live game does not. Either the CPU writes
// a different palette or the bridge loses some of it, and only a comparison
// against palette.bin can say which.
assign obs_tram_we   = oc_tram_we;
assign obs_pal_we    = oc_pal_we;
assign obs_oc_addr   = oc_addr;
assign obs_oc_din    = oc_din;
assign obs_xlat_we   = oc_xlat_we;
assign obs_xlat_addr = oc_xlat_addr;
assign obs_xlat_din  = oc_xlat_din;

  assign obs_ts       = u_cpu.ts;
  assign obs_pf_valid = u_cpu.pf_valid;
  assign obs_pf_armed = u_cpu.pf_armed;
  assign obs_pf_match = (u_cpu.pf_ip == u_cpu.ip);
  assign obs_ic_valid = u_cpu.ic_valid;
  assign obs_pf_ip    = u_cpu.pf_ip;
  assign obs_ip       = u_cpu.ip;

endmodule
