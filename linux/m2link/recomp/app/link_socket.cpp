#include "app/link_socket.h"

#include <chrono>
#include <cstring>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")
using native_socket = SOCKET;
namespace {
int last_error() { return WSAGetLastError(); }
bool would_block(int e) { return e == WSAEWOULDBLOCK || e == WSAEINPROGRESS || e == WSAEALREADY; }
void close_socket(long long s) { closesocket(native_socket(s)); }
bool set_nonblocking(long long s, bool on) {
    u_long v = on ? 1 : 0;
    return ioctlsocket(native_socket(s), FIONBIO, &v) == 0;
}
struct WsaInit {
    WsaInit() { WSADATA d; WSAStartup(MAKEWORD(2, 2), &d); }
    ~WsaInit() { WSACleanup(); }
};
void net_init() { static WsaInit init; }
constexpr int kNoSignal = 0;
} // namespace
#else
#include <arpa/inet.h>
#include <cerrno>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
using native_socket = int;
namespace {
int last_error() { return errno; }
bool would_block(int e) { return e == EAGAIN || e == EWOULDBLOCK || e == EINPROGRESS || e == EALREADY; }
void close_socket(long long s) { ::close(native_socket(s)); }
bool set_nonblocking(long long s, bool on) {
    const int flags = fcntl(native_socket(s), F_GETFL, 0);
    return flags >= 0 && fcntl(native_socket(s), F_SETFL, on ? flags | O_NONBLOCK : flags & ~O_NONBLOCK) == 0;
}
void net_init() {}
#ifdef MSG_NOSIGNAL
constexpr int kNoSignal = MSG_NOSIGNAL; // Linux: a closed peer is an error, not SIGPIPE
#else
constexpr int kNoSignal = 0; // macOS: SO_NOSIGPIPE on the socket instead
#endif
} // namespace
#endif

namespace app {

namespace {
uint64_t now_ms() {
    return uint64_t(std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());
}
void no_sigpipe(long long s) {
#ifdef SO_NOSIGPIPE
    int one = 1;
    setsockopt(native_socket(s), SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#else
    (void)s;
#endif
}
} // namespace

bool TcpLink::parse_address(const std::string &s, std::string &host, uint16_t &port) {
    const auto colon = s.rfind(':');
    if (colon == std::string::npos || colon == 0 || colon + 1 >= s.size()) return false;
    const long p = std::strtol(s.c_str() + colon + 1, nullptr, 10);
    if (p <= 0 || p > 65535) return false;
    host = s.substr(0, colon);
    if (host.size() > 2 && host.front() == '[' && host.back() == ']') host = host.substr(1, host.size() - 2); // [::1]:port
    port = uint16_t(p);
    return true;
}

TcpLink::TcpLink(uint16_t listen_port, const std::string &next) {
    net_init();
    if (!parse_address(next, next_host_, next_port_)) {
        error_ = "next cabinet: expected host:port, got \"" + next + "\"";
        return;
    }
    // Listen on every interface (IPv6 with IPv4 mapped where available).
    native_socket s = ::socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP);
    bool v6 = true;
    if (s == native_socket(-1) || static_cast<long long>(s) < 0) {
        s = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        v6 = false;
    }
    int one = 1, zero = 0;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<const char *>(&one), sizeof one);
    int bound;
    if (v6) {
        setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, reinterpret_cast<const char *>(&zero), sizeof zero);
        sockaddr_in6 a{};
        a.sin6_family = AF_INET6;
        a.sin6_addr = in6addr_any;
        a.sin6_port = htons(listen_port);
        bound = ::bind(s, reinterpret_cast<sockaddr *>(&a), sizeof a);
    } else {
        sockaddr_in a{};
        a.sin_family = AF_INET;
        a.sin_addr.s_addr = htonl(INADDR_ANY);
        a.sin_port = htons(listen_port);
        bound = ::bind(s, reinterpret_cast<sockaddr *>(&a), sizeof a);
    }
    if (bound != 0 || ::listen(s, 1) != 0 || !set_nonblocking(s, true)) {
        error_ = "cannot listen on port " + std::to_string(listen_port) + " (in use?)";
        close_socket(s);
        return;
    }
    listen_ = s;
    poll();
}

