// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// R881: STAND-INS FOR fx68k AND m2_scsp, so tb_m2_sdram_cdc_load runs the REAL
// m2_2a_sound -- its bus state machine, the line cache, R871's read-merge-write,
// R877's posted writes, the snoop, the b_/c_ address maps -- against the real
// m2_sdram_cdc and m2_sdram. Only built into that bench (they take the real
// modules' names and port lists, so they cannot share a build with them).
//
//   fx68k    a bus master whose cycles the C++ chooses (DPI c68_step): AS, the
//            data strobes, R/W, the address and the write data, registered;
//            DTACK and the read data handed back. Never an interrupt cycle.
//   m2_scsp  the two SDRAM clients of the real SCSP, each with the REAL
//            m2_scsp_cache: the slot fetch (m2_scsp's G_L1 / G_W1 / G_F1 for one
//            pick, the line chosen by DPI c6_step, each hit reported by c6_hit)
//            and the DSP's memory side (m2_scsp_dsp's R_LOOK / R_FILL / R_AGAIN,
//            w_pend / w_out / gap and the m_req mux, copied; each step's read
//            and write chosen by c7_step, each read's word reported by c7_read;
//            NOFL words only -- PACK / UNPACK are arithmetic, not memory).
//            The 68000's register port answers three clocks after its pulse.

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
module fx68k (
  input  clk,
  input  HALTn,
  input  extReset,
  input  pwrUp,
  input  enPhi1, enPhi2,
  output eRWn, output ASn, output LDSn, output UDSn,
  output logic E, output VMAn,
  output FC0, output FC1, output FC2,
  output BGn,
  output oRESETn, output oHALTEDn,
  input  DTACKn, input VPAn,
  input  BERRn,
  input  BRn, BGACKn,
  input  IPL0n, input IPL1n, input IPL2n,
  input  [15:0] iEdb, output [15:0] oEdb,
  output [23:1] eab
);
  import "DPI-C" function void c68_step(input bit rst, input bit dtackn, input int iedb,
                                        output bit asn, output bit rwn, output bit udsn, output bit ldsn,
                                        output int a, output int d);
  logic        asn_r, rwn_r, udsn_r, ldsn_r;
  logic [23:1] a_r;
  logic [15:0] d_r;
  always_ff @(posedge clk) begin
    bit as_, rw_, ud_, ld_;
    int a_, d_;
    c68_step(extReset, DTACKn, int'(iEdb), as_, rw_, ud_, ld_, a_, d_);
    asn_r <= as_; rwn_r <= rw_; udsn_r <= ud_; ldsn_r <= ld_;
    a_r <= a_[23:1]; d_r <= d_[15:0];
  end
  assign ASn = asn_r; assign eRWn = rwn_r; assign UDSn = udsn_r; assign LDSn = ldsn_r;
  assign eab = a_r; assign oEdb = d_r;
  assign {FC2, FC1, FC0} = 3'b101;          // supervisor data: never an acknowledge
  assign E = 1'b0; assign VMAn = 1'b1; assign BGn = 1'b1; assign oRESETn = 1'b1; assign oHALTEDn = 1'b1;
endmodule

module m2_scsp #(
  parameter bit FM        = 1'b1,
  parameter bit MIDI_OUT  = 1'b1,
  parameter bit LFO_NOISE = 1'b1
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        cpu_req,
  input  logic        cpu_we,
  input  logic [11:1] cpu_addr,
  input  logic [15:0] cpu_din,
  input  logic  [1:0] cpu_be,
  output logic        cpu_ack,
  output logic [15:0] cpu_dout,
  output logic  [2:0] ipl,
  input  logic  [7:0] midi_data,
  input  logic        midi_valid,
  output logic        midi_ack,
  output logic  [7:0] mout_data,
  output logic        mout_valid,
  input  logic        mout_ack,
  output logic        sm_req,
  output logic [15:0] sm_line,
  input  logic        sm_ack,
  input  logic [63:0] sm_data,
  output logic        dm_req,
  output logic        dm_we,
  output logic [18:1] dm_addr,
  output logic [15:0] dm_wdata,
  input  logic        dm_ack,
  input  logic [63:0] dm_data,
  input  logic        snp,
  input  logic [18:1] snp_addr,
  input  logic        out_ready,
  output logic        out_valid,
  output logic signed [31:0] out_l_raw, out_r_raw,
  output logic signed [15:0] out_l, out_r,
  input  logic        tick44,
  input  logic  [5:0] tph,              // (the timers' phase, R883: unused here)
  input  logic        cpu_tick,         // (the 68000's sample boundary, R885: unused here)
  input  logic        step_mode,
  input  logic        step_go,
  output logic        quiet,
  output logic        dbg_slot_valid,
  output logic  [4:0] dbg_slot,
  output logic signed [31:0] dbg_slot_smp,
  output logic [31:0] dbg_samples,
  output logic [31:0] dbg_miss,
  output logic  [3:0] dbg_mvol
);
  import "DPI-C" function void c6_step(input bit rst, output bit go, output int line);
  import "DPI-C" function void c6_hit(input int line, input longint data);
  import "DPI-C" function void c7_step(input bit rst, input bit idle, output bit go, output bit rd, output bit wr,
                                       output int addr, output int wdata);
  import "DPI-C" function void c7_read(input int addr, input int word);

  // ---- the 68000's register port
  logic [2:0] cp;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) cp <= '0;
    else cp <= {cp[1:0], cpu_req};
  end
  assign cpu_ack = cp[2];
  assign cpu_dout = 16'h0000;
  assign ipl = 3'd0;
  assign midi_ack = 1'b0; assign mout_data = 8'd0; assign mout_valid = 1'b0;
  assign out_valid = 1'b0; assign out_l_raw = '0; assign out_r_raw = '0; assign out_l = '0; assign out_r = '0;
  assign quiet = 1'b1; assign dbg_slot_valid = 1'b0; assign dbg_slot = '0; assign dbg_slot_smp = '0;
  assign dbg_samples = '0; assign dbg_mvol = '0;

  // ---- the DSP's write, for the slot cache's second snoop (m2_scsp: dsp_wr_done / dsp_wr_addr)
  logic        wr_done;
  logic [18:1] w_a;

  // ================================================== the slot fetch (m2_scsp)
  typedef enum logic [1:0] { G_IDLE, G_L1, G_W1, G_F1 } gst_t;
  gst_t        gs;
  logic [15:0] fl;                          // fa1[18:3]
  logic        lk_req, lk_hit, fill_req, fill_done;
  logic [63:0] lk_data;
  assign lk_req   = gs == G_L1;
  assign fill_req = gs == G_F1;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin gs <= G_IDLE; fl <= '0; end
    else begin
      case (gs)
        G_IDLE: begin
          bit g; int l;
          c6_step(1'b0, g, l);
          if (g) begin fl <= l[15:0]; gs <= G_L1; end
        end
        G_L1: gs <= G_W1;
        G_W1: if (lk_hit) begin c6_hit(int'(fl), longint'(lk_data)); gs <= G_IDLE; end else gs <= G_F1;
        G_F1: if (fill_done) gs <= G_L1;
        default: gs <= G_IDLE;
      endcase
    end
  end
  m2_scsp_cache #(.IDX(8)) u_cache (
    .clk(clk), .rst_n(rst_n),
    .lk_req(lk_req), .lk_line(fl), .lk_hit(lk_hit), .lk_data(lk_data),
    .fill_req(fill_req), .fill_line(fl), .fill_done(fill_done), .fill_data(),
    .m_req(sm_req), .m_line(sm_line), .m_ack(sm_ack), .m_data(sm_data),
    .snp(snp), .snp_line(snp_addr[18:3]), .snp2(wr_done), .snp2_line(w_a[18:3]),
    .dbg_fills(dbg_miss)
  );

  // ================================================ the DSP's memory (m2_scsp_dsp)
  // op_v is m2_scsp_dsp's ph 4 of a step with MRD and / or MWT (mem_now), which
  // it reaches only once mv_pend and w_pend are clear (its `stall`).
  logic        op_v, op_rd, op_wr;
  logic [18:1] op_a;
  logic [15:0] op_d;
  logic        mv_pend, w_pend, w_out, gap, wr_snp;
  logic [15:0] w_d;
  logic [18:1] r_a;
  typedef enum logic [1:0] { R_IDLE, R_LOOK, R_FILL, R_AGAIN } rst_t;
  rst_t        rs;
  logic        r_lk_req, r_lk_hit, r_fill_done, c_mreq;
  logic [15:0] r_lk_line, c_mline;
  logic [63:0] r_lk_data;
  always_comb begin
    r_lk_req  = (op_v && op_rd) || rs == R_AGAIN;
    r_lk_line = (rs == R_AGAIN) ? r_a[18:3] : op_a[18:3];
  end
  m2_scsp_cache #(.IDX(6)) u_rcache (
    .clk(clk), .rst_n(rst_n),
    .lk_req(r_lk_req), .lk_line(r_lk_line), .lk_hit(r_lk_hit), .lk_data(r_lk_data),
    .fill_req(rs == R_FILL), .fill_line(r_a[18:3]), .fill_done(r_fill_done), .fill_data(),
    .m_req(c_mreq), .m_line(c_mline), .m_ack(dm_ack && !w_out), .m_data(dm_data),
    .snp(snp), .snp_line(snp_addr[18:3]), .snp2(wr_snp), .snp2_line(w_a[18:3]),
    .dbg_fills()
  );
  always_comb begin
    dm_we = w_out; dm_wdata = w_d;
    dm_addr = w_out ? w_a : {c_mline, 2'b00};
    dm_req = !gap && (w_out || c_mreq);
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      op_v <= 1'b0; op_rd <= 1'b0; op_wr <= 1'b0; op_a <= '0; op_d <= '0;
      mv_pend <= 1'b0; w_pend <= 1'b0; w_out <= 1'b0; gap <= 1'b0; wr_snp <= 1'b0; wr_done <= 1'b0;
      w_a <= '0; w_d <= '0; r_a <= '0; rs <= R_IDLE;
    end else begin
      wr_done <= 1'b0; wr_snp <= 1'b0;
      gap <= dm_req && dm_ack;
      // (m2_scsp_dsp: a write goes out once no read is in flight)
      if (w_out && dm_ack) begin w_out <= 1'b0; w_pend <= 1'b0; wr_done <= 1'b1; end
      else if (w_pend && !w_out && !mv_pend && !gap) begin w_out <= 1'b1; wr_snp <= 1'b1; end
      case (rs)
        R_LOOK: begin
          if (r_lk_hit) begin
            c7_read(int'(r_a), int'(r_lk_data[{r_a[2:1], 4'b0} +: 16]));
            mv_pend <= 1'b0; rs <= R_IDLE;
          end else rs <= R_FILL;
        end
        R_FILL: if (r_fill_done) rs <= R_AGAIN;
        R_AGAIN: rs <= R_LOOK;
        default: ;
      endcase
      // ph 4
      op_v <= 1'b0;
      if (op_v) begin
        if (op_rd) begin r_a <= op_a; rs <= R_LOOK; mv_pend <= 1'b1; end
        if (op_wr) begin w_pend <= 1'b1; w_a <= op_a; w_d <= op_d; end
      end else if (!mv_pend && !w_pend) begin
        bit g, r, w; int a, d;
        c7_step(1'b0, 1'b1, g, r, w, a, d);
        op_v <= g; op_rd <= r; op_wr <= w; op_a <= a[17:0]; op_d <= d[15:0];
      end
    end
  end
endmodule
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on DECLFILENAME */
