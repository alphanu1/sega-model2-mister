// license:BSD-3-Clause
// copyright-holders:Ariane Fugmann
//
// The Model 2 communication board (837-10537 on Daytona USA Revision A),
// split between the FPGA and m2link. Derived from the Daytona USA
// recompilation's src/runtime/comm_board.{h,cpp} (github.com/alphanu1/
// daytona-arcade-recomp at b33baeb, BSD-3-Clause; verbatim in recomp/runtime/),
// itself MAME's m2comm device in its M2COMM_SIMULATION mode
// (src/mame/sega/m2comm.cpp at dddd73680656e355bb2b5beecab1167c9f07bf81;
// BSD-3-Clause, notice above kept as the licence requires; see
// THIRD_PARTY.md).
//
// WHAT IS WHOSE (study R916, second addendum). In the recomp, comm_tick()
// runs inside the game's vblank and read_fg() inside its FG reads, so a frame
// can only land, zfg only flip and a slave only answer at those two points.
// On MiSTer the game runs in the FPGA and this program beside it, so those
// points are kept in the FPGA (rtl/io/m2_comm.sv) and everything else is
// here, unchanged from the recomp:
//
//   here:   the sockets (the recomp's TcpLink), read_frame / send_frame /
//           lost exactly as the recomp's; the numbering tokens 0xff / 0xfe
//           and the master's countdown, at each vblank, as comm_tick; the
//           master's data frame and vsync at each vblank; a slave's answer
//           and a token's forwarding when the core has taken the frame.
//   core:   storing a frame where the game sees it, the zfg flip, zfg_delay,
//           linktimer (link_framesync's wait), all at the game's vblank and
//           FG reads; the snapshot of the game's own block that is sent.
//
// A received frame is written into the rx bank the game is NOT reading and
// OFFERED (mailbox); the core takes it at the game's next vblank or FG read
// past zfg_delay, as the recomp's loop would. Frames that come while an offer
// is out wait, and the next offer carries all of them -- the recomp's loop
// takes every frame that is there, flipping zfg once each.
#pragma once

#include "runtime/comm_board.h"   // rt::LinkTransport, the recomp's interface

#include <cstddef>
#include <cstdint>
#include <deque>
#include <vector>

namespace m2link {

using rt::LinkTransport;

// The core's page, as the FPGA lays it out (rtl/io/m2_comm.sv).
struct CorePage {
    static constexpr size_t kStatus = 0x4000, kMailbox = 0x4008, kSnapTick = 0x4800, kSnapTake = 0x4c00;
    static constexpr size_t kBank1 = 0x8000, kSize = 0xb000;
    volatile uint8_t *mem;
};

// What the status word says (one read of it).
struct CoreStatus {
    uint8_t tick, taken, taken_tick, cnwr, cn, fg, zfg, rxbank, fs_wait, tick_pend, take_tick, hb;
    bool valid;
};
CoreStatus read_status(const CorePage &p);

class CoreBoard {
public:
    CoreBoard(CorePage page, uint16_t frame_offset = 0x1c0) : p_(page), frame_offset_(frame_offset) {}
    void set_transport(LinkTransport *t) { transport_ = t; }
    void set_framesync(bool on) { framesync_ = on ? 1 : 0; }
    void set_sync_timeout_ms(uint64_t ms) { sync_timeout_ms_ = ms; } // tests: a simulated core's slow frames

    // Start from the core as it is (the helper may start late).
    void attach(const CoreStatus &s);
    // One pass: the core's news since the last one, the network, the next
    // offer, the mailbox. Returns true if anything happened.
    bool poll(const CoreStatus &s);

    enum class Link { Off, Waiting, Up, Lost };
    Link link() const;
    int id() const { return linkid_; }
    int count() const { return linkcount_; }

private:
    using Frame = std::vector<uint8_t>;
    CorePage p_;
    uint16_t frame_offset_;
    LinkTransport *transport_ = nullptr;
    uint8_t fg_ = 0, framesync_ = 0;
    uint8_t linkenable_ = 0, linkalive_ = 0, linkid_ = 0, linkcount_ = 0;
    uint16_t linktimer_ = 0;
    uint8_t buffer0_[0x1000] = {};
    std::vector<uint8_t> rx_;

    CoreStatus last_{};
    // the hand-over with the core
    std::deque<Frame> queue_;          // frames received and not yet offered
    std::vector<Frame> offered_;       // the frames in the offer that is out
    bool offer_out_ = false, offer_tok_ = false, offer_flip_ = false;
    uint8_t seq_ = 0, offer_bank_ = 0, cur_bank_ = 0, bank_of_[256] = {};
    std::vector<uint8_t> shadow_[2];   // each bank's rx area (0xe00 bytes), as written
    uint32_t mbox_ = 0xffffffff;
    uint64_t sync_ms_ = 0;             // framesync: the last vsync token (or link-up)
    uint64_t sync_timeout_ms_ = 3000;  // the recomp's kSyncTimeout

    bool is_master() const;
    bool is_slave() const;
    bool is_relay() const;
    int frame_size() const;
    void cn_w(uint8_t cn);
    void tick();                        // comm_tick, this side of it
    void taken(const CoreStatus &s);    // the offer was taken: answer, forward
    void offer();                       // the next offer, from the queue
    void write_mailbox();
    void read_frames_linked();          // linked: frames into the queue
    int read_frame(int data_size);
    void send_block(uint8_t frame_type, const uint8_t *snapshot, const std::vector<uint8_t> &rx);
    void send_frame(int data_size);
    void lost();
};

} // namespace m2link
