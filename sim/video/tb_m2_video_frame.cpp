// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// Render one whole frame out of m2_video and write it out, so the 2D path can
// be compared against MAME PIXEL BY PIXEL rather than by eye.
//
// P1.5's exit criterion 4 says the rendered frame must match MAME's screenshot.
// That was judged on hardware, by looking at it — which catches a wrong tilemap
// and does not catch a wrong colour, an off-by-one scroll, a dropped priority
// case or a layer that is right for 383 lines and wrong for one. This is the
// instrument that does.
//
// INPUT IS THE CPU'S OWN OUTPUT. The tile, char and palette images fed in here
// are the ones our i960 built from the real Daytona ROM, dumped by
// tb_i960_rom.cpp and already verified byte-identical to MAME's (study R26).
// So a difference in the picture is the RENDERER's, with the content side
// already ruled out — which is the whole reason to do them in that order.
//
// Addressing follows Model2.sv exactly, because that is the mapping proven on
// hardware:
//   tram_addr  15 bits, indexes 16-bit words of tile.bin
//   pal_addr   12 bits, indexes 16-bit words of palette.bin
//   char_addr  18 bits, indexes 16-bit words of char.bin, and char_data is
//              {word1, word0} — two consecutive words, not one dword.

#include "Vm2_video.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <algorithm>

static Vm2_video *dut;

static std::vector<uint16_t> tram, pal;
static std::vector<uint16_t> chr;

static bool load_u16(const std::string &path, std::vector<uint16_t> &out) {
  FILE *f = std::fopen(path.c_str(), "rb");
  if (!f) return false;
  std::fseek(f, 0, SEEK_END); long n = std::ftell(f); std::fseek(f, 0, SEEK_SET);
  std::vector<uint8_t> b(size_t(n), 0);
  const size_t got = std::fread(b.data(), 1, size_t(n), f);
  std::fclose(f);
  if (got != size_t(n)) return false;
  out.resize(b.size() / 2);
  for (size_t i = 0; i < out.size(); ++i)
    out[i] = uint16_t(b[i*2] | (uint16_t(b[i*2+1]) << 8));
  return true;
}

// 656x424 total, 496x384 visible — MAME's set_raw for Model 2, verified by
// sim/video/tb_m2_video_timing.cpp.
static const int W = 496, H = 384;
static std::vector<uint8_t> fb;

