#pragma once

#include <cstdint>
#include <cstddef>

namespace soluna::transport {

// RTP header (RFC 3550), 12 bytes
struct __attribute__((packed)) RtpHeader {
    uint8_t  cc : 4;       // CSRC count
    uint8_t  extension : 1;
    uint8_t  padding : 1;
    uint8_t  version : 2;  // always 2
    uint8_t  pt : 7;       // payload type
    uint8_t  marker : 1;
    uint16_t sequence;
    uint32_t timestamp;
    uint32_t ssrc;
};

static_assert(sizeof(RtpHeader) == 12, "RTP header must be 12 bytes");

// Payload types (dynamic, Soluna-specific)
constexpr uint8_t kPayloadTypePCM24  = 96;  // dynamic
constexpr uint8_t kPayloadTypeF32    = 97;
constexpr uint8_t kPayloadTypeOpus   = 98;

// AES67-standard payload types (static assignments)
constexpr uint8_t kPayloadTypeAES67_L24 = 10;  // 24-bit linear PCM
constexpr uint8_t kPayloadTypeAES67_L16 = 11;  // 16-bit linear PCM

// WiFi reliability payload types
constexpr uint8_t kPayloadTypeNACK = 126;  // NACK retransmission request
constexpr uint8_t kPayloadTypeFEC  = 127;  // FEC parity packet

// RTP extension header (RFC 3550 section 5.3.1)
struct __attribute__((packed)) RtpExtensionHeader {
    uint16_t profile_specific;  // 0x4F53 = "OS" for OSTP
    uint16_t length;            // extension length in 32-bit words (2 for OSTP)
};

static_assert(sizeof(RtpExtensionHeader) == 4, "RTP ext header must be 4 bytes");

} // namespace soluna::transport
