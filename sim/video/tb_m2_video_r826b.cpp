// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R826b: THE 2D HELD TO ITS 3D, PLAYED FROM A SCHEDULE. m2_video_ovr_top's
// `d` path (SCR_SYNC, and SCR_STEP / SCR_DEPTH when built so) is driven by an
// event list written by the R826 event model (game steps, flips, the vblank
// IRQ's scroll writes, the 3D's publishes, R652 holds), and the scroll the
// sequencer actually latched for tilemap 2 (hctrl_r, the window pair's
// scroll) is read back on every line. Each list's scroll words are distinct
// (hscr2 = 7 (tag + 2) mod 512), so the line's latched word names the list it
// was written for.
//
//   schedule lines:  <t> <type> <value...>    t in frames, vblank k at t = k
//     V <tag>     a vblank the game is given: scr_ttag = tag, scr_vtgl toggles
//     W <tag>     the vblank IRQ writes the scroll words of list <tag>
//     F 0         a flip (0x803008): scr_flip toggles
//     P <tag>     the 3D publishes list <tag> (scr_tag)
//     R <p> <top> <bot>  the model's prediction for the frame after vblank k:
//                 3D list p, 2D list shown at line 0 and at line 383
//
// Reported: frames where the RTL's line-0 / line-383 lists equal the model's
// (the model is checked against the RTL), and the RTL's own alignment against
// the 3D list on screen: aligned / +1 / -1 / torn (line 0 and 383 differ) /
// other.
//
//   obj_m2_vr826b*/Vm2_video_ovr_top <schedule> [label]

#include "Vm2_video_ovr_top.h"
#include "Vm2_video_ovr_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <map>
#include <algorithm>
#include <cmath>
#include <array>

struct Port {
  int wait = -1; bool need_low = false;
  void step(uint8_t req, uint32_t addr, uint8_t &ack, uint64_t &data, const std::vector<uint16_t> &chr) {
    ack = 0;
    if (!req) need_low = false;
    if (wait < 0 && req && !need_low) wait = 0;
    if (wait == 0) {
      const uint32_t a = addr & 0x3fffcu;
      uint64_t w = 0;
      for (int k = 0; k < 4; k++) w |= uint64_t((a + k) < chr.size() ? chr[a + k] : 0xffffu) << (16 * k);
      data = w; ack = 1; wait = -1; need_low = true;
    } else if (wait > 0) --wait;
  }
};

// The words written for list L (iteration L + 2 in tb_m2_video_r826's terms):
// pair 0/1 window mode 2 with the HUD shake, pair 2/3 window mode 1 with the
// backdrop scroll 7 (L + 2).
static void words(int L, uint16_t w[8]) {
  const int j = L + 2;
  w[0] = (j % 4 == 0) ? 0x0010 : (j % 4 == 2) ? 0xfff0 : 0x0000;
  w[1] = 0;
  w[2] = uint16_t((7 * j) & 0x1ff);
  w[3] = 0;
  w[4] = 0x4000;
  w[5] = 0;
  w[6] = uint16_t(0x2000 | ((0x16a + 3 * j) & 0x1ff));
  w[7] = 0;
}
// hscr2 -> list: 7 * 439 = 1 (mod 512)
static int tag_of(uint16_t h, int near) {
  int j = int((uint32_t(h & 0x1ff) * 439u) & 0x1ffu);
  int L = j - 2;
  while (L < near - 256) L += 512;
  while (L > near + 256) L -= 512;
  return L;
}

