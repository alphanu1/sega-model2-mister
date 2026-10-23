// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R945: THE GAME'S SETTINGS ACROSS A POWER CYCLE, through the framework's own
// hps_io (tb_m2_nv_save_top.sv). This file is Main_MiSTer on the HPS_BUS, word
// for word as support/arcade/mra_loader.cpp and user_io.cpp send them:
//
//   ROM (index 5, Hanguk Pro Yagu 98's factory EEPROM): FIO_FILE_INDEX 5;
//     FIO_FILE_TX 0xff; FIO_FILE_TX_DAT + words; FIO_FILE_TX 0
//   arcade_nvm_load (only when the .nvm exists): a buffer of the MRA's size,
//     ZERO-FILLED, the file read over it, ALL of it sent on index 2
//   the OSD's save: the core pulses ioctl_upload_req, Main polls
//     UIO_CHK_UPLOAD (0x3C) on the io channel and gets {index, 1}, then
//     arcade_nvm_save: FIO_FILE_INDEX 2; FIO_FILE_TX 0xaa; FIO_FILE_TX_DAT and
//     size / 2 reads; FIO_FILE_TX 0
//
// and the i960 is the game: it bit-bangs the 93C46 through the 315-5649's
// port A / B exactly as model2_state::eeprom_w / in0_r wire it, reads every
// word back serially (the game's own view of its EEPROM), and writes and
// reads backup RAM on its bus.
//
// Each round, with a random EEPROM default (or none), random settings and a
// random strobe spacing (log-uniform, 4 to 400 clk_sys a word: hps_io's
// handshake is tens of cycles on the board; 4 is the pipeline's floor):
//   boot 1  no .nvm: the EEPROM is the MRA's default; the game writes its
//           settings and some backup RAM; the OSD save uploads 16520 bytes --
//           checked byte for byte: backup RAM, "M2EEPROM", the 64 words
//   boot 2  that file: the EEPROM is the SAVED settings, backup RAM the saved
//           RAM; saving again gives the same file
//   boot 3  no .nvm: the MRA's default again
//   boot 4  an earlier core's 16 KB file, zero-padded by Main: the default,
//           and the file's backup RAM
//   boot 5  the saved file with one tag bit flipped: the default
//   boot 6  the saved file under an old MRA (size 16384): the default
//
// Usage: Vtb_m2_nv_save [+rounds=<n>] [+seed=<s>] [+spacing=<cycles>]
// (+spacing fixes the strobe spacing; +spacing=3 is the negative control --
// one cycle inside the pipeline, and the bench must FAIL).

#include "Vtb_m2_nv_save_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <cmath>
#include <random>
#include <vector>

static const int BAK = 16384, TAG = 8, EEB = 128, NVSZ = BAK + TAG + EEB;   // 16520
static const uint8_t TAGB[8] = {'M', '2', 'E', 'E', 'P', 'R', 'O', 'M'};

static Vtb_m2_nv_save_top *t;
static uint64_t cyc;
static int spacing = 0, fixed_spacing = 0;
static uint64_t bad = 0;
static std::mt19937 rng;

static void tick() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); ++cyc; }

#define CHECK(cond, ...) do { if (!(cond)) { if (++bad <= 30) { std::printf("  FAIL cyc %llu: ", (unsigned long long)cyc); std::printf(__VA_ARGS__); std::printf("\n"); } } } while (0)

