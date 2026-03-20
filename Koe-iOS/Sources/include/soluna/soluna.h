#pragma once

/**
 * Soluna — Open Network Audio System
 *
 * SPDX-License-Identifier: MIT
 */

#include <cstdint>
#include <cstddef>

#define SOLUNA_VERSION_MAJOR 0
#define SOLUNA_VERSION_MINOR 1
#define SOLUNA_VERSION_PATCH 0

namespace soluna {

// Standard audio parameters
constexpr uint32_t kDefaultSampleRate = 48000;
constexpr uint32_t kDefaultBitDepth = 24;
constexpr uint32_t kMaxChannels = 64;

// Packet timing tiers (samples per packet at 48kHz)
enum class PacketTier : uint8_t {
    Ultra    = 0,   // 125us,  6 samples (GbE only)
    Low      = 1,   // 250us, 12 samples (GbE)
    Standard = 2,   // 1ms,   48 samples (GbE, 100M)
    WiFi     = 3,   // 2ms,   96 samples (WiFi 5/6)
    LAN      = 4,   // 5ms,  240 samples (home LAN — low latency)
    Robust   = 5,   // 10ms, 480 samples (high jitter tolerance)
};

constexpr uint32_t samples_per_packet(PacketTier tier) {
    switch (tier) {
        case PacketTier::Ultra:    return 6;
        case PacketTier::Low:      return 12;
        case PacketTier::Standard: return 48;
        case PacketTier::WiFi:     return 96;
        case PacketTier::LAN:      return 240;
        case PacketTier::Robust:   return 480;
    }
    return 240;
}

// Audio sample formats
enum class SampleFormat : uint8_t {
    S24_LE  = 0,   // 24-bit signed integer, little-endian (in 32-bit container)
    F32_LE  = 1,   // 32-bit float, little-endian
    S16_LE  = 2,   // 16-bit signed integer, little-endian
    S32_LE  = 3,   // 32-bit signed integer, little-endian
};

constexpr size_t sample_size(SampleFormat fmt) {
    switch (fmt) {
        case SampleFormat::S16_LE: return 2;
        case SampleFormat::S24_LE: return 4; // stored in 32-bit container
        case SampleFormat::S32_LE: return 4;
        case SampleFormat::F32_LE: return 4;
    }
    return 4;
}

// Stream modes — determines latency vs synchronization tradeoff
enum class StreamMode : uint8_t {
    Sync = 0,   // Multi-room sync: PTP-aligned playout, buffers aligned across devices
    Jam  = 1,   // Low-latency jam: minimal buffering, skip PTP alignment, ~20ms e2e
};

// Network ports
constexpr uint16_t kPortPTPEvent    = 319;
constexpr uint16_t kPortPTPGeneral  = 320;
constexpr uint16_t kPortMDNS        = 5353;
constexpr uint16_t kPortRTPBase     = 5004;
constexpr uint16_t kPortRTPMax      = 5199;
constexpr uint16_t kPortControl     = 8400;
constexpr uint16_t kPortControlUDP  = 8401;

// Multicast addresses
constexpr const char* kMulticastPTP     = "224.0.1.129";
constexpr const char* kMulticastAudio   = "239.69.0.1";
constexpr const char* kMulticastMDNS    = "224.0.0.251";

} // namespace soluna
