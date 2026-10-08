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
// TEXTURING A SPAN, one pixel at a time, between the quad filler and the band
// buffer.
//
// WHY IT SITS HERE AND NOT IN THE BAND. A band buffer writes FOUR pixels a
// cycle because a flat span is one colour repeated, and that is most of what
// makes the 3D fit its beam slot. A textured span is a different colour per
// pixel, so it cannot use that path -- but it does not have to CHANGE it
// either: a one-pixel span is a perfectly good span, and the band already
// takes one per handshake. So this unit expands a textured span into a run of
// single-pixel spans and the band is untouched, stipple and clipping included.
//
// AN UNTEXTURED SPAN PASSES STRAIGHT THROUGH, COMBINATIONALLY, AND THAT IS NOT
// AN OPTIMISATION -- IT IS A CORRECTNESS PROPERTY. Registering it instead costs
// one cycle a span, and tb_m2_raster3d caught exactly that: the reference's own
// frame painted 6,396 pixels where the frame before it painted 5,945, because
// the fill no longer finished inside its beam slot and the band went up with
// part of the picture missing. The bands are beam-paced, so latency in this
// path is not free and a flat span must cost what it always did.
//
// THE COLOUR IS THE POLYGON'S, SCALED BY THE TEXEL. The reference maps the
// texel through the luma table and then through the colour table:
//
//     luma = lumaram[lumabase + (t >> 1)] * object.luma / 256;
//     colour = gamma(colortable_{r,g,b}[(colorbase_ch << 8) | luma])
//
// which is the SAME colour ramp the flat path uses, read at an index the
// texture supplies instead of one the lighting supplies. Scaling the polygon's
// finished colour by the texel is that ramp approximated as linear. It puts
// the texture's detail and its shape on the screen with the polygon's own hue
// and lighting; what it does not reproduce is the curve of the ramp or a luma
// table that is not the identity. The exact path needs sixteen colours
// resolved per polygon -- a four-bit texel can only take sixteen values -- and
// that is a table and an allocator, not a change to this walk.