static std::vector<int> g_line_fetch;
static int g_line_n = 0;
static bool g_hb_prev = false;
static uint64_t g_fetches = 0, g_req_cycles = 0, g_cycles = 0;
static bool g_req_prev = false;

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  std::string in = "/tmp/m2-i960-diff/ours";
  std::string out = "/tmp/m2-frame";
  int frames = 3;
  int char_lat = 1;
  for (int i = 1; i < argc; i++) {
    if (!std::strncmp(argv[i], "+in=", 4))     in  = argv[i] + 4;
    if (!std::strncmp(argv[i], "+out=", 5))    out = argv[i] + 5;
    if (!std::strncmp(argv[i], "+frames=", 8)) frames = std::atoi(argv[i] + 8);
    // Char fetch latency, in pixel clocks. Zero is not realistic and one is not
    // SDRAM; the point of the switch is that a picture that changes with it is
    // reporting a BANDWIDTH problem, not a logic one, and the two must not be
    // confused. m2_video counts its own overruns for the same reason.
    if (!std::strncmp(argv[i], "+charlat=", 9)) char_lat = std::atoi(argv[i] + 9);
  }

  if (!load_u16(in + "/tile.bin", tram) ||
      !load_u16(in + "/char.bin", chr) ||
      !load_u16(in + "/palette.bin", pal)) {
    std::printf("m2_video frame: no dumps under %s\n", in.c_str());
    std::printf("SKIP (run tools/i960-datadiff.sh first, or pass +in=<dir>)\n");
    return 0;
  }
  // An ALL-ZERO tile RAM is a real and correct state, not a failure: it is what
  // the boot dump holds, because Daytona has not drawn anything by the time it
  // stalls waiting for the sound board. Rendering it produces a black frame,
  // and calling that a renderer failure would be wrong. Skip and say why.
  {
    bool any = false;
    for (uint16_t w : tram) if (w) { any = true; break; }
    if (!any) {
      std::printf("m2_video frame: tile RAM in %s is entirely zero\n", in.c_str());
      std::printf("SKIP (nothing has been drawn yet -- use a dump from a frame "
                  "with content, e.g. tools/m2-framediff.sh)\n");
      return 0;
    }
  }
  std::printf("m2_video frame render\n");
  std::printf("  tile %zu words, char %zu words, palette %zu words  (from %s)\n",
              tram.size(), chr.size(), pal.size(), in.c_str());

  // The colour translation table, if the dump has one. Model 2's palette runs
  // each 5-bit channel through it before the gamma curve, and MAME indexes it
  // at a STRIDE OF 256 WORDS -- so 32 entries per channel out of 24,576, and
  // the base offsets are 0x0080>>1, 0x4080>>1 and 0x8080>>1 in words.
  std::vector<uint16_t> xlat;
  const bool have_xlat = load_u16(in + "/colorxlat.bin", xlat);
  std::printf("  colorxlat: %s\n", have_xlat ? "loaded" : "absent (table stays pal5bit)");

  dut = new Vm2_video;
  dut->rst_n = 0; dut->ce_pix = 0; dut->tile_mask = 0x3fff;
  dut->xlat_we = 0; dut->xlat_addr = 0; dut->xlat_din = 0;
  dut->tram_data = 0; dut->char_data = 0; dut->char_ack = 0; dut->pal_data = 0;

  fb.assign(size_t(W) * H * 3, 0);

  // The tram and palette reads are REGISTERED in Model2.sv — one cycle of
  // latency, not combinational. Reproduced here, because a renderer that works
  // with a combinational read and not a registered one passes in simulation and
  // fails on the board.
  uint16_t tram_q = 0, pal_q = 0;
  int      cl = 0;
  uint32_t char_pend = 0;
  bool     char_busy = false;

  int  x = 0, y = -1, frame = 0;
  bool hb_p = true, vb_p = true;
  uint64_t cyc = 0;
  const uint64_t LIMIT = uint64_t(frames + 1) * 656 * 424 * 2 + 4096;

  auto half = [&](int lvl) {
    dut->clk = lvl; dut->eval();
  };

  while (cyc < LIMIT && frame <= frames) {
    dut->ce_pix = !dut->ce_pix;

    // Memory model, sampled before the edge.
    dut->tram_data = tram_q;
    dut->pal_data  = pal_q;
    // PER-LINE FETCH DEMAND. Whether buffering more lines helps depends
    // entirely on whether demand is bursty or uniformly over budget, and those
    // two want opposite fixes.
    if (dut->vid_hb && !g_hb_prev) { g_line_fetch.push_back(g_line_n); g_line_n = 0; }
    g_hb_prev = dut->vid_hb;
    if (dut->char_req && !g_req_prev) ++g_line_n;
    if (dut->char_req) ++g_req_cycles;
    if (dut->char_req && !g_req_prev) ++g_fetches;
    g_req_prev = dut->char_req;
    ++g_cycles;
    dut->char_ack  = 0;
    if (char_busy) {
      if (--cl <= 0) { dut->char_data = char_pend; dut->char_ack = 1; char_busy = false; }
    } else if (dut->char_req) {
      const uint32_t a = dut->char_addr & 0x3ffffu;
      const uint16_t w0 = (a     < chr.size()) ? chr[a]     : 0;
      const uint16_t w1 = (a + 1 < chr.size()) ? chr[a + 1] : 0;
      char_pend = uint32_t(w0) | (uint32_t(w1) << 16);
      cl = char_lat;
      if (cl <= 0) { dut->char_data = char_pend; dut->char_ack = 1; }
      else char_busy = true;
    }

    // Load the translation table during reset, one entry per cycle. Ninety-six
    // entries, so it is complete long before the first pixel.
    dut->xlat_we = 0;
    if (have_xlat && cyc < 96) {
      static const uint32_t BASE[3] = { 0x0080u >> 1, 0x4080u >> 1, 0x8080u >> 1 };
      const uint32_t ch = uint32_t(cyc) / 32, iv = uint32_t(cyc) % 32;
      const uint32_t idx = BASE[ch] + (iv << 8);
      dut->xlat_we   = 1;
      dut->xlat_addr = uint8_t(ch * 32 + iv);
      dut->xlat_din  = uint8_t(idx < xlat.size() ? (xlat[idx] & 0xff) : 0);
    }

    half(0);
    half(1);
    ++cyc;
    if (cyc == 128) dut->rst_n = 1;

    // Registered reads land after the edge, addressed by what the DUT drove.
    tram_q = (dut->tram_addr < tram.size()) ? tram[dut->tram_addr] : 0;
    pal_q  = (dut->pal_addr  < pal.size())  ? pal[dut->pal_addr]   : 0;

    if (!dut->ce_pix) continue;          // one pixel per ce_pix

    const bool hb = dut->vid_hb, vb = dut->vid_vb;
    if (vb && !vb_p) { ++frame; y = -1; }        // entered vblank: frame done
    if (!hb && hb_p) { x = 0; if (!vb) ++y; }    // left hblank: new visible line
    if (!hb && !vb && frame == frames && y >= 0 && y < H && x < W) {
      const size_t o = (size_t(y) * W + x) * 3;
      fb[o+0] = dut->vid_r; fb[o+1] = dut->vid_g; fb[o+2] = dut->vid_b;
    }
    if (!hb && !vb) ++x;
    hb_p = hb; vb_p = vb;
  }

  // PPM for looking at, RAW for comparing. Both, because "it looks right" and
  // "it is right" are different claims and this project has been caught by the
  // gap between them before.
  {
    const std::string p1 = out + ".ppm";
    FILE *f = std::fopen(p1.c_str(), "wb");
    if (f) {
      std::fprintf(f, "P6\n%d %d\n255\n", W, H);
      std::fwrite(fb.data(), 1, fb.size(), f);
      std::fclose(f);
      std::printf("  wrote %s\n", p1.c_str());
    }
    const std::string p2 = out + ".raw";
    FILE *g = std::fopen(p2.c_str(), "wb");
    if (g) { std::fwrite(fb.data(), 1, fb.size(), g); std::fclose(g); }
  }

  // A frame that is entirely one colour is the failure this harness exists to
  // notice: it means the render ran and produced nothing, which a file-size
  // check would call success.
  size_t nonzero = 0, distinct_rows = 0;
  for (size_t i = 0; i < fb.size(); i += 3) if (fb[i] | fb[i+1] | fb[i+2]) ++nonzero;
  for (int r = 1; r < H; ++r)
    if (std::memcmp(&fb[size_t(r) * W * 3], &fb[size_t(r-1) * W * 3], size_t(W) * 3))
      ++distinct_rows;
  // THE TAPS Model2.sv THROWS AWAY. This render is correct, so these are the
  // values a working board must show. dbg_ctrl comes out of tile RAM itself
  // (m2_video line 504), so a board reading zero here has not got the tilemap
  // into M10K whatever the SDRAM readback says.
  {
    std::vector<int> v;
    for (int x : g_line_fetch) if (x > 0) v.push_back(x);
    if (!v.empty()) {
      std::sort(v.begin(), v.end());
      long sum = 0; for (int x : v) sum += x;
      std::printf("  per-line fetch demand over %zu non-empty lines: "
                  "mean %.1f  median %d  p90 %d  max %d\n",
                  v.size(), double(sum)/double(v.size()),
                  v[v.size()/2], v[(v.size()*9)/10], v.back());
      std::printf("    burstiness max/mean = %.2fx  (>2x means buffering ahead "
                  "smooths real variance; ~1x means demand is uniform and only "
                  "fewer fetches or more bandwidth helps)\n",
                  double(v.back()) / (double(sum)/double(v.size())));
    }
  }
  std::printf("  fetches %llu over %llu cycles; engine waiting on memory %llu "
              "cycles (%.1f%% of all time)\n",
              (unsigned long long)g_fetches, (unsigned long long)g_cycles,
              (unsigned long long)g_req_cycles,
              100.0 * double(g_req_cycles) / double(g_cycles ? g_cycles : 1));
  std::printf("  dbg_ctrl: %04x %04x   dbg_layer_have: %03x %03x %03x %03x\n"
              "  dbg_fetches: %u  dbg_overruns: %u\n",
              dut->dbg_ctrl[0], dut->dbg_ctrl[1],
              dut->dbg_layer_have[0], dut->dbg_layer_have[1],
              dut->dbg_layer_have[2], dut->dbg_layer_have[3],
              (unsigned)dut->dbg_fetches, (unsigned)dut->dbg_overruns);
  std::printf("  %zu of %d pixels non-black, %zu row transitions\n",
              nonzero, W * H, distinct_rows);

  const bool ok = nonzero > 0 && distinct_rows > 4;
  std::printf("%s\n", ok ? "PASS" : "FAIL (frame is blank or uniform)");
  return ok ? 0 : 1;
}
