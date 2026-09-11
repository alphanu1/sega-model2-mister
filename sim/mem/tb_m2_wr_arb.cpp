// tb_m2_wr_arb -- five owners on one write port, against the adapter's rules.
//
// The port behind the arbiter is modelled as m2_sdram_x2's write side does
// it: a request is issued to the controller when the line is up with no
// `w_done` and no acknowledge in flight; the controller latches address and
// data at issue and acknowledges LAT cycles later with a one-cycle pulse;
// `w_done` latches on the acknowledge and clears only on a cycle the request
// line is low. The owners are level requesters that hold until acknowledged
// and then, after a random pause, ask again. Every write each owner asked
// for must land exactly once, with its own address and data, in order, and
// the whole thing must never stop -- which is what the combinational mux
// failed at on the board (R209).
#include "Vm2_wr_arb.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>
#include <deque>

static int checks = 0, fails = 0;
#define CHECK(c, ...) do { ++checks; if (!(c)) { ++fails; std::printf("  FAIL: " __VA_ARGS__); std::printf("\n"); } } while (0)

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const int N = 5;
  const int LAT = std::getenv("LAT") ? std::atoi(std::getenv("LAT")) : 5;
  const int ROUNDS = std::getenv("ROUNDS") ? std::atoi(std::getenv("ROUNDS")) : 20000;
  auto d = new Vm2_wr_arb;
  d->clk = 0; d->rst_n = 0; d->req = 0; d->s_ack = 0;
  for (int i = 0; i < N; i++) { d->addr[i] = 0; d->din[i] = 0; }
  d->eval(); d->clk = 1; d->eval(); d->clk = 0; d->eval();
  d->rst_n = 1;

  // Owners.
  struct Owner { int state; int pause; uint32_t seq; std::deque<std::pair<uint32_t,uint16_t>> expect; int done; int pulsed; };
  std::vector<Owner> ow(N);
  for (int i = 0; i < N; i++) { ow[i] = {0, i * 3, 0, {}, 0, 0}; }
  // Owner 2 (the coprocessor's slot) asks with 0-3 idle cycles between, as
  // the TGP does between the halves and instructions, and now and then goes
  // quiet for tens of cycles, as it does after a mailbox write; owner 3 (the push
  // DMA) asks in pairs with one idle cycle between, like the halves of a
  // dword. The others are sparse.
  auto next_pause = [&](int i) {
    switch (i) { case 2: return (std::rand() % 8 == 0) ? 40 + std::rand() % 40 : std::rand() % 4; case 3: return (std::rand() % 2) ? 1 : 3; default: return 5 + std::rand() % 40; }
  };
  // The port model.
  int w_done = 0, inflight = -1, cnt = 0; uint32_t l_addr = 0; uint16_t l_din = 0; int ack = 0;
  long issued = 0, landed = 0, idle_run = 0, max_idle_run = 0, ack_no_owner = 0;
  std::vector<long> per_owner(N, 0);

  // Owner 2 (the coprocessor's slot) is REGISTERED both ways in Model2.sv:
  // its request reaches the arbiter a cycle late and the acknowledge reaches
  // it a cycle late, so its line stays up for cycles after it was served.
  // On the board that is one register on the request (tgp_bufw_req_r), one
  // on the acknowledge (tgp_bufw_ack_r) and one inside m2_tgp before wr_pend
  // falls: the line is up for THREE cycles after the acknowledge. O2D sets
  // how many cycles the request line lags the owner's state (default 2, plus
  // the acknowledge register makes three).
  const int O2D = std::getenv("O2D") ? std::atoi(std::getenv("O2D")) : 2;
  std::deque<int> o2_req_q(O2D, 0); int o2_ack_d = 0;
  for (int cyc = 0; cyc < ROUNDS; cyc++) {
    // Owners drive their requests (registered on the previous ack).
    uint32_t req = 0;
    // Owner 2 consumes last cycle's acknowledge now.
    if (o2_ack_d) { Owner &o = ow[2]; CHECK(o.state == 1, "owner 2 acknowledged while not asking (cycle %d)", cyc); o.state = 0; o.pause = next_pause(2); ++o.done; }
    for (int i = 0; i < N; i++) {
      Owner &o = ow[i];
      // AN IDLE OWNER'S LINES ARE GARBAGE. m2_tgp's address and data follow
      // its bus the moment the instruction completes, so a grant earned by a
      // stale request line writes whatever is there -- on the board, over
      // the mailbox's low half (build/wrarb2 s15). A write that lands from an
      // idle owner is the fault this test exists to catch.
      if (o.state == 0) { d->addr[i] = 0xBAD000 | (cyc & 0xfff); d->din[i] = 0xBAD; }
      if (o.state == 0) { if (o.pause > 0) --o.pause; else { o.state = 1; o.seq++; d->addr[i] = (i << 20) | (o.seq & 0xfffff); d->din[i] = (i << 12) | (o.seq & 0xfff); o.expect.push_back({d->addr[i], d->din[i]}); } }
      // Owner 4 is the ROM loader's slot: it PULSES its request for one cycle
      // and then waits for the acknowledge with the line low.
      if (o.state == 1 && (i != 4 || o.pulsed == 0) && i != 2) req |= 1u << i;
      if (o.state == 1 && i == 4) o.pulsed = 1;
    }
    if (o2_req_q.front()) req |= 1u << 2;  // the registered line
    o2_req_q.pop_front(); o2_req_q.push_back(ow[2].state == 1);
    d->req = req;
    d->s_ack = ack;
    d->eval();
    // Port model, evaluated on the arbiter's combinational outputs this cycle.
    const int s_req = d->s_req;
    int f_req = s_req && !w_done && !ack;
    if (f_req && inflight < 0) { inflight = 0; l_addr = d->s_addr; l_din = d->s_din; cnt = LAT; ++issued; }
    // Owners consume their acknowledge this cycle.
    o2_ack_d = (d->ack >> 2) & 1;
    for (int i = 0; i < N; i++) if (((d->ack >> i) & 1) && i != 2) {
      Owner &o = ow[i];
      CHECK(o.state == 1, "owner %d acknowledged while not asking (cycle %d)", i, cyc);
      o.state = 0; o.pause = next_pause(i); ++o.done; o.pulsed = 0;
    }
    if (ack && !d->ack) ++ack_no_owner;
    // Clock.
    d->clk = 1; d->eval(); d->clk = 0; d->eval();
    // Port model's registered state.
    int new_ack = 0;
    if (inflight >= 0) { if (--cnt == 0) { new_ack = 1; ++landed; inflight = -1;
        // the write lands: it must be the head of exactly one owner's queue
        int who = -1;
        for (int i = 0; i < N; i++) if (!ow[i].expect.empty() && ow[i].expect.front().first == l_addr && ow[i].expect.front().second == l_din) who = i;
        CHECK(who >= 0, "a write landed that nobody asked for: addr %06x din %04x (cycle %d)", l_addr, l_din, cyc);
        if (who >= 0) { ow[who].expect.pop_front(); ++per_owner[who]; }
    } }
    if (!s_req) w_done = 0; else if (ack) w_done = 1;
    ack = new_ack;
    // Liveness: with owner 2 always asking, the port must never idle long.
    if (inflight < 0 && !ack) { if (++idle_run > max_idle_run) max_idle_run = idle_run; } else idle_run = 0;
  }
  std::printf("  %ld issued, %ld landed, per owner %ld %ld %ld %ld %ld, longest idle %ld cycles, acks with no owner %ld\n",
              issued, landed, per_owner[0], per_owner[1], per_owner[2], per_owner[3], per_owner[4], max_idle_run, ack_no_owner);
  CHECK(issued == landed + (inflight >= 0 ? 1 : 0), "issued %ld != landed %ld (one may still be in flight)", issued, landed);
  CHECK(max_idle_run <= LAT + 8, "port idled %ld cycles with a requester waiting", max_idle_run);
  CHECK(ack_no_owner == 0, "%ld acknowledges reached no owner", ack_no_owner);
  for (int i = 0; i < N; i++) {
    CHECK(ow[i].expect.size() <= 1, "owner %d has %zu writes asked for and never landed", i, ow[i].expect.size());
    CHECK(ow[i].done > 0, "owner %d never got a turn", i);
  }
  // Starvation: the lowest-priority owner must still be served while owner 2
  // asks every cycle -- a grant per transaction, not per cycle, guarantees it
  // only if the released port is re-arbitrated fairly enough; report it.
  std::printf("m2_wr_arb: checks=%d fails=%d\n", checks, fails);
  std::printf(fails ? "FAIL\n" : "PASS\n");
  delete d;
  return fails ? 1 : 0;
}
