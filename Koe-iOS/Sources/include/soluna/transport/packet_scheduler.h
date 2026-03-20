#pragma once

#include <soluna/soluna.h>
#include <soluna/pal/time.h>
#include <cstdint>

namespace soluna::transport {

/**
 * Schedules packet transmission at precise intervals.
 */
class PacketScheduler {
public:
    explicit PacketScheduler(PacketTier tier, uint32_t sample_rate = kDefaultSampleRate);

    // Call at start to initialize timing
    void reset();

    // Wait until next packet should be sent. Returns the target timestamp.
    pal::Timestamp wait_next();

    // Get packet interval in nanoseconds
    int64_t interval_ns() const { return interval_ns_; }

    // Get samples per packet
    uint32_t samples_per_packet() const { return samples_per_packet_; }

private:
    int64_t interval_ns_;
    uint32_t samples_per_packet_;
    pal::Timestamp next_send_time_;
};

} // namespace soluna::transport