// ---------------------------------------------------------------- the HPS
static uint16_t spi_w(uint16_t w) {
  t->io_din = w; t->io_strobe = 1; tick(); t->io_strobe = 0;
  for (int i = 1; i < spacing; i++) tick();
  t->eval();
  return t->io_dout;
}
static void fpga_en(bool on) { t->fp_enable = on; tick(); tick(); }
static void io_en(bool on) { t->io_enable = on; tick(); tick(); }
static void set_index(int i) { fpga_en(1); spi_w(0x55); spi_w(uint16_t(i)); fpga_en(0); }
static void download(int idx, const std::vector<uint8_t> &buf) {
  set_index(idx);
  fpga_en(1); spi_w(0x53); spi_w(0xff); fpga_en(0);
  CHECK(t->dl_active, "download did not start");
  fpga_en(1); spi_w(0x54);
  for (size_t k = 0; k + 1 < buf.size(); k += 2) spi_w(uint16_t(buf[k] | (buf[k + 1] << 8)));
  fpga_en(0);
  fpga_en(1); spi_w(0x53); spi_w(0x00); fpga_en(0);
  CHECK(!t->dl_active, "download did not end");
}
// arcade_nvm_load: a zero-filled buffer of the MRA's size, the file over it
static void nvm_load(const std::vector<uint8_t> *file, int mra_size) {
  if (!file) return;   // FileLoadConfig fails: nothing is sent
  std::vector<uint8_t> buf(size_t(mra_size), 0);
  std::memcpy(buf.data(), file->data(), std::min(file->size(), buf.size()));
  download(2, buf);
}
static std::vector<uint8_t> upload(int idx, int size) {
  set_index(idx);
  fpga_en(1); spi_w(0x53); spi_w(0xaa); fpga_en(0);
  CHECK(t->ul_active, "upload did not start");
  std::vector<uint8_t> buf(size_t(size), 0);
  fpga_en(1); spi_w(0x54);
  for (int k = 0; k < size; k += 2) { uint16_t w = spi_w(0); buf[k] = w & 0xff; buf[k + 1] = w >> 8; }
  fpga_en(0);
  fpga_en(1); spi_w(0x53); spi_w(0x00); fpga_en(0);
  CHECK(!t->ul_active, "upload did not end");
  return buf;
}
// the OSD's "Save settings": status[17] up, Main polls UIO_CHK_UPLOAD
static std::vector<uint8_t> osd_save(int mra_size) {
  io_en(1); uint16_t r0 = spi_w(0x3c); io_en(0);
  CHECK(r0 == 0, "UIO_CHK_UPLOAD answered %04x before the save line", r0);
  t->save_btn = 1; for (int i = 0; i < 8; i++) tick(); t->save_btn = 0; for (int i = 0; i < 8; i++) tick();
  io_en(1); uint16_t r = spi_w(0x3c); io_en(0);
  CHECK(r == 0x0201, "UIO_CHK_UPLOAD answered %04x, not 0201 (index 2, requested)", r);
  io_en(1); uint16_t r2 = spi_w(0x3c); io_en(0);
  CHECK(r2 == 0, "UIO_CHK_UPLOAD answered %04x twice for one save", r2);
  return upload(2, mra_size);
}

// ---------------------------------------------------------------- the i960
static uint8_t io_access(bool we, int off, uint8_t data) {
  for (int i = 0; i < 4; i++) tick();
  t->sel = 1; t->we = we; t->word = off >> 1; t->be = (off & 1) ? 0x4 : 0x1;
  t->wdata = (off & 1) ? (uint32_t(data) << 16) : data;
  t->eval();
  uint8_t r = uint8_t(t->rdata >> (16 * (off & 1)));
  tick();
  t->sel = 0; t->we = 0;
  return r;
}
// model2_state::eeprom_w: bit 0 ctrlmode, 5 DI, 6 CS, 7 CLK
static void pa(int cs, int clk, int di) { io_access(true, 0, uint8_t(0x01 | (clk << 7) | (cs << 6) | (di << 5))); }
static int do_bit() { return (io_access(false, 1, 0) >> 5) & 1; }   // in0_r: DO on PB bit 5
static void clock_bit(int di) { pa(1, 0, di); pa(1, 1, di); pa(1, 0, di); }
static void ee_cmd(int op, int a) {
  pa(0, 0, 0); pa(1, 0, 0);
  clock_bit(1);
  const int c = (op << 6) | (a & 63);
  for (int b = 7; b >= 0; b--) clock_bit((c >> b) & 1);
}
static void ee_ewen() { ee_cmd(0, 0x30); pa(0, 0, 0); }
static void ee_write(int a, uint16_t w) {
  ee_cmd(1, a);
  for (int b = 15; b >= 0; b--) clock_bit((w >> b) & 1);
  pa(0, 0, 0);
  pa(1, 0, 0); CHECK(do_bit() == 1, "93C46 not ready after a write"); pa(0, 0, 0);
}
static uint16_t ee_read(int a) {
  ee_cmd(2, a);
  uint16_t d = 0;
  for (int i = 0; i < 16; i++) { if (i) clock_bit(0); d = uint16_t((d << 1) | do_bit()); }
  pa(0, 0, 0);
  return d;
}
static void game_start() { io_access(true, 8, 0xfe); }   // port A an output
static void ee_expect(const uint16_t *exp, const char *what) {
  int miss = 0;
  for (int a = 0; a < 64; a++) {
    uint16_t g = ee_read(a);
    if (g != exp[a] && miss++ < 3) CHECK(false, "%s: EEPROM word %d reads %04x, expected %04x", what, a, g, exp[a]);
  }
  if (miss > 3) CHECK(false, "%s: %d EEPROM words wrong in all", what, miss);
}
static void bak_write(int w, uint32_t v) {
  t->bsel = 1; t->bwe = 1; t->bword = w; t->bbe = 0xf; t->bwdata = v; tick();
  t->bsel = 0; t->bwe = 0; tick();
}
static uint32_t bak_read(int w) {
  t->bsel = 1; t->bwe = 0; t->bword = w; tick();
  t->bsel = 0; t->eval();
  return t->brdata;
}
static uint32_t file_dword(const std::vector<uint8_t> &f, int w) {
  return uint32_t(f[4 * w]) | uint32_t(f[4 * w + 1]) << 8 | uint32_t(f[4 * w + 2]) << 16 | uint32_t(f[4 * w + 3]) << 24;
}
static void bak_expect(const std::vector<uint8_t> *f, const std::vector<int> &words, const char *what) {
  for (int w : words) {
    uint32_t e = f ? file_dword(*f, w) : 0xffffffffu;
    uint32_t g = bak_read(w);
    CHECK(g == e, "%s: backup word %d reads %08x, expected %08x", what, w, g, e);
  }
}

