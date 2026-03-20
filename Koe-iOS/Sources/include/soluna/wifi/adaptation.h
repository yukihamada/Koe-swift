#pragma once

/**
 * WiFi Adaptation Controller — Quality monitoring and auto-tuning
 *
 * Monitors network conditions and adapts:
 * - FEC level (none / XOR / Reed-Solomon)
 * - Jitter buffer depth
 * - Packet size / tier
 * - Opus bitrate (if compression enabled)
 *
 * SPDX-License-Identifier: MIT
 */

#include <soluna/soluna.h>
#include <soluna/wifi/fec.h>
#include <cstdint>
#include <functional>
#include <mutex>

namespace soluna::wifi {

struct WiFiQualityMetrics {
    double jitter_ms = 0.0;         // inter-packet jitter
    double packet_loss_rate = 0.0;  // 0.0-1.0 (e.g., 0.02 = 2%)
    double rtt_ms = 0.0;            // round-trip time (if available)
    int rssi_dbm = -50;             // WiFi signal strength
    double throughput_mbps = 0.0;   // estimated throughput
    int64_t timestamp_ns = 0;       // when metrics were sampled
};

enum class WiFiQualityLevel : uint8_t {
    Excellent = 0,   // jitter <1ms, loss <0.1%
    Good = 1,        // jitter <3ms, loss <1%
    Fair = 2,        // jitter <5ms, loss <3%
    Poor = 3,        // jitter <10ms, loss <5%
    Critical = 4,    // jitter >10ms or loss >5%
};

struct AdaptationConfig {
    // Thresholds for quality levels
    double jitter_excellent_ms = 1.0;
    double jitter_good_ms = 3.0;
    double jitter_fair_ms = 5.0;
    double jitter_poor_ms = 10.0;

    double loss_excellent = 0.001;   // 0.1%
    double loss_good = 0.01;         // 1%
    double loss_fair = 0.03;         // 3%
    double loss_poor = 0.05;         // 5%

    // Adaptation timing
    double evaluation_interval_ms = 1000.0;  // re-evaluate every N ms
    double hysteresis_ms = 3000.0;           // min time between FEC changes

    // FEC auto-selection
    bool auto_fec = true;
    uint8_t rs_parity_min = 1;
    uint8_t rs_parity_max = 4;
    uint8_t fec_group_size = 5;

    // Opus adaptation
    bool auto_opus_bitrate = true;
    uint32_t opus_bitrate_min = 32000;
    uint32_t opus_bitrate_max = 128000;

    StreamMode mode = StreamMode::Sync;
};

struct AdaptationState {
    WiFiQualityLevel quality = WiFiQualityLevel::Good;
    FecMode fec_mode = FecMode::None;
    uint8_t fec_parity = 1;
    PacketTier packet_tier = PacketTier::WiFi;
    uint32_t opus_bitrate = 96000;
    double jitter_buffer_depth_ms = 4.0;
    int64_t last_change_ns = 0;
};

using AdaptationCallback = std::function<void(const AdaptationState& state)>;

class AdaptationController {
public:
    explicit AdaptationController(const AdaptationConfig& config = {});
    ~AdaptationController();

    /**
     * Feed new quality metrics. May trigger adaptation.
     * Returns true if adaptation state changed.
     */
    bool update(const WiFiQualityMetrics& metrics);

    /**
     * Record a packet loss event.
     */
    void record_loss(uint64_t lost, uint64_t total);

    /**
     * Record a jitter measurement.
     */
    void record_jitter(double jitter_ms);

    /**
     * Get current adaptation state.
     */
    AdaptationState state() const;

    /**
     * Get current quality level.
     */
    WiFiQualityLevel quality_level() const;

    /**
     * Get recommended FEC config based on current quality.
     */
    FecConfig recommended_fec() const;

    /**
     * Get recommended jitter buffer depth in ms.
     */
    double recommended_jitter_depth_ms() const;

    /**
     * Get recommended Opus bitrate.
     */
    uint32_t recommended_opus_bitrate() const;

    /**
     * Set callback for state changes.
     */
    void set_callback(AdaptationCallback cb);

    /** Switch stream mode. Jam mode uses aggressive low-latency adaptation. */
    void set_mode(StreamMode mode);

    void reset();

private:
    AdaptationConfig config_;
    mutable std::mutex mutex_;
    AdaptationState state_;
    AdaptationCallback callback_;

    // Running statistics
    double jitter_ema_ms_ = 0.0;
    double loss_ema_ = 0.0;
    uint64_t total_packets_ = 0;
    uint64_t lost_packets_ = 0;
    int64_t last_eval_ns_ = 0;

    WiFiQualityLevel classify(const WiFiQualityMetrics& m) const;
    void adapt(WiFiQualityLevel level);
    FecMode select_fec_mode(WiFiQualityLevel level) const;
    uint8_t select_fec_parity(WiFiQualityLevel level) const;
    double select_jitter_depth(WiFiQualityLevel level) const;
    uint32_t select_opus_bitrate(WiFiQualityLevel level) const;
};

} // namespace soluna::wifi
