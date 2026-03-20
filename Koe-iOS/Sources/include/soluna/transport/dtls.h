#pragma once

/**
 * DTLS Socket — Optional encryption wrapper for UDP transport
 *
 * Provides transparent DTLS 1.2 encryption over UDP using OpenSSL.
 * Same interface as UdpSocket for drop-in replacement.
 *
 * Requires: OpenSSL 1.1+ or 3.x
 * Enable: cmake -DSOLUNA_ENABLE_DTLS=ON
 *
 * SPDX-License-Identifier: MIT
 */

#include <soluna/pal/net.h>
#include <cstdint>
#include <cstddef>
#include <memory>
#include <string>

namespace soluna::transport {

/**
 * DTLS role in the handshake.
 */
enum class DtlsRole {
    Server,   // Accepts incoming DTLS connections
    Client,   // Initiates DTLS handshake
};

/**
 * DTLS configuration.
 */
struct DtlsConfig {
    DtlsRole role = DtlsRole::Server;
    std::string cert_file;       // PEM certificate (empty = self-signed)
    std::string key_file;        // PEM private key (empty = self-signed)
    uint32_t handshake_timeout_ms = 5000;
};

/**
 * DtlsSocket wraps a UdpSocket and adds DTLS encryption.
 *
 * All send_to/recv_from calls are transparently encrypted/decrypted.
 * The underlying UDP socket is owned by DtlsSocket.
 */
class DtlsSocket {
public:
    ~DtlsSocket();

    DtlsSocket(const DtlsSocket&) = delete;
    DtlsSocket& operator=(const DtlsSocket&) = delete;

    /**
     * Create a DTLS-wrapped socket.
     * Returns nullptr if OpenSSL is not available.
     */
    static std::unique_ptr<DtlsSocket> create(const DtlsConfig& config);

    /** Bind underlying UDP socket. */
    bool bind(uint16_t port);

    /** Perform DTLS handshake with a peer. */
    bool handshake(const soluna::pal::SocketAddress& peer);

    /** Send encrypted data. */
    int send_to(const void* data, size_t len, const soluna::pal::SocketAddress& dest);

    /** Receive and decrypt data. */
    int recv_from(void* data, size_t len, soluna::pal::SocketAddress& src);

    /** Check if handshake is complete. */
    bool is_connected() const;

    /** Get underlying UDP socket fd. */
    int fd() const;

    /** Shutdown DTLS session. */
    void shutdown();

private:
    DtlsSocket();

    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace soluna::transport