// power on: a fresh configuration (the MLAB's and M10K's initial contents),
// the MRA's ROMs and nvram with the game held, then the game released
static void power_on(const uint16_t *dflt, const std::vector<uint8_t> *file, int mra_size) {
  delete t; t = new Vtb_m2_nv_save_top;
  t->clk = 0; t->por_n = 0; t->rst_n = 0; t->fp_enable = 0; t->io_enable = 0; t->io_strobe = 0;
  t->io_din = 0; t->save_btn = 0; t->sel = 0; t->we = 0; t->word = 0; t->be = 0; t->wdata = 0;
  t->bsel = 0; t->bwe = 0; t->bword = 0; t->bbe = 0; t->bwdata = 0;
  for (int i = 0; i < 6; i++) tick();
  t->por_n = 1; tick();
  if (dflt) {   // <rom index="5">: the factory image, before <nvram>
    std::vector<uint8_t> img(EEB);
    for (int a = 0; a < 64; a++) { img[2 * a] = dflt[a] & 0xff; img[2 * a + 1] = dflt[a] >> 8; }
    download(5, img);
  }
  nvm_load(file, mra_size);
  for (int i = 0; i < 20; i++) tick();
  t->rst_n = 1; tick();
  game_start();
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  int rounds = 24; unsigned seed = 1;
  for (int i = 1; i < argc; i++) {
    if (!std::strncmp(argv[i], "+rounds=", 8)) rounds = std::atoi(argv[i] + 8);
    if (!std::strncmp(argv[i], "+seed=", 6)) seed = unsigned(std::strtoul(argv[i] + 6, nullptr, 10));
    if (!std::strncmp(argv[i], "+spacing=", 9)) fixed_spacing = std::atoi(argv[i] + 9);
  }
  rng.seed(seed);
  uint64_t boots = 0, ee_words = 0, saved_bytes = 0;
  int min_sp = 1 << 30, max_sp = 0;

  for (int r = 0; r < rounds; r++) {
    spacing = fixed_spacing ? fixed_spacing
            : int(std::lround(std::exp(std::log(4.0) + (std::log(400.0) - std::log(4.0)) * (rng() / 4294967296.0))));
    if (!fixed_spacing && r == 0) spacing = 4;   // the floor, every run
    min_sp = std::min(min_sp, spacing); max_sp = std::max(max_sp, spacing);
    const bool has_dflt = (r & 1);               // Hanguk Pro Yagu 98's index 5, or none (the rest)
    uint16_t dflt[64], blank[64], cur[64];
    for (int a = 0; a < 64; a++) { dflt[a] = uint16_t(rng()); blank[a] = 0xffff; }
    const uint16_t *mra = has_dflt ? dflt : blank;

    // boot 1: no .nvm
    power_on(has_dflt ? dflt : nullptr, nullptr, NVSZ); ++boots;
    ee_expect(mra, "boot 1 (no file)"); ee_words += 64;
    std::memcpy(cur, mra, sizeof cur);
    ee_ewen();
    const int nset = 1 + int(rng() % 64);
    for (int k = 0; k < nset; k++) {   // the test menu's changes
      int a = int(rng() % 64); uint16_t w = uint16_t(rng());
      if (k == 0) { a = 63; }          // the last word too, every round
      ee_write(a, w); cur[a] = w;
    }
    ee_expect(cur, "boot 1 after the game's writes"); ee_words += 64;
    std::vector<int> bw;   // backup RAM words the game writes
    for (int k = 0; k < 24; k++) bw.push_back(int(rng() % 4096));
    bw.push_back(0); bw.push_back(4095);
    for (int w : bw) bak_write(w, uint32_t(rng()));
    std::vector<uint8_t> bak_snap(BAK);
    for (int w = 0; w < 4096; w++) { uint32_t v = bak_read(w); std::memcpy(&bak_snap[4 * w], &v, 4); }

    std::vector<uint8_t> f1 = osd_save(NVSZ); saved_bytes += f1.size();
    for (int k = 0; k < BAK; k++)
      if (f1[k] != bak_snap[k]) { CHECK(false, "saved file byte %d (backup) %02x, expected %02x", k, f1[k], bak_snap[k]); break; }
    for (int k = 0; k < TAG; k++) CHECK(f1[BAK + k] == TAGB[k], "saved tag byte %d is %02x", k, f1[BAK + k]);
    for (int a = 0; a < 64; a++) {
      uint16_t w = uint16_t(f1[BAK + TAG + 2 * a] | (f1[BAK + TAG + 2 * a + 1] << 8));
      CHECK(w == cur[a], "saved EEPROM word %d is %04x, expected %04x (MAME .nv layout)", a, w, cur[a]);
    }
    // a change after the save is not in the file
    ee_ewen(); ee_write(0, uint16_t(~cur[0]));

    // boot 2: the saved file
    power_on(has_dflt ? dflt : nullptr, &f1, NVSZ); ++boots;
    ee_expect(cur, "boot 2 (the saved file)"); ee_words += 64;
    bak_expect(&f1, bw, "boot 2 (the saved file)");
    std::vector<uint8_t> f2 = osd_save(NVSZ); saved_bytes += f2.size();
    CHECK(f2 == f1, "boot 2's save differs from the file it loaded");

    // boot 3: no file
    power_on(has_dflt ? dflt : nullptr, nullptr, NVSZ); ++boots;
    ee_expect(mra, "boot 3 (no file)"); ee_words += 64;
    bak_expect(nullptr, bw, "boot 3 (no file)");

    // boot 4: an earlier core's 16 KB file (Main zero-pads it to 16520)
    std::vector<uint8_t> old(f1.begin(), f1.begin() + BAK);
    power_on(has_dflt ? dflt : nullptr, &old, NVSZ); ++boots;
    ee_expect(mra, "boot 4 (a 16 KB file)"); ee_words += 64;
    bak_expect(&old, bw, "boot 4 (a 16 KB file)");

    // boot 5: a damaged tag
    std::vector<uint8_t> dmg = f1;
    dmg[BAK + int(rng() % TAG)] ^= uint8_t(1u << (rng() % 8));
    power_on(has_dflt ? dflt : nullptr, &dmg, NVSZ); ++boots;
    ee_expect(mra, "boot 5 (a damaged tag)"); ee_words += 64;

    // boot 6: the new file under an old MRA (16384): Main sends 16 KB
    power_on(has_dflt ? dflt : nullptr, &f1, BAK); ++boots;
    ee_expect(mra, "boot 6 (old MRA size)"); ee_words += 64;
    bak_expect(&f1, bw, "boot 6 (old MRA size)");

    std::printf("  round %2d: %s, %2d settings written, strobe every %3d cycles: %s\n", r,
                has_dflt ? "MRA default image" : "no MRA image     ", nset, spacing, bad ? "FAILING" : "ok");
  }
  delete t;
  std::printf("  %d rounds, %llu boots, %llu EEPROM words read back by the game, %llu bytes saved, strobe spacing %d-%d, %llu cycles\n",
              rounds, (unsigned long long)boots, (unsigned long long)ee_words, (unsigned long long)saved_bytes,
              min_sp, max_sp, (unsigned long long)cyc);
  if (bad) { std::printf("FAIL: %llu mismatches\n", (unsigned long long)bad); return 1; }
  std::printf("PASS\n");
  return 0;
}
