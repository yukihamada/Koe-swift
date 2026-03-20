#pragma once

/**
 * PTP-synchronized Playout Buffer
 *
 * Holds received audio packets and releases them at the correct
 * PTP-synchronized playout time. This ensures all receivers
 * on the network play the same sample at the same wall-clock time.
 *
 * SPDX-License-Identifier: MIT
 */

#include <soluna/soluna.h>
#include <soluna/pal/time.h>
#include <cstdint>
#include <cstddef>
#include <vector>
#include <mutex>

namespace soluna::pipeline {

struct PlayoutPacket {
    uint32_t media_timestamp = 0;   // OSTP media timestamp
    uint32_t rtp_timestamp = 0;
    uint16_t sequence = 0;
    std::vector<uint8_t> audio_data;
    bool valid = false;
};

struct PlayoutBufferConfig {
    uint32_t capacity_packets = 64;
    uint32_t sample_rate = kDefaultSampleRate;
    uint32_t channels = 1;
    size_t frame_size = 4;            // bytes per frame per channel
    uint32_t target_depth_packets = 4; // target buffer depth
    int64_t playout_delay_ns = 1'000'000; // 1ms default playout delay
    StreamMode mode = StreamMode::Sync;
};

struct PlayoutBufferStats {
    uint64_t packets_received = 0;
    uint64_t packets_played = 0;
    uint64_t packets_dropped_late = 0;
    uint64_t packets_dropped_overflow = 0;
    uint64_t underruns = 0;
    int32_t current_depth = 0;   // packets in buffer
    int64_t playout_offset_ns = 0; // current playout timing offset
};

class PlayoutBuffer {
public:
    explicit PlayoutBuffer(const PlayoutBufferConfig& config = {});

    /**
     * Insert a received packet into the buffer.
     * Returns true if accepted, false if dropped (late or overflow).
     */
    bool insert(const PlayoutPacket& packet);

    /**
     * Read the next packet for playout at the given PTP time.
     * Returns true if a packet is available, fills 'out'.
     * If no packet is ready (underrun), returns false.
     */
    bool read_at(int64_t ptp_now_ns, PlayoutPacket& out);

    /**
     * Read frames directly into a float buffer for audio output.
     * Uses internal conversion from S24.
     * Returns frames written (may be less than requested on underrun).
     */
    size_t read_frames(int64_t ptp_now_ns, float* output, size_t frame_count,
                       uint32_t channels);

    /** Set the playout delay in nanoseconds. */
    void set_playout_delay(int64_t delay_ns);

    /** Switch stream mode. In Jam mode, bypasses PTP alignment for minimum latency. */
    void set_mode(StreamMode mode);

    /** Get current stats. */
    PlayoutBufferStats stats() const;

    /** Reset buffer to empty state. */
    void reset();

private:
    PlayoutBufferConfig config_;
    std::vector<PlayoutPacket> ring_;
    size_t write_idx_ = 0;
    mutable std::mutex mutex_;
    PlayoutBufferStats stats_;

    // Base time mapping: first received packet sets the reference
    int64_t base_media_ns_ = 0;
    int64_t base_ptp_ns_ = 0;
    bool base_set_ = false;

    StreamMode mode_ = StreamMode::Sync;

    int64_t media_ts_to_playout_ns(uint32_t media_ts) const;
};

} // namespace soluna::pipeline
