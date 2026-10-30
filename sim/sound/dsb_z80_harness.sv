// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
// (from the Sega Model 1 core, sega-model1-mister 2657c46, sim/sound/dsb_z80_harness.sv)
//
// dsb_z80 and a full tv80s side by side on the same ROM, the same T clock and
// the same UART bytes, each with its own RAM and its own UART. tv80s is the
// reference for what a Z80 does with the program; the bench compares every
// port access of the two, value and T-state.
//
// Changed from Model 1: the ROM is a plusarg (+rom=<hex>), so the same bench
// runs Star Wars' epr-16471.2 and STCC's epr-19275.2s; each core has a real
// m2_i8251 (the board's UART: mode / command sequencing, internal reset, RxE)
// whose RxRDY & RxE drives that core's INT, as MAME wires the DSB; and the
// memory answers in `lat` cycles on chip and `lat_far` elsewhere, with the
// on-chip ranges the board keeps (0000-07ff, 9000-90ff, ff00-ffff).
`timescale 1ns/1ps
module dsb_z80_harness (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        tick,
  input  logic        rx_stb,        // a byte arrives at both UARTs
  input  logic  [7:0] rx_byte,
  input  logic  [7:0] lat,           // dsb_z80 memory latency, cycles, on chip
  input  logic  [7:0] lat_far,       // ... and elsewhere (SDRAM)
  // tv80s port accesses (commit edge)
  output logic        t_wr, t_rd,
  output logic  [7:0] t_port, t_data,
  // dsb_z80 port accesses
  output logic        c_wr, c_rd,
  output logic  [7:0] c_port, c_data,
  output logic        trap,
  output logic [15:0] trap_cnt, trap_pc, c_pc,
  // dsb_z80 memory accesses as they complete, and its fetches, for the census
  output logic        c_mstb, c_mwe, c_fetch,
  output logic [15:0] c_maddr, c_sp,
  output logic        t_int, c_int,  // an interrupt accepted (tv80s: its INT ack M1)
  output logic  [7:0] ovr            // bytes that arrived with one still pending
);
  // ---------------------------------------------------------- shared ROM
  logic [7:0] rom [32768];
  initial begin
    string f;
    if (!$value$plusargs("rom=%s", f)) f = "build/rom/dsb/epr-16471.hex";
    $readmemh(f, rom);
  end

  // ---------------------------------------------------------- the UART input
  // each core's UART takes the byte when it is free; one pending per side
  logic t_rxv, c_rxv, t_rxa, c_rxa; logic [7:0] t_rxb, c_rxb;
  always_ff @(posedge clk) begin
    if (!rst_n) begin t_rxv <= 1'b0; c_rxv <= 1'b0; ovr <= '0; end
    else begin
      if (t_rxa) t_rxv <= 1'b0;
      if (c_rxa) c_rxv <= 1'b0;
      if (rx_stb) begin
        if (t_rxv && !t_rxa) ovr <= ovr + 8'd1;
        t_rxv <= 1'b1; t_rxb <= rx_byte; c_rxv <= 1'b1; c_rxb <= rx_byte;
      end
    end
  end

  // ---------------------------------------------------------- tv80s
  logic [15:0] A; logic [7:0] di, dout;
  logic mreq_n, iorq_n, rd_n, wr_n, m1_n;
  logic [7:0] tram [32768];
  logic t_irq; logic [7:0] t_udout;
  tv80s u_ref (
    .reset_n(rst_n), .clk(clk), .cen(tick),
    .wait_n(1'b1), .int_n(!t_irq), .nmi_n(1'b1), .busrq_n(1'b1),
    .m1_n(m1_n), .mreq_n(mreq_n), .iorq_n(iorq_n), .rd_n(rd_n), .wr_n(wr_n),
    .rfsh_n(), .halt_n(), .busak_n(), .A(A), .di(di), .dout(dout));
  wire io_rd_l = !iorq_n && !rd_n && m1_n;
  wire io_wr_l = !iorq_n && !wr_n && m1_n;
  wire mem_wr  = !mreq_n && !wr_n;
  // tv80s latches di during T2, by which point it may already have lifted
  // rd_n: hold the I/O data until the next memory cycle begins.
  logic io_hold;
  always_ff @(posedge clk) begin
    if (!rst_n || !mreq_n) io_hold <= 1'b0;
    else if (io_rd_l)      io_hold <= 1'b1;
  end
  wire t_uadr = (A[7:1] == 7'b1111000);
  always_comb begin
    if (io_rd_l || io_hold) di = t_uadr ? t_udout : 8'h00;
    else         di = A[15] ? tram[A[14:0]] : rom[A[14:0]];
  end
  logic io_rd_d, io_wr_d, mem_wr_d; logic [15:0] aw; logic [7:0] dw;
  always_ff @(posedge clk) begin
    io_rd_d <= io_rd_l; io_wr_d <= io_wr_l; mem_wr_d <= mem_wr;
    if (io_wr_l || mem_wr) begin aw <= A; dw <= dout; end
    if (io_rd_l) begin aw <= A; end
  end
  // commit on the trailing edge, as m1_ioz80 does
  assign t_wr = io_wr_d && !io_wr_l;
  assign t_rd = io_rd_d && !io_rd_l;
  assign t_port = aw[7:0];
  wire t_usel = (t_wr || t_rd) && (aw[7:1] == 7'b1111000);
  logic [7:0] t_udo;
  m2_i8251 u_tuart (
    .clk(clk), .rst_n(rst_n),
    .sel(t_usel), .we(t_wr), .addr(aw[0]), .din(dw), .dout(t_udo),
    .data_o(), .stat_o(),
    .tx_data(), .tx_valid(), .tx_ack(1'b1),
    .rx_data(t_rxb), .rx_valid(t_rxv), .rx_ack(t_rxa),
    .irq(), .irq_rx(t_irq), .irq_tx());
  // the value tv80s is given while the access is live: the register its
  // live address names
  assign t_udout = A[0] ? u_tuart.status : u_tuart.rx_hold;
  assign t_data = t_wr ? dw : ((aw[7:1] == 7'b1111000) ? t_udo : 8'h00);
  always_ff @(posedge clk)
    if (mem_wr_d && !mem_wr && aw[15]) tram[aw[14:0]] <= dw;
  // tv80s's INT acknowledge: an M1 with IORQ
  logic t_ack_d;
  always_ff @(posedge clk) t_ack_d <= !m1_n && !iorq_n;
  assign t_int = !m1_n && !iorq_n && !t_ack_d;

  // ---------------------------------------------------------- dsb_z80
  logic m_req, m_we, m_ack; logic [15:0] m_addr; logic [7:0] m_wdata, m_rdata;
  logic [7:0] cram [32768];
  logic io_rd, io_wr; logic [7:0] io_addr, io_wdata, io_rdata;
  logic c_irq; logic [7:0] c_udo;
  dsb_z80 u_cut (
    .clk(clk), .rst_n(rst_n), .tick(tick),
    .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata), .m_ack(m_ack), .m_rdata(m_rdata),
    .io_rd(io_rd), .io_wr(io_wr), .io_addr(io_addr), .io_wdata(io_wdata), .io_rdata(io_rdata),
    .irq(c_irq),
    .trap(trap), .trap_pc(trap_pc), .trap_cnt(trap_cnt), .dbg_pc(c_pc));
  wire c_uadr = (io_addr[7:1] == 7'b1111000);
  m2_i8251 u_cuart (
    .clk(clk), .rst_n(rst_n),
    .sel((io_rd || io_wr) && c_uadr), .we(io_wr), .addr(io_addr[0]), .din(io_wdata), .dout(c_udo),
    .data_o(), .stat_o(),
    .tx_data(), .tx_valid(), .tx_ack(1'b1),
    .rx_data(c_rxb), .rx_valid(c_rxv), .rx_ack(c_rxa),
    .irq(), .irq_rx(c_irq), .irq_tx());
  // read data from the address alone, as dsb_board: dsb_z80 samples it the
  // cycle before its strobe
  assign io_rdata = c_uadr ? c_udo : 8'h00;
  wire far = !(m_addr < 16'h0800 || m_addr[15:8] == 8'h90 || m_addr[15:8] == 8'hff);
  logic [7:0] cnt; logic busy;
  always_ff @(posedge clk) begin
    m_ack <= 1'b0;
    if (!rst_n) begin busy <= 1'b0; cnt <= '0; end
    else if (!busy && m_req && !m_ack) begin busy <= 1'b1; cnt <= far ? lat_far : lat; end
    else if (busy) begin
      if (cnt == 0) begin
        busy <= 1'b0; m_ack <= 1'b1;
        if (m_we) begin if (m_addr[15]) cram[m_addr[14:0]] <= m_wdata; end
        else m_rdata <= m_addr[15] ? cram[m_addr[14:0]] : rom[m_addr[14:0]];
      end else cnt <= cnt - 8'd1;
    end
  end
  assign c_wr = io_wr; assign c_rd = io_rd; assign c_port = io_addr;
  assign c_data = io_wr ? io_wdata : io_rdata;
  assign c_mstb = m_ack; assign c_mwe = m_we; assign c_maddr = m_addr;
  assign c_fetch = m_ack && (u_cut.st == 3'd1);            // S_FWAIT: an opcode byte
  assign c_sp = u_cut.SP;
  assign c_int = (u_cut.st == 3'd0) && u_cut.int_take;
endmodule

