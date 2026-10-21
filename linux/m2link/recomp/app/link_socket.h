// Link play over TCP (rt::LinkTransport for the communication board): this
// cabinet listens for the one before it in the ring and connects to the next,
// as the arcade's cables do. Two cabinets: each one's "next" is the other.
// Everything non-blocking except a frame's send (all of it, or the link is
// lost after a 2 s stall); the next cabinet is retried until it answers.
// POSIX sockets, or Winsock on Windows.
#pragma once

#include "runtime/comm_board.h"

#include <cstdint>
#include <string>

namespace app {

class TcpLink : public rt::LinkTransport {
public:
    // listen_port: where the cabinet before this one connects; next:
    // "host:port" of the cabinet after it.
    TcpLink(uint16_t listen_port, const std::string &next);
    ~TcpLink() override;
    TcpLink(const TcpLink &) = delete;
    TcpLink &operator=(const TcpLink &) = delete;

    void poll() override;
    bool rx_open() const override { return rx_ >= 0; }
    bool tx_open() const override { return tx_ >= 0 && connected_; }
    int read(uint8_t *buf, int max) override;
    bool write(const uint8_t *buf, int n) override;

    const std::string &error() const { return error_; } // set up failed (bad address, port in use)
    static bool parse_address(const std::string &s, std::string &host, uint16_t &port);

private:
    using Socket = long long; // a socket handle (int on POSIX, SOCKET on Windows); -1 = none
    Socket listen_ = -1, rx_ = -1, tx_ = -1;
    bool connected_ = false;
    std::string next_host_;
    uint16_t next_port_ = 0;
    uint64_t next_try_ms_ = 0;
    std::string error_;
    void start_connect();
    void close_tx();
};

} // namespace app
