#pragma once

/**
 * Adaptive PLL — Media clock recovery for WiFi paths
 *
 * Recovers the media clock from incoming RTP timestamps when
 * PTP precision is insufficient (e.g., WiFi with high jitter).
 * Uses a PLL that adapts its bandwidth based on network conditions.
 *
 * SPDX-License-Identifier: MIT
 */

#include <cstdint>

namespace soluna::sync {

struct AdaptivePllConfig {
    double initial_bandwidth_hz = 1.0;  // PLL loop bandwidth
    double min_bandwidth_hz = 0.1;
    double max_bandwidth_hz = 10.0;
    uint32_t sample_rate = 48000;
    double jitter_threshold_ns = 500000.0; // 500us — widen bandwidth above this
};

struct AdaptivePllState {
    double phase_error_ns = 0.0;
    double freq_offset_ppb = 0.0;
    double bandwidth_hz = 1.0;
    double jitter_estimate_ns = 0.0;
    uint64_t sample_count = 0;
    bool locked = false;
};

class AdaptivePll {
public:
    explicit AdaptivePll(const AdaptivePllConfig& config = {});

    /**
     * Feed a new media timestamp pair.
     * local_ns: local clock time when packet arrived
     * media_ns: media timestamp from OSTP header (converted to ns)
     * Returns recommended sample rate ratio adjustment.
     */
    double feed(int64_t local_ns, int64_t media_ns);

    /** Reset PLL state. */
    void reset();

    const AdaptivePllState& state() const { return state_; }

private:
    AdaptivePllConfig config_;
    AdaptivePllState state_;
    int64_t last_local_ns_ = 0;
    int64_t last_media_ns_ = 0;
    bool first_sample_ = true;
};

} // namespace soluna::sync
