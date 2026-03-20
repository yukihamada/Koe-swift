#pragma once

/**
 * Transport Manager — Unified socket management with optional DTLS encryption
 *
 * Provides a unified interface for creating transport sockets that can
 * optionally use DTLS encryption. When security.dtls_enabled=true, all
 * RTP traffic will be transparently encrypted.
 *
 * SPDX-License-Identifier: MIT
 */

#include <soluna/pal/net.h>
#include <soluna/config/config.h>
#include <soluna/transport/dtls.h>

#include <memory>
#include <string>
#include <mutex>
#include <map>

namespace soluna::transport {

/**
 * Abstract transport socket interface.
 * Common interface for both plain UDP and DTLS-wrapped sockets.
 */
class TransportSocket {
public:
    virtual ~TransportSocket() = default;

    virtual bool bind(uint16_t port) = 0;
    virtual bool join_multicast(const std::string& group, const std::string& iface = "") = 0;
    virtual bool leave_multicast(const std::string& group) = 0;

    virtual int send_to(const void* data, size_t len, const pal::SocketAddress& dest) = 0;
    virtual int recv_from(void* data, size_t len, pal::SocketAddress& src) = 0;
    virtual int recv_from_nonblock(void* data, size_t len, pal::SocketAddress& src) = 0;

    virtual bool set_dscp(uint8_t dscp) = 0;
    virtual bool set_recv_timeout_ms(uint32_t ms) = 0;
    virtual int fd() const = 0;

    virtual bool is_secure() const = 0;
};

/**
 * Plain UDP transport socket (no encryption).
 */
class PlainTransportSocket : public TransportSocket {
public:
    explicit PlainTransportSocket(std::unique_ptr<pal::UdpSocket> socket);

    bool bind(uint16_t port) override;
    bool join_multicast(const std::string& group, const std::string& iface = "") override;
    bool leave_multicast(const std::string& group) override;

    int send_to(const void* data, size_t len, const pal::SocketAddress& dest) override;
    int recv_from(void* data, size_t len, pal::SocketAddress& src) override;
    int recv_from_nonblock(void* data, size_t len, pal::SocketAddress& src) override;

    bool set_dscp(uint8_t dscp) override;
    bool set_recv_timeout_ms(uint32_t ms) override;
    int fd() const override;

    bool is_secure() const override { return false; }

private:
    std::unique_ptr<pal::UdpSocket> socket_;
};

/**
 * DTLS-encrypted transport socket.
 */
class SecureTransportSocket : public TransportSocket {
public:
    explicit SecureTransportSocket(std::unique_ptr<DtlsSocket> socket,
                                   std::unique_ptr<pal::UdpSocket> fallback = nullptr);

    bool bind(uint16_t port) override;
    bool join_multicast(const std::string& group, const std::string& iface = "") override;
    bool leave_multicast(const std::string& group) override;

    int send_to(const void* data, size_t len, const pal::SocketAddress& dest) override;
    int recv_from(void* data, size_t len, pal::SocketAddress& src) override;
    int recv_from_nonblock(void* data, size_t len, pal::SocketAddress& src) override;

    bool set_dscp(uint8_t dscp) override;
    bool set_recv_timeout_ms(uint32_t ms) override;
    int fd() const override;

    bool is_secure() const override { return true; }

    /** Perform DTLS handshake with a peer. */
    bool handshake(const pal::SocketAddress& peer);

    /** Check if DTLS session is established. */
    bool is_connected() const;

    /** Shutdown DTLS session. */
    void shutdown();

private:
    std::unique_ptr<DtlsSocket> dtls_socket_;
    std::unique_ptr<pal::UdpSocket> fallback_socket_; // for multicast (DTLS doesn't support multicast)
    uint16_t bound_port_ = 0;
};

/**
 * TransportManager manages socket creation based on security configuration.
 *
 * Usage:
 *   TransportManager mgr(security_config);
 *   auto socket = mgr.create_socket();
 *   if (mgr.is_dtls_enabled()) {
 *       auto* secure = static_cast<SecureTransportSocket*>(socket.get());
 *       secure->handshake(peer_addr);
 *   }
 */
class TransportManager {
public:
    /**
     * Create a transport manager with the given security configuration.
     */
    explicit TransportManager(const config::SecurityConfig& config = {});

    /**
     * Create a transport socket.
     * Returns DTLS socket if enabled, plain UDP otherwise.
     *
     * @param role DTLS role (Server or Client) when DTLS is enabled
     */
    std::unique_ptr<TransportSocket> create_socket(DtlsRole role = DtlsRole::Client);

    /**
     * Create a transport socket for transmitting.
     * Uses client role for DTLS handshake.
     */
    std::unique_ptr<TransportSocket> create_tx_socket();

    /**
     * Create a transport socket for receiving.
     * Uses server role for DTLS handshake.
     */
    std::unique_ptr<TransportSocket> create_rx_socket();

    /**
     * Establish a secure channel with a peer (DTLS handshake).
     * This is a convenience method that creates a socket and performs handshake.
     *
     * @param peer_addr The peer address to connect to
     * @param local_port Optional local port to bind to (0 = ephemeral)
     * @return Connected secure socket, or nullptr on failure
     */
    std::unique_ptr<TransportSocket> establish_secure_channel(
        const pal::SocketAddress& peer_addr,
        uint16_t local_port = 0);

    /** Check if DTLS is enabled. */
    bool is_dtls_enabled() const { return config_.dtls_enabled; }

    /** Get the security configuration. */
    const config::SecurityConfig& config() const { return config_; }

private:
    config::SecurityConfig config_;
};

} // namespace soluna::transport
