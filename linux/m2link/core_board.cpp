// license:BSD-3-Clause
// copyright-holders:Ariane Fugmann
//
// The communication board, the half that is not in the FPGA: see
// core_board.h. Every function here that the recomp also has (read_frame,
// send_frame, lost, the numbering in comm_tick) is the recomp's code with
// its shared RAM the core's; what moved to the FPGA is marked "core:".

#include "core_board.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>

namespace m2link {

namespace {
uint64_t now_ms() {
    return uint64_t(std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());
}
constexpr int kTxBytes = 0x1c0;           // the game's own block, 0x2000-0x21bf (the core's snapshot)
} // namespace

CoreStatus read_status(const CorePage &p) {
    const volatile uint32_t *w = reinterpret_cast<const volatile uint32_t *>(p.mem + CorePage::kStatus);
    const uint32_t lo = w[0], hi = w[1];
    CoreStatus s;
    s.tick = uint8_t(lo);
    s.taken = uint8_t(lo >> 8);
    s.taken_tick = uint8_t(lo >> 16);
    s.cnwr = uint8_t(lo >> 24);
    s.cn = hi & 1;
    s.fg = (hi >> 1) & 1;
    s.zfg = (hi >> 2) & 1;
    s.rxbank = (hi >> 3) & 1;
    s.fs_wait = (hi >> 4) & 1;
    s.tick_pend = (hi >> 5) & 1;
    s.take_tick = (hi >> 6) & 1;
    s.hb = uint8_t(hi >> 8);
    s.valid = (hi >> 16) == 0x4C02;
    return s;
}

CoreBoard::Link CoreBoard::link() const {
    if (!transport_ || !linkenable_) return Link::Off;
    if (linkalive_ == 1) return Link::Up;
    if (linkalive_ == 2) return Link::Lost;
    return Link::Waiting;
}

bool CoreBoard::is_master() const { return fg_ == 0x01 || p_.mem[1] == 0x01; }
bool CoreBoard::is_slave() const { return fg_ == 0x00 && p_.mem[1] == 0x02; }
bool CoreBoard::is_relay() const { return fg_ == 0x00 && p_.mem[1] == 0x00; }
int CoreBoard::frame_size() const { return p_.mem[0x13] << 8 | p_.mem[0x12]; }

void CoreBoard::attach(const CoreStatus &s) {
    last_ = s;
    fg_ = s.fg;
    seq_ = s.taken;
    cur_bank_ = s.rxbank;
    bank_of_[seq_] = cur_bank_;
    shadow_[0].assign(0xe00, 0);
    shadow_[1].assign(0xe00, 0);
    if (s.cn) cn_w(1);
    write_mailbox();
}

void CoreBoard::cn_w(uint8_t cn) {
    queue_.clear();
    offered_.clear();
    offer_out_ = false;
    seq_ = last_.taken; // core: the init command cancels any offer
    if (!cn) {
        // reset command (core: zfg, cn, fg)
        linkenable_ = 0x00;
        return;
    }
    // init command (core: the RAM's clear and header, rx bank 0)
    linkenable_ = 0x01;
    linkid_ = 0x00;
    linkalive_ = 0x00;
    linkcount_ = 0x00;
    linktimer_ = 0x00e8; // 58 fps * 4s
    rx_.clear();
    cur_bank_ = 0;
    bank_of_[seq_] = 0;
    shadow_[0].assign(0xe00, 0);
    shadow_[1].assign(0xe00, 0);
    tick();
}

bool CoreBoard::poll(const CoreStatus &s) {
    bool busy = false;
    if (s.cnwr != last_.cnwr) {
        last_.taken = s.taken;
        fg_ = s.fg;
        cn_w(s.cn);
        busy = true;
    } else if (s.fg != last_.fg) fg_ = s.fg;

    // The core took the offer: at a vblank or an FG read, as the recomp's
    // comm_tick / read_fg loop takes a frame.
    if (offer_out_ && s.taken == seq_) {
        taken(s);
        busy = true;
    }
    // Each vblank the core processed (after any held one is released).
    const int ticks = std::min<int>(uint8_t(s.tick - last_.tick), 8);
    last_ = s;
    for (int i = 0; i < ticks; i++) tick();
    busy |= ticks > 0;

    if (linkenable_ == 0x01 && linkalive_ == 0x01) {
        read_frames_linked();
        if (!offer_out_ && !queue_.empty()) {
            offer();
            busy = true;
        }
        // link_framesync: the recomp gives up a wait after 3 s and loses the
        // link; the core gives the game back sooner (it must not freeze).
        if (framesync_ && now_ms() - sync_ms_ > sync_timeout_ms_) lost();
    }
    write_mailbox();
    return busy;
}

// comm_tick, this side of it: the numbering before the link is up, the
// master's frame and vsync after. (core: zfg ^= 1 while waiting with both
// lines up -- the mailbox's "flip every vblank" -- and, linked, the frames
// taken, linktimer and zfg_delay.)
void CoreBoard::tick() {
    if (linkenable_ != 0x01 || !transport_) return;
    transport_->poll();
    volatile uint8_t *shared_ = p_.mem;
    const int data_size = frame_size() + 1;
    int recv = 0;
    int idx = 0;
    const bool is_master = this->is_master();
    const bool is_slave = this->is_slave();
    const bool is_relay = this->is_relay();

    if (linkalive_ == 0x02) {
        // link failed...
        shared_[0] = 0xff;
        return;
    } else if (linkalive_ == 0x00) {
        // link not yet established...
        shared_[0] = 0x00;
        shared_[2] = 0xff;
        shared_[3] = 0xff;

        // if both lines are there check ring
        if (transport_->rx_open() && transport_->tx_open()) {
            // core: zfg ^= 0x01

            // try to read one message
            recv = read_frame(data_size);
            while (recv > 0) {
                // check if message id
                idx = buffer0_[0];

                // 0xFF - link id
                if (idx == 0xff) {
                    if (is_master) {
                        // master gets first id and starts next state
                        linkid_ = 0x01;
                        linkcount_ = buffer0_[1];
                        linktimer_ = 0x00;
                    } else {
                        // slave get own id, relay does nothing
                        if (is_slave) buffer0_[1]++;

                        // forward message to other nodes
                        send_frame(data_size);
                    }
                }

                // 0xFE - link size
                else if (idx == 0xfe) {
                    if (is_slave) {
                        // fetch linkid and linkcount, then decrease linkid
                        linkid_ = buffer0_[1];
                        linkcount_ = buffer0_[2];
                        buffer0_[1]--;

                        // forward message to other nodes
                        send_frame(data_size);
                    } else if (is_relay) {
                        // fetch linkid and linkcount, then decrease linkid
                        linkid_ = 0x00;
                        linkcount_ = buffer0_[2];

                        // forward message to other nodes
                        send_frame(data_size);
                    }

                    // consider it done
                    linkalive_ = 0x01;
                    sync_ms_ = now_ms();

                    // write to shared mem
                    shared_[0] = 0x01;
                    shared_[2] = linkid_;
                    shared_[3] = linkcount_;
                }

                if (linkalive_ == 0x00) recv = read_frame(data_size);
                else recv = 0;
            }

            // if we are master and link is not yet established
            if (is_master && (linkalive_ == 0x00)) {
                if (linktimer_ == 0x01) {
                    // send first packet
                    buffer0_[0] = 0xff;
                    buffer0_[1] = 0x01;
                    buffer0_[2] = 0x00;
                    send_frame(data_size);
                } else if (linktimer_ == 0x00) {
                    // send second packet
                    buffer0_[0] = 0xfe;
                    buffer0_[1] = linkcount_;
                    buffer0_[2] = linkcount_;
                    send_frame(data_size);

                    // consider it done
                    linkalive_ = 0x01;
                    sync_ms_ = now_ms();

                    // write to shared mem
                    shared_[0] = 0x01;
                    shared_[2] = linkid_;
                    shared_[3] = linkcount_;
                } else if (linktimer_ > 0x01) {
                    // decrease delay timer
                    linktimer_--;
                }
            }
        }
    }

    // if link established
    if (linkalive_ == 0x01) {
        // core: the frames that were there were taken at this vblank, and
        // linktimer's wait (link_framesync) was the core's, before it.
        if (is_master) {
            // update "ring buffer" if link established: the game's block as
            // the core copied it at this vblank, and the slots as the game
            // sees them now
            send_block(linkid_, reinterpret_cast<const uint8_t *>(const_cast<uint8_t *>(p_.mem)) + CorePage::kSnapTick,
                       shadow_[bank_of_[last_.taken_tick]]);

            // send vsync
            buffer0_[0] = 0xfc;
            buffer0_[1] = 0x01;
            send_frame(data_size);
        }
    }
}

// The offer was taken. The recomp's loop over what it carried: each data
// frame stored (core: done, and zfg flipped) and answered by a slave with its
// own block as it stood then (core: the snapshot), or passed on by a relay;
// each vsync token passed on unless this is the master (core: linktimer = 0).
void CoreBoard::taken(const CoreStatus &s) {
    cur_bank_ = offer_bank_;
    const int data_size = frame_size() + 1;
    const uint8_t *snap = reinterpret_cast<const uint8_t *>(const_cast<uint8_t *>(p_.mem)) +
                          (s.take_tick ? CorePage::kSnapTick : CorePage::kSnapTake);
    const bool is_master = this->is_master();
    const bool is_slave = this->is_slave();
    const bool is_relay = this->is_relay();
    for (const Frame &f : offered_) {
        const int idx = f[0];
        if (idx >= 0 && idx <= linkcount_) {
            if (is_slave) send_block(linkid_, snap, std::vector<uint8_t>(f.begin() + 1, f.end()));
            else if (is_relay) {
                std::memcpy(buffer0_, f.data(), std::min(f.size(), sizeof buffer0_));
                send_frame(data_size);
            }
        } else if (idx == 0xfc) {
            if (!is_master) {
                std::memcpy(buffer0_, f.data(), std::min(f.size(), sizeof buffer0_));
                send_frame(data_size);
            }
        }
    }
    if (offer_tok_) sync_ms_ = now_ms();
    offered_.clear();
    offer_out_ = false;
}

// Everything received since the last offer, as one: the newest data frame's
// block in the bank the game is not reading, zfg to flip once per data frame
// (so twice is no flip, as in the recomp's loop), and whether a token came.
void CoreBoard::offer() {
    std::vector<Frame> items(queue_.begin(), queue_.end());
    queue_.clear();
    int ndata = 0;
    bool tok = false;
    const Frame *newest = nullptr;
    for (const Frame &f : items) {
        if (int(f[0]) <= int(linkcount_)) {
            ++ndata;
            newest = &f;
        } else if (f[0] == 0xfc) tok = true;
    }
    if (!ndata && !tok) return; // nothing the game would see
    uint8_t bank = cur_bank_;
    if (newest) {
        bank = cur_bank_ ^ 1;
        const int fs = std::min<int>(frame_size(), int(newest->size()) - 1);
        const size_t off = (bank ? CorePage::kBank1 : 0) + 0x2000 + frame_offset_;
        volatile uint32_t *dst = reinterpret_cast<volatile uint32_t *>(p_.mem + off);
        for (int j = 0; j + 4 <= fs; j += 4) {
            uint32_t w;
            std::memcpy(&w, newest->data() + 1 + j, 4);
            dst[j >> 2] = w;
        }
        shadow_[bank].assign(newest->begin() + 1, newest->begin() + 1 + fs);
    }
    offered_ = std::move(items);
    offer_bank_ = bank;
    offer_tok_ = tok;
    offer_flip_ = ndata & 1;
    bank_of_[uint8_t(seq_ + 1)] = bank;
    ++seq_;
    offer_out_ = true;
}

void CoreBoard::write_mailbox() {
    const bool lines = transport_ && transport_->rx_open() && transport_->tx_open();
    const uint32_t m = uint32_t(seq_) | uint32_t(offer_bank_) << 8 | uint32_t(offer_flip_) << 9 |
                       uint32_t(offer_tok_) << 10 | uint32_t(linkenable_ == 1 && linkalive_ == 1) << 11 |
                       uint32_t(framesync_) << 12 | uint32_t(linkenable_ == 1 && linkalive_ == 0 && lines) << 13;
    if (m == mbox_) return;
    std::atomic_thread_fence(std::memory_order_seq_cst); // the block lands first
    *reinterpret_cast<volatile uint32_t *>(p_.mem + CorePage::kMailbox) = m;
    std::atomic_thread_fence(std::memory_order_seq_cst);
    mbox_ = m;
}

void CoreBoard::read_frames_linked() {
    transport_->poll();
    const int data_size = frame_size() + 1;
    while (read_frame(data_size) > 0) queue_.emplace_back(buffer0_, buffer0_ + std::min<int>(data_size, int(sizeof buffer0_)));
}

void CoreBoard::lost() {
    linkalive_ = 0x02;
    linktimer_ = 0x00;
    queue_.clear();
}

// One whole frame into buffer0_: data_size, or 0 while it is not all here
// (what has come is kept). The previous cabinet closing the line loses the
// link. (The recomp's, unchanged.)
int CoreBoard::read_frame(int data_size) {
    if (!transport_) return 0;
    if (!transport_->rx_open()) {
        if (linkalive_ == 0x01) lost(); // rx connection lost
        return 0;
    }
    data_size = std::min<int>(data_size, int(sizeof buffer0_));
    uint8_t chunk[4096];
    while (int(rx_.size()) < data_size) {
        const int n = transport_->read(chunk, std::min<int>(int(sizeof chunk), data_size - int(rx_.size())));
        if (n < 0) {
            if (linkalive_ == 0x01) lost(); // rx connection lost
            return 0;
        }
        if (n == 0) return 0;
        rx_.insert(rx_.end(), chunk, chunk + n);
    }
    std::memcpy(buffer0_, rx_.data(), size_t(data_size));
    rx_.erase(rx_.begin(), rx_.begin() + data_size);
    return data_size;
}

// send_data: the frame type, then shared 0x2000 on for frame_size bytes --
// the game's block (the core's snapshot of it) and the slots after it (the
// rx area as the game sees it: the bank's block).
void CoreBoard::send_block(uint8_t frame_type, const uint8_t *snapshot, const std::vector<uint8_t> &rx) {
    const int fs = frame_size();
    buffer0_[0] = frame_type;
    const volatile uint32_t *src = reinterpret_cast<const volatile uint32_t *>(snapshot);
    for (int i = 0; i < kTxBytes; i += 4) {
        const uint32_t w = src[i >> 2];
        std::memcpy(buffer0_ + 1 + i, &w, 4);
    }
    for (int i = kTxBytes; i < fs && 1 + i < int(sizeof buffer0_); i++) {
        const size_t j = size_t(i - kTxBytes);
        buffer0_[1 + i] = j < rx.size() ? rx[j] : 0;
    }
    send_frame(fs + 1);
}

void CoreBoard::send_frame(int data_size) {
    if (!transport_) return;
    if (!transport_->tx_open()) {
        if (linkalive_ == 0x01) lost(); // tx connection lost
        return;
    }
    if (!transport_->write(buffer0_, std::min<int>(data_size, int(sizeof buffer0_)))) {
        if (linkalive_ == 0x01) lost(); // tx connection lost
    }
}

} // namespace m2link
