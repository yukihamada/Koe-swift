#pragma once

/**
 * AES67 Compatibility Mode — SAP/SDP announcer for AES67 interop
 *
 * When enabled, Soluna can interoperate with AES67-compliant devices by:
 * - Sending standard RTP without OSTP extension headers
 * - Using AES67 payload types (L24=10, L16=11)
 * - Announcing sessions via SAP multicast (224.2.127.254:9875)
 * - Generating SDP session descriptions
 *
 * Note: This is AES67 "compatible", not fully AES67 certified.
 *
 * SPDX-License-Identifier: MIT
 */

#include <soluna/soluna.h>
#include <soluna/transport/rtp.h>
#include <cstdint>
#include <cstddef>
#include <string>
#include <vector>
#include <functional>
#include <memory>

namespace soluna::transport {

// AES67 standard payload types
constexpr uint8_t kPayloadTypeL24 = 10;  // 24-bit linear PCM (AES67)
constexpr uint8_t kPayloadTypeL16 = 11;  // 16-bit linear PCM (AES67)

// SAP multicast address and port (RFC 2974)
constexpr const char* kSapMulticastAddr = "224.2.127.254";
constexpr uint16_t    kSapPort          = 9875;

// SAP announce interval
constexpr uint32_t kSapIntervalSec = 30;

// SAP header (RFC 2974)
struct __attribute__((packed)) SapHeader {
    uint8_t  version_flags;  // V=1, A=0(IPv4), R=0, T=0, E=0, C=0
    uint8_t  auth_length;    // 0 (no authentication)
    uint16_t msg_id_hash;    // hash of session description
    uint32_t originating_source;  // IPv4 address of announcer
};

static_assert(sizeof(SapHeader) == 8, "SAP header must be 8 bytes");

/**
 * AES67 session descriptor.
 */
struct Aes67Session {
    std::string session_name;
    std::string origin_address;    // local IP
    uint32_t    session_id = 0;
    uint32_t    session_version = 1;
    std::string multicast_group;
    uint16_t    rtp_port = 5004;
    uint32_t    sample_rate = 48000;
    uint32_t    channels = 1;
    uint32_t    bit_depth = 24;    // 24 or 16
    uint8_t     payload_type = kPayloadTypeL24;
    uint32_t    packet_time_us = 1000;  // 1ms default for AES67
};

/**
 * Generate SDP text for an AES67 session.
 *
 * Returns standard SDP (v=0, o=, s=, c=, t=, m=, a=) suitable for
 * SAP announcement or manual configuration.
 */
std::string aes67_generate_sdp(const Aes67Session& session);

/**
 * Build a SAP announcement packet containing the SDP.
 *
 * @param session    AES67 session to announce
 * @param out_buf    Output buffer
 * @param buf_size   Output buffer size
 * @return           Number of bytes written, 0 on error
 */
size_t aes67_build_sap_packet(const Aes67Session& session,
                              uint8_t* out_buf, size_t buf_size);

/**
 * Build an AES67-compatible RTP packet (no OSTP extension).
 *
 * @param out_buf      Output buffer
 * @param buf_size     Output buffer size
 * @param ssrc         RTP SSRC
 * @param sequence     RTP sequence number
 * @param timestamp    RTP timestamp
 * @param payload_type AES67 payload type (L24 or L16)
 * @param payload      Audio payload data
 * @param payload_size Audio payload size in bytes
 * @return             Total packet size, 0 on error
 */
size_t aes67_build_rtp_packet(uint8_t* out_buf, size_t buf_size,
                              uint32_t ssrc, uint16_t sequence,
                              uint32_t timestamp, uint8_t payload_type,
                              const void* payload, size_t payload_size);

/**
 * Parse the payload type from an RTP packet to determine if it
 * is an AES67-standard packet (PT 10 or 11).
 */
bool aes67_is_standard_packet(const RtpHeader& hdr);

/**
 * Compute SAP message ID hash from SDP text.
 */
uint16_t aes67_sap_hash(const std::string& sdp);

// ============================================================================
// AES67 Receiver Support
// ============================================================================

/**
 * Parsed AES67 remote session from SDP.
 */
struct Aes67RemoteSession {
    std::string session_name;
    std::string origin_address;
    uint32_t session_id = 0;
    uint32_t session_version = 0;
    std::string multicast_ip;
    uint16_t port = 0;
    uint32_t sample_rate = 48000;
    uint8_t channels = 1;
    uint8_t bit_depth = 24;
    uint8_t payload_type = kPayloadTypeL24;
    uint32_t packet_time_us = 1000;
    bool has_ptp_refclk = false;
};

/**
 * Parse SDP text and extract AES67 session parameters.
 *
 * @param sdp       SDP text to parse
 * @param out       Parsed session information
 * @return          true if parsing succeeded
 */
bool aes67_parse_sdp(const char* sdp, Aes67RemoteSession& out);
bool aes67_parse_sdp(const std::string& sdp, Aes67RemoteSession& out);

/**
 * SAP Listener — Receives SAP announcements and discovers AES67 sessions.
 *
 * Joins multicast group 224.2.127.254:9875 and invokes callback for each
 * discovered session.
 */
class SapListener {
public:
    using SessionCallback = std::function<void(const Aes67RemoteSession& session, bool is_deletion)>;

    SapListener();
    ~SapListener();

    SapListener(const SapListener&) = delete;
    SapListener& operator=(const SapListener&) = delete;

    /**
     * Start listening for SAP announcements.
     *
     * @param on_session Callback invoked for each discovered session.
     *                   is_deletion=true means session is being withdrawn.
     * @return true if started successfully
     */
    bool start(SessionCallback on_session);

    /**
     * Stop listening.
     */
    void stop();

    /**
     * Check if listener is running.
     */
    bool is_running() const;

    /**
     * Get number of known sessions.
     */
    size_t session_count() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace soluna::transport
