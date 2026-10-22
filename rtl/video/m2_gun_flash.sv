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
// VIRTUA COP'S GUN FLASH AS WHOLE WHITE FRAMES (R929, GitHub #13).
//
// WHAT THE GAME DOES (MAME 0.289 vcopa, sim/io/mame_m2_gunflash.lua). On an
// accepted shot its vblank handler (0x58400, from the IRQ that acks bit 0)
// writes ALL ONES over tilemaps 0/1's window table -- tile RAM words
// 0x6000-0x65FF, CPU 0x0100C000-0x0100CBFF, 384 stl from word 0x6000 up --
// and at each of the next four vblanks writes it back to zero (a countdown at
// work RAM 0x5B1E50). With the table all ones every 8-pixel column shows
// tilemap 1 instead of tilemap 0, and tilemap 1 is held full of tile 0x8283:
// category 1 (in front of the 3D), glyph 0x283 all pen 4, palette 0x054 =
// 0xFFFF. So the frame after the vblank that wrote it is white from edge to
// edge, over the 3D, exactly one frame -- MAME shows it so (255, 255, 255 on
// every pixel), on Virtua Cop and, by the same table, Virtua Cop 2. Nothing
// else changes: no video, sync, render-mode or palette register, no I/O board
// output (lamps / PD stay 0, the "FPGA" at 0x8100 is only read), the 3D list
// under it is the ordinary one. The game takes the gun's position at the
// vblank that ends that white frame (MAME: a gun moved during the white frame
// is the position used; one moved a frame later is not), which is when the
// cabinet's gun board, latching on the light it saw in it, has a reading.
//
// WHAT THIS MODULE ADDS. The request is the game's own write: word 0x6000
// (the table's first word, row 0, columns 0-127) written 0xFFFF by the CPU;
// the stage-start band the game also draws with this table (rows 172-199,
// 0x59D8C) never touches row 0. It is tracked from the CPU's tile-RAM write
// port (clk_sys) and crossed into the video clock, and acted on at the START
// OF A FRAME (the native vertical blank's falling edge), so the picture
// changes only between whole frames -- a CRT gun reads a whole white field,
// never a torn one, wherever in the frame the i960's writes happened to land.
// The OSD's mode:
//   0 Arcade   the frame the game asks for is white, whole: every frame that
//              starts while the request stands (normally exactly one), at
//              most FMAX in a row. The game's own tilemap flash is left as it
//              is, so this adds nothing a correct board would not show,
//              except that it is whole and does not depend on the tile path.
//   1 CRT gun  for a light gun that reads the CRT itself (the GunCon 2 through
//              Main_MiSTer). Such a gun goes blind on a dark part of the
//              scene, Main then reports it off the screen (a reload), and it
//              needs several fields of light before its reports are good
//              again (retrorepair's GunCon 2 traces) -- one white frame, with
//              the game taking the aim at the vblank that ends it, is too
//              short and too late. So: on ANY pull (on or off the screen --
//              a gun on a dark spot reads as off), white from the next frame
//              start, the pull HELD BACK from the game for HOLD frames, then
//              given to it pressed for PRESS frames (longer if the trigger is
//              still held), and white kept until the game's own flash frame
//              has been shown (its request seen and withdrawn) -- the frame
//              after which it takes the aim, by then from a gun that has had
//              HOLD + ~3 fields of light. At most CMAX frames (a pull the game
//              does not answer, a reload, the attract). A pull during a
//              sequence joins it. The cost is HOLD frames of trigger latency,
//              in this mode only.
//   2, 3 Off   no white: the game's flash is taken out of the picture too --
//              while its request stands (and until the frame after it is
//              withdrawn) the renderer's reads of the tilemap 0/1 window
//              table return zero, so tilemap 0 shows as on any other frame.
//              Tile RAM keeps what the game wrote; the game never reads it.
//
// en low (any game but Virtua Cop) holds everything off: white 0, kill 0.
//
// TIMING. clk_sys side: one register stage on the write port's compare. The
// video side (clk_mem) sees the request and the pull toggle through two flops
// each, and clk_sys sees the video's release / press-end toggles likewise
// (all move a handful of times a second; the request is written in the
// vertical blank, a frame before it is used). kill is a registered function
// of the renderer's read address, one cycle behind it, as tile RAM's own
// output is (m2_tdp_ram2c registers b_q on b_addr). trig_game_n is
// registered (it goes to the I/O board's Z80, which polls at 1 kHz).
`timescale 1ns/1ps
module m2_gun_flash #(
  parameter int unsigned FMAX  = 4,    // Arcade: frames in a row while the request stands
  parameter int unsigned HOLD  = 3,    // CRT gun: white frames before the game gets the pull
  parameter int unsigned PRESS = 3,    // CRT gun: frames the game then sees it pressed, at least
  parameter int unsigned CMAX  = 8     // CRT gun: white frames at most
) (
  // ---- clk_sys: the CPU's tile-RAM writes, the guns, the OSD
  input  logic        clk_sys,
  input  logic        rst_sys_n,
  input  logic        en,              // Virtua Cop, the feature built (quasi-static)
  input  logic [1:0]  mode,            // OSD (quasi-static)
  input  logic        cpu_tram_we,     // the CPU's own write (not the copy engine's)
  input  logic [14:0] cpu_tram_addr,   // word address
  input  logic [15:0] cpu_tram_din,
  input  logic [1:0]  trig_n,          // IN1 bits 1:0 from the guns, active low
  output logic [1:0]  trig_game_n,     // ... as the game gets them (= trig_n but in CRT gun)

  // ---- clk_mem: the video
  input  logic        clk,
  input  logic        rst_n,
  input  logic        vb,              // the native vertical blank (m2_video vid_vb)
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [14:0] tram_addr,       // the renderer's tile-RAM read address (bits 14:11 used)
  /* verilator lint_on UNUSEDSIGNAL */
  output logic        kill,            // zero the tile-RAM word the renderer reads this cycle
  output logic        white            // this frame is the flash
);

  logic       rl_t, pe_t;              // clk_mem toggles to clk_sys: release the pull; the press is over

  // ------------------------------------------------------------ clk_sys
  logic       req;                     // word 0x6000 holds 0xFFFF: the game asks for its flash
  logic       en_s, crt_s, off_s;
  logic [1:0] trig_q;
  logic       tg;                      // toggles on a pull that starts a sequence
  logic [2:0] rl_y, pe_y;              // the video's release / press-end toggles, synchronised
  logic       hold, pend;              // the pull held back; then given pressed
  logic [1:0] pm;                      // the players whose pull is in the sequence
  wire  [1:0] pull = ~trig_n & ~trig_q;
  wire        rl_e = rl_y[2] ^ rl_y[1];
  wire        pe_e = pe_y[2] ^ pe_y[1];
  wire        crt_on = en_s && crt_s;
  always_ff @(posedge clk_sys or negedge rst_sys_n) begin
    if (!rst_sys_n) begin
      req <= 1'b0; en_s <= 1'b0; crt_s <= 1'b0; off_s <= 1'b0; trig_q <= 2'b00; tg <= 1'b0;
      rl_y <= '0; pe_y <= '0; hold <= 1'b0; pend <= 1'b0; pm <= 2'b00;
    end else begin
      en_s   <= en;
      crt_s  <= (mode == 2'd1);
      off_s  <= mode[1];
      trig_q <= ~trig_n;
      rl_y   <= {rl_y[1:0], rl_t};
      pe_y   <= {pe_y[1:0], pe_t};
      if (cpu_tram_we && cpu_tram_addr == 15'h6000) req <= (cpu_tram_din == 16'hFFFF);
      if (!crt_on) begin
        hold <= 1'b0; pend <= 1'b0; pm <= 2'b00;
      end else begin
        if (|pull) begin
          pm <= pm | pull;                       // joins a sequence in progress
          if (!hold && !pend && pm == 2'b00) begin hold <= 1'b1; tg <= ~tg; end
        end
        if (rl_e && hold) begin hold <= 1'b0; pend <= 1'b1; end
        if (pe_e && pend) begin pend <= 1'b0; pm <= 2'b00; end
      end
    end
  end
  // the game's IN1: for the players in a sequence released while held back,
  // then pressed; everyone else's (and every other mode's) straight through
  assign trig_game_n = {(crt_on && pm[1]) ? ~pend : trig_n[1],
                        (crt_on && pm[0]) ? ~pend : trig_n[0]};

  // ------------------------------------------------------------ clk_mem
  logic [1:0] req_y, en_y, off_y, crt_y;
  logic [2:0] tg_y;
  logic       vb_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      req_y <= '0; en_y <= '0; off_y <= '0; crt_y <= '0; tg_y <= '0; vb_q <= 1'b1;
    end else begin
      req_y <= {req_y[0], req};
      en_y  <= {en_y[0], en_s};
      off_y <= {off_y[0], off_s};
      crt_y <= {crt_y[0], crt_s};
      tg_y  <= {tg_y[1:0], tg};
      vb_q  <= vb;
    end
  end
  wire rq     = req_y[1];
  wire on     = en_y[1];
  wire off    = off_y[1];
  wire crt    = crt_y[1];
  wire fstart = vb_q && !vb;           // the vertical blank ended: a frame starts
  wire pulled = tg_y[2] ^ tg_y[1];

  logic [3:0] an;                      // Arcade: white frames in a row for this request
  logic       cp;                      // CRT gun: a pull waiting for the next frame
  logic       ca;                      // CRT gun: a sequence in progress (white, or the press)
  logic       cw;                      // CRT gun: its white
  logic       cs;                      // CRT gun: the game's request seen since the release
  logic [3:0] cn;                      // CRT gun: frames started since the pull
  logic       ktail;                   // Off: the frame after the request is withdrawn
  // At a frame start: Arcade shows it white when the request stands (at most
  // FMAX in a row). CRT gun: white from the frame after the pull; the game
  // gets the pull at the start of frame HOLD + 1, pressed for PRESS frames;
  // the white ends at the first frame start after the game's request has come
  // and gone (its flash frame shown, the aim taken), or after CMAX frames.
  wire       aw    = rq && (an < 4'(FMAX));
  wire       cstop = (cs && !rq) || (cn >= 4'(CMAX));
  wire       cw_n  = cp || (ca && cw && !cstop);
  wire       ca_n  = cp || (ca && (cw_n || (cn < 4'(HOLD + PRESS))));
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      an <= '0; cp <= 1'b0; ca <= 1'b0; cw <= 1'b0; cs <= 1'b0; cn <= '0;
      rl_t <= 1'b0; pe_t <= 1'b0; ktail <= 1'b0; white <= 1'b0;
    end else begin
      if (pulled && crt && on) cp <= 1'b1;
      if (rq) ktail <= 1'b1;
      if (fstart) begin
        if (!rq)     an <= '0;
        else if (aw) an <= an + 4'd1;
        cw <= cw_n;
        ca <= ca_n;
        if (cp) begin
          cp <= 1'b0; cs <= 1'b0; cn <= 4'd1;
        end else if (ca) begin
          cn <= cn + 4'd1;
          if (rq && cn > 4'(HOLD))    cs <= 1'b1;
          if (cn == 4'(HOLD))         rl_t <= ~rl_t;
          if (cn == 4'(HOLD + PRESS)) pe_t <= ~pe_t;
        end
        white <= on && !off && (aw || (crt && cw_n));
        if (!rq) ktail <= 1'b0;
      end
      if (!on || !crt) begin cp <= 1'b0; ca <= 1'b0; cw <= 1'b0; end
    end
  end

  // Off: the renderer reads tilemaps 0/1's window table (words 0x6000-0x67FF)
  // as zero while the request stands and through the frame start after it
  // goes, so the rewrite to zero (row 0 first) cannot leak a row of white.
  // Registered, aligned with tile RAM's registered output.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) kill <= 1'b0;
    else        kill <= on && off && (rq || ktail) && (tram_addr[14:11] == 4'b1100);
  end

endmodule
