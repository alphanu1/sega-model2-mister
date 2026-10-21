// license:BSD-3-Clause
// copyright-holders:Ariane Fugmann
//
// MAME's m2comm_device (M2COMM_SIMULATION), transplanted: see comm_board.h.
// Changes: the sockets are a non-blocking LinkTransport, so read_frame keeps
// partial frames until whole instead of waiting; the frame-sync wait gives up
// after kSyncTimeout (MAME waits forever); messages through osd_printf_verbose
// are dropped.

#include "runtime/comm_board.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <thread>

namespace rt {

namespace {
constexpr auto kSyncTimeout = std::chrono::seconds(3);
}

CommBoard::Link CommBoard::link() const {
    if (!transport_ || !linkenable_) return Link::Off;
    if (linkalive_ == 1) return Link::Up;
    if (linkalive_ == 2) return Link::Lost;
    return Link::Waiting;
}

void CommBoard::cn_w(uint8_t data) {
    cn_ = data & 0x01;
    if (!cn_) {
        // reset command
        linkenable_ = 0x00;
        zfg_ = 0;
        cn_ = 0;
        fg_ = 0;
    } else {
        // init command
        linkenable_ = 0x01;
        linkid_ = 0x00;
        linkalive_ = 0x00;
        linkcount_ = 0x00;
        linktimer_ = 0x00e8; // 58 fps * 4s
        rx_.clear();

        // zero memory
        std::memset(shared_, 0, 0x4000);

        shared_[0x01] = 0x02;

        // frameSize - 0x0e00
        shared_[0x12] = 0x00;
        shared_[0x13] = 0x0e;

        // frameOffset - 0x01c0 in most games
        shared_[0x14] = uint8_t(frame_offset_ & 0xff);
        shared_[0x15] = uint8_t(frame_offset_ >> 8);

        comm_tick();
    }
}

uint8_t CommBoard::fg_r() {
    read_fg();
    return uint8_t(fg_ | (~zfg_ << 7) | 0x7e);
}

void CommBoard::vblank() { comm_tick(); }

void CommBoard::lost() {
    linkalive_ = 0x02;
    linktimer_ = 0x00;
}

void CommBoard::comm_tick() {
    if (linkenable_ != 0x01 || !transport_) return;
    transport_->poll();
    const int frame_start = 0x2000;
    const int frame_size = shared_[0x13] << 8 | shared_[0x12];
    const int frame_offset = frame_start | shared_[0x15] << 8 | shared_[0x14];
    const int data_size = frame_size + 1;
    int recv = 0;
    int idx = 0;

    // EPR-16726 uses fg for master/slave
    const bool is_master = (fg_ == 0x01 || shared_[1] == 0x01);
    const bool is_slave = (fg_ == 0x00 && shared_[1] == 0x02);
    const bool is_relay = (fg_ == 0x00 && shared_[1] == 0x00);

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
            zfg_ ^= 0x01;

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
        const auto deadline = std::chrono::steady_clock::now() + kSyncTimeout;
        do {
            // try to read a message
            recv = read_frame(data_size);
            while (recv > 0) {
                // check if valid id
                idx = buffer0_[0];
                if (idx >= 0 && idx <= linkcount_) {
                    // save message to "ring buffer"
                    for (int j = 0x00; j < frame_size; j++) shared_[(frame_offset + j) & 0x3fff] = buffer0_[1 + j];
                    zfg_ ^= 0x01;
                    if (is_slave) send_data(linkid_, frame_start, frame_size, data_size);
                    else if (is_relay) send_frame(data_size);
                } else if (idx == 0xfc) {
                    // 0xFC - VSYNC
                    linktimer_ = 0x00;
                    // forward message to other nodes
                    if (!is_master) send_frame(data_size);
                }

                // try to read another message
                recv = read_frame(data_size);
            }
            if (linktimer_ == 0x01) {
                if (std::chrono::steady_clock::now() > deadline) { lost(); break; } // MAME waits forever
                std::this_thread::yield();
                transport_->poll();
            }
        } while (linktimer_ == 0x01);

        if (linkalive_ != 0x01) return;

        // enable wait for vsync
        linktimer_ = framesync_;

        if (is_master) {
            // update "ring buffer" if link established
            send_data(linkid_, frame_start, frame_size, data_size);

            // send vsync
            buffer0_[0] = 0xfc;
            buffer0_[1] = 0x01;
            send_frame(data_size);
        }

        zfg_delay_ = 0x02;
    }
}

void CommBoard::read_fg() {
    if (zfg_delay_ > 0x00) {
        zfg_delay_--;
        return;
    }
    if (linkalive_ != 0x01 || !transport_) return;
    const int frame_start = 0x2000;
    const int frame_size = shared_[0x13] << 8 | shared_[0x12];
    const int frame_offset = frame_start | shared_[0x15] << 8 | shared_[0x14];
    const int data_size = frame_size + 1;

    const bool is_master = (fg_ == 0x01 || shared_[1] == 0x01);
    const bool is_slave = (fg_ == 0x00 && shared_[1] == 0x02);
    const bool is_relay = (fg_ == 0x00 && shared_[1] == 0x00);

    const auto deadline = std::chrono::steady_clock::now() + kSyncTimeout;
    do {
        int recv = read_frame(data_size);
        while (recv > 0) {
            const int idx = buffer0_[0];
            if (idx >= 0 && idx <= linkcount_) {
                for (int j = 0x00; j < frame_size; j++) shared_[(frame_offset + j) & 0x3fff] = buffer0_[1 + j];
                zfg_ ^= 0x01;
                if (is_slave) send_data(linkid_, frame_start, frame_size, data_size);
                else if (is_relay) send_frame(data_size);
            } else if (idx == 0xfc) {
                linktimer_ = 0x00;
                if (!is_master) send_frame(data_size);
            }
            recv = read_frame(data_size);
        }
        if (linktimer_ == 0x01) {
            if (std::chrono::steady_clock::now() > deadline) { lost(); break; }
            std::this_thread::yield();
            transport_->poll();
        }
    } while (linktimer_ == 0x01);
}

// One whole frame into buffer0_: data_size, or 0 while it is not all here
// (what has come is kept). The previous cabinet closing the line loses the
// link.
int CommBoard::read_frame(int data_size) {
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

void CommBoard::send_data(uint8_t frame_type, int frame_start, int frame_size, int data_size) {
    buffer0_[0] = frame_type;
    for (int i = 0x0000; i < frame_size && 1 + i < int(sizeof buffer0_); i++) buffer0_[1 + i] = shared_[(frame_start + i) & 0x3fff];
    send_frame(data_size);
}

void CommBoard::send_frame(int data_size) {
    if (!transport_) return;
    if (!transport_->tx_open()) {
        if (linkalive_ == 0x01) lost(); // tx connection lost
        return;
    }
    if (!transport_->write(buffer0_, std::min<int>(data_size, int(sizeof buffer0_)))) {
        if (linkalive_ == 0x01) lost(); // tx connection lost
    }
}

} // namespace rt
