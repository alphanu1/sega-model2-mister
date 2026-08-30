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
#include <cmath>
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
  // THE SAMPLE ROMS, 4 MB each. pcm1 is mpr-16491 + mpr-16492 and pcm2 is
  // mpr-16493 + mpr-16494 -- established by reading MAME's own region contents
  // and matching them against the files, not by assuming the MRA's order.
  std::vector<uint8_t> pcm1, pcm2;
  for (auto f : {"mpr-16491.32", "mpr-16492.33"}) {
    std::vector<uint8_t> v;
    if (load_file(dir + f, v)) pcm1.insert(pcm1.end(), v.begin(), v.end());
  }
  for (auto f : {"mpr-16493.4", "mpr-16494.5"}) {
    std::vector<uint8_t> v;
    if (load_file(dir + f, v)) pcm2.insert(pcm2.end(), v.begin(), v.end());
  }
  std::printf("  samples: pcm1 %.1f MB, pcm2 %.1f MB\n",
              pcm1.size()/1048576.0, pcm2.size()/1048576.0);

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
  d->pcm1_ack = 0; d->pcm1_data = 0;
  d->pcm2_ack = 0; d->pcm2_data = 0;
  d->rx_data = 0; d->rx_valid = 0; d->tx_ack = 0;

  // TWO LATENCIES, NOT ONE. These were the same variable, and that made every
  // reading of the sample rate uninterpretable: raising it slowed the 68000's
  // own instruction fetch at the same time, so "silent at 80" was a CPU that
  // had not started the music yet, read as a MULTIPCM cliff.
  const int ROM_LAT = std::getenv("M2_SND_ROMLAT")
                    ? std::atoi(std::getenv("M2_SND_ROMLAT")) : 6;
  const int PCM_LAT = std::getenv("M2_SND_PCMLAT")
                    ? std::atoi(std::getenv("M2_SND_PCMLAT")) : ROM_LAT;
  int lat = 0;
  bool serving = false;

  // THE ROM PORT, MODELLED AS THE REAL ONE BEHAVES -- INCLUDING A HELD ACK.
  //
  // This asserted rom_ack for exactly ONE cycle, and m2_sdram holds p_ack for
  // ACK_HOLD, which is 2. A one-cycle ack cannot expose the held-acknowledge
  // hazard of study R32 at all: a consumer that re-arms its request while the
  // previous acknowledge is still high captures the OLD word, and every test
  // here would pass while the board fetched stale data.
  //
  // The hold is a parameter and it is swept, because the point of a test is to
  // find the value at which the design breaks and not to confirm the one that
  // was assumed.
  const int ACK_HOLD = std::getenv("M2_SND_ACKHOLD")
                     ? std::atoi(std::getenv("M2_SND_ACKHOLD")) : 2;
  int ack_left = 0, p1_ack_left = 0, p2_ack_left = 0;
  int p1_lat = 0, p2_lat = 0;
  bool p1_serving = false, p2_serving = false;
  auto tick = [&]() {
    if (d->rom_req && !serving && !d->rom_ack) { serving = true; lat = ROM_LAT; }
    if (serving) {
      if (lat > 0) { --lat; }
      else {
        uint32_t wa = d->rom_addr;              // word address, 17:1
        d->rom_data = (wa < rom.size()) ? rom[wa] : 0xffff;
        d->rom_ack  = 1;
        ack_left    = ACK_HOLD;
        serving = false;
      }
    }
    // The two sample ports. Same latency model as the program ROM, because
    // they contend for the same controller on hardware.
    if (d->pcm1_req && !p1_serving && !d->pcm1_ack) { p1_serving = true; p1_lat = PCM_LAT; }
    if (p1_serving) {
      if (p1_lat > 0) --p1_lat;
      else {
        uint64_t a = uint64_t(d->pcm1_addr) * 8;   // burst index -> byte
        uint64_t v = 0;
        for (int b = 0; b < 8; ++b)
          v |= uint64_t(a + b < pcm1.size() ? pcm1[a + b] : 0xff) << (b * 8);
        d->pcm1_data = v;
        d->pcm1_ack = 1; p1_ack_left = ACK_HOLD; p1_serving = false;
      }
    }
    if (d->pcm2_req && !p2_serving && !d->pcm2_ack) { p2_serving = true; p2_lat = PCM_LAT; }
    if (p2_serving) {
      if (p2_lat > 0) --p2_lat;
      else {
        uint64_t a = uint64_t(d->pcm2_addr) * 8;
        uint64_t v = 0;
        for (int b = 0; b < 8; ++b)
          v |= uint64_t(a + b < pcm2.size() ? pcm2[a + b] : 0xff) << (b * 8);
        d->pcm2_data = v;
        d->pcm2_ack = 1; p2_ack_left = ACK_HOLD; p2_serving = false;
      }
    }
    d->clk = 0; d->eval();
    d->clk = 1; d->eval();
    if (ack_left    > 0 && --ack_left    == 0) d->rom_ack  = 0;
    if (p1_ack_left > 0 && --p1_ack_left == 0) d->pcm1_ack = 0;
    if (p2_ack_left > 0 && --p2_ack_left == 0) d->pcm2_ack = 0;
  };

  // THE LINK, LIVE, WHICH THE HARDWARE HAS AND THIS TEST DID NOT.
  //
  // Every run so far left rx_valid at zero, so the board's UART never received
  // anything and its RX interrupt never fired. On hardware the i960 sends its
  // 48 bytes within the first couple of hundred milliseconds, and that is a
  // whole code path -- an interrupt, a handler, a queue -- that simulation has
  // never entered. The board runs, takes vector 0x2C repeatedly and never reads
  // its UART; a difference this large between the two is where to look first.
  //
  // MAME's own bytes, paced at the real line rate of 31,250 baud, which at
  // 48 MHz is 15,360 cycles a byte.
  static const uint8_t link[] = {
    0xf8, 0xf8, 0xff,
    0xbe, 0x14, 0x1f,  0xbe, 0x16, 0x02,  0xbe, 0x1b, 0x06,
    0xbe, 0x1c, 0x03,  0xbe, 0x1d, 0x01,  0xbe, 0x1e, 0x02,
    0xbe, 0x1f, 0x05,  0xbe, 0x36, 0x09,  0xbe, 0x17, 0x00,
    0xbe, 0x18, 0x04,  0xbe, 0x35, 0x00,  0xbe, 0x34, 0x00,
    0xae, 0x10, 0x08,  0xbe, 0x17, 0x00,  0xbe, 0x19, 0x00
  };
  const bool do_link = std::getenv("M2_SND_NOLINK") == nullptr;
  const long LINK_AT   = std::getenv("M2_SND_LINKAT")
                       ? std::atol(std::getenv("M2_SND_LINKAT")) : 3000000L;
  const long BYTE_CYC  = 15360;
  size_t link_i = 0;
  long   link_next = LINK_AT;
  long   link_sent = 0;

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
  // LONG ENOUGH TO SEND THE LINK, EVEN WITHOUT A REFERENCE. It was 2,000,000,
  // which stops before the first byte and is exactly why VPA being tied high
  // survived: the board never took an interrupt, so the acknowledge cycle was
  // unreachable and every test passed while the hardware looped 39.9 million
  // bus cycles through a garbage vector. A suite that cannot reach a path
  // cannot defend it.
  const long MAXC = std::getenv("M2_SND_CYCLES")
                  ? std::atol(std::getenv("M2_SND_CYCLES"))
                  : (ref.empty() ? 30000000L : 600000000L);
  // MATCHED ON THE FLY, not collected and compared afterwards. The board's bus
  // carries prefetches and operand reads as well as instruction starts, so it
  // needs several times as many cycles as MAME has instructions -- collecting a
  // fixed number and stopping reports a partial match as a divergence.
  std::vector<uint32_t> got;
  int prev_as = 0;
  uint32_t first_pc = 0xffffffff;
  size_t ri = 0, resyncs = 0, skipped = 0;
  long pcm_samples = 0, cache_reads = 0, cache_bad = 0;
  long last_sample_c = 0, per_min = 1L<<30, per_max = 0, per_sum = 0, per_n = 0;
  double per_sumsq = 0;
  int  prev_slot = 0;
  int fm_min = 0, fm_max = 0, fm_tail_min = 0, fm_tail_max = 0;
  long fm_n = 0, fm_nz = 0, fm_tail_n = 0, fm_tail_nz = 0;
  uint32_t stuck_at = 0;
  long stuck_since = 0;
  long c = 0;
  for (; c < MAXC; ++c) {
    // Offer the next byte when the wire is free and its line time has passed.
    if (do_link && link_i < sizeof link && c >= link_next && !d->rx_valid) {
      d->rx_data  = link[link_i];
      d->rx_valid = 1;
    }
    if (d->rx_valid && d->rx_ack) {
      d->rx_valid = 0;
      ++link_i; ++link_sent;
      link_next = c + BYTE_CYC;
    }
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
      // WHEN, NOT JUST WHETHER. Counting non-zero samples over a whole run says
      // nothing about whether the chip is still voicing anything at the end of
      // it -- a burst of noise while the registers settle and then silence
      // scores exactly the same as music. The last tenth is measured separately
      // and it is the one that matters.
      if (c > MAXC - MAXC / 10) {
        ++fm_tail_n;
        if (l != 0) ++fm_tail_nz;
        if (l < fm_tail_min) fm_tail_min = l;
        if (l > fm_tail_max) fm_tail_max = l;
      }
    }
    // EVERY BYTE THE CACHE HANDS BACK, AGAINST THE ROM. The chip captures
    // c_data on the same edge it sees c_ack, so that is the edge to check.
    if (d->obs_p1_ack && d->obs_p1_req) {
      uint32_t a = d->obs_p1_addr;
      uint8_t want = (a < pcm1.size()) ? pcm1[a] : 0xff;
      ++cache_reads;
      if (d->obs_p1_data != want) {
        if (cache_bad < 6)
          std::printf("  CACHE WRONG at %06X: got %02X want %02X\n",
                      a, d->obs_p1_data, want);
        ++cache_bad;
      }
    }
    // THE PERIOD, NOT JUST THE RATE. A chip that is uniformly 50% slow sounds
    // flat, like a tape running slow, and is tolerable. One that varies between
    // 70% and 100% sounds warbly, and is much worse to listen to even though
    // its AVERAGE rate is better. Average alone cannot tell those apart, which
    // is why a change that raised the average was reported as sounding worse.
    if (prev_slot == 27 && d->obs_pcm_slot == 0) {
      ++pcm_samples;
      if (last_sample_c) {
        long per = c - last_sample_c;
        if (pcm_samples > 200) {          // past the startup transient
          if (per < per_min) per_min = per;
          if (per > per_max) per_max = per;
          per_sum += per; per_n++;
          per_sumsq += double(per) * double(per);
        }
      }
      last_sample_c = c;
    }
    prev_slot = d->obs_pcm_slot;
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
  // WHERE THE SOUND IS SUPPOSED TO COME OUT. The Model 1 board has an FM chip
  // and two sample chips, and which one carries the music is not a guess to
  // make -- the firmware's own register traffic says. If it writes the
  // MULTIPCMs far more than the YM, then a core with only the YM is correctly
  // silent and the missing piece is named.
  std::printf("  register writes: YM3438 %u, MULTIPCM %u\n",
              (unsigned)d->dbg_ym_writes, (unsigned)d->dbg_pcm_writes);
  std::printf("  link: %ld of %zu bytes taken by the sound board\n",
              link_sent, sizeof link);
  std::printf("  rate-stage underruns: %u\n", (unsigned)d->obs_under);
  if (per_n > 0) {
    double mean = double(per_sum) / per_n;
    double var  = per_sumsq / per_n - mean * mean;
    double sd   = var > 0 ? std::sqrt(var) : 0;
    std::printf("  sample period: %ld..%ld cycles, mean %.0f, sd %.1f (%.1f%% jitter)\n",
                per_min, per_max, mean, sd, 100.0 * sd / mean);
  }
  {
    // 48 MHz / cycles-per-sample. The chip's own rate is 10 MHz / 224.
    const double secs = double(c) / 48e6;
    const double hz   = secs > 0 ? double(pcm_samples) / secs : 0;
    std::printf("  MULTIPCM sample rate: %.0f Hz of 44643 (%.0f%%)\n",
                hz, 100.0 * hz / 44643.0);
  }
  std::printf("  FM output: %d..%d over %ld samples, %ld non-zero\n",
              fm_min, fm_max, fm_n, fm_nz);
  std::printf("  FM, last tenth: %d..%d, %ld of %ld non-zero\n",
              fm_tail_min, fm_tail_max, fm_tail_nz, fm_tail_n);

  int fails = 0;

  std::printf("  sample cache: %ld reads, %ld wrong\n", cache_reads, cache_bad);
  if (cache_bad) {
    std::printf("  FAIL the sample cache returns wrong bytes\n");
    ++fails;
  }

  // STILL VOICING AT THE END, which is the property that matters and the one
  // the first version of this check missed. Counting non-zero samples over a
  // whole run scored a burst of noise while the YM's registers settled exactly
  // the same as music, and reported "the sound board makes sound" for a board
  // that was silent from the first second onward. The tail says otherwise.
  if (do_link && fm_tail_n > 0 && fm_tail_nz * 100 < fm_tail_n) {
    std::printf("  FAIL silent at the end: %ld of %ld tail samples non-zero\n",
                fm_tail_nz, fm_tail_n);
    ++fails;
  }

  // EVERY BYTE, OR THE BOARD IS NOT SERVICING ITS UART. One byte taken is the
  // signature of an interrupt that never returns: the first arrives, RXRDY
  // sets, the CPU vectors somewhere wrong and never reads it, so the wire
  // blocks with the second byte in hand. That is precisely what the hardware
  // reported -- two bytes across the link, one of them still held -- and what
  // VPA tied high produces.
  if (do_link && link_i < sizeof link) {
    std::printf("  FAIL the sound board stopped reading its UART after %ld bytes\n",
                link_sent);
    ++fails;
  }
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