struct Ev { double t; char ty; int v; int a, b, c; };

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  if (argc < 2) { std::fprintf(stderr, "usage: %s <schedule> [label]\n", argv[0]); return 2; }
  const char *label = argc > 2 ? argv[2] : argv[1];
  std::vector<Ev> ev;
  {
    FILE *f = std::fopen(argv[1], "r");
    if (!f) { std::perror(argv[1]); return 2; }
    char line[256];
    while (std::fgets(line, sizeof line, f)) {
      Ev e{}; char ty = 0; int a = 0, b = 0, c = 0;
      const int n = std::sscanf(line, "%lf %c %d %d %d", &e.t, &ty, &a, &b, &c);
      if (n < 3) continue;
      e.ty = ty; e.v = a; e.a = a; e.b = b; e.c = c;
      ev.push_back(e);
    }
    std::fclose(f);
  }
  std::stable_sort(ev.begin(), ev.end(), [](const Ev &x, const Ev &y) { return x.t < y.t; });
  int nframes = 0;
  for (const Ev &e : ev) nframes = std::max(nframes, int(std::floor(e.t)) + 1);

  Vm2_video_ovr_top *d = new Vm2_video_ovr_top;
  auto *rp = d->rootp;
  std::vector<uint16_t> tr(0x8000, 0), td(0x8000, 0), chr(0x40000);
  for (size_t i = 0; i < chr.size(); i++) chr[i] = uint16_t((i * 2654435761u) >> 13);
  // base image: maps 2/3 hold distinct tiles, 0/1 the HUD rows; window words of list -2
  for (int L = 0; L < 4; L++)
    for (int i = 0; i < 0x1000; i++)
      td[size_t(L) * 0x1000 + size_t(i)] = (L >= 2) ? uint16_t((L == 3 ? 0x1000 : 0) | i)
                                                    : uint16_t(0x2000 + L * 8 + (i % 8));
  { uint16_t w[8]; words(-2, w); for (int i = 0; i < 8; i++) td[size_t(0x5000 + i)] = w[i]; }
  tr = td;
  Port pr, pd;
  d->rst_n = 0; d->ce_pix = 0; d->interlace = 0; d->ntsc_lines = 0; d->r_m_ack = 0; d->d_m_ack = 0;
  d->d_flip = 0; d->d_tag = 0; d->d_vtgl = 0; d->d_ttag = 0;
  uint16_t rq = 0, dq = 0;
  unsigned ce_acc = 0;
  // line bookkeeping
  int lvc = -1;
  long abs_line = -1;          // line starts seen
  long v0 = -1;                // abs line of model vblank 0
  int vbl_seen = 0;
  uint64_t line_cyc = 0, cyc_per_line = 4100;
  size_t ei = 0;
  int vtgl_pend = -1;
  bool flip = false, vtgl = false;
  // per model frame k: RTL tag at line 0 and 383, and every change
  std::map<int, int> rtl_top, rtl_bot, rtl_chg;
  std::map<int, int> last_tag;
  std::map<int, std::array<int,3>> pred;
  for (const Ev &e : ev) if (e.ty == 'R') pred[int(std::floor(e.t + 1e-9))] = {e.a, e.b, e.c};
  int cur_near = 0;
  const uint64_t LIMIT = uint64_t(nframes + 6) * 4200ull * 424ull;
  for (uint64_t cyc = 0; cyc < LIMIT; ++cyc) {
    if (ce_acc + 16 >= 100) { ce_acc = ce_acc + 16 - 100; d->ce_pix = 1; } else { ce_acc += 16; d->ce_pix = 0; }
    d->r_tram_data = rq; d->d_tram_data = dq;
    uint8_t a; uint64_t w = 0;
    pr.step(d->r_m_req, d->r_m_addr, a, w, chr); d->r_m_ack = a; if (a) d->r_m_data = w;
    pd.step(d->d_m_req, d->d_m_addr, a, w, chr); d->d_m_ack = a; if (a) d->d_m_data = w;
    d->clk = 0; d->eval();
    if (int(d->vcnt) != lvc) {
      if (lvc >= 0 && abs_line >= 1) cyc_per_line = line_cyc;
      lvc = int(d->vcnt); abs_line++; line_cyc = 0;
      if (lvc == 384) { vbl_seen++; if (vbl_seen == 3 && v0 < 0) v0 = abs_line; }
    } else line_cyc++;
    // schedule
    if (v0 >= 0) {
      while (ei < ev.size()) {
        const Ev &e = ev[ei];
        const double ln = e.t * 424.0;
        const long el = v0 + long(std::floor(ln));
        const uint64_t ec = uint64_t((ln - std::floor(ln)) * double(cyc_per_line));
        if (abs_line < el || (abs_line == el && line_cyc < ec)) break;
        switch (e.ty) {
          case 'W': { uint16_t ww[8]; words(e.v, ww); for (int i = 0; i < 8; i++) td[size_t(0x5000 + i)] = ww[i]; cur_near = e.v; break; }
          case 'F': flip = !flip; d->d_flip = flip; break;
          case 'P': d->d_tag = uint8_t(e.v & 15); break;
          case 'V': d->d_ttag = uint8_t(e.v & 15); vtgl_pend = 40; break;
          default: break;
        }
        ei++;
      }
    }
    if (vtgl_pend >= 0 && vtgl_pend-- == 0) { vtgl = !vtgl; d->d_vtgl = vtgl; }
    // the latched scroll of tilemap 2, per line rendered (q == Q_HTAB, layer 2)
    if (v0 >= 0 && rp->m2_video_ovr_top__DOT__u_d__DOT__q == 9 && rp->m2_video_ovr_top__DOT__u_d__DOT__cur_layer == 2) {
      const int line = int(rp->m2_video_ovr_top__DOT__u_d__DOT__cur_line);
      const int tg = tag_of(uint16_t(rp->m2_video_ovr_top__DOT__u_d__DOT__hctrl_r), cur_near);
      // the frame this line is shown in: visible line L of model frame k is
      // abs line v0 + k*424 + 40 + L; the sequencer runs a few lines ahead
      const long lead_abs = abs_line + 4;
      const int k = int((lead_abs - v0 - 40) / 424);
      if (line == 0) rtl_top[k] = tg;
      if (line == 383) rtl_bot[k] = tg;
      if (line < 384) {
        auto it = last_tag.find(k);
        if (it != last_tag.end() && it->second != tg) rtl_chg[k]++;
        last_tag[k] = tg;
      }
    }
    const uint32_t ra = d->r_tram_addr, da = d->d_tram_addr;
    d->clk = 1; d->eval();
    if (cyc == 64) d->rst_n = 1;
    rq = tr[ra & 0x7fff]; dq = td[da & 0x7fff];
    if (v0 >= 0 && abs_line > v0 + long(nframes + 1) * 424) break;
  }
  delete d;
  int n = 0, agree = 0, al = 0, p1 = 0, m1 = 0, tear = 0, oth = 0;
  for (auto &kv : pred) {
    const int k = kv.first;
    if (!rtl_top.count(k) || !rtl_bot.count(k)) continue;
    n++;
    const int P = kv.second[0], mt = kv.second[1], mb = kv.second[2];
    const int t = rtl_top[k], b = rtl_bot[k];
    if (t == mt && b == mb) agree++;
    else if (std::getenv("R826B_DIFF")) std::printf("   frame %d: 3D %d  model %d/%d  RTL %d/%d\n", k, P, mt, mb, t, b);
    if (t != b) tear++;
    else if (t == P) al++;
    else if (t == P + 1) p1++;
    else if (t == P - 1) m1++;
    else oth++;
    if (std::getenv("R826B_TRACE")) std::printf("   frame %d: 3D %d  model %d/%d  RTL %d/%d chg %d\n", k, P, mt, mb, t, b, rtl_chg[k]);
  }
  std::printf("  %-32s frames %4d  RTL = model %4d  | RTL: aligned %4d  +1 %3d  -1 %3d  torn %3d  other %3d\n",
              label, n, agree, al, p1, m1, tear, oth);
  return (n > 0 && agree == n) ? 0 : 1;
}
