// m2_geo_view: the projection from the window command (R642), checked against
// MAME's formulas on the values p13 logged, and on the power-up window.
#include "Vm2_geo_view.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
static Vm2_geo_view *d;
static int checks = 0, fails = 0;
static float f(uint32_t u) { float x; std::memcpy(&x, &u, 4); return x; }
static void ck(const char *w, float got, float want) {
  ++checks; if (got != want) { ++fails; std::printf("  FAIL %-28s got %g want %g\n", w, got, want); }
}
static void tick() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); }
static int s12(uint32_t v) { v &= 0xfff; return (v & 0x800) ? int(v) - 4096 : int(v); }
static void window(uint32_t vs, uint32_t ve, uint32_t c0, const char *name) {
  d->win_vp_s = vs; d->win_vp_e = ve; d->win_c0 = c0; tick(); tick(); tick();
  const int vx0 = s12(vs >> 16), vy0 = s12(vs), vx1 = s12(ve >> 16), vy1 = s12(ve);
  const int cx = s12(c0 >> 16), cy = s12(c0);
  std::printf("test: %s -- centre (%d,%d), viewport (%d,%d)-(%d,%d)\n", name, cx, cy, vx0, vy0, vx1, vy1);
  ck("xc = crtc_x + cx",          f(d->xc),       float(0 + cx));
  ck("yc = 384 - cy + crtc_y",    f(d->yc),       float(384 - cy + 128));
  ck("a_left = -(cx - vp0)",      f(d->a_left),   float(-(cx - vx0)));
  ck("a_right = vp2 - cx",        f(d->a_right),  float(vx1 - cx));
  ck("a_bottom = vp3 - cy (top)", f(d->a_bottom), float(vy1 - cy));
  ck("a_top = -(cy - vp1)",       f(d->a_top),    float(-(cy - vy0)));
}
int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vm2_geo_view;
  d->rst_n = 0; d->win_vp_s = 0x00000080; d->win_vp_e = 0x01f00200; d->win_c0 = 0x00f80140;
  tick(); tick();
  std::printf("test: reset -- R174's constants\n");
  ck("xc", f(d->xc), 248); ck("yc", f(d->yc), 192);
  ck("a_left", f(d->a_left), -248); ck("a_right", f(d->a_right), 248);
  ck("a_bottom", f(d->a_bottom), 192); ck("a_top", f(d->a_top), -192);
  d->rst_n = 1;
  window(0x00000080, 0x01f00200, 0x00f80140, "power-up window (MAME frame 0)");
  ck("  ... which is R174's yc", f(d->yc), 192);
  window(0xffff0080, 0x01f00200, 0x00f8010e, "Daytona, centre y 270 (85% of frames)");
  window(0xffff0080, 0x01f00200, 0x00f80138, "attract camera, centre y 312");
  window(0xffff0080, 0x01f00200, 0x01600098, "vanishing point 2 (352,152)");
  window(0x0f0f0f0f, 0x07ff07ff, 0x08000800, "extremes: negative corners, -2048 centre");
  std::printf("m2_geo_view: checks=%d fails=%d\n%s\n", checks, fails, fails ? "FAIL" : "PASS");
  delete d; return fails ? 1 : 0;
}
