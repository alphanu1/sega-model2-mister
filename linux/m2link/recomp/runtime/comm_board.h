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
// Cabinets form a ring: each sends to the next and receives from the one
// before. At start the master (set in the game's test mode: LINK ID) sends a
// numbering token round the ring, so every cabinet learns its id and the
// count; then every frame each one passes its block of race data on, and the
// master sends a vsync token. The shared RAM is the game's (M2Board maps it
// at 0x01a00000); the bytes travel through a LinkTransport the host provides
// (TCP in the app), which never blocks. Without a transport the board is not
// here at all: M2Board keeps its plain registers and the game sees no link.
#pragma once

#include <cstdint>
#include <vector>

namespace rt {

// The two cables: to the next cabinet and from the one before. Non-blocking.
class LinkTransport {
public:
    virtual ~LinkTransport() = default;
    virtual void poll() = 0;        // accept / connect as needed
    virtual bool rx_open() const = 0; // a cabinet is sending to us
    virtual bool tx_open() const = 0; // we are connected to the next cabinet
    // Bytes received: > 0 how many, 0 none yet, < 0 the connection closed.
    virtual int read(uint8_t *buf, int max) = 0;
    // All of buf, or false: the connection is lost.
    virtual bool write(const uint8_t *buf, int n) = 0;
};

class CommBoard {
public:
    // shared: the board's 16 KB shared RAM. frame_offset: where in the
    // received block a frame lands (0x1c0 for most games).
    explicit CommBoard(uint8_t *shared, uint16_t frame_offset = 0x1c0) : shared_(shared), frame_offset_(frame_offset) {}
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

private:
    uint8_t *shared_;
    uint16_t frame_offset_;
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
};

} // namespace rt