TcpLink::~TcpLink() {
    for (Socket s : {listen_, rx_, tx_})
        if (s >= 0) close_socket(s);
}

void TcpLink::close_tx() {
    if (tx_ >= 0) close_socket(tx_);
    tx_ = -1;
    connected_ = false;
    next_try_ms_ = now_ms() + 500;
}

void TcpLink::start_connect() {
    addrinfo hints{}, *res = nullptr;
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    const std::string port = std::to_string(next_port_);
    if (getaddrinfo(next_host_.c_str(), port.c_str(), &hints, &res) != 0 || !res) {
        next_try_ms_ = now_ms() + 2000; // name not found yet: try again later
        return;
    }
    native_socket s = ::socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (static_cast<long long>(s) < 0) {
        freeaddrinfo(res);
        next_try_ms_ = now_ms() + 2000;
        return;
    }
    set_nonblocking(s, true);
    no_sigpipe(s);
    int one = 1;
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char *>(&one), sizeof one); // a frame at a time, now
    const int r = ::connect(s, res->ai_addr, socklen_t(res->ai_addrlen));
    freeaddrinfo(res);
    if (r != 0 && !would_block(last_error())) {
        close_socket(s);
        next_try_ms_ = now_ms() + 500;
        return;
    }
    tx_ = s;
    connected_ = r == 0;
}

void TcpLink::poll() {
    if (listen_ < 0) return;
    if (rx_ < 0) { // the cabinet before us connecting
        native_socket s = ::accept(native_socket(listen_), nullptr, nullptr);
        if (static_cast<long long>(s) >= 0) {
            set_nonblocking(s, true);
            rx_ = s;
        }
    }
    if (tx_ < 0 && now_ms() >= next_try_ms_) start_connect();
    if (tx_ >= 0 && !connected_) { // a connect in progress: done yet?
        fd_set w;
        FD_ZERO(&w);
        FD_SET(native_socket(tx_), &w);
        timeval tv{0, 0};
        if (::select(int(tx_ + 1), nullptr, &w, nullptr, &tv) > 0) {
            int err = 0;
            socklen_t len = sizeof err;
            getsockopt(native_socket(tx_), SOL_SOCKET, SO_ERROR, reinterpret_cast<char *>(&err), &len);
            if (err != 0) close_tx(); // refused: not up yet, try again
            else {
                connected_ = true;
                set_nonblocking(tx_, false); // sends: whole frames, with a time limit
#ifdef _WIN32
                DWORD ms = 2000;
                setsockopt(native_socket(tx_), SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char *>(&ms), sizeof ms);
#else
                timeval to{2, 0};
                setsockopt(native_socket(tx_), SOL_SOCKET, SO_SNDTIMEO, &to, sizeof to);
#endif
            }
        }
    }
}

int TcpLink::read(uint8_t *buf, int max) {
    if (rx_ < 0) return 0;
    const auto n = ::recv(native_socket(rx_), reinterpret_cast<char *>(buf), max, 0);
    if (n > 0) return int(n);
    if (n == 0 || !would_block(last_error())) { // closed by the other cabinet
        close_socket(rx_);
        rx_ = -1;
        return -1;
    }
    return 0;
}

bool TcpLink::write(const uint8_t *buf, int n) {
    if (!tx_open()) return false;
    while (n > 0) {
        const auto sent = ::send(native_socket(tx_), reinterpret_cast<const char *>(buf), n, kNoSignal);
        if (sent <= 0) {
            close_tx();
            return false;
        }
        buf += sent;
        n -= int(sent);
    }
    return true;
}

} // namespace app
