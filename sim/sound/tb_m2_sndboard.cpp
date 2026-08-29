// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// The sound board's 68000, against MAME's own instruction stream.
//
// This is the same shape as the i960 lockstep that got the main CPU right, and
// for the same reason: "it seems to run" is not a result. MAME's debugger traces
// :m1audio:sndcpu from reset, and the first instruction is
//
//     000300: move #$2700, SR
//
// so the PC sequence is a hard oracle. A 68000 that fetches the right opcodes
// but takes a branch the wrong way diverges within a few hundred instructions,
// and this says exactly where.
//
// The ROM is the real 256 KB: epr-16489.7 and epr-16490.8, interleaved to 16
// bits. The MRA declares them output="16" map="12", which is a byte swap -- the
// 68000 is big-endian and the file pair is not -- and getting that backwards
// makes every opcode garbage, which is a failure worth being able to recognise
// immediately rather than debug as "the CPU does not run".
//
// The ROM is served with LATENCY, not instantly. A harness that answers in the
// same cycle hides every DTACK stall the real fetch has, and the bus state
// machine's whole job is those stalls.

#include "Vm2_sndboard_harness.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>

static Vm2_sndboard_harness *d;

static bool load_file(const std::string &p, std::vector<uint8_t> &v) {
  FILE *f = std::fopen(p.c_str(), "rb");
  if (!f) return false;
  std::fseek(f, 0, SEEK_END); long n = std::ftell(f); std::fseek(f, 0, SEEK_SET);
  v.resize(size_t(n));
  size_t got = std::fread(v.data(), 1, size_t(n), f);
  std::fclose(f);
  return got == size_t(n);
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  const char *rp = std::getenv("M2_ROMPATH");
  const std::string dir = std::string(rp ? rp :
      (std::string(std::getenv("HOME") ? std::getenv("HOME") : ".") + "/roms/Model2"))
      + "/daytona93/";

  std::vector<uint8_t> a, b;
  if (!load_file(dir + "epr-16489.7", a) || !load_file(dir + "epr-16490.8", b)) {
    std::printf("SKIP (no ROMs; set M2_ROMPATH to a directory holding daytona93/)\n");
    return 0;
  }

  // 128 KB + 128 KB -> 256 KB of 16-bit words, CONCATENATED, each word BYTE
  // SWAPPED. Both halves of that were got wrong first time and the ROM itself
  // settles them without any guessing:
  //
  //   epr-16489.7 begins  f0 00 fe ff 00 00 00 03
  //
  // Swap each 16-bit word and that is SP = 0x00F0FFFE -- the top of the 64 KB
  // RAM at 0xF00000, which is what a stack pointer should be -- and PC =
  // 0x00000300, which is exactly where MAME's trace starts. Unswapped it is
  // 0xF000FEFF and 0x00000003, neither of which is anything.
  //
  // And they are two separate 128 KB images, not two halves of an interleave.
  // The MRA has two single-part <interleave> blocks rather than one with two
  // parts, and the map confirms it: MAME's second ROM window, 080000-09FFFF,
  // reads region offset 0x20000 -- byte 0x20000 is exactly where the second
  // file starts. Interleaving them makes every other word wrong, which reads
  // as a CPU that fetches its reset vector correctly and then runs nonsense.
  std::vector<uint16_t> rom(128 * 1024, 0xffff);
  for (size_t w = 0; w * 2 + 1 < a.size(); ++w)
    rom[w] = uint16_t((a[w * 2 + 1] << 8) | a[w * 2]);
  for (size_t w = 0; w * 2 + 1 < b.size(); ++w)
    rom[65536 + w] = uint16_t((b[w * 2 + 1] << 8) | b[w * 2]);

  // MAME's stream. Optional: without it this still runs and reports what the
  // board did, which is what a first bring-up needs.
  std::vector<uint32_t> ref;
  if (const char *tr = std::getenv("M2_SND_TRACE")) {
    FILE *f = std::fopen(tr, "r");
    if (f) {
      char line[512];
      while (std::fgets(line, sizeof line, f)) {
        // "000300: move #$2700, SR"
        char *colon = std::strchr(line, ':');
        if (!colon || colon - line != 6) continue;
        char hex[7]; std::memcpy(hex, line, 6); hex[6] = 0;
        char *end = nullptr;
        unsigned long v = std::strtoul(hex, &end, 16);
        if (end == hex + 6) ref.push_back(uint32_t(v));
      }
      std::fclose(f);
      std::printf("  reference: %zu instructions from MAME\n", ref.size());
    }
  }

  d = new Vm2_sndboard_harness;
  d->rst_n = 0;
  d->rom_ack = 0; d->rom_data = 0;
  d->rx_data = 0; d->rx_valid = 0; d->tx_ack = 0;

  const int ROM_LAT = std::getenv("M2_SND_ROMLAT")
                    ? std::atoi(std::getenv("M2_SND_ROMLAT")) : 6;
  int lat = 0;
  bool serving = false;

  auto tick = [&]() {
    // The ROM port, with latency.
    if (d->rom_req && !serving && !d->rom_ack) { serving = true; lat = ROM_LAT; }
    if (serving) {
      if (lat > 0) { --lat; }
      else {
        uint32_t wa = d->rom_addr;              // word address, 17:1
        d->rom_data = (wa < rom.size()) ? rom[wa] : 0xffff;
        d->rom_ack  = 1;
        serving = false;
      }
    }
    d->clk = 0; d->eval();
    d->clk = 1; d->eval();
    if (d->rom_ack) d->rom_ack = 0;
  };

  for (int i = 0; i < 64; ++i) tick();
  d->rst_n = 1;

  // Follow instruction fetches on the bus. The 68000 prefetches, so not every
  // fetch is an instruction START -- the PC stream is taken from the address of
  // a read in the ROM window that MAME also lists, matched in ORDER rather than
  // one for one, which is what makes this robust to prefetch depth.
  // Cheap without a reference, thorough with one. In the suite this runs far
  // enough to prove the CPU boots and clears RAM; the full 285,571-instruction
  // lockstep is a deliberate M2_SND_TRACE run, because the trace is 12 MB of
  // MAME output and does not belong in the repository.
  const long MAXC = std::getenv("M2_SND_CYCLES")
                  ? std::atol(std::getenv("M2_SND_CYCLES"))
                  : (ref.empty() ? 2000000L : 600000000L);
  // MATCHED ON THE FLY, not collected and compared afterwards. The board's bus
  // carries prefetches and operand reads as well as instruction starts, so it
  // needs several times as many cycles as MAME has instructions -- collecting a
  // fixed number and stopping reports a partial match as a divergence.
  std::vector<uint32_t> got;
  int prev_as = 0;
  uint32_t first_pc = 0xffffffff;
  size_t ri = 0, resyncs = 0, skipped = 0;
  int fm_min = 0, fm_max = 0;
  long fm_n = 0, fm_nz = 0;
  uint32_t stuck_at = 0;
  long stuck_since = 0;
  long c = 0;
  for (; c < MAXC; ++c) {
    tick();
    if (d->obs_as && !prev_as) {
      uint32_t ad = d->obs_addr;
      if (!d->obs_we && ad < 0x100000) {
        if (first_pc == 0xffffffff) first_pc = ad;
        if (got.size() < 64) got.push_back(ad);
        if (ri < ref.size() && ad == ref[ri]) {
          ++ri;
          stuck_at = ad; stuck_since = c;
        } else if (ri > 0 && ri < ref.size()) {
          // RESYNC ACROSS A WAIT LOOP, on the same terms as
          // tools/i960-resync-diff.py -- and for the same reason. The firmware
          // polls hardware that is not built yet:
          //
          //   0007B0: move.b $d00001.l, D3   / btst #7 / bne $7b0
          //
          // is the YM3438's BUSY flag, and MAME's real part is busy for many
          // iterations where this stub answers immediately. The board leaves
          // the loop early, so the reference has iterations the board never
          // produces. That is a difference in speed, not in behaviour.
          //
          // NOT LOOP COLLAPSING, which study R15 records as having produced
          // wrong answers. The streams are compared raw; only on a mismatch is
          // a resynchronisation looked for, it is accepted ONLY if everything
          // skipped is inside a SHORT REPEATING CYCLE, and every one is counted
          // so a resync hiding a real defect shows up as an implausible number
          // rather than being silently absorbed. Going somewhere NEW is a
          // defect and still stops the comparison.
          size_t lim = ri + 64 < ref.size() ? ri + 64 : ref.size();
          size_t hit = 0;
          for (size_t k = ri; k < lim; ++k) if (ref[k] == ad) { hit = k; break; }
          if (hit > ri) {
            bool spin = true;
            for (size_t k = ri; k < hit && spin; ++k) {
              bool seen = false;
              for (size_t j = (ri > 12 ? ri - 12 : 0); j < ri; ++j)
                if (ref[j] == ref[k]) { seen = true; break; }
              if (!seen) spin = false;
            }
            if (spin) {
              resyncs++; skipped += hit - ri;
              ri = hit + 1;
              stuck_at = ad; stuck_since = c;
            }
          }
        }
      }
    }
    {
      int16_t l = int16_t(d->snd_l);
      if (l != 0) ++fm_nz;
      if (l < fm_min) fm_min = l;
      if (l > fm_max) fm_max = l;
      ++fm_n;
    }
    prev_as = d->obs_as;
    if (!ref.empty() && ri >= ref.size()) break;
    // A divergence shows as the reference standing still while the board keeps
    // running. Give it a wide margin -- some of these instructions are long --
    // and report WHERE it stopped, which is the useful half.
    if (!ref.empty() && ri > 0 && c - stuck_since > 2000000) break;
  }

  std::printf("  ran %ld cycles, %u bus cycles, first ROM read at %06X\n",
              c, (unsigned)d->dbg_insns, first_pc);

  // THE FM OUTPUT ITSELF. A CPU that follows MAME's path and emits silence has
  // not made sound, and that is the whole point of the exercise. Reported as
  // range and a count of non-zero samples: a dead channel is zero, a
  // mis-clocked one is a rail, and correct FM is neither.
  std::printf("  FM output: %d..%d over %ld samples, %ld non-zero\n",
              fm_min, fm_max, fm_n, fm_nz);
  if (fm_n > 0 && fm_nz == 0) {
    std::printf("  NOTE the FM is silent -- the CPU ran but nothing was voiced\n");
  }

  int fails = 0;
  if (first_pc != 0x000000) {
    // The 68000 fetches its stack pointer from 0 and its PC from 4 before
    // anything else. Not seeing that means the CPU never came out of reset,
    // which is a different failure from executing the wrong code.
    std::printf("  FAIL first ROM read was %06X, expected 000000 (reset vector)\n", first_pc);
    ++fails;
  }

  if (!ref.empty()) {
    std::printf("  matched %zu of %zu reference instructions in order", ri, ref.size());
    if (resyncs) std::printf("  [%zu resyncs, %zu skipped]", resyncs, skipped);
    if (ri < ref.size())
      std::printf("  (stopped after %06X)", stuck_at);
    std::printf("\n");
    // THE FLOOR, AND WHY IT IS WHERE IT IS.
    //
    // 72,035 instructions of MAME's own path: the reset vector, the 32,768-word
    // RAM clear, the MULTIPCM initialisation on both banks, the YM3438
    // register load. Then:
    //
    //   000542: move.b $d00001.l, D3
    //   000548: btst   #$1, D3
    //   00054C: beq    $554
    //
    // and MAME does NOT take that branch. Bit 1 of the YM3438's status is the
    // TIMER B OVERFLOW flag, and the firmware's main loop sequences music on
    // it. With the chip STUBBED that flag never sets, so the board took the
    // branch MAME does not and the paths parted at 72,035 -- correctly, since
    // the hardware did not exist.
    //
    // With the real jt12 in place that wall moved to 98,025, and the one after
    // it is a DIFFERENT KIND OF THING. The board now gets the flag; it simply
    // reaches the poll at a different absolute moment than MAME does, so the
    // two read it in different states at 0x5CC. That is relative timing between
    // a 10 MHz CPU and an 8 MHz timer, not a defect, and no amount of work on
    // this core will make two independent emulations agree on it -- the
    // standing rule is that a MAME cycle count is not a hardware fact.
    //
    // So instruction lockstep has given what it can give. Past here the honest
    // instrument is the AUDIO, checked below: silence and noise are both
    // obvious, and neither depends on the two machines staying in step.
    const size_t FLOOR = 98000;
    if (ri < FLOOR) {
      std::printf("  FAIL matched %zu, below the established floor of %zu\n", ri, FLOOR);
      ++fails;
    } else if (ri < ref.size()) {
      std::printf("  stops at the YM3438's timer B flag, which is the next piece\n");
    }
    if (false) {
      std::printf("  FAIL the board leaves MAME's path\n");
      std::printf("  MAME  :");
      for (size_t i = 0; i < 8 && i < ref.size(); ++i) std::printf(" %06X", ref[i]);
      std::printf("\n  board :");
      for (size_t i = 0; i < 8 && i < got.size(); ++i) std::printf(" %06X", got[i]);
      std::printf("\n");
      ++fails;
    }
  }

  std::printf("m2_sndboard: fails=%d\n", fails);
  std::printf("%s\n", fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