`timescale 1ns/1ps

module m2_span_tex #(
  // TWO PIXELS PER TEXEL FETCH (R279). A textured span costs a fetch and a
  // handshake per pixel, and the bands are beam-paced: at four cycles a pixel
  // a busy frame does not finish. One texel covering two pixels halves both
  // costs, and on this screen it is barely visible -- Daytona's textures are
  // magnified far more often than minified, so adjacent pixels usually share a
  // texel anyway. Set to 1 to fetch per pixel.
  // R650: UNUSED -- the step is the run-time `pxk` input. Kept so existing
  // instantiations and build scripts still elaborate.
  /* verilator lint_off UNUSEDPARAM */
  parameter int unsigned PIXSTEP = 2,
  /* verilator lint_on UNUSEDPARAM */
  // R539: texel fetches in flight; must equal m2_texel_x2's K.
  parameter int unsigned TXK = 4,
  // R607: FRONT TO BACK. A group whose pixels are all already painted this
  // band -- by a nearer polygon -- is not fetched: the reference never
  // fetches a filled pixel (model2rd.ipp: `if (fill[x] > 0) continue;`
  // before the texel). This copy of m2_raster3d's fill mask is read here; the
  // band's own check, per pixel at the write, is what keeps the picture exact,
  // so a stale or conservative answer here only costs a fetch.
  parameter bit          FTB    = 1'b0,
  // R633: HALF THE FETCHES WHILE LATE. With REUSE, a group issued while `late`
  // is high, directly after a fetched group of the same span, fetches nothing
  // and paints with its neighbour's texel -- fetch, reuse, fetch, reuse.
  // Modelled on MAME's heavy frames: with m2_texel_bl's point mode (R627)
  // it cuts the misses by 57-59% where point alone cuts 37%.
  parameter bit          REUSE  = 1'b0,
  // R616: SAMPLE EACH GROUP AT ITS CENTRE. One texel serves PIXSTEP pixels;
  // taken at the group's first pixel it lags the rest by up to PIXSTEP-1
  // pixels of gradient. 1 starts the walk (PIXSTEP-1)/2 pixels in, for u/z,
  // v/z and 1/z alike so the divide still pairs them at one point.
  parameter bit          GC     = 1'b0,
  parameter int unsigned SCR_W  = 496,
  parameter int unsigned BAND_H = 8,
  // Derived -- never overridden. PARAMETERS, not localparams: Quartus 17.0
  // rejects a localparam in the parameter port list, where Verilator takes it.
  parameter int unsigned MROW  = (SCR_W + 31) / 32,
  parameter int unsigned MDEP  = BAND_H * MROW,
  parameter int unsigned MAW   = $clog2(MDEP)
) (
  input  logic               clk,
  input  logic               rst_n,
  // R607: the fill mask -- written by m2_raster3d as the band paints.
  input  logic [MDEP-1:0]    mk_valid,
  input  logic               mk_we,
  input  logic [MAW-1:0]     mk_waddr,
  input  logic [31:0]        mk_wdata,
  input  logic signed [15:0] mk_band_y0,

  // ---- span in, from m2_raster_fill
  // R650: THE TEXEL STEP AT RUN TIME (OSD), log2 of the pixels one texel
  // serves: 0-3 for 1, 2, 4, 8. Latched with each span, so a change lands on
  // the next span and never inside one. PIXSTEP above is now unused.
  input  logic [1:0]         pxk,
  input  logic               in_valid,
  output logic               in_ready,
  input  logic signed [31:0] in_y, in_x0, in_x1,
  input  logic [23:0]        in_col,
  input  logic               in_moire,
  input  logic signed [31:0] in_u, in_v,          // quarter-texels, 16 fractional bits
  // 8.8 texels a pixel (R286), shifted up to this unit's 16.16 on the way in.
  input  logic signed [23:0] in_dudx, in_dvdx,     // R618: 16.8
  // R339: 1/z at the span's start and its gradient along x. u and v above are
  // u/z and v/z, and the texel coordinate is u = (uoz << 15) / ooz -- the
  // perspective divide, done once per PIXSTEP group.
  input  logic signed [31:0] in_ooz,
  input  logic signed [23:0] in_doozdx,
  input  logic [23:0]        in_tex,
  input  logic               in_tex_en,

  // ---- span out, to the band buffers
  // R310: A SPAN IS STILL INSIDE THIS UNIT. With a FIFO in front, the quad
  // store running dry no longer means the spans have been painted -- they can
  // still be queued or mid-fetch, and a span that outlives its band is painted
  // into the NEXT one. The band sequencer waits on this.
  output logic               busy,
  output logic               out_valid,
  input  logic               out_ready,
  output logic signed [31:0] out_y, out_x0, out_x1,
  output logic [23:0]        out_col,
  output logic               out_moire,

  // ---- the texel fetch. R539: ISSUED, NOT HELD. tx_req is a one-cycle issue
  // with its payload, taken whenever tx_rdy; answers come back in issue order
  // on tx_ack/tx_texel and are consumed with tx_take. Up to TXK in flight.
  output logic               tx_req,
  input  logic               tx_rdy,
  input  logic               tx_ack,
  output logic [31:0]        tx_tex,
  output logic [19:0]        tx_u, tx_v,
  // R620: {discard, t} from m2_texel_bl -- t is the filtered 8-bit texel and
  // discard is the reference's translucent test, made where the four texels are.
  input  logic [8:0]         tx_texel,
  output logic               tx_take,
  input  logic               late,            // R633: m2_raster3d's tex_late

  output logic [31:0]        dbg_texpix,      // textured pixels emitted
  // TEXELS THAT ARE NOT 0xF, which is the question "did the game upload its
  // textures at all". Unwritten memory reads 0xFFFF by this project's standing
  // rule, so an empty sheet returns 0xF for every texel and a textured polygon
  // comes out FLAT AND FULL BRIGHTNESS -- indistinguishable, by eye, from a
  // texture path that does nothing. tb_m2_boot sees no CPU write to either
  // sheet in 20 M instructions, so this is not a hypothetical.
  output logic [31:0]        dbg_texnz,
  // R446: kept so m2_raster3d and Model2.sv stay byte-identical to the build
  // this is being tested against. The current state costs nothing to expose;
  // the dwell counter that used to sit behind it is gone (R443).
  output logic [2:0]         dbg_hot,
  output logic [15:0]        dbg_hotcyc,
  // R554: wait_why on a port, so the board can count it (R551 made it for the
  // bench; the board's late bands are texture-bound and this says on what).
  output logic [2:0]         dbg_wait
);

  typedef enum logic [2:0] { T_IDLE, T_RUN, T_DRAIN } st_t;   // R476
  st_t st;

  // R490: TWO SETS OF THE OUTPUT-SIDE SPAN PARAMETERS, so the divide pipeline
  // never drains between spans. R488 measured the walk at 8 + 2*groups cycles,
  // and the 8 is this six-deep pipeline refilling from empty on EVERY span --
  // two thirds of the cost of a short one, and 13-26% of a band's whole
  // ~15,750-cycle budget.
  //
  // Only the OUTPUT side needs duplicating. du/dv/doz and the issue pointer are
  // finished with a span the moment its last group is issued, which is exactly
  // when the next span is now accepted, so they stay single.
  //
  // Depth two, in order: sp_iss is the span being issued, sp_out the span whose
  // groups are reaching the output, sp_n how many are in flight. No per-stage
  // tag is needed because the pipeline preserves order and sh_last already
  // marks each span's final group -- the output advances sp_out when it sees
  // one leave.
  logic signed [31:0] y_p [2], x1_p [2];
  logic [1:0]         k_p [2];      // R650: each span's pxk, latched with it
  function automatic logic signed [31:0] stp(input logic [1:0] k);
    stp = 32'sd1 <<< k;
  endfunction
  logic        sp_iss, sp_out;
  logic  [1:0] sp_n;
  logic [23:0]        col_p [2];
  logic               moire_p [2];
  // R476: u_r/v_r/ooz_r are gone -- the issue pointer walks the span and the
  // gradients are all the consumer needs.
  logic signed [31:0] du_r, dv_r;
  // R339: 1/z walks the span exactly as u and v do.
  logic signed [31:0] doz_r;
  // R539: uq_r/vq_r are gone -- the fetch takes d4_u/d4_v with its issue.
  // R433: the Newton step and the coordinate multiply, split across cycles.
  // R446: THE DIVIDE MOVES BESIDE THE FETCH INSTEAD OF IN FRONT OF IT.
  //
  // As four FSM states the walk ran T_RCP1..4 -> T_FETCH -> T_EMIT for EVERY
  // PIXSTEP group: four cycles of divide serialised ahead of every texel fetch,
  // on spans ~125 groups wide. Before orientation a group was T_FETCH ->
  // T_EMIT. That serialisation is why bands fell from 41-85% to one or two.
  //
  // 1/z is linear, so the NEXT group's value is known as soon as this one
  // starts: u_nxt/ooz_nxt below. The four stages become a pipeline clocked
  // every cycle on those, so group N+1's coordinates are computed WHILE group
  // N's texel is in flight, and the fetch never waits for a divide again.
  // Only the first group of a span pays, once, in T_WARM.

  // Clamp to a positive 32-bit value: a vertex far enough away makes the
  // coordinate enormous, and to_tx would read a wrapped one as a small texel.
  function automatic logic signed [31:0] sat32(input logic [63:0] v);
    sat32 = (v[63:31] != 33'd0) ? 32'sh7FFFFFFF : 32'(v);
  endfunction

  // R339: THE RECIPROCAL SEED, 128 ENTRIES ON THE TOP 8 BITS.
  //
  // A plain table accurate enough for half a texel needs ~12 index bits --
  // 4,096 entries, about 1,000 ALM in MLAB, and there is no M10K left at
  // 553/553. ONE NEWTON STEP buys those bits in DSP instead, which is the
  // resource with 49 blocks idle:
  //
  //     seed alone       7.8e-3   ->  2.0     texels on a 256-texel coordinate
  //     + one Newton     6.1e-5   ->  0.016   texels
  //
  // which is an order of magnitude under what the plane fit's own quantisation
  // contributes (0.02 to 0.59 texels, R338), so the divide is not the limit.
  (* ramstyle = "MLAB" *) logic [24:0] rcp_tab [128];
  initial begin
    for (int i = 0; i < 128; i++)
      rcp_tab[i] = 25'((64'd1 <<< 47) / (64'(128 + i) <<< 16));
  end

  // Where the leading one of ooz sits, so it can be normalised to [2^23, 2^24).
  function automatic logic [5:0] top_bit(input logic [31:0] v);
    logic [5:0] n;
    begin
      n = 6'd0;
      for (int i = 31; i >= 0; i--) if (v[i] && n == 6'd0) n = 6'(i);
      top_bit = n;
    end
  endfunction
  logic [23:0]        tex_p [2];
  // R476: no registered texel -- the emit uses the one that has just arrived.
  // A FETCH THAT NEVER ANSWERS MUST NOT STOP THE BAND. m2_texel has its own
  // timeout on the memory, but it also goes deaf while it sweeps its tags, and
  // this walk is inside the band fill -- a wait here is a band that never
  // completes and a picture that stops. On expiry the texel is taken as 0xF,
  // which is what unwritten memory reads anyway.
  // R539: to_cnt is gone. A fetch the cache cannot take is answered by
  // m2_texel_x2 (0xF, in order), which is where the timeout can keep order.

  // The stored coordinate is quarter-texels with sixteen fractional bits; the
  // fetch wants texels with eight, which is ten bits to the right. Negative
  // coordinates clamp to zero rather than wrapping into the top of the sheet:
  // a plane fitted through a clipped quad can step slightly outside it.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [19:0] to_tx(input logic signed [31:0] q);
    to_tx = q[31] ? 20'd0 : q[29:10];      // the fraction below bit 10 is dropped
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // R496: A REGISTER, NOT A MUX, IN FRONT OF THE CACHE'S ADDRESS PORT.
  //
  // R490 wrote this as `tex_p[fq_p]`, which put a 2:1 select on a path that
  // had been a plain register read and that lands directly on an M10K address
  // input inside m2_texel. Twenty-six of the thirty worst clk_mem paths in
  // s183 were this one:
  //
  //   m2_span_tex|tex_p[0][5] -> m2_texel|...|ram_block1a17~portb_address_reg11
  //                                                              -1.271 ns
  //
  // ahead of m2_sdram's `inflight -> state.S_SEL`, which had been the worst
  // path in every previous build of this design. Eight builds carrying R490
  // failed to run and this is why: the change made to fix the picture moved
  // the clock instead.
  //
  // The select is resolved when the fetch is ISSUED and held in one register,
  // so the cache sees exactly what it saw before R490 -- a register.

  // The texel as an intensity: 0x0 -> 0, 0xF -> 0xFF, evenly spaced.
  // R476: the emit computes its own intensity from the texel that has just
  // arrived, so there is no registered copy to derive one from.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [7:0] scale(input logic [7:0] c, input logic [7:0] i);
    logic [15:0] p;
    begin
      // (c * i + c) >> 8, so a full texel -- i = 255 -- returns c EXACTLY
      // rather than c * 255/256. Without the +c, turning textures on darkens
      // every pixel by a step even where the texture is solid.
      p = 16'(c) * 16'(i) + 16'(c);
      scale = p[15:8];
    end
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  wire tex_now = in_tex_en && in_tex[0];

  // R326: THE TRANSLUCENT TEXEL TEST, WHICH IS THE WHOLE OF MAME'S ALPHA.
  //
  // model2rd.ipp's fetch_bilinear_texel<Translucent> sets 0x00800000 on every
  // texel EXCEPT 0xf0, and draw_scanline_tex<Translucent> then does
  // `if (t < 0x00400000) continue;`. With point sampling that reduces exactly
  // to: on a translucent polygon a texel of 0xF is transparent and every other
  // value draws normally. On a NON-translucent polygon 0xF is a legitimate
  // full-brightness texel and must not be skipped -- which is why this is
  // gated on the header bit rather than applied to every span.
  //
  // Bit 8 of the packed texture word is the translucent flag (see the packing
  // in m2_geo_engine); it used to be texwrapy, which nothing read.
  //
  // Skipping costs nothing but the pixel: the walk advances identically, so a
  // fully transparent span still terminates on its own x1.
  //
  // R620: THE TEST NOW LIVES IN m2_texel_bl, which blends the four texels'
  // alphas and discards below half, as fetch_bilinear_texel does; its point
  // mode reduces to the rule above. It arrives here as bit 8 of the answer.

  wire idle    = (st == T_IDLE);
  assign busy  = !idle || e_valid;

  // The registered half, used only while a textured span is being walked.
  logic               e_valid;
  logic [23:0]        e_col;
  // THE PIXEL'S OWN x, LATCHED WITH ITS COLOUR. Taking it from the walking
  // register instead puts every pixel one to the right of where its texel came
  // from: the walk advances in the same cycle the pixel is offered, so the
  // combinational read sees the NEXT x.
  logic signed [31:0] e_x;
  // AND THE GROUP'S LAST PIXEL, REGISTERED WITH IT. Computing `min(x + PIXSTEP
  // - 1, x1)` on the way OUT puts a 32-bit add, a compare and a mux between a
  // register and the band buffer's write decode -- combinational the whole
  // way, because a flat span passes through this unit as wires. It is latched
  // here instead.
  logic signed [31:0] e_x1;
  // R490: the pixel standing at the output is its span's LAST. The span's
  // parameter set cannot be released until that pixel has been TAKEN, or out_y
  // and out_moire would switch to the next span's values while the previous
  // span's final pixel is still being presented.
  logic               e_last;

  // Flat spans go through as wires; textured pixels come from the registers.
  assign out_valid = idle ? (in_valid && !tex_now) : e_valid;
  assign out_y     = idle ? in_y     : y_p[e_p];
  assign out_x0    = idle ? in_x0    : e_x;
  // PIXSTEP wide, clipped at the span's end -- computed when the pixel is
  // formed, not when it is offered.
  assign out_x1    = idle ? in_x1 : e_x1;
  assign out_col   = idle ? in_col   : e_col;
  assign out_moire = idle ? in_moire : moire_p[e_p];

  // A flat span is accepted only when the band takes it, which is the handshake
  // the fill saw before this unit existed. A textured one is accepted at once
  // and walked from the registers.
  // R490: a FLAT span still needs the unit truly idle -- passed through as
  // wires, it would overtake the textured pixels still in the pipeline. Only a
  // textured one may be accepted on top of a draining span.
  assign in_ready  = (idle && (tex_now || out_ready)) || ld_over;
  assign dbg_hot    = st;          // R446: free, no counter behind it

  // R520: THE LONGEST STRETCH THIS UNIT WAS BUSY AND DID NOTHING.
  //
  // dbg_hotcyc has been hardwired to zero since it was declared -- its header
  // describes a longest-dwelt-state counter that was never built, the seventh
  // dead instrument found in this push. It is already routed to the top level
  // and onto the UART's Z channel, so the number that actually matters costs
  // no ports and no bandwidth.
  //
  // R490 draws on the board for three to five seconds and then the 3D stops
  // for good while the CPU and tilemap run on. That is this unit ceasing to
  // accept: a span that never completes leaves sp_n high, in_ready never
  // asserts again, the quad store's FIFO backs up and the fill can never
  // finish another band. Six simulated regimes have failed to reproduce it
  // (R513, R517, R518), so the board has to say.
  //
  // A healthy unit is sometimes busy for a long time -- a texel timeout is 511
  // cycles and a stalled band adds more -- but it always comes back. The
  // diagnostic is the MAXIMUM run of cycles spent busy while accepting nothing
  // and emitting nothing. Hundreds is normal. Saturated is wedged, and the
  // value survives the event, so one capture after the 3D dies says whether it
  // was this unit or something upstream of it.
  logic [15:0] stuck_run;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      stuck_run <= 16'd0; dbg_hotcyc <= 16'd0;
    end else begin
      if (!busy || (in_valid && in_ready) || (out_valid && out_ready))
        stuck_run <= 16'd0;
      else if (!(&stuck_run))
        stuck_run <= stuck_run + 16'd1;
      if (stuck_run > dbg_hotcyc) dbg_hotcyc <= stuck_run;
    end
  end

  // R446: the group after this one. Stable for as long as the FSM sits in
  // T_FETCH/T_EMIT, which is what lets the pipeline below settle on it.
  // R476: THE PIPELINE CARRIES SUCCESSIVE GROUPS NOW, NOT ONE HELD STILL.
  //
  // It used to be fed dv_u/dv_o = u_nxt/ooz_nxt -- the SAME next-group value,
  // recomputed every cycle while the walk sat on the current one -- and the FSM
  // waited `dv_age >= 6` for it to settle, then advanced and waited again. A
  // fixed-latency pipeline fed a constant, so nothing overlapped.
  //
  // R475 measured what that costs, with the bench answering every texel in ONE
  // cycle: **7.41 cycles per group**, which is 45,835 groups x 7.41 x 20 ns =
  // 6.8 ms of a 16.7 ms frame before any texel latency at all -- twice the
  // 3.3 ms the misses cost. The divide was the bottleneck, not the fetch, and
  // it is why R470's 60 MHz renderer bought nothing: a faster clock shortens a
  // fixed wait proportionally while the crossing it added got longer.
  //
  // So an ISSUE pointer walks the span a group per cycle into the pipeline, a
  // shadow carries each group's x alongside, and the consumer takes results as
  // they emerge. The divide's six cycles are paid once per SPAN instead of once
  // per group.
  logic signed [31:0] iss_u, iss_v, iss_ooz;
  logic signed [31:0] iss_x;
  logic               iss_run;      // still issuing groups for this span
  logic [3:0]         iss_step;     // R650: the issuing span's step, 1-8
  wire                iss_last  = (iss_x + 32'(iss_step) - 32'sd1) >= x1_p[sp_iss];

  wire signed [31:0] dv_o    = iss_ooz;
  wire signed [31:0] dv_u    = iss_u;
  wire signed [31:0] dv_v    = iss_v;

  // THE SHADOW. Six deep, matching d0..d4b, so the x that arrives with a
  // result is the x that was issued with its operands. Getting this depth
  // wrong pairs a group's coordinates with another group's position, which
  // draws a span whose texture slides along it -- and every arithmetic check
  // still passes.
  localparam int unsigned PIPE_D = 7;   // R718: d0, d1a, d1, d2, d3, d4a, d4
  logic                    sh_v    [PIPE_D];
  logic signed [31:0]      sh_x    [PIPE_D];
  logic                    sh_last [PIPE_D];
  // R490: WHICH SPAN EACH GROUP BELONGS TO. One pointer cannot serve the whole
  // tail of this pipeline: the retire stage and the output stage are separate,
  // so while span A's last pixel is being taken at the output, span B's first
  // group can already be at the retire stage being coloured. Reading both from
  // a single sp_out coloured B's groups with A's parameters -- caught by the
  // back-to-back test as 194 groups carrying the wrong span's y.
  logic                    sh_p    [PIPE_D];

  logic [2:0]  dv_age;            // kept: the span's first result still warms

  // R476: the result standing at the end of the pipeline, and the fetch slot.
  wire                res_valid = sh_v[PIPE_D-1];
  // R607: this group's pixels are all painted already (registered one stage
  // before the fetch decision, from the mask as it stood a cycle earlier).
  logic               sh_m;
  wire                res_skip  = FTB && sh_m;
  // R633: reuse the texel of the group fetched just before, same span,
  // adjacent -- tracked at the consumer (cons_take), where fetches are issued
  logic               lf_v;          // the last group taken was a real fetch
  logic               lf_p;          // ... of this span slot
  logic signed [15:0] lf_xn;         // ... whose neighbour is at this x (x + PIXSTEP,
                                     // added as it is stored: cons_take drives pipe_en)
  wire                res_reuse;

  // R607: THE MASK COPY AND THE QUERY. One bit a pixel, 32 to a word, a row
  // of the band in MROW words; m2_raster3d owns the valid bits (cleared as a
  // band starts) and writes both copies as the band paints. The query is for
  // the group one stage before the fetch decision. A group that crosses a
  // 32-pixel word is not skipped -- conservative, and about one in eight at
  // PIXSTEP 4. Pixels off the screen or outside the band count as painted:
  // the band would drop them.
  // no_rw_check: see m2_raster3d mk_a. A stale answer here only costs a fetch.
  (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] mk [MDEP];
  always_ff @(posedge clk) if (mk_we) mk[mk_waddr] <= mk_wdata;
  // R631: THE QUERY IN TWO HALVES (s409: one path through all of it --
  // clamp, index multiply, the MLAB read, two variable shifts, the compare
  // -- missed 70 MHz by 66 ps, and a wrong answer skips painting: bands never
  // drawn on the board). The index, the pixels the group needs and the two
  // early answers depend only on the group's x and its span, which are in
  // the shadow a stage sooner and do not change as it shifts, so they are
  // worked out from sh_*[PIPE_D-3] and registered with the shift; the mask
  // word is still read at PIPE_D-2, when it was before. Same answers.
  logic               mq_f1, mq_f0;     // answer "full" / "not full" outright
  logic [MAW-1:0]     mq_wi;
  logic [31:0]        mq_need;
  logic               mp_f1, mp_f0;
  logic [MAW-1:0]     mp_wi;
  logic [31:0]        mp_need;
  // R684: SIXTEEN BITS, not 32. Every value here is a screen x or y -- the
  // band and the writer already take [15:0] (R553) -- and the 32-bit clamps,
  // compares and subtracts were most of the +416 LUTs R683's build measured
  // for this query, on a device 28 LABs short. Taken as bit slices into
  // signed variables, no casts (R662).
  localparam logic signed [15:0] QXMAX = 16'(SCR_W - 1);
  localparam logic signed [15:0] QBH   = 16'(BAND_H);
  always_comb begin
    automatic logic               qp   = sh_p[PIPE_D-3];
    /* verilator lint_off UNUSEDSIGNAL */
    automatic logic signed [31:0] qs32 = stp(k_p[qp]);   // a step of 1-8
    /* verilator lint_on UNUSEDSIGNAL */
    automatic logic signed [15:0] qs   = qs32[15:0];
    automatic logic signed [15:0] qx   = sh_x[PIPE_D-3][15:0];
    automatic logic signed [15:0] qx1  = x1_p[qp][15:0];
    automatic logic signed [15:0] qy   = y_p[qp][15:0];
    automatic logic signed [15:0] qe   = qx + qs - 16'sd1;   // R650
    automatic logic signed [15:0] qxe  = (qe > qx1) ? qx1 : qe;
    automatic logic signed [15:0] qrow = qy - mk_band_y0;
    automatic logic signed [15:0] xa   = (qx  < 16'sd0) ? 16'sd0 : qx;
    automatic logic signed [15:0] xb   = (qxe > QXMAX) ? QXMAX : qxe;
    mp_wi   = MAW'(qrow) * MAW'(MROW) + MAW'(xa[15:5]);
    mp_need = (32'hFFFF_FFFF << xa[4:0]) & (32'hFFFF_FFFF >> (5'd31 - xb[4:0]));
    mp_f1   = (qrow < 16'sd0) || (qrow >= QBH) || (xb < xa);
    mp_f0   = !mp_f1 && (xa[15:5] != xb[15:5]);
  end
  logic mq_full;
  always_comb begin
    automatic logic [31:0] w = mk_valid[mq_wi] ? mk[mq_wi] : 32'd0;
    if (mq_f1)      mq_full = 1'b1;
    else if (mq_f0) mq_full = 1'b0;
    else            mq_full = ((w & mq_need) == mq_need);
  end
  /* verilator lint_off UNUSEDSIGNAL */   // R553: only [15:0] is queued
  wire signed [31:0]  res_x     = sh_x[PIPE_D-1];
  /* verilator lint_on UNUSEDSIGNAL */
  wire                res_last  = sh_last[PIPE_D-1];
  wire                res_p     = sh_p[PIPE_D-1];

  // R539: the fetches in flight, in issue order -- each one's pixel x, its
  // span's last-group flag and its parameter set. Answers arrive in the same
  // order, so the head of this queue is always the answer's owner.
  localparam int unsigned OW = $clog2(TXK) + 1;
  // R553: 16 bits, not 32 -- screen x, and the band takes span_x0[15:0].
  logic signed [15:0] of_x    [TXK];
  logic               of_last [TXK];
  logic               of_p    [TXK];
  logic               of_skip [TXK];   // R607
  logic               of_reuse [TXK];  // R633
  logic [OW-1:0]      of_wp, of_rp;
  // R478: THE RETIRE STAGE. R476 computed e_col straight from the arriving
  // texel, which put m2_texel's `hold` register, the nibble select, the
  // adapter and scale() in ONE cycle:
  //
  //   m2_texel|hold[12] -> m2_span_tex|e_col[22]   9.570 ns
  //
  // and cost about 0.6 ns of clk_sys across three seeds. The old walk
  // registered the texel first and coloured it the cycle after; streaming the
  // walk removed that stage by accident. Putting it back costs a stage but not
  // a cycle per group, because the next fetch is issued on the same edge.
  logic               rt_valid;
  logic [8:0]         rt_texel;   // R620: {discard, t}
  logic signed [31:0] rt_x;
  logic               rt_last;
  logic               rt_p, e_p;   // R490
  logic               rt_skip;     // R607
  logic [8:0]         lt_texel;    // R633: the last fetched answer, for a reuse

  // Take a result when there is one, no fetch is outstanding, and the emit
  // slot will be free. The pipeline runs whenever the output is not being held.
  // The span load, seen by the pipeline block so the issue pointer starts with
  // the span. The FSM loads du_r/dv_r/doz_r on the same edge; the first advance
  // happens a cycle later, by which time they are valid.
  // R490: a span is accepted COLD (nothing in flight) or OVERLAPPED (the
  // current span has issued its last group and there is a free parameter set).
  // The overlap case must NOT clear the shadow -- the valids in it belong to
  // the span still draining and are wanted.
  wire sp_room   = (sp_n < 2'd2);
  wire ld_cold   = (st == T_IDLE) && in_valid && tex_now;
  wire ld_over   = (st == T_RUN) && in_valid && tex_now && !iss_run && sp_room
                && pipe_en;
  wire ld_span   = ld_cold || ld_over;
  // R616: (PIXSTEP-1)/2 pixels of each gradient, 16.16 (gradients are 8.8).
  // R650: x (2^pxk - 1) as a shift and a subtract.
  wire signed [31:0] gc_du = GC ? (((32'(in_dudx)   <<< pxk) - 32'(in_dudx))   <<< 7) : 32'sd0;
  wire signed [31:0] gc_dv = GC ? (((32'(in_dvdx)   <<< pxk) - 32'(in_dvdx))   <<< 7) : 32'sd0;
  wire signed [31:0] gc_do = GC ? (((32'(in_doozdx) <<< pxk) - 32'(in_doozdx)) <<< 7) : 32'sd0;
  // R478: the retire slot only has to be free by the NEXT edge, not this one.
  // Requiring !rt_valid outright cost a whole cycle a group (2.36 -> 3.36):
  // the emit that frees it happens on the same edge the fetch would start.
  wire rt_frees  = rt_valid && (!e_valid || out_ready);
  // R539: a result is issued as a fetch whenever a credit is free -- no longer
  // only when the previous fetch has come back. The retire slot is not
  // reserved here; the answer waits in the adapter until it is free.
  wire of_room   = ((of_wp - of_rp) != OW'(TXK));
  // R607: a skipped group takes a queue slot but no credit and no fetch, and
  // leaves the queue without an answer once it is at the head -- the answers
  // still come back in the order the real fetches were made.
  assign res_reuse = REUSE && late && !res_skip && lf_v && (lf_p == res_p)
                  && (lf_xn == res_x[15:0]);
  wire cons_take = res_valid && (res_skip || res_reuse || tx_rdy) && of_room && (st == T_RUN);
  wire head_skip = of_skip[of_rp[OW-2:0]];
  wire head_reuse = of_reuse[of_rp[OW-2:0]];   // R633
  // An answer moves into the retire stage when that stage is empty or
  // emptying this cycle.
  wire rt_take   = (head_skip || head_reuse || tx_ack) && (of_wp != of_rp) && (!rt_valid || rt_frees)
                && (st == T_RUN);
  assign tx_take = rt_take && !head_skip && !head_reuse;   // R607, R633
  // R551: WHY THE WALK IS BUSY, for the bench only (nothing reads it, so the
  // fitter drops it). 1 the band painter is not taking the emitted group,
  // 2 fetches are out and the oldest has not been answered, 3 a result is
  // ready but no fetch credit is free, 4 the divide pipeline has nothing ready
  // (span start / refill), 0 not busy.
  logic [2:0] wait_why /*verilator public_flat_rd*/;
  assign dbg_wait = wait_why;
  always_comb begin
    wait_why = 3'd0;
    if (busy) begin
      if (e_valid && !out_ready)                        wait_why = 3'd1;
      else if ((of_wp != of_rp) && !tx_ack && !head_skip && !head_reuse) wait_why = 3'd2;
      else if (res_valid && !tx_rdy)                    wait_why = 3'd3;
      else if (!res_valid)                              wait_why = 3'd4;
    end
  end
  wire pipe_en   = !res_valid || cons_take;
  logic signed [31:0] d0_o;   logic [5:0] d0_e;   // R448: stage 1a
  logic [5:0]  d1_e;   logic [31:0] d1_m;  logic [24:0] d1_r;
  logic [5:0]  d1a_e;  logic [31:0] d1a_m;   // R718: stage 1b's shift, before the table
  logic [31:0] d2_nd;  logic [5:0]  d2_e;  logic [24:0] d2_r;
  logic [24:0] d3_r1;  logic [5:0]  d3_e;
  logic signed [31:0] d4_u, d4_v;
  logic        [63:0] d4a_pu, d4a_pv;   // R468: the product, before the shift
  logic         [4:0] d4a_sh;
  // The coordinate that entered the pipeline with the 1/z now emerging from it,
  // delayed three cycles to match. Getting this wrong pairs a texel coordinate
  // with the wrong pixel's depth, which is the whole fault this change exists
  // to avoid introducing.
  logic signed [31:0] u_h1, v_h1, u_h2, v_h2, u_h3, v_h3, u_h4, v_h4, u_h5, v_h5;

  // R539: the register R496 asked for now lives in m2_texel_x2, which loads
  // each request into f_tex/f_u/f_v before the cache's adders see it. Here the
  // payload goes straight into the adapter's request queue with the issue.
  assign tx_tex = {8'd0, tex_p[res_p]};
  // R339: the DIVIDED coordinates, not u/z and v/z themselves.
  assign tx_u   = to_tx(d4_u);
  assign tx_v   = to_tx(d4_v);
  assign tx_req = cons_take && !res_skip && !res_reuse;   // R607, R633
  // R615: THE 3D FRAME DIFFERENTIAL'S PROBE -- every real fetch, with the
  // pixel group and texture it is for. Read by tb_m2_raster3d through
  // the simulator's public access; nothing in the design reads it, so synthesis
  // removes it.
  logic               dbg_fetch   /*verilator public_flat_rd*/;
  logic signed [31:0] dbg_fetch_x /*verilator public_flat_rd*/;
  logic signed [31:0] dbg_fetch_y /*verilator public_flat_rd*/;
  logic        [19:0] dbg_fetch_u /*verilator public_flat_rd*/;
  logic        [19:0] dbg_fetch_v /*verilator public_flat_rd*/;
  logic        [23:0] dbg_fetch_t /*verilator public_flat_rd*/;
  logic        [23:0] dbg_fetch_c /*verilator public_flat_rd*/;
  assign dbg_fetch   = tx_req;
  assign dbg_fetch_x = res_x;
  assign dbg_fetch_y = y_p[res_p];
  assign dbg_fetch_u = tx_u;
  assign dbg_fetch_v = tx_v;
  assign dbg_fetch_t = tex_p[res_p];
  assign dbg_fetch_c = col_p[res_p];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      d0_o <= '0; d0_e <= '0;
      d1_e <= '0; d1_m <= '0; d1_r <= '0; d1a_e <= '0; d1a_m <= '0;
      d2_nd <= '0; d2_e <= '0; d2_r <= '0;
      d3_r1 <= '0; d3_e <= '0; d4_u <= '0; d4_v <= '0;
      d4a_pu <= '0; d4a_pv <= '0; d4a_sh <= '0;   // R468
      u_h1 <= '0; v_h1 <= '0; u_h2 <= '0; v_h2 <= '0; u_h3 <= '0; v_h3 <= '0;
      u_h4 <= '0; v_h4 <= '0; u_h5 <= '0; v_h5 <= '0; sh_m <= 1'b0;   // R607
      mq_f1 <= 1'b0; mq_f0 <= 1'b1; mq_wi <= '0; mq_need <= '0;   // R631
      iss_u <= '0; iss_v <= '0; iss_ooz <= '0; iss_x <= '0; iss_run <= 1'b0; iss_step <= 4'd1;
      for (int k = 0; k < PIPE_D; k++) begin
        sh_v[k] <= 1'b0; sh_x[k] <= '0; sh_last[k] <= 1'b0; sh_p[k] <= 1'b0;
      end
    end else if (ld_cold) begin
      // R476: START OF SPAN. On a COLD start the shadow is cleared so a stale
      // valid from the previous span cannot emerge as a group of this one --
      // which would draw one span's texel at another span's x and pass every
      // arithmetic check.
      //
      // R490: ON AN OVERLAPPED START IT MUST NOT BE. The valids standing in the
      // shadow then belong to the span still draining, and clearing them is
      // exactly the fault the R476 comment describes, in the other direction --
      // the previous span would lose its remaining groups. Order is preserved
      // by the pipeline and each span's end is marked by sh_last, so the two
      // spans' groups coexist without a per-stage tag.
      iss_u   <= in_u   + gc_du;     // R616
      iss_v   <= in_v   + gc_dv;
      iss_ooz <= in_ooz + gc_do;
      iss_x   <= in_x0;
      iss_step <= 4'd1 << pxk;       // R650
      iss_run <= 1'b1;
      if (ld_cold) begin
        for (int k = 0; k < PIPE_D; k++) begin
          sh_v[k] <= 1'b0; sh_x[k] <= '0; sh_last[k] <= 1'b0; sh_p[k] <= 1'b0;
        end
        sh_m <= 1'b0;   // R607
        mq_f1 <= 1'b0; mq_f0 <= 1'b1; mq_wi <= '0; mq_need <= '0;   // R631
      end
    end else if (pipe_en) begin
      // R476: THE WHOLE PIPELINE STALLS TOGETHER. When the consumer cannot take
      // the result at the output, nothing moves -- issue, stages and shadow all
      // hold. Letting the stages advance while the output is held would drop
      // the result that is standing there.
      //
      // Issue one group per enabled cycle, and shift the shadow with it.
      // R490: AN OVERLAPPED LOAD HAPPENS HERE, NOT IN A BRANCH OF ITS OWN.
      // Taking a separate branch for it skipped the shadow shift below while
      // the FSM block -- a different always_ff -- went on consuming the result
      // standing at the pipeline's output. The two desynchronised and the same
      // group emerged twice, which the back-to-back test caught as 294 groups
      // where 289 were sent. A load may only be accepted on a cycle the
      // pipeline is moving, which is why ld_over carries `pipe_en`.
      if (ld_over) begin
        iss_u   <= in_u   + gc_du;   // R616
        iss_v   <= in_v   + gc_dv;
        iss_ooz <= in_ooz + gc_do;
        iss_x   <= in_x0;
        iss_step <= 4'd1 << pxk;     // R650
        iss_run <= 1'b1;
      end else if (iss_run) begin
        // R650: du_r/dv_r/doz_r are the per-GROUP steps, shifted by the
        // span's pxk as they were loaded, so this add has nothing in front
        iss_u   <= iss_u   + du_r;
        iss_v   <= iss_v   + dv_r;
        iss_ooz <= iss_ooz + doz_r;
        iss_x   <= iss_x   + 32'(iss_step);
        if (iss_last) iss_run <= 1'b0;
      end
      sh_v[0]    <= iss_run;
      sh_x[0]    <= iss_x;
      sh_last[0] <= iss_run && iss_last;
      sh_p[0]    <= sp_iss;                 // R490
      sh_m       <= mq_full;                // R607: follows sh_*[PIPE_D-1]
      mq_f1 <= mp_f1; mq_f0 <= mp_f0; mq_wi <= mp_wi; mq_need <= mp_need;   // R631
      for (int k = 1; k < PIPE_D; k++) begin
        sh_v[k]    <= sh_v[k-1];
        sh_x[k]    <= sh_x[k-1];
        sh_last[k] <= sh_last[k-1];
        sh_p[k]    <= sh_p[k-1];            // R490
      end

      // R448: STAGE 1 SPLIT IN TWO. As one cycle it was the ooz_nxt add, then
      // top_bit's priority encode, then a variable shift, then the rcp_tab
      // read -- four operations, and report_timing named it:
      //   m2_span_tex|doz_r[17] -> m2_span_tex|d1_r[19]   -0.905 on clk_sys
      // A four-stage pipeline with four things in its first stage, written to
      // take a divide OUT of a critical path.
      //
      // 1a: the add and the encode. 1b: the shift and the table read.
      d0_o <= dv_o;
      d0_e <= top_bit(dv_o);
      // R718: 1b SPLIT AGAIN -- the variable shift, then the table read. At
      // 75 MHz the shift into rcp_tab missed (s738: d0_o -> d1_r -0.653).
      d1a_e <= d0_e;
      d1a_m <= (d0_e >= 6'd23) ? (d0_o >> (d0_e - 6'd23))
                               : (d0_o << (6'd23 - d0_e));
      d1_e <= d1a_e; d1_m <= d1a_m; d1_r <= rcp_tab[d1a_m[22:16]];
      // stage 2: the Newton residual
      d2_nd <= 32'((((64'd1 <<< 48) - (64'(d1_m) * 64'(d1_r))) >> 24));
      d2_e  <= d1_e; d2_r <= d1_r;
      // stage 3: the refined reciprocal
      d3_r1 <= 25'((64'(d2_r) * 64'(d2_nd)) >> 23);
      d3_e  <= d2_e;
      // stage 4a: the coordinate multiply. R468: THE SHIFT MOVED OFF IT.
      //
      //   m2_span_tex|Mult1~mult_hh_pl -> m2_span_tex|d4_v[26]   16.933 ns
      //
      // was the worst clk_3d path on s134 once R466 moved m2_persp_recip off
      // it. One cycle carried a 64-bit multiply, a VARIABLE shift by sh and
      // then sat32 -- a DSP output straight into a barrel shifter, the same
      // shape R457, R459, R461 and R466 each split.
      //
      // `sh` is not the offender: it comes off the registered d3_e and
      // computes beside the multiply. The multiply feeding the shifter is.
      //
      // COSTS LATENCY, NOT THROUGHPUT. d0..d4 is a pipeline (R446/R448), not a
      // state walk -- group N+1's coordinates are computed while group N's
      // texel is in flight -- so one more stage means dv_age reaches six
      // instead of five, and nothing issues any slower.
      d4a_pu <= 64'(u_h5) * 64'(d3_r1);   // R718: one deeper, to match
      d4a_pv <= 64'(v_h5) * 64'(d3_r1);
      d4a_sh <= (d3_e < 6'd23) ? 5'd16 : 5'(d3_e - 6'd7);

      // stage 4b: the un-normalise and the clamp, on the registered product.
      d4_u <= sat32(d4a_pu >> d4a_sh);
      d4_v <= sat32(d4a_pv >> d4a_sh);
      u_h1 <= dv_u;  v_h1 <= dv_v;
      u_h2 <= u_h1;  v_h2 <= v_h1;
      u_h3 <= u_h2;  v_h3 <= v_h2;
      u_h4 <= u_h3;  v_h4 <= v_h3;   // R448: one deeper, to match
      u_h5 <= u_h4;  v_h5 <= v_h4;   // R718: and one more
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= T_IDLE; dv_age <= 3'd0; of_wp <= '0; of_rp <= '0;   // R539
      rt_valid <= 1'b0; rt_texel <= 9'd0; rt_x <= '0; rt_last <= 1'b0;   // R478
      for (int k = 0; k < 2; k++) begin
        y_p[k] <= '0; x1_p[k] <= '0; col_p[k] <= '0; k_p[k] <= '0;
        moire_p[k] <= 1'b0; tex_p[k] <= '0;
      end
      sp_iss <= 1'b0; sp_out <= 1'b0; sp_n <= 2'd0; e_last <= 1'b0;   // R490
      rt_p <= 1'b0; e_p <= 1'b0; rt_skip <= 1'b0;                     // R490, R607
      lf_v <= 1'b0; lf_p <= 1'b0; lf_xn <= '0; lt_texel <= 9'd0;      // R633
      du_r <= '0; dv_r <= '0;
      doz_r <= '0;
      // R433
      e_valid <= 1'b0; e_col <= '0; e_x <= '0; e_x1 <= '0;
      dbg_texpix <= '0; dbg_texnz <= '0;
    end else begin
      if (e_valid && out_ready) e_valid <= 1'b0;

      // R490: A SPAN IS FINISHED when its last pixel has been taken -- or, if
      // that pixel was a transparent texel the emit skipped, at the skip. The
      // skip case is easy to miss: e_valid is never raised for it, so waiting
      // on out_ready alone would strand the parameter set and wedge the unit
      // behind a span that had already ended.
      //
      // R535: AND BOTH CAN HAPPEN ON THE SAME EDGE. Span A's last pixel is taken
      // at the output while span B -- one group wide, translucent, texel 0xF --
      // is skipped at the retire stage behind it. Two spans end; the old single
      // `span_done` counted one, sp_n stayed a span too high for good, the unit
      // never returned to T_IDLE, and a flat span (accepted only when idle) then
      // waited forever. That is the wedge R520 caught on the board the first
      // time an R490 build booted (s239, walk_stuck_max 0xFFFF). Narrow
      // translucent edges are common in a real scene and absent from every
      // bench until the soak sent them.
      begin
        automatic logic done_e  = e_valid && out_ready && e_last;
        automatic logic done_rt = rt_valid && (!e_valid || out_ready) && rt_last
                                  && (rt_skip || rt_texel[8]);   // R607, R620
        automatic logic [2:0] n_next = 3'(sp_n) + 3'(ld_span)
                                     - 3'(done_e) - 3'(done_rt);
        automatic logic slot = ld_cold ? sp_out : ~sp_iss;

        if (done_e ^ done_rt) sp_out <= ~sp_out;   // both: two steps, same slot
        if (ld_span) begin
          y_p[slot]     <= in_y;
          x1_p[slot]    <= in_x1;
          col_p[slot]   <= in_col;
          moire_p[slot] <= in_moire;
          tex_p[slot]   <= in_tex;
          du_r          <= (32'(in_dudx)   <<< 8) <<< pxk;   // R650: a group's step
          dv_r          <= (32'(in_dvdx)   <<< 8) <<< pxk;
          doz_r         <= (32'(in_doozdx) <<< 8) <<< pxk;
          k_p[slot]     <= pxk;
          sp_iss        <= slot;
        end
        sp_n <= n_next[1:0];
        // Back to passing flat spans through only when nothing is left.
        if ((done_e || done_rt) && (n_next == 3'd0)) st <= T_IDLE;
      end
      // R446: the pipeline is four deep; this says when its output matches the
      // operands currently presented. It must NOT be gated by the branch that
      // waits on it -- R424 made that mistake and deadlocked the walk.
      if (dv_age != 3'd7) dv_age <= dv_age + 3'd1;

      case (st)
        T_IDLE: if (ld_cold) begin
          dv_age  <= 3'd0;
          st      <= T_RUN;
        end

        // R476: ONE STATE, NOT THREE. T_WARM waited for the first divide,
        // T_FETCH waited for a texel and T_EMIT waited for dv_age to reach six
        // again -- and that last wait was per GROUP, which R475 measured as
        // 7.41 cycles a group with a perfect cache. The pipeline now carries
        // successive groups, so the six cycles are paid once per span while it
        // fills, and after that a result is standing at the output every cycle
        // the consumer can take one.
        T_RUN: begin
          // R539: issue. The result standing at the pipeline's output goes to
          // the adapter as a fetch (tx_req = cons_take, payload combinational
          // from d4_u/d4_v) and its pixel joins the in-flight queue.
          if (cons_take) begin
            of_x   [of_wp[OW-2:0]] <= res_x[15:0];
            of_last[of_wp[OW-2:0]] <= res_last;
            of_p   [of_wp[OW-2:0]] <= res_p;
            of_skip[of_wp[OW-2:0]] <= res_skip;   // R607
            of_reuse[of_wp[OW-2:0]] <= res_reuse; // R633
            of_wp <= of_wp + 1'd1;
            // R633: the last real fetch -- a reuse or a skip breaks the chain,
            // so fetches and reuses alternate
            lf_v <= !res_skip && !res_reuse;
            lf_p <= res_p;
            lf_xn <= res_x[15:0] + 16'(stp(k_p[res_p]));   // R650
          end

          // R539: retire. The oldest answer joins the oldest pixel. The retire
          // stage is loaded here and EMPTIED below -- and the two can happen
          // on the same edge, so the emptying must not undo the loading.
          if (rt_take) begin
            rt_valid <= 1'b1;
            rt_texel <= head_reuse ? lt_texel : tx_texel;   // R633
            if (!head_skip && !head_reuse) lt_texel <= tx_texel;
            rt_x     <= 32'(of_x[of_rp[OW-2:0]]);   // sign-extended
            rt_last  <= of_last[of_rp[OW-2:0]];
            rt_p     <= of_p   [of_rp[OW-2:0]];
            rt_skip  <= head_skip;                  // R607
            of_rp    <= of_rp + 1'd1;
            // R484: WRAPS, DOES NOT SATURATE (see the history in git).
            if (!head_skip && !head_reuse && tx_texel[7:0] != 8'hff) dbg_texnz <= dbg_texnz + 1'd1;
          end

          // Colour and emit the retired group.
          if (rt_valid && (!e_valid || out_ready)) begin
            automatic logic       skip = rt_skip || rt_texel[8];   // R607, R620
            automatic logic [7:0] iv   = rt_texel[7:0];            // R620: already 8 bits
            if (!rt_take) rt_valid <= 1'b0;       // R539: a take refills it
            e_valid <= !skip;                     // R326: transparent texel
            e_last  <= rt_last;                   // R490
            e_x     <= rt_x;
            e_x1    <= ((rt_x + stp(k_p[rt_p]) - 32'sd1) > x1_p[rt_p])
                         ? x1_p[rt_p] : (rt_x + stp(k_p[rt_p]) - 32'sd1);   // R650
            e_col   <= {scale(col_p[rt_p][23:16], iv),
                        scale(col_p[rt_p][15:8],  iv),
                        scale(col_p[rt_p][7:0],   iv)};
            e_p     <= rt_p;                      // R490
            if (!skip) dbg_texpix <= dbg_texpix + stp(k_p[rt_p]);   // R484: wraps
          end
        end

        default: st <= T_IDLE;
      endcase
    end
  end

endmodule
