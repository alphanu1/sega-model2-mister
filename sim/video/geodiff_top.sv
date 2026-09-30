// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// THE GEOMETRY DIFFERENTIAL'S DEVICE UNDER TEST (R643): the walker, the
// projection and the geometry, joined exactly as Model2.sv joins them, with
// the memories left to the bench. The bench serves them from one walk's dump
// out of MAME (patch p14) and compares every quad with the polygons MAME kept
// for that walk. The rasteriser differential (R615) starts from MAME's
// projected polygons, so everything upstream of it -- transform, lighting,
// clip, projection, texture coordinates, headers, z -- is what this checks.

`timescale 1ns/1ps

module geodiff_top #(
  parameter int unsigned AW = 25
) (
  input  logic        clk,
  input  logic        rst_n,
  // the pointer write that starts a walk (m2_geo's front door)
  input  logic        wr_setrp,
  input  logic [31:0] wdata,
  input  logic        frame_start,
  // bufferram reads (dword index), and the walk's own writes (polygon/texture RAM)
  output logic        rd_req,
  output logic [18:0] rd_addr,
  input  logic [31:0] rd_data,
  input  logic        rd_ack,
  output logic        sd_wr_req,
  output logic [AW:1] sd_wr_addr,
  output logic [15:0] sd_wr_din,
  input  logic        sd_wr_ack,
  // the engine's reads, with the object's memory select as Model2.sv latches it
  output logic        mem_req,
  output logic [23:0] mem_addr,
  output logic [1:0]  mem_space,
  output logic [31:0] obj_oba_r,
  input  logic [31:0] mem_data,
  input  logic        mem_ack,
  // quads out
  output logic        q_valid,
  input  logic        q_ready,
  output logic signed [15:0] q_x0, q_y0, q_x1, q_y1, q_x2, q_y2, q_x3, q_y3,
  output logic [15:0] q_frac,
  output logic [12:0] q_u0, q_v0, q_u1, q_v1, q_u2, q_v2, q_u3, q_v3,
  output logic [23:0] q_tex,
  output logic [23:0] q_col,
  output logic [31:0] q_z,
  output logic [7:0]  q_lum,
  output logic [15:0] q_oz0, q_oz1, q_oz2, q_oz3,
  // what the walk and the engine counted
  output logic [15:0] walk_ops, walk_objs, walk_frames, mtx_n, foc_n, lit_n, tp_n,
  output logic [7:0]  walk_unknown,
  output logic [15:0] polys, objects, culled, clip_in, clip_out, clip_dropped, n_nonfinite, behind
);

  localparam logic [AW:1] GAME_BUFFER = AW'(32'h16f0000);
  localparam logic [AW:1] GAME_PRAM0  = AW'(32'h1710000);
  localparam logic [AW:1] GAME_PRAM1  = AW'(32'h1720000);
  localparam logic [AW:1] GAME_TEXRAM = AW'(32'h1740000);

  logic        mat_we;
  logic [3:0]  mat_idx;
  logic [31:0] mat_data, foc_x, foc_y, obj_oba, obj_obc, obj_tha, obj_tpa;
  logic        obj_valid, eng_busy;
  logic [31:0] lit_x, lit_y, lit_z;
  logic        tp_we;
  logic [4:0]  tp_idx;
  logic [7:0]  tp_diffuse, tp_ambient, zadj_e;
  logic [31:0] win_vp_s, win_vp_e, win_c0;
  logic [31:0] xc, yc, a_left, a_right, a_bottom, a_top;

  m2_geo #(.AW(AW), .DEPTH(128)) u_geo (
    .clk(clk), .rst_n(rst_n),
    .wr_ctl(1'b0), .wr_setwp(1'b0), .wr_setrp(wr_setrp),
    .trig_mode(2'd0),
    .wr_push(1'b0), .wdata(wdata),
    .rd_wp(), .rd_rp(),
    .base_buffer(GAME_BUFFER),
    .sd_wr_req(sd_wr_req), .sd_wr_addr(sd_wr_addr), .sd_wr_din(sd_wr_din),
    .sd_wr_ack(sd_wr_ack), .sd_busy(),
    .dbg_pushes(), .dbg_dropped(),
    .dbg_geocnt(), .dbg_geoctl(),
    .frame_start(frame_start),
    .rd_req(rd_req), .rd_addr(rd_addr), .rd_data(rd_data), .rd_ack(rd_ack),
    .dbg_walk_ops(walk_ops), .dbg_walk_objs(walk_objs),
    .dbg_walk_frames(walk_frames), .dbg_walk_unknown(walk_unknown),
    .dbg_walk_state(),
    .dbg_rp(), .dbg_wp(),
    .mtx0(), .mtx4(), .mtx8(), .mtx11(),
    .mat_we(mat_we), .mat_idx(mat_idx), .mat_data(mat_data),
    .eng_busy(eng_busy),
    .base_pram0(GAME_PRAM0), .base_pram1(GAME_PRAM1),
    .base_texram(GAME_TEXRAM), .dbg_td_words(),
    .dbg_pd_words(), .dbg_pd_cmds(),
    .foc_x(foc_x), .foc_y(foc_y),
    .zadj_e(zadj_e),
    .win_vp_s(win_vp_s), .win_vp_e(win_vp_e), .win_c0(win_c0), .win_cnt(),
    .lit_x(lit_x), .lit_y(lit_y), .lit_z(lit_z),
    .dbg_lit_n(lit_n), .dbg_nops(),
    .dbg_walk_flip(), .dbg_walk_fallback(), .push_stall(),
    .skip(2'd0),   // R699
    .dbg_overtake(),
    .tp_we(tp_we), .tp_idx(tp_idx),
    .tp_diffuse(tp_diffuse), .tp_ambient(tp_ambient),
    .dbg_tp_n(tp_n),
    .obj_tpa(obj_tpa), .obj_tha(obj_tha), .obj_oba(obj_oba), .obj_obc(obj_obc),
    .obj_valid(obj_valid),
    .dbg_mtx_n(mtx_n), .dbg_foc_n(foc_n)
  );

  m2_geo_view #(.CRTC_X(0), .CRTC_Y(128)) u_view (
    .clk(clk), .rst_n(rst_n),
    .win_vp_s(win_vp_s), .win_vp_e(win_vp_e), .win_c0(win_c0),
    .xc(xc), .yc(yc), .a_left(a_left), .a_right(a_right),
    .a_bottom(a_bottom), .a_top(a_top)
  );

  always_ff @(posedge clk) if (obj_valid) obj_oba_r <= obj_oba;

  m2_geometry u_geometry (
    .clk(clk), .rst_n(rst_n),
    .start(obj_valid), .oba(obj_oba), .obc(obj_obc), .busy(eng_busy),
    .mat_we(mat_we), .mat_idx(mat_idx), .mat_data(mat_data),
    .foc_x(foc_x), .foc_y(foc_y),
    .mem_req(mem_req), .mem_addr(mem_addr),
    .mem_data(mem_data), .mem_ack(mem_ack),
    .xc(xc), .yc(yc),
    .a_left(a_left), .a_right(a_right),
    .a_bottom(a_bottom), .a_top(a_top),
    .tha(obj_tha), .tpa(obj_tpa), .lit_x(lit_x), .lit_y(lit_y), .lit_z(lit_z),
    .tp_we(tp_we), .tp_idx(tp_idx), .tp_diffuse(tp_diffuse), .tp_ambient(tp_ambient),
    .col_inval(1'b0), .tex_lum(2'd2), .gamma_sel(2'd2), .mem_space(mem_space), .dbg_col_miss(),
    .q_valid(q_valid), .q_ready(q_ready),
    .q_x0(q_x0), .q_y0(q_y0), .q_x1(q_x1), .q_y1(q_y1),
    .q_x2(q_x2), .q_y2(q_y2), .q_x3(q_x3), .q_y3(q_y3),
    .q_oz0(q_oz0), .q_oz1(q_oz1), .q_oz2(q_oz2), .q_oz3(q_oz3),
    .q_u0(q_u0), .q_v0(q_v0), .q_u1(q_u1), .q_v1(q_v1),
    .q_u2(q_u2), .q_v2(q_v2), .q_u3(q_u3), .q_v3(q_v3),
    .q_tex(q_tex), .q_lum(q_lum),
    .q_frac(q_frac),
    .q_col(q_col), .q_z(q_z),
    .dbg_polys(polys), .dbg_objects(objects), .dbg_capped(),
    .dbg_culled(culled),
    .dbg_clip_in(clip_in), .dbg_clip_out(clip_out),
    .dbg_clip_dropped(clip_dropped), .dbg_nonfinite(n_nonfinite), .dbg_behind(behind), .zadj_e(zadj_e),
    .dbg_lum_go(), .dbg_lum(),
    .dbg_pj_lost(),
    .dbg_eng_state(), .dbg_qst(),
    .dbg_clip_state()
  );

endmodule
