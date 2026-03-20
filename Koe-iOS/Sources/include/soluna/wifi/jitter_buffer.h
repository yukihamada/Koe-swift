#pragma once

/**
 * Lock-free Jitter Buffer — WiFi audio buffering
 *
 * Reorders and buffers incoming packets to absorb network jitter.
 * Uses a fixed-size circular array indexed by sequence number — no heap
 * allocations, no mutexes on the audio path.
 *
 * SPDX-License-Identifier: MIT
 */

#include <soluna/soluna.h>
#include <cstdint>
#include <cstddef>
#include <atomic>
#include <cstring>

namespace soluna::wifi {

struct JitterBufferConfig {
    uint32_t sample_rate = 48000;
    uint32_t channels = 1;
    uint32_t frame_size = 4;          // bytes per sample (int32_t)
    uint32_t max_packet_payload = 4096; // max payload bytes per packet

    // Buffer depth range in milliseconds
    double min_depth_ms = 2.0;
    double max_depth_ms = 20.0;
    double initial_depth_ms = 4.0;

    // Adaptation parameters
    double depth_increase_factor = 1.5;    // multiply depth on underrun
    double depth_decrease_rate = 0.001;    // ms per successful read
    double jitter_smoothing = 0.05;        // EMA alpha for jitter estimate

    StreamMode mode = StreamMode::Sync;
};

struct JitterBufferStats {
    double current_depth_ms = 0.0;
    double target_depth_ms = 0.0;
    double jitter_ms = 0.0;           // estimated jitter
    double max_jitter_ms = 0.0;
    uint64_t packets_received = 0;
    uint64_t packets_played = 0;
    uint64_t packets_dropped_late = 0;
    uint64_t packets_dropped_overflow = 0;
    uint64_t underruns = 0;
    uint32_t buffer_occupancy = 0;     // current packet count in buffer
    double packet_loss_rate = 0.0;     // 0.0-1.0
};

/**
 * Lock-free jitter buffer using a fixed-size circular slot array.
 *
 * Slots are indexed by (sequence % capacity). Each slot has an atomic
 * "occupied" flag. The writer (network thread) sets occupied=true after
 * writing; the reader (audio thread) reads the slot and sets occupied=false.
 *
 * No mutex, no heap allocation after construction.
 */
class JitterBuffer {
public:
    explicit JitterBuffer(const JitterBufferConfig& config = {});
    ~JitterBuffer();

    JitterBuffer(const JitterBuffer&) = delete;
    JitterBuffer& operator=(const JitterBuffer&) = delete;

    /**
     * Push a received packet into the buffer (network thread).
     * Lock-free. No heap allocation.
     */
    void push(uint16_t sequence, int64_t timestamp_ns,
              const void* data, size_t data_size);

    /**
     * Pop the next packet for playout (audio thread).
     * Lock-free. Returns bytes copied, or 0 if not ready.
     */
    size_t pop(void* out_buf, size_t buf_size);

    /**
     * Check if buffer has enough data for playout.
     */
    bool ready() const;

    /** Reset the buffer. */
    void reset();

    /** Get current statistics (read-only snapshot). */
    JitterBufferStats stats() const;

    /** Get current target depth in milliseconds. */
    double target_depth_ms() const;

    /** Switch stream mode at runtime. Adjusts depth parameters. */
    void set_mode(StreamMode mode);

private:
    static constexpr size_t kSlotCount = 512; // power of 2, ~1 second at 2ms packets
    static constexpr size_t kSlotMask = kSlotCount - 1;

    struct Slot {
        alignas(64) std::atomic<bool> occupied{false};
        uint16_t sequence = 0;
        size_t   data_size = 0;
        uint8_t  data[4096]; // fixed inline storage — no heap alloc
    };

    JitterBufferConfig config_;
    Slot slots_[kSlotCount];

    // Reader state (audio thread only)
    uint16_t next_sequence_ = 0;
    bool started_ = false;

    // Adaptive depth
    std::atomic<double> target_depth_ms_;

    // Jitter estimation (writer thread only)
    double jitter_estimate_ms_ = 0.0;
    double max_jitter_ms_ = 0.0;
    int64_t prev_arrival_ns_ = 0;

    // Atomic statistics (updated by respective threads)
    std::atomic<uint64_t> total_received_{0};
    std::atomic<uint64_t> total_played_{0};
    std::atomic<uint64_t> late_drops_{0};
    std::atomic<uint64_t> overflow_drops_{0};
    std::atomic<uint64_t> underruns_{0};
    std::atomic<uint64_t> total_expected_{0};
    std::atomic<uint64_t> total_lost_{0};
    std::atomic<uint32_t> occupancy_{0}; // approximate

    void adapt_depth();
    static int16_t seq_diff(uint16_t a, uint16_t b);
};

} // namespace soluna::wifi
