// license:BSD-3-Clause
// copyright-holders:Ariane Fugmann
//
// The Model 2 communication board (837-10537 on Daytona USA Revision A):
// link play between cabinets. Transplanted from MAME's m2comm device in its
// M2COMM_SIMULATION mode (src/mame/sega/m2comm.cpp at
// dddd73680656e355bb2b5beecab1167c9f07bf81; BSD-3-Clause, notice above kept
// as the licence requires; see THIRD_PARTY.md): the board's Z80 program
// (EPR-16726) is not run; the protocol it carries is.
//
// THIS COPY: the Daytona USA recompilation's src/runtime/comm_board.h
// (github.com/alphanu1/daytona-arcade-recomp at b33baeb, BSD-3-Clause; the
// file itself unchanged since e52a63c), verbatim in recomp/runtime/, adapted
// for the MiSTer helper, m2link. The protocol, the state machine and every
// byte on the wire are the recomp's. What changed, and only this:
//
//   * namespace m2link (the verbatim rt::CommBoard can be linked beside it);
//   * the shared RAM is the core's, in DDR3, through /dev/mem: volatile, and
//     whole frames move a 32-bit word at a time where the recomp moves bytes
//     (the same bytes to the same places, fewer uncached accesses);
//   * the init command's set-up of the shared RAM (clear, header, status
//     bytes) is the core's, done in the FPGA before the game's next access
//     to the RAM completes (rtl/io/m2_comm.sv), so cn_w(1) leaves the RAM
//     alone here when core_init is set -- doing it a frame later would wipe
//     what the game has written since;
//   * zfg() for the helper to publish to the core.
//
// Cabinets form a ring: each sends to the next and receives from the one
// before. At start the master (set in the game's test mode: LINK ID) sends a
// numbering token round the ring, so every cabinet learns its id and the
// count; then every frame each one passes its block of race data on, and the
// master sends a vsync token. The bytes travel through a LinkTransport the
// host provides (app::TcpLink, the recomp's own), which never blocks.
#pragma once

#include "runtime/comm_board.h"   // rt::LinkTransport, the recomp's interface

#include <cstdint>
#include <vector>

namespace m2link {

using rt::LinkTransport;

class CommBoard {
public:
    // shared: the board's 16 KB shared RAM. frame_offset: where in the
    // received block a frame lands (0x1c0 for most games). core_init: the
    // core sets the RAM up on the init command (see above).
    explicit CommBoard(volatile uint8_t *shared, uint16_t frame_offset = 0x1c0, bool core_init = true)
        : shared_(shared), frame_offset_(frame_offset), core_init_(core_init) {}
    void set_transport(LinkTransport *t) { transport_ = t; }
    // Hold each cabinet to the master's frame (MAME's -comm_framesync); off
    // by default, as in MAME: cabinets run free and exchange data as it comes.
    void set_framesync(bool on) { framesync_ = on ? 1 : 0; }

    uint8_t cn_r() const { return uint8_t(cn_ | 0xfe); }
    void cn_w(uint8_t data);
    uint8_t fg_r();
    void fg_w(uint8_t data) { fg_ = data & 1; }
    void vblank(); // MAME check_vint_irq: once per frame

    // For the host's status line.
    enum class Link { Off, Waiting, Up, Lost };
    Link link() const;
    int id() const { return linkid_; }
    int count() const { return linkcount_; }
    uint8_t zfg() const { return zfg_; } // FG bit 7 is ~zfg

private:
    volatile uint8_t *shared_;
    uint16_t frame_offset_;
    bool core_init_;
    LinkTransport *transport_ = nullptr;
    uint8_t zfg_ = 0, cn_ = 0, fg_ = 0, framesync_ = 0;
    uint8_t linkenable_ = 0, linkalive_ = 0, linkid_ = 0, linkcount_ = 0, zfg_delay_ = 0;
    uint16_t linktimer_ = 0;
    uint8_t buffer0_[0x1000] = {};
    std::vector<uint8_t> rx_; // bytes received toward the next whole frame
    void comm_tick();
    void read_fg();
    int read_frame(int data_size);
    void send_data(uint8_t frame_type, int frame_start, int frame_size, int data_size);
    void send_frame(int data_size);
    void lost();
    void store_frame(int frame_offset, int frame_size); // buffer0_[1..] -> shared
};

} // namespace m2link
