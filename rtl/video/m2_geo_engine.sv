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
// THE POLYGON SEQUENCER: an object_data command becomes a stream of quads.
//
// This is the block Model 1 could not supply. Its arithmetic transfers -- see
// study R170 and THIRD_PARTY.md, m2_geo_xform and the rest are its stages
// unmodified -- but the STREAM GRAMMAR is Model 2's own, so this is written
// here against model2_v.cpp's geo_parse_np_ns and model2_3d_push.
//
// The grammar is transcribed in study R171 and the two things that make it
// awkward are both here:
//
//   1. THE LINK IS NOT A STRIP. Which pair of vertices the next polygon
//      inherits is a field in the attribute word, (attr >> 8) & 3, with three
//      different carries. A sequencer written for a plain triangle strip is
//      correct for types 0 and 2 and silently wrong for 1 and 3, and the
//      failure is geometry that looks plausible everywhere and is right
//      nowhere.
//
//   2. A TRIANGLE STILL CONSUMES THE POINT IT DOES NOT USE. `input += 3` in
//      the reference. Skipping the read instead of consuming it desynchronises
//      the stream, which reads as a corrupt object rather than as a bug here --
//      the same failure mode the display-list walk had twice.
//
// FLAT FIRST, AND DELIBERATELY. The normal is read and stepped over but not
// transformed: it exists only to compute luminance and the texture LOD, and the
// ported rasterizer takes a single 24-bit colour with no texture input at all.
// So flat is the natural first target rather than a simplification that has to
// be undone -- lighting and texture add stages beside this one without changing
// the stream logic. Vertices leave here TRANSFORMED but still floating point;
// the screen conversion is fp_to_int's job downstream.
//
// THE MEMORY PORT IS SHARED WITH THE WALK, AND THAT IS SAFE HERE FOR A REASON
// WORTH STATING. m2_geo's walk stops while an object is fetched -- one state
// machine, strictly sequential, never two requests in flight. That is NOT the
// arrangement that cost this project four days (R167): there the coprocessor
// and the walker were INDEPENDENT owners of one port and their transactions
// overlapped. Sequential sharing by a single requester is fine; concurrent
// sharing by two is not. Do not "optimise" this into overlap.

