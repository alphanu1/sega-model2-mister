// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE for the full text.
//
// Simulation wiring for the SDRAM controller: controller, protocol-checking
// device model, and the bandwidth monitor, with the same timing parameters
// handed to both sides.
//
// Passing one set of localparams to both the controller and the checker is the
// point. A controller built for one clock and checked against a model built
// for another agrees with itself and with nothing real, and that mistake
// leaves no trace in the output.
//
// Ports are broken out per master rather than as packed arrays so the C++
// harness can drive them without unpacking wide vectors by hand.

`timescale 1ns/1ps

module m2_sdram_harness #(
  // Set with -GCOL_BITS at build time. 9 = 32 MB module, 11 = 128 MB. The
  // device model follows the same number, so a geometry the controller decodes
  // wrongly shows up as a read mismatch rather than silently aliasing.
  parameter int unsigned COL_BITS = 9
) (
  input  logic        clk,
  input  logic        rst_n,
  output logic        ready,

  // ROM download
  input  logic        wr_req,
  input  logic [COL_BITS+15:1] wr_addr,
  input  logic [15:0] wr_din,
  input  logic [1:0]  wr_be,
  output logic        wr_ack,

  // ALL TEN PORTS THE CORE ACTUALLY HAS, not the first five.
  //
  // It was five, and blen() has had ten entries for a long time. Ports 8 and 9
  // burst TWO -- the TGP's 32-bit word out of a 16-bit memory -- and a burst
  // length that only exists in the DUT is not covered by anything: the
  // controller's capture composed every non-single transfer from four slots,
  // so a pair silently took half its result from the previous transfer. A test
  // that drives 0..4 cannot see that no matter how long it runs.
  input  logic        p0_req, p1_req, p2_req, p3_req, p4_req,
                      p5_req, p6_req, p7_req, p8_req, p9_req,
  input  logic        p0_we,
  input  logic [COL_BITS+15:1] p0_addr, p1_addr, p2_addr, p3_addr, p4_addr,
                               p5_addr, p6_addr, p7_addr, p8_addr, p9_addr,
  input  logic [15:0] p0_din,
  input  logic [1:0]  p0_be,
  output logic [63:0] p0_dout, p1_dout, p2_dout, p3_dout, p4_dout,
                      p5_dout, p6_dout, p7_dout, p8_dout, p9_dout,
  output logic        p0_ack, p1_ack, p2_ack, p3_ack, p4_ack,
                      p5_ack, p6_ack, p7_ack, p8_ack, p9_ack,

  // Device model observability
  output int unsigned violations,
  output logic [15:0] v_flags,
  output int unsigned reads_served,
  output int unsigned writes_served,

  // Telemetry readback
  input  logic [2:0]  mon_sel,
  input  logic        mon_snap,
  output logic [23:0] mon_req,
  output logic [23:0] mon_grant,
  output logic [23:0] mon_wait,
  output logic [7:0]  mon_bmax,
  output logic [23:0] mon_total
);

  localparam int unsigned NP    = 10;   // all ten the core uses: 8 and 9 burst two
  localparam int unsigned T_RCD = 2;
  localparam int unsigned T_RP  = 2;
  localparam int unsigned T_RC  = 7;
  localparam int unsigned T_RAS = 5;
  localparam int unsigned T_WR  = 2;
  localparam int unsigned CL    = 2;
  localparam int unsigned T_REFI = 700;
  // Long enough to be a real bring-up but short enough that every test does
  // not pay 100 us of NOPs; the sequence exercised is identical.
  localparam int unsigned INIT_NOP = 600;

  logic [NP-1:0]       p_req, p_we, p_ack;
  logic [NP-1:0][COL_BITS+15:1] p_addr;
  logic [NP-1:0][15:0] p_din;
  logic [NP-1:0][1:0]  p_be;
  logic [NP-1:0][63:0] p_dout;
  logic [NP-1:0]       dbg_req, dbg_grant;

  // Indexed rather than concatenated: a concatenation silently renumbers every
  // port when one is added, and the width mismatch that follows is reported
  // against the assignment, not against the port that moved.
  always_comb begin
    p_req  = '0;  p_we = '0;  p_addr = '0;  p_din = '0;  p_be = '1;
    p_req[0] = p0_req; p_req[1] = p1_req; p_req[2] = p2_req; p_req[3] = p3_req;
    p_req[4] = p4_req; p_req[5] = p5_req; p_req[6] = p6_req; p_req[7] = p7_req;
    p_req[8] = p8_req; p_req[9] = p9_req;
    p_addr[0] = p0_addr; p_addr[1] = p1_addr; p_addr[2] = p2_addr;
    p_addr[3] = p3_addr; p_addr[4] = p4_addr; p_addr[5] = p5_addr;
    p_addr[6] = p6_addr; p_addr[7] = p7_addr; p_addr[8] = p8_addr;
    p_addr[9] = p9_addr;
    p_we[0]  = p0_we;
    p_din[0] = p0_din;
    p_be[0]  = p0_be;
  end

  assign p0_ack = p_ack[0]; assign p1_ack = p_ack[1]; assign p2_ack = p_ack[2];
  assign p3_ack = p_ack[3]; assign p4_ack = p_ack[4]; assign p5_ack = p_ack[5];
  assign p6_ack = p_ack[6]; assign p7_ack = p_ack[7]; assign p8_ack = p_ack[8];
  assign p9_ack = p_ack[9];
  assign p0_dout = p_dout[0];
  assign p1_dout = p_dout[1];
  assign p2_dout = p_dout[2];
  assign p3_dout = p_dout[3];
  assign p4_dout = p_dout[4];
  assign p5_dout = p_dout[5];
  assign p6_dout = p_dout[6];
  assign p7_dout = p_dout[7];
  assign p8_dout = p_dout[8];
  assign p9_dout = p_dout[9];

  logic        cke, cs_n, ras_n, cas_n, we_n;
  logic [1:0]  ba, dqm;
  logic [12:0] a;
  logic [15:0] dq_c2m, dq_m2c;
  logic        dq_oe_c, dq_oe_m;

  m2_sdram #(
    .COL_BITS(COL_BITS),
    .NP(NP), .T_RCD(T_RCD), .T_RP(T_RP), .T_RC(T_RC), .T_RAS(T_RAS),
    .T_WR(T_WR), .CL(CL), .T_REFI(T_REFI), .INIT_NOP(INIT_NOP), .ACK_HOLD(2)
  ) dut (
    .clk(clk), .rst_n(rst_n), .ready(ready),
    // CL+3, what the device MODEL needs, and after the selector range moved
    // earlier for the board that is selector 3, not 0. The renumbering broke
    // this test immediately -- 23,744 mismatches -- which is the harness doing
    // its job: the model's correct value is not the board's.
    .rd_lat_sel(3'd3),
    .sd_cke(cke), .sd_cs_n(cs_n), .sd_ras_n(ras_n), .sd_cas_n(cas_n),
    .sd_we_n(we_n), .sd_ba(ba), .sd_a(a), .sd_dqm(dqm),
    .sd_dq_o(dq_c2m), .sd_dq_oe(dq_oe_c), .sd_dq_i(dq_m2c),
    .wr_req(wr_req), .wr_addr(wr_addr), .wr_din(wr_din), .wr_be(wr_be),
    .wr_ack(wr_ack),
    .p_req(p_req), .p_we(p_we), .p_addr(p_addr), .p_din(p_din), .p_be(p_be),
    .p_dout(p_dout), .p_ack(p_ack),
    .dbg_req(dbg_req), .dbg_grant(dbg_grant)
  );

  // The same timing numbers, so the checker is checking the clock the
  // controller was built for.
  // THE MODEL TAKES THE SAME COL_BITS AS THE CONTROLLER, AND THAT IS A BLIND
  // SPOT, not an oversight to fix here: a geometry mismatch with the REAL part
  // is invisible to this suite, because the model and the controller agree with
  // each other while both are wrong about the board. 74,729 checks passed at
  // COL_BITS=11 while the hardware aliased.
  //
  // This is the trap docs/differential-testing.md names: a reference written
  // from the same reading as the implementation catches a slip between the two,
  // never a shared misreading. Geometry can only be settled on hardware.
  sdram_model #(
    .COL_BITS(COL_BITS),
    .T_RCD(T_RCD), .T_RP(T_RP), .T_RC(T_RC), .T_RAS(T_RAS), .T_WR(T_WR),
    .CL(CL), .T_REFI(781), .REFI_SLACK(9)
  ) device (
    .clk(clk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n),
    .we_n(we_n), .ba(ba), .a(a), .dqm(dqm),
    .dq_i(dq_c2m), .dq_oe_i(dq_oe_c),
    .dq_o(dq_m2c), .dq_oe_o(dq_oe_m),
    .violations(violations), .v_flags(v_flags),
    .reads_served(reads_served), .writes_served(writes_served)
  );

  bw_monitor #(.MASTERS(NP), .CW(24), .BW(8)) mon (
    .clk(clk), .rst_n(rst_n),
    .req(dbg_req), .grant(dbg_grant),
    .snap(mon_snap), .sel(mon_sel[2:0]),
    .req_count(mon_req), .grant_count(mon_grant), .wait_count(mon_wait),
    .burst_max(mon_bmax), .total_cycles(mon_total)
  );

endmodule
