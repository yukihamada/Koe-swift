#pragma once

#include <cstdint>
#include <cstddef>
#include <string>
#include <memory>

namespace soluna::pal {

struct SocketAddress {
    std::string ip;
    uint16_t port = 0;
};

class UdpSocket {
public:
    virtual ~UdpSocket() = default;

    virtual bool bind(uint16_t port) = 0;
    virtual bool join_multicast(const std::string& group, const std::string& iface = "") = 0;
    virtual bool leave_multicast(const std::string& group) = 0;

    virtual int send_to(const void* data, size_t len, const SocketAddress& dest) = 0;
    virtual int recv_from(void* data, size_t len, SocketAddress& src) = 0;

    // Non-blocking receive. Returns 0 if no data available, -1 on error.
    virtual int recv_from_nonblock(void* data, size_t len, SocketAddress& src) = 0;

    virtual bool set_dscp(uint8_t dscp) = 0;
    virtual bool set_recv_timeout_ms(uint32_t ms) = 0;
    virtual int fd() const = 0;

    static std::unique_ptr<UdpSocket> create();
};

} // namespace soluna::pal
