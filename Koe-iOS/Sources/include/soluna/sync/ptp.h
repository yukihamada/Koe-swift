#pragma once

/**
 * PTPv2 (IEEE 1588-2008) Protocol Definitions
 *
 * Implements the subset needed for network audio synchronization:
 * - Sync / Follow_Up (master → slave offset measurement)
 * - Delay_Req / Delay_Resp (slave → master delay measurement)
 * - Announce (BMCA master election)
 *
 * SPDX-License-Identifier: MIT
 */

#include <soluna/pal/time.h>
#include <cstdint>
#include <cstddef>
#include <cstring>
#include <array>

namespace soluna::sync {

// PTP message types
enum class PtpMessageType : uint8_t {
    Sync        = 0x0,
    DelayReq    = 0x1,
    FollowUp    = 0x8,
    DelayResp   = 0x9,
    Announce    = 0xB,
};

// PTP clock classes (IEEE 1588 Table 5)
enum class PtpClockClass : uint8_t {
    PrimarySyncRef     = 6,    // GPS / atomic
    AppSpecific        = 13,   // Application-specific (e.g. grandmaster)
    LostPrimarySyncRef = 7,
    Default            = 248,  // Default (slave-only capable)
};

// PTP clock accuracy (IEEE 1588 Table 6)
enum class PtpClockAccuracy : uint8_t {
    Within25ns   = 0x20,
    Within100ns  = 0x21,
    Within250ns  = 0x22,
    Within1us    = 0x23,
    Within2_5us  = 0x24,
    Within10us   = 0x25,
    Within25us   = 0x26,
    Within100us  = 0x27,
    Within250us  = 0x28,
    Within1ms    = 0x29,
    Unknown      = 0xFE,
};

// PTP port identity
struct PtpPortIdentity {
    std::array<uint8_t, 8> clock_id{};
    uint16_t port_number = 1;

    bool operator==(const PtpPortIdentity& o) const {
        return clock_id == o.clock_id && port_number == o.port_number;
    }
    bool operator!=(const PtpPortIdentity& o) const { return !(*this == o); }
};

// PTP clock quality (for BMCA)
struct PtpClockQuality {
    PtpClockClass clock_class = PtpClockClass::Default;
    PtpClockAccuracy clock_accuracy = PtpClockAccuracy::Unknown;
    uint16_t offset_scaled_log_variance = 0xFFFF;
};

// PTP timestamp (80-bit: 48-bit seconds + 32-bit nanoseconds)
struct PtpTimestamp {
    uint16_t seconds_msb = 0;   // upper 16 bits of 48-bit seconds
    uint32_t seconds_lsb = 0;   // lower 32 bits
    uint32_t nanoseconds = 0;

    int64_t to_ns() const {
        int64_t sec = (static_cast<int64_t>(seconds_msb) << 32) | seconds_lsb;
        return sec * 1'000'000'000LL + nanoseconds;
    }

    static PtpTimestamp from_ns(int64_t ns) {
        PtpTimestamp t;
        int64_t sec = ns / 1'000'000'000LL;
        t.nanoseconds = static_cast<uint32_t>(ns % 1'000'000'000LL);
        t.seconds_msb = static_cast<uint16_t>((sec >> 32) & 0xFFFF);
        t.seconds_lsb = static_cast<uint32_t>(sec & 0xFFFFFFFF);
        return t;
    }

    static PtpTimestamp from_pal(const pal::Timestamp& ts) {
        return from_ns(ts.to_ns());
    }

    pal::Timestamp to_pal() const {
        return pal::Timestamp::from_ns(to_ns());
    }
};

// PTP common header (34 bytes)
struct PtpHeader {
    PtpMessageType message_type = PtpMessageType::Sync;
    uint8_t version = 2;          // PTP version
    uint16_t message_length = 0;
    uint8_t domain_number = 0;
    uint8_t flags[2] = {0, 0};
    int64_t correction_field = 0;  // scaled nanoseconds (ns × 2^16)
    PtpPortIdentity source_port_id;
    uint16_t sequence_id = 0;
    uint8_t control_field = 0;
    int8_t log_message_interval = 0;
};

// Announce message body
struct PtpAnnounceBody {
    PtpTimestamp origin_timestamp;
    uint16_t current_utc_offset = 37;  // TAI-UTC
    uint8_t grandmaster_priority1 = 128;
    PtpClockQuality grandmaster_clock_quality;
    uint8_t grandmaster_priority2 = 128;
    std::array<uint8_t, 8> grandmaster_identity{};
    uint16_t steps_removed = 0;
    uint8_t time_source = 0xA0;  // internal oscillator
};

// Delay_Resp message body
struct PtpDelayRespBody {
    PtpTimestamp receive_timestamp;
    PtpPortIdentity requesting_port_id;
};

// ---- Serialization ----

// Serialize PTP header + body into buffer. Returns bytes written, 0 on error.
size_t ptp_serialize_sync(uint8_t* buf, size_t buf_size,
    const PtpHeader& hdr, const PtpTimestamp& origin_ts);

size_t ptp_serialize_follow_up(uint8_t* buf, size_t buf_size,
    const PtpHeader& hdr, const PtpTimestamp& precise_ts);

size_t ptp_serialize_delay_req(uint8_t* buf, size_t buf_size,
    const PtpHeader& hdr, const PtpTimestamp& origin_ts);

size_t ptp_serialize_delay_resp(uint8_t* buf, size_t buf_size,
    const PtpHeader& hdr, const PtpDelayRespBody& body);

size_t ptp_serialize_announce(uint8_t* buf, size_t buf_size,
    const PtpHeader& hdr, const PtpAnnounceBody& body);

// ---- Deserialization ----

// Parse PTP header from buffer. Returns true on success.
bool ptp_parse_header(const uint8_t* buf, size_t buf_size, PtpHeader& hdr);

// Parse timestamp from body (Sync, Follow_Up, Delay_Req)
bool ptp_parse_timestamp_body(const uint8_t* buf, size_t buf_size, PtpTimestamp& ts);

// Parse Delay_Resp body
bool ptp_parse_delay_resp(const uint8_t* buf, size_t buf_size, PtpDelayRespBody& body);

// Parse Announce body
bool ptp_parse_announce(const uint8_t* buf, size_t buf_size, PtpAnnounceBody& body);

// Message sizes
constexpr size_t kPtpHeaderSize = 34;
constexpr size_t kPtpSyncSize = 44;        // header + 10-byte timestamp
constexpr size_t kPtpFollowUpSize = 44;
constexpr size_t kPtpDelayReqSize = 44;
constexpr size_t kPtpDelayRespSize = 54;   // header + 10-byte ts + 10-byte port id
constexpr size_t kPtpAnnounceSize = 64;

} // namespace soluna::sync
