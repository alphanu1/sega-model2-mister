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
  parameter int          SELFTEST_CYCLES = 200_000
) (
  input  logic        clk_cpu,
  input  logic        clk_mem,
  input  logic        rst_n,
  input  logic  [3:0] irq,

  // ---- the SDRAM port, answered in C++
  output logic        sd_req,
  output logic        sd_we,
  output logic [AW:1] sd_addr,
  output logic [15:0] sd_din,
  output logic  [1:0] sd_be,
  input  logic [63:0] sd_dout,
  input  logic        sd_ack,

  // ---- what the test asks about
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
  output logic  [7:0] obs_mstate,     // {0,0,sd_ack,ack_mem,req_mem,st[2:0]}
  // Readable so the testbench can dump what the CPU actually built and compare
  // it against MAME's tilemap and palette rather than against a hope.
  input  logic [14:0] dump_addr,
  output logic [15:0] dump_tram,
  output logic [15:0] dump_pal
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
  (* ramstyle = "M10K" *) logic [15:0] pal  [4096];
  logic [15:0] oc_tram_q, oc_pal_q;

  always_ff @(posedge clk_mem) begin
    if (oc_tram_we) tram[oc_addr]        <= oc_din;
    if (oc_pal_we)  pal[oc_addr[11:0]]   <= oc_din;
    oc_tram_q <= tram[oc_addr];
    oc_pal_q  <= pal[oc_addr[11:0]];
  end

  // A second read port purely for the dump. Costs a duplicated array in
  // synthesis and nothing here, because this module is never synthesised.
  assign dump_tram = tram[dump_addr];
  assign dump_pal  = pal[dump_addr[11:0]];

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
    .clk(clk_cpu), .rst_n(rst_n),
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

  m2_cpu_bridge #(.AW(AW), .BOARD_2A(1'b0)) u_bridge (
    .clk_cpu(clk_cpu), .rst_n_cpu(rst_n),
    .bus_req(bus_req), .bus_we(bus_we), .bus_addr(bus_addr), .bus_be(bus_be),
    .bus_wdata(bus_wdata), .bus_rdata(bus_rdata), .bus_ack(bus_ack),
    .clk_mem(clk_mem), .rst_n_mem(rst_n),
    // The bases the top level uses for a game image.
    // The top level's own bases for a game image (Model2.sv GAME_*), so the
    // address arithmetic under test is the arithmetic that runs on the board.
    .base_prog (AW'(32'h0000000)), .base_data (AW'(32'h0020000)),
    .base_work (AW'(32'h1600000)), .base_board(AW'(32'h1680000)),
    .base_char (AW'(32'h1690000)),
    .sd_req(sd_req), .sd_we(sd_we), .sd_addr(sd_addr), .sd_din(sd_din),
    .sd_be(sd_be), .sd_dout(sd_dout), .sd_ack(sd_ack),
    .oc_tram_we(oc_tram_we), .oc_pal_we(oc_pal_we), .oc_addr(oc_addr),
    .oc_din(oc_din), .oc_tram_q(oc_tram_q), .oc_pal_q(oc_pal_q),
    .oc_xlat_we(oc_xlat_we), .oc_xlat_addr(oc_xlat_addr), .oc_xlat_din(oc_xlat_din),
    .io_rdata(cpu_io_rdata), .io_sel(cpu_io_sel), .io_we(cpu_io_we),
    .io_addr(cpu_io_addr), .io_wdata(cpu_io_wdata), .io_be(cpu_io_be),
    .dbg_cpu_reads(), .dbg_cpu_writes(), .dbg_unmapped(),
    .dbg_last_addr(), .dbg_last_dout(), .dbg_probe6(), .dbg_probe2(),
    .dbg_tram_wr(dbg_tram_wr), .dbg_pal_wr(), .dbg_mstate(obs_mstate)
  );

  // ---- the peripherals, real
  wire        iob_sel = cpu_io_sel && (cpu_io_addr[23:12] == 12'hc00);
  wire [31:0] iob_rdata;

  m2_ioboard #(
    .STATUS_CYCLES(STATUS_CYCLES), .SELFTEST_CYCLES(SELFTEST_CYCLES)
  ) u_ioboard (
    .clk(clk_mem), .rst_n(rst_n),
    .sel(iob_sel), .we(cpu_io_we), .word(cpu_io_addr[11:2]),
    .be(cpu_io_be), .wdata(cpu_io_wdata), .rdata(iob_rdata),
    .dbg(iob_dbg), .dbg_win_rd(iob_win_rd),
    .dbg_flag_rd(iob_flag_rd), .dbg_seen(iob_seen)
  );

  wire        bak_sel = cpu_io_sel && (cpu_io_addr[23:14] == 10'b11_0100_0000);
  wire [31:0] bak_rdata;

  m2_backup u_backup (
    .clk(clk_mem), .sel(bak_sel), .we(cpu_io_we),
    .word(cpu_io_addr[13:2]), .be(cpu_io_be), .wdata(cpu_io_wdata),
    .rdata(bak_rdata), .dbg_w0(bak_w0), .dbg_writes(bak_writes)
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

  assign cpu_io_rdata =
    iob_sel                           ? iob_rdata :
    bak_sel                           ? bak_rdata :
    (cpu_io_addr[23:4] == 20'h98003)  ? {4{tgpid_b}} :
    (cpu_io_addr[23:0] == 24'h980004) ? 32'd1 :
    (cpu_io_addr[23:0] == 24'h98000c) ? (io_videoctl[0]
                                          ? {29'd0, io_framenum[0], io_videoctl[1:0]}
                                          : {28'd0, io_framenum[1], 1'b0, io_videoctl[1:0]}) :
    (cpu_io_addr[23:0] == 24'he80000) ? {20'd0, io_intreq} :
    (cpu_io_addr[23:0] == 24'he80004) ? {20'd0, io_intena} :
    32'd0;

  always_ff @(posedge clk_mem or negedge rst_n) begin
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

endmodule