`timescale 1ns/1ps

module m2_geo_engine #(
  // A CEILING ON POLYGONS PER OBJECT, AND IT IS A DEVIATION ON PURPOSE.
  //
  // "if count == 0 then rolls over to max size" gives 0xfffff -- 1,048,575
  // polygons. At roughly 120 cycles each (four vertices through a 29-cycle
  // reciprocal, plus the clipper) that is 126 M cycles, 2.5 SECONDS at 50 MHz,
  // with the display-list walk stopped behind it. The picture would freeze and
  // look like a hang.
  //
  // It matters because an object pointed at polygon RAM reads unwritten SDRAM
  // today: opcode 0x05 geo_polygon_data is not implemented, so those reads
  // return 0xFFFF... , whose low two bits are 3 -- never the terminator. A
  // single such object runs to the ceiling.
  //
  // 4096 is well past any real Model 2 object and costs 8 ms in the worst case.
  // dbg_capped counts objects that hit it, so this is a number on the debug
  // stream rather than a silent truncation.
  parameter int MAX_POLYS = 4096
) (
  input  logic        clk,
  input  logic        rst_n,

  // ---- from the walker, when an object_data's four operands are in
  input  logic        start,
  input  logic [31:0] oba,            // object address, selects ROM or RAM
  input  logic [31:0] obc,            // object count; 0 means run to the end
  output logic        busy,

  // ---- the matrix, passed through to the transform stage
  input  logic        mat_we,
  input  logic [3:0]  mat_idx,
  input  logic [31:0] mat_data,

  // ---- the vertex stream. One dword per acknowledge, address in dwords.
  output logic        mem_req,
  output logic [23:0] mem_addr,
  input  logic [31:0] mem_data,
  input  logic        mem_ack,

  // ---- the projection. Model 2 has NO perspective divide: apply_focus is
  //      x *= focus.x, y *= focus.y and the result IS the screen coordinate,
  //      as a float. Study R172, and it is why m2_geo_project -- Model 1's
  //      divide-by-z -- is not in this pipeline.
  input  logic [31:0] foc_x, foc_y,

  // ---- R222: WHAT THE POLYGON'S COLOUR NEEDS. The reference's flat colour is
  //      palette entry 0x1000 + colorbase (texture header word 3 >> 6, 10
  //      bits), each 5-bit component run through the colour translation table
  //      at (component << 8 | luma >> 2), then the gamma curve. The luminance
  //      is |normal . light| (0 if that and normal . point differ in sign)
  //      times the texture parameter's diffuse plus its ambient, 0..255.
  input  logic [31:0] tha,                 // geo_object_data's texture header address
  input  logic [31:0] lit_x, lit_y, lit_z, // the light vector (cmd 0x0a)
  input  logic        tp_we,               // texture parameters (cmd 0x06), streamed
  input  logic [4:0]  tp_idx,
  input  logic [7:0]  tp_diffuse, tp_ambient,
  input  logic        col_inval,           // the CPU wrote the palette or the table
  // R239: how bright a textured polygon's placeholder is, 0..3 = the polygon's
  // full luminance, three quarters, half, a quarter. An OSD option, because the
  // reference scales the polygon's luminance by each TEXEL's own and we have no
  // texels: full was judged too bright on the board, half was never judged, and
  // a build per guess is the wrong instrument. The board decides.
  input  logic [1:0]  tex_lum,
  // Which memory the read is for: 0 polygon memory (as ever), 1 texture
  // (mem_addr[23]: texture RAM rather than ROM), 2 the palette mirror, 3 the
  // translation table mirror. All dword-addressed; the top level owns the bases.
  output logic [1:0]  mem_space,
  output logic [23:0] poly_col,            // the polygon's colour, lit, gamma applied
  // R246: WHICH DEPTH THIS POLYGON SORTS BY. model2_v.cpp picks it per polygon
  // from the attribute word -- 0 reuses the previous polygon's, 1 the minimum
  // vertex z, 2 the maximum, 3 a literal 1e10 -- and this core used the
  // minimum for every polygon.
  output logic  [1:0] poly_zmode,
  output logic [7:0]  poly_luma,           // its luminance, for the bench
  output logic [15:0] dbg_col_miss,        // colour cache misses

  // ---- a SECOND pool client, for those two multiplies. The pool exists to be
  //      shared (m2_fp_pool); muxing them onto the transform's port here would
  //      rebuild a private arbiter next to a general one.
  output logic        fmul_req,
  output logic [31:0] fmul_a, fmul_b,
  input  logic        fmul_gnt, fmul_rsp,
  input  logic [31:0] fmul_res,
  // R219: the face test's adder, the pool's slot the geometry had tied off.
  output logic        fadd_req,
  output logic [31:0] fadd_a, fadd_b,
  input  logic        fadd_gnt, fadd_rsp,
  input  logic [31:0] fadd_res,

  // ---- the shared arithmetic, forwarded to m2_geo_xform
  output logic        mul_req,
  output logic [31:0] mul_a, mul_b,
  input  logic        mul_gnt, mul_rsp,
  input  logic [31:0] mul_res,
  output logic        add_req,
  output logic [31:0] add_a, add_b,
  output logic        add_sub,
  input  logic        add_gnt, add_rsp,
  input  logic [31:0] add_res,

  // ---- one polygon out, four vertices, still floating point
  output logic        poly_valid,
  input  logic        poly_ready,
  output logic [31:0] v0x, v0y, v0z,
  output logic [31:0] v1x, v1y, v1z,
  output logic [31:0] v2x, v2y, v2z,
  output logic [31:0] v3x, v3y, v3z,
  output logic [31:0] poly_attr,
  // R217 (slimmed): the strip's carry, stated rather than searched for.
  // prev_link is the link mode of the last EMITTED polygon of this object,
  // chain_ok says that polygon was emitted (not culled, not the first) so
  // its projected pixels are the ones vertices 0 and 1 of this polygon
  // carry: default carry -> v0 = last v3, v1 = last v2; link 1 -> v0 =
  // last v2, v1 = last v1; link 3 -> v0 = last v0, v1 = last v3.
  output logic [1:0]  poly_prev_link,
  output logic        poly_chain_ok,
  // The polygon's normal, in OBJECT space -- it still needs rotating by the
  // matrix, which is transform_vector (the 3x3 without the translation row).
  output logic [31:0] nrm_x, nrm_y, nrm_z,

  output logic [15:0] dbg_polys,      // emitted this object
  output logic [15:0] dbg_objects,    // objects completed
  output logic [15:0] dbg_capped,     // objects that ran into MAX_POLYS
  output logic [15:0] dbg_culled      // R219: polygons the reference would not render
);

  // ---------------------------------------------------------------- transform
  logic        xf_in_valid, xf_in_ready, xf_out_valid;
  logic [31:0] xf_in_x, xf_in_y, xf_in_z;
  logic [31:0] xf_out_x, xf_out_y, xf_out_z;

  m2_geo_xform u_xform (
    .clk(clk), .rst_n(rst_n),
    .mat_we(mat_we), .mat_idx(mat_idx), .mat_data(mat_data),
    .in_valid(xf_in_valid), .in_ready(xf_in_ready),
    .in_x(xf_in_x), .in_y(xf_in_y), .in_z(xf_in_z),
    // 1 for points (transform_point), 0 for the polygon normal
    // (transform_vector -- the 3x3 without the translation row). MAME does
    // both with the same matrix and distinguishes them exactly this way.
    .in_translate(xf_translate),
    .mul_req(mul_req), .mul_a(mul_a), .mul_b(mul_b),
    .mul_gnt(mul_gnt), .mul_rsp(mul_rsp), .mul_res(mul_res),
    .add_req(add_req), .add_a(add_a), .add_b(add_b), .add_sub(add_sub),
    .add_gnt(add_gnt), .add_rsp(add_rsp), .add_res(add_res),
    .out_valid(xf_out_valid), .out_x(xf_out_x), .out_y(xf_out_y), .out_z(xf_out_z)
  );

  // ------------------------------------------------------------ the vertices
  //
  // Named for the reference's command_buffer slots so the mapping is checkable
  // against study R171 rather than remembered:
  //
  //   p0prev = buffer[2..4]   P0(n-1)      p1prev = buffer[5..7]   P1(n-1)
  //   p0cur  = buffer[11..13] P0(n)        p1cur  = buffer[14..16] P1(n)
  //
  // and process_polygon maps v[0]=P1(n-1), v[1]=P0(n-1), v[2]=P0(n), v[3]=P1(n)
  // -- v[0] and v[1] are SWAPPED relative to buffer order.
  logic [31:0] p0prev [3], p1prev [3], p0cur [3], p1cur [3];
  logic [31:0] attr;
  logic [23:0] ptr;
  logic [31:0] remain;
  logic [31:0] nrm [3];
  logic        xf_translate;
  assign nrm_x = nrm[0]; assign nrm_y = nrm[1]; assign nrm_z = nrm[2];

  typedef enum logic [4:0] {
    E_IDLE, E_RD, E_XF, E_XFW, E_FOC, E_FOCW, E_STORE, E_ATTR, E_NORM,
    E_NXF, E_NXFW, E_SKIP,
    E_EMIT, E_LINK, E_DONE, E_DOT, E_DOTA,
    // R222: the luminance, the texture header, the colour
    E_LUMM, E_LUMMW, E_LUMA, E_LUMAW, E_TH0, E_TH3, E_CC, E_PAL, E_XL, E_CW
  } estate_t;
  estate_t st, ret;

  logic [1:0] widx;                 // which of x,y,z is being read
  logic [31:0] xyz [3];
  logic [1:0] dst;                  // 0=p0prev 1=p1prev 2=p0cur 3=p1cur
  logic [1:0] skipn;
  logic [31:0] fx, fy, fz;   // the point, between transform and focus
  // R219: THE REFERENCE CULLS WHAT WE EMITTED. model2_v.cpp check_culling:
  // a single-sided polygon (attr bit 17 clear) whose face is the back
  // (normal . point < 0, the point being the polygon's first new vertex
  // AFTER the matrix and BEFORE the focus) is not rendered, and neither is
  // a polygon of link type 0 (attr bits 9:8). This engine emitted every
  // polygon: the back of every car and building, and the title's frames
  // carried ~5,000 quads where the reference's own peak is 4,798 records
  // "of which not all emit" (study R215/R216). The dot product is three
  // multiplies on the focus multiplier's port and two adds on the pool's
  // spare adder slot, in sequence, before E_EMIT.
  logic [31:0] dpx, dpy, dpz;      // the first new point, pre-focus
  logic [31:0] dprod [3];
  logic [1:0]  dstep, dgot;
  logic        dot_neg;
  logic        emitted_last;     // the polygon just emitted went out (R217)
  logic        fsel;         // 0 = scaling x, 1 = scaling y

  // ---- R222 state
  logic [21:0] th_w;         // texture header address, in 16-bit words
  logic        th_ram;       // ...in texture RAM (tha bit 23), else the ROM
  logic        dsel;         // E_DOT: 0 = with the point, 1 = with the light
  logic        dotp_zero;
  logic [31:0] dotl;
  logic [31:0] lum;
  logic [7:0]  luma8;
  logic [15:0] hdr0;         // texture header word 0: renderer bits 13-14
  logic [9:0]  cbase;        // header word 3 >> 6
  logic        tex_flat;     // R231: a textured polygon, drawn as lit grey until textures exist
  logic [14:0] c555;         // the palette entry
  logic [1:0]  xi;           // which component's translation is being read
  logic [7:0]  rgb [3];
  logic [23:0] xaddr;        // the extra reads: dword address, which half, which space
  logic        xhalf;
  logic [1:0]  xspace;
  logic        cc_wait;
  logic [7:0]  cc_idx;
  logic [255:0] cc_valid;
  // The texture parameters as floats, converted once when the walker streams
  // them; the colour cache: 256 entries direct-mapped on {colorbase, luma6}.
  (* ramstyle = "MLAB" *) logic [63:0] tp_tab [32];    // {ambient, diffuse}
  logic [63:0] tp_rd;
  (* ramstyle = "MLAB" *) logic [40:0] cc_mem [256];   // {textured, key, r, g, b}
  logic [40:0] cc_rd;
  wire  [16:0] cc_key = {tex_flat, cbase, luma8[7:2]};
  // R231/R234: THE PLACEHOLDER FOR A TEXTURE. The reference paints a textured
  // polygon from its texture sheet, each texel's own luma scaled by the
  // polygon's; it reads the palette for the colour base all the same. So a
  // textured polygon keeps its palette entry at the polygon's FULL luminance
  // -- the car liveries' base colours, which the board showed as right
  // before any placeholder existed -- and only where that entry is BLACK,
  // which is most of the scenery and carries no colour information at all,
  // does it take a mid grey at HALF the luminance, a mid-range texel's
  // brightness, because grey at the polygon's 255 is white on this game's
  // table. The first version greyed and halved everything and turned blue
  // cars white; the board is the oracle on this. The cache key is the same
  // as a flat polygon's plus the textured flag, so an entry that is black
  // always resolves to the same grey and the cache stays consistent.
  localparam logic [14:0] TEX_GREY = 15'h4210;
  logic [7:0] lum_x;         // the luminance the table is read at, chosen at E_PAL
  logic [1:0] tex_lum_d;     // R239: the mode last used; a change empties the cache
  function automatic logic [7:0] scale_lum(input logic [7:0] l, input logic [1:0] m);
    case (m)
      2'd0:    scale_lum = l;
      2'd1:    scale_lum = l - {2'b00, l[7:2]};   // three quarters
      2'd2:    scale_lum = {1'b0, l[7:1]};
      default: scale_lum = {2'b00, l[7:2]};
    endcase
  endfunction
  wire         cc_we  = (st == E_CW);

  // An 8-bit integer as an IEEE single.
  function automatic logic [31:0] i8f(input logic [7:0] v);
    logic [2:0] p;
    logic [31:0] m;
    begin
      p = v[7] ? 3'd7 : v[6] ? 3'd6 : v[5] ? 3'd5 : v[4] ? 3'd4
        : v[3] ? 3'd3 : v[2] ? 3'd2 : v[1] ? 3'd1 : 3'd0;
      m = {24'd0, v} << (5'd23 - {2'd0, p});
      i8f = (v == 8'd0) ? 32'd0 : {1'b0, 8'd127 + {5'd0, p}, m[22:0]};
    end
  endfunction
  // (int) of a single clamped to 0..255, as the reference's clamp then cast.
  function automatic logic [7:0] f2i8(input logic [31:0] f);
    logic [7:0] e;
    logic [31:0] m;
    begin
      e = f[30:23];
      m = {8'd0, 1'b1, f[22:0]} >> (5'd23 - 5'(e - 8'd127));
      f2i8 = f[31] ? 8'd0 : (e < 8'd127) ? 8'd0 : (e >= 8'd135) ? 8'd255 : m[7:0];
    end
  endfunction
  // The gamma curve, m2_palette's: max((v - 64) * 255 / 191, 0), truncated.
  function automatic logic [7:0] gam(input logic [7:0] v);
    logic [24:0] p;
    begin
      p = ({17'd0, (v - 8'd64)} * 25'd87496);
      gam = (v <= 8'd64) ? 8'd0 : (p[24:16] > 9'd255) ? 8'd255 : p[23:16];
    end
  endfunction
  // A header word's dword address in the texture space: RAM indexes 64 K
  // words, the ROM 4 M; mem_addr[23] says which.
  function automatic logic [23:0] th_dw(input logic [21:0] w, input logic ram);
    th_dw = ram ? {1'b1, 8'd0, w[15:1]} : {3'd0, w[21:1]};
  endfunction
  // The translation table word for component c of the palette entry at this
  // luminance: c * 0x2000 + (component5 << 8 | luma >> 2); its dword.
  function automatic logic [23:0] xl_dw(input logic [1:0] c, input logic [14:0] p, input logic [7:0] l);
    logic [4:0] c5;
    begin
      c5 = (c == 2'd0) ? p[4:0] : (c == 2'd1) ? p[9:5] : p[14:10];
      xl_dw = {10'd0, c, c5, 2'b00, l[7:3]};
    end
  endfunction

  wire xrd = (st == E_TH0) || (st == E_TH3) || (st == E_PAL) || (st == E_XL);
  assign mem_addr  = xrd ? xaddr  : ptr;
  assign mem_space = xrd ? xspace : 2'd0;
  assign poly_luma = luma8;
  assign poly_zmode = attr[11:10];             // R246: (attr >> 10) & 3

  always_ff @(posedge clk) begin
    if (tp_we) tp_tab[tp_idx] <= {i8f(tp_ambient), i8f(tp_diffuse)};
    tp_rd <= tp_tab[attr[22:18]];
    if (cc_we) cc_mem[cc_idx] <= {cc_key, rgb[0], rgb[1], rgb[2]};
    cc_rd <= cc_mem[cc_idx];
  end
  // Rising-edge acknowledge and a one-cycle request gap per word: see the
  // same note in m2_geo.sv (R207). This engine advances ptr on every
  // acknowledge and held its request across words the same way.
  logic mem_ack_d, mem_go_d;
  wire  mem_go;
  assign mem_go = mem_ack & ~mem_ack_d;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin mem_ack_d <= 1'b0; mem_go_d <= 1'b0; end
    else begin mem_ack_d <= mem_ack; mem_go_d <= mem_go; end
  end
  assign mem_req  = ~mem_go_d & ((st == E_RD) || (st == E_ATTR) || (st == E_NORM) || (st == E_SKIP) || xrd);

  assign v0x = p1prev[0]; assign v0y = p1prev[1]; assign v0z = p1prev[2];
  assign v1x = p0prev[0]; assign v1y = p0prev[1]; assign v1z = p0prev[2];
  assign v2x = p0cur[0];  assign v2y = p0cur[1];  assign v2z = p0cur[2];
  assign v3x = p1cur[0];  assign v3y = p1cur[1];  assign v3z = p1cur[2];
  assign poly_attr = attr;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= E_IDLE; ret <= E_IDLE; busy <= 1'b0; poly_valid <= 1'b0;
      dbg_capped <= 16'd0; dbg_culled <= 16'd0;
      fadd_req <= 1'b0; fadd_a <= 32'd0; fadd_b <= 32'd0; dpx <= 32'd0; dpy <= 32'd0; dpz <= 32'd0;
      dprod[0] <= 32'd0; dprod[1] <= 32'd0; dprod[2] <= 32'd0; dstep <= 2'd0; dgot <= 2'd0; dot_neg <= 1'b0;
      poly_prev_link <= 2'd0; poly_chain_ok <= 1'b0; emitted_last <= 1'b0;
      nrm[0] <= 32'd0; nrm[1] <= 32'd0; nrm[2] <= 32'd0; xf_translate <= 1'b1;
      ptr <= 24'd0; remain <= 32'd0; widx <= 2'd0; dst <= 2'd0; skipn <= 2'd0;
      attr <= 32'd0; xf_in_valid <= 1'b0;
      fmul_req <= 1'b0; fmul_a <= 32'd0; fmul_b <= 32'd0;
      fx <= 32'd0; fy <= 32'd0; fz <= 32'd0; fsel <= 1'b0;
      dbg_polys <= 16'd0; dbg_objects <= 16'd0;
      th_w <= 22'd0; th_ram <= 1'b0; dsel <= 1'b0; dotp_zero <= 1'b0; dotl <= 32'd0;
      lum <= 32'd0; luma8 <= 8'd0; hdr0 <= 16'd0; cbase <= 10'd0; c555 <= 15'd0; xi <= 2'd0;
      rgb[0] <= 8'd0; rgb[1] <= 8'd0; rgb[2] <= 8'd0;
      xaddr <= 24'd0; xhalf <= 1'b0; xspace <= 2'd0; cc_wait <= 1'b0; cc_idx <= 8'd0;
      cc_valid <= '0; poly_col <= 24'd0; dbg_col_miss <= 16'd0; tex_flat <= 1'b0; lum_x <= 8'd0; tex_lum_d <= 2'd0;
      for (int k = 0; k < 3; k++) begin
        p0prev[k] <= 32'd0; p1prev[k] <= 32'd0;
        p0cur[k]  <= 32'd0; p1cur[k]  <= 32'd0; xyz[k] <= 32'd0;
      end
    end else begin
      xf_in_valid <= 1'b0;

      case (st)
        E_IDLE: if (start) begin
          poly_chain_ok <= 1'b0; emitted_last <= 1'b0;   // R217: a new object, no carry
          // oba's low bits are the offset; which memory it selects is decoded
          // by the top level, which owns the bases.
          ptr    <= oba[23:0];
          // "if count == 0 then rolls over to max size" -- Virtual On and
          // Gunblade NY, per the reference. 0xfffff, not zero.
          remain <= ((obc == 32'd0) || (obc > 32'(MAX_POLYS)))
                    ? 32'(MAX_POLYS) : obc;
          dbg_polys <= 16'd0;
          busy   <= 1'b1;
          widx   <= 2'd0; dst <= 2'd0;
          th_w   <= tha[21:0]; th_ram <= tha[23]; dsel <= 1'b0;   // R222
          st     <= E_RD; ret <= E_RD;
        end

        // ---- read three words into xyz, then hand them to the transform
        E_RD: if (mem_go) begin
          xyz[widx] <= mem_data;
          ptr <= ptr + 24'd1;
          if (widx == 2'd2) begin widx <= 2'd0; st <= E_XF; end
          else widx <= widx + 2'd1;
        end

        // ISSUE AND WAIT ARE SEPARATE STATES, AND THAT IS NOT STYLE.
        //
        // Checking out_valid in the same state that raises in_valid latches the
        // result still standing from the PREVIOUS point -- the transform is a
        // pipelined stage and its output is valid before this one's input has
        // even been accepted. The bench caught it as every vertex being the
        // previous vertex's value, an exact one-place shift through all three
        // polygons: v2 read 200 where 400 was due, v3 read 400 where 500 was.
        E_XF: begin
          xf_in_x <= xyz[0]; xf_in_y <= xyz[1]; xf_in_z <= xyz[2];
          if (xf_in_ready) begin
            xf_in_valid <= 1'b1;
            st <= E_XFW;
          end
        end

        // The transform's result goes to the focus stage, not to a slot: a
        // vertex is not a screen coordinate until focus has been applied.
        E_XFW: if (xf_out_valid) begin
          fx <= xf_out_x; fy <= xf_out_y; fz <= xf_out_z;
          if (dst == 2'd2) begin dpx <= xf_out_x; dpy <= xf_out_y; dpz <= xf_out_z; end   // R219
          fsel <= 1'b0;
          st <= E_FOC;
        end

        // x *= focus.x, then y *= focus.y. z is untouched -- apply_focus does
        // not scale it, and the sort key downstream wants camera-space z.
        E_FOC: begin
          fmul_req <= 1'b1;
          fmul_a   <= fsel ? fy : fx;
          fmul_b   <= fsel ? foc_y : foc_x;
          if (fmul_gnt) begin fmul_req <= 1'b0; st <= E_FOCW; end
        end

        E_FOCW: if (fmul_rsp) begin
          if (!fsel) begin fx <= fmul_res; fsel <= 1'b1; st <= E_FOC; end
          else       begin fy <= fmul_res; st <= E_STORE; end
        end

        E_STORE: begin
          case (dst)
            2'd0: begin p0prev[0] <= fx; p0prev[1] <= fy; p0prev[2] <= fz;
                        dst <= 2'd1; widx <= 2'd0; st <= E_RD; end
            2'd1: begin p1prev[0] <= fx; p1prev[1] <= fy; p1prev[2] <= fz;
                        st <= E_ATTR; end
            2'd2: begin p0cur[0] <= fx; p0cur[1] <= fy; p0cur[2] <= fz;
                        if (attr[0]) begin dst <= 2'd3; widx <= 2'd0; st <= E_RD; end
                        else begin
                          // TRIANGLE: rope P1(n) = P0(n), and still CONSUME the
                          // three words of the point we do not use.
                          p1cur[0] <= fx; p1cur[1] <= fy; p1cur[2] <= fz;
                          skipn <= 2'd3; st <= E_SKIP;
                        end end
            default: begin p1cur[0] <= fx; p1cur[1] <= fy; p1cur[2] <= fz;
                           dstep <= 2'd0; dgot <= 2'd0; st <= E_DOT; end
          endcase
        end

        // ---- the attribute word terminates the object when (attr & 3) == 0
        E_ATTR: if (mem_go) begin
          attr <= mem_data;
          ptr  <= ptr + 24'd1;
          if (remain == 32'd0) begin
            // Stopped on the count, not on the terminator: either the object
            // genuinely ran out, or the stream is not an object at all.
            dbg_capped <= dbg_capped + 16'd1;
            st <= E_DONE;
          end else if (mem_data[1:0] == 2'd0) st <= E_DONE;
          else begin skipn <= 2'd3; st <= E_NORM; end
        end

        // ---- THE NORMAL IS KEPT NOW. It used to be read and thrown away,
        //      because flat shading needs no luminance and only the stream
        //      position mattered. Model 2's lighting is
        //
        //          dotl = dot(normal, light)   dotp = dot(normal, point)
        //          luminance = (dotl*dotp < 0) ? 0 : |dotl|
        //          luminance = luminance * diffuse + ambient, clamped 0..255
        //
        //      so these three words are half of every luminance the renderer
        //      will compute. They arrive in stream order x, y, z; skipn counts
        //      down from 3, so 3->x, 2->y, 1->z.
        E_NORM: if (mem_go) begin
          ptr <= ptr + 24'd1;
          case (skipn)
            2'd3: nrm[0] <= mem_data;
            2'd2: nrm[1] <= mem_data;
            default: nrm[2] <= mem_data;
          endcase
          // With all three words in, ROTATE the normal before moving on. It is
          // read in object space and every use of it -- both dot products --
          // is in view space.
          if (skipn == 2'd1) st <= E_NXF;
          else skipn <= skipn - 2'd1;
        end

        // transform_vector: the same matrix, the translation row suppressed.
        // Issue and wait are separate states for the reason E_XF/E_XFW are.
        E_NXF: begin
          xf_in_x <= nrm[0]; xf_in_y <= nrm[1];
          xf_in_z <= (skipn == 2'd1) ? mem_data : nrm[2];
          xf_translate <= 1'b0;
          if (xf_in_ready) begin
            xf_in_valid <= 1'b1;
            st <= E_NXFW;
          end
        end
        E_NXFW: begin
          xf_in_valid <= 1'b0;
          if (xf_out_valid) begin
            nrm[0] <= xf_out_x; nrm[1] <= xf_out_y; nrm[2] <= xf_out_z;
            xf_translate <= 1'b1;          // back to points
            widx <= 2'd0; dst <= 2'd2; st <= E_RD;
          end
        end

        // ---- the unused triangle point, consumed
        E_SKIP: if (mem_go) begin
          ptr <= ptr + 24'd1;
          if (skipn == 2'd1) begin dstep <= 2'd0; dgot <= 2'd0; st <= E_DOT; end
          else skipn <= skipn - 2'd1;
        end
        // ---- R219: normal . point, three multiplies then two adds; R222 runs
        //      it a second time against the light (dsel).
        E_DOT: begin
          if (dstep < 2'd3) begin
            fmul_req <= 1'b1;
            fmul_a   <= (dstep == 2'd0) ? nrm[0] : (dstep == 2'd1) ? nrm[1] : nrm[2];
            fmul_b   <= dsel ? ((dstep == 2'd0) ? lit_x : (dstep == 2'd1) ? lit_y : lit_z)
                             : ((dstep == 2'd0) ? dpx   : (dstep == 2'd1) ? dpy   : dpz);
            if (fmul_gnt) begin fmul_req <= 1'b0; dstep <= dstep + 2'd1; end
          end
          if (fmul_rsp) begin
            dprod[dgot] <= fmul_res;
            dgot <= dgot + 2'd1;
            if (dgot == 2'd2) begin dstep <= 2'd0; dgot <= 2'd0; st <= E_DOTA; end
          end
        end
        E_DOTA: begin
          if (dstep == 2'd0) begin
            fadd_req <= 1'b1; fadd_a <= dprod[0]; fadd_b <= dprod[1];
            if (fadd_gnt) begin fadd_req <= 1'b0; dstep <= 2'd1; end
          end else if (dstep == 2'd2) begin
            fadd_req <= 1'b1; fadd_a <= dprod[0]; fadd_b <= dprod[2];
            if (fadd_gnt) begin fadd_req <= 1'b0; dstep <= 2'd3; end
          end
          if (fadd_rsp) begin
            if (dstep == 2'd1) begin dprod[0] <= fadd_res; dstep <= 2'd2; end
            else if (!dsel) begin
              dot_neg   <= fadd_res[31] && (fadd_res[30:0] != 31'd0);
              dotp_zero <= (fadd_res[30:0] == 31'd0);
              dsel <= 1'b1; dstep <= 2'd0; dgot <= 2'd0; st <= E_DOT;   // R222: now the light
            end else begin
              dotl <= fadd_res; dsel <= 1'b0; st <= E_LUMM;
            end
          end
        end

        // ---- R222: luminance = (dotl*dotp < 0 ? 0 : |dotl|) * diffuse + ambient
        E_LUMM: begin
          fmul_req <= 1'b1;
          fmul_a   <= ((dotl[30:0] != 31'd0) && !dotp_zero && (dotl[31] != dot_neg))
                      ? 32'd0 : {1'b0, dotl[30:0]};
          fmul_b   <= tp_rd[31:0];                       // diffuse, as a float
          if (fmul_gnt) begin fmul_req <= 1'b0; st <= E_LUMMW; end
        end
        E_LUMMW: if (fmul_rsp) begin lum <= fmul_res; st <= E_LUMA; end
        E_LUMA: begin
          fadd_req <= 1'b1; fadd_a <= lum; fadd_b <= tp_rd[63:32];   // + ambient
          if (fadd_gnt) begin fadd_req <= 1'b0; st <= E_LUMAW; end
        end
        E_LUMAW: if (fadd_rsp) begin
          luma8  <= f2i8(fadd_res);
          xaddr  <= th_dw(th_w, th_ram); xhalf <= th_w[0]; xspace <= 2'd1;
          st     <= E_TH0;
        end

        // ---- R222: the texture header, words 0 (renderer) and 3 (colorbase);
        //      then the address steps by tho * 4, tho the signed attr[16:12].
        E_TH0: if (mem_go) begin
          hdr0  <= xhalf ? mem_data[31:16] : mem_data[15:0];
          xaddr <= th_dw(th_w + 22'd3, th_ram); xhalf <= ~th_w[0];
          st    <= E_TH3;
        end
        E_TH3: if (mem_go) begin
          cbase   <= xhalf ? mem_data[31:22] : mem_data[15:6];
          tex_flat <= hdr0[14];
          cc_idx  <= (xhalf ? mem_data[29:22] : mem_data[13:6])
                   ^ {(xhalf ? mem_data[31:30] : mem_data[15:14]), luma8[7:2]};
          cc_wait <= 1'b0;
          th_w    <= th_w + {{15{attr[16]}}, attr[16:12], 2'b00};
          if (hdr0[13]) begin
            // TRANSLUCENT, AND THE REFERENCE DRAWS NOTHING FOR IT. The texture
            // header's bit 13 is the translucent flag and bit 14 selects
            // textured; model2_3d_render picks m_render_callbacks[(h0>>13)&3]
            // and BOTH translucent entries -- draw_scanline_solid<true> and
            // draw_scanline_tex<true> -- return on their first line. This used
            // to cull only the flat one, so 16% of the title's objects (261 of
            // 1,659, textured AND translucent) were drawn here as opaque flat
            // polygons that the reference discards. Blending is not built; not
            // drawing them is what the reference does and is nearer right than
            // drawing them solid.
            remain <= remain - 32'd1;
            dbg_culled <= dbg_culled + 16'd1;
            emitted_last <= 1'b0;
            st <= E_LINK;
          end else st <= E_CC;
        end

        // ---- R222: the colour cache, then the palette and the three
        //      translation reads on a miss.
        E_CC: if (!cc_wait) cc_wait <= 1'b1;         // cc_rd is one cycle behind cc_idx
        else if (cc_valid[cc_idx] && (cc_rd[40:24] == cc_key)) begin
          poly_col <= cc_rd[23:0];
          st <= E_EMIT;
        end else begin
          dbg_col_miss <= dbg_col_miss + 16'd1;
          xaddr <= {15'd0, cbase[9:1]}; xhalf <= cbase[0]; xspace <= 2'd2;
          st <= E_PAL;
        end
        E_PAL: if (mem_go) begin
          automatic logic [14:0] pe;
          automatic logic        grey;
          automatic logic [7:0]  lu;
          pe   = xhalf ? mem_data[30:16] : mem_data[14:0];
          grey = tex_flat && (pe == 15'd0);                   // R234: no colour at all
          if (grey) pe = TEX_GREY;
          lu   = grey ? {1'b0, luma8[7:1]} : (tex_flat ? scale_lum(luma8, tex_lum) : luma8);   // R239
          c555  <= pe; lum_x <= lu;
          xi    <= 2'd0;
          xaddr <= xl_dw(2'd0, pe, lu);
          xhalf <= lu[2]; xspace <= 2'd3;
          st    <= E_XL;
        end
        E_XL: if (mem_go) begin
          rgb[xi] <= gam(xhalf ? mem_data[23:16] : mem_data[7:0]);
          if (xi == 2'd2) st <= E_CW;
          else begin xi <= xi + 2'd1; xaddr <= xl_dw(xi + 2'd1, c555, lum_x); end
        end
        E_CW: begin
          cc_valid[cc_idx] <= 1'b1;                   // cc_we writes the entry this cycle
          poly_col <= {rgb[0], rgb[1], rgb[2]};
          st <= E_EMIT;
        end

        E_EMIT: if ((attr[9:8] == 2'd0) || (dot_neg && !attr[17])) begin
          // R219: culled as the reference culls it -- link type 0, or the
          // back of a single-sided polygon. The strip carry still runs.
          remain <= remain - 32'd1;
          dbg_culled <= dbg_culled + 16'd1;
          emitted_last <= 1'b0;
          st <= E_LINK;
        end else begin
          poly_valid <= 1'b1;
          if (poly_valid && poly_ready) begin
            poly_valid <= 1'b0;
            dbg_polys  <= dbg_polys + 16'd1;
            remain     <= remain - 32'd1;
            emitted_last <= 1'b1;
            st         <= E_LINK;
          end
        end

        // ---- the carry, chosen by (attr >> 8) & 3. Study R171.
        E_LINK: begin
          poly_prev_link <= attr[9:8];
          poly_chain_ok  <= emitted_last;
          case (attr[9:8])
            2'd1: begin                     // reuse P0(n-1) and P0(n)
              p1prev[0] <= p0cur[0]; p1prev[1] <= p0cur[1]; p1prev[2] <= p0cur[2];
            end
            2'd3: begin                     // reuse P1(n-1) and P1(n)
              p0prev[0] <= p1cur[0]; p0prev[1] <= p1cur[1]; p0prev[2] <= p1cur[2];
            end
            default: begin                  // 0 and 2: reuse P0(n) and P1(n)
              p0prev[0] <= p0cur[0]; p0prev[1] <= p0cur[1]; p0prev[2] <= p0cur[2];
              p1prev[0] <= p1cur[0]; p1prev[1] <= p1cur[1]; p1prev[2] <= p1cur[2];
            end
          endcase
          st <= E_ATTR;
        end

        E_DONE: begin
          busy <= 1'b0;
          dbg_objects <= dbg_objects + 16'd1;
          st <= E_IDLE;
        end

        default: st <= E_IDLE;
      endcase
      if (col_inval) cc_valid <= '0;                 // R222: the CPU rewrote the colours
      tex_lum_d <= tex_lum;
      if (tex_lum != tex_lum_d) cc_valid <= '0;      // R239: the placeholder changed; the cached colours are stale
    end
  end

endmodule
