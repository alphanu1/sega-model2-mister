// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// THE HARDWARE PATH, ON A DESK: ioctl -> m2_rom_loader -> m2_sdram -> readback.
//
// The board reports the ROM readback as an address-independent 000000FF. The
// capture phase is ruled out (a wrong phase shifts data, it does not return a
// constant) and the controller is ruled out (74,729 checks against the device
// model, 0 fails). So the fault is in the integration, and this reproduces the
// integration rather than its parts.
//
// The readback FSM below is copied VERBATIM from Model2.sv. If it is paraphrased
// the harness tests something the board is not running, which is the whole
// failure mode this exercise exists to avoid.

`timescale 1ns/1ps

module m2_romload_harness #(
  parameter int unsigned COL_BITS = 11,
  parameter int unsigned SDR_AW = 2 + 13 + COL_BITS
) (
  input  logic        clk,
  input  logic        rst_n,
  // Swept by the testbench. The device MODEL presents data on the same edge
  // the controller uses and wants CL+3 (sel 0); the real board is clocked on
  // the inverse and wants CL+2 (sel 1). They are different numbers for a
  // physical reason, so the harness must not hardcode either.
  input  logic  [1:0] rd_lat_sel,

  // ioctl, exactly as hps_io presents it
  input  logic        ioctl_download,
  input  logic [15:0] ioctl_index,
  input  logic        ioctl_wr,
  input  logic [26:0] ioctl_addr,
  input  logic [15:0] ioctl_dout,
  output logic        ioctl_wait,

  output logic        mem_ready,
  output logic        rom_loaded,
  output logic        overflow,

  // What the overlay shows
  output logic [31:0] rb_w0,
  output logic [31:0] rb_w1,
  output logic  [1:0] rb_state,

  // Device model observability
  // Write-path observability: the readback proves data came back, this proves
  // WHERE it went. Nothing had ever checked the two agree.
  output logic        dbg_wr_req,
  output logic [SDR_AW:1] dbg_wr_addr,
  output logic [15:0] dbg_wr_din,
  output logic        dbg_wr_ack,

  output logic        dbg_rb_req,
  output logic        dbg_rb_ack,
  output logic [SDR_AW:1] dbg_rb_addr,
  output logic [63:0] dbg_rb_dout,

  output int unsigned violations,
  output int unsigned reads_served,
  output int unsigned writes_served
);

  localparam int unsigned NP = 5;

  logic        ldr_wr_req, ldr_wr_ack;
  logic [SDR_AW:1] ldr_wr_addr;
  logic [15:0] ldr_wr_din;
  logic  [1:0] ldr_wr_be;

  logic [NP-1:0]       p_req, p_ack;
  logic [NP-1:0][SDR_AW:1] p_addr;
  logic [NP-1:0][63:0] p_dout;

  logic        rb_req;
  logic [SDR_AW:1] rb_addr;
  wire  [63:0] rb_dout = p_dout[1];
  wire         rb_ack  = p_ack[1];

  always_comb begin
    p_req  = '0;
    p_addr = '0;
    // PORT 1, NOT PORT 0. m2_sdram's blen() is hardcoded per port: ports 1-3
    // burst FOUR 16-bit words (the full 64-bit p_dout) and ports 0 and 4 return
    // ONE. Port 0 gave a correct low half and a permanently zero upper half,
    // which reads like a broken controller and is a port-selection mistake.
    // Ports 1-3 are the streaming ports; the CPU takes 0 precisely because it
    // wants single words.
    p_req[1]  = rb_req;
    p_addr[1] = rb_addr;
  end

  assign dbg_rb_req  = rb_req;
  assign dbg_rb_ack  = rb_ack;
  assign dbg_rb_addr = rb_addr;
  assign dbg_rb_dout = rb_dout;

  assign dbg_wr_req  = ldr_wr_req;
  assign dbg_wr_addr = ldr_wr_addr;
  assign dbg_wr_din  = ldr_wr_din;
  assign dbg_wr_ack  = ldr_wr_ack;

  logic        cke, cs_n, ras_n, cas_n, we_n;
  logic [1:0]  ba, dqm;
  logic [12:0] a;
  logic [15:0] dq_c2m, dq_m2c;
  logic        dq_oe_c, dq_oe_m;
  logic [15:0] v_flags;

  // INIT_NOP shortened only; every other number matches Model2.sv, including
  // T_REFI(600) for the 80 MHz domain.
  m2_sdram #(.COL_BITS(COL_BITS), .NP(NP), .T_REFI(600), .INIT_NOP(600)) u_sdram (
    .clk(clk), .rst_n(rst_n), .ready(mem_ready),
    .rd_lat_sel(rd_lat_sel),
    .sd_cke(cke), .sd_cs_n(cs_n), .sd_ras_n(ras_n), .sd_cas_n(cas_n),
    .sd_we_n(we_n), .sd_ba(ba), .sd_a(a), .sd_dqm(dqm),
    .sd_dq_o(dq_c2m), .sd_dq_oe(dq_oe_c), .sd_dq_i(dq_m2c),
    .wr_req(ldr_wr_req), .wr_addr(ldr_wr_addr), .wr_din(ldr_wr_din),
    .wr_be(ldr_wr_be), .wr_ack(ldr_wr_ack),
    .p_req(p_req), .p_we('0), .p_addr(p_addr), .p_din('0), .p_be('1),
    .p_dout(p_dout), .p_ack(p_ack),
    .dbg_req(), .dbg_grant()
  );

  m2_rom_loader #(.SDR_AW(SDR_AW)) u_loader (
    .clk(clk), .rst(~rst_n),
    .mem_ready(mem_ready),
    .ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
    .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
    .ioctl_wait(ioctl_wait),
    .sdr_wr_req(ldr_wr_req), .sdr_wr_addr(ldr_wr_addr),
    .sdr_wr_din(ldr_wr_din), .sdr_wr_be(ldr_wr_be), .sdr_wr_ack(ldr_wr_ack),
    .tgp_wr(), .tgp_addr(), .tgp_din(),
    .ucode_words(), .ucode_csum(),
    .rom_loaded(rom_loaded), .overflow(overflow)
  );

  sdram_model #(.COL_BITS(COL_BITS), .T_REFI(781), .REFI_SLACK(9)) device (
    .clk(clk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n),
    .we_n(we_n), .ba(ba), .a(a), .dqm(dqm),
    .dq_i(dq_c2m), .dq_oe_i(dq_oe_c),
    .dq_o(dq_m2c), .dq_oe_o(dq_oe_m),
    .violations(violations), .v_flags(v_flags),
    .reads_served(reads_served), .writes_served(writes_served)
  );

  // ---- VERBATIM FROM Model2.sv, and it must stay that way ----------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rb_req <= 1'b0; rb_addr <= '0; rb_state <= 2'd0;
      rb_w0 <= 32'd0; rb_w1 <= 32'd0;
    end else begin
      case (rb_state)
        2'd0: if (rom_loaded) begin rb_addr <= SDR_AW'(8); rb_req <= 1'b1; rb_state <= 2'd1; end
        2'd1: if (rb_ack) begin rb_w0 <= rb_dout[31:0]; rb_req <= 1'b0;
                                rb_addr <= SDR_AW'(4); rb_state <= 2'd2; end
        2'd2: begin rb_req <= 1'b1; rb_state <= 2'd3; end
        2'd3: if (rb_ack) begin rb_w1 <= rb_dout[63:32]; rb_req <= 1'b0; end
        default: ;
      endcase
    end
  end

endmodule
