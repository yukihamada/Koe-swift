#pragma once

/**
 * Session Manager — Stream lifecycle management
 *
 * Manages audio streams between devices:
 * - Creates and destroys streams
 * - Tracks active connections
 * - Handles stream negotiation (format, channels)
 *
 * SPDX-License-Identifier: MIT
 */

#include <soluna/soluna.h>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace soluna::control {

enum class StreamState {
    Inactive,
    Negotiating,
    Active,
    Error,
};

struct StreamInfo {
    uint16_t stream_id = 0;
    std::string source_device;
    std::string sink_device;
    uint32_t channels = 1;
    uint32_t sample_rate = 48000;
    SampleFormat format = SampleFormat::S24_LE;
    PacketTier tier = PacketTier::Standard;
    std::string multicast_group;
    uint16_t rtp_port = 5004;
    uint32_t ssrc = 0;
    StreamState state = StreamState::Inactive;
    int64_t created_ns = 0;
    uint64_t packets_sent = 0;
    uint64_t packets_received = 0;
};

class SessionManager {
public:
    SessionManager();
    ~SessionManager();

    SessionManager(const SessionManager&) = delete;
    SessionManager& operator=(const SessionManager&) = delete;

    /**
     * Create a new stream.
     * Returns stream_id, or 0 on failure.
     */
    uint16_t create_stream(const std::string& source_device,
                           const std::string& sink_device,
                           uint32_t channels = 1,
                           uint32_t sample_rate = 48000);

    /** Destroy a stream. */
    bool destroy_stream(uint16_t stream_id);

    /** Get stream info. */
    std::unique_ptr<StreamInfo> get_stream(uint16_t stream_id) const;

    /** List all streams. */
    std::vector<StreamInfo> list_streams() const;

    /** Update stream state. */
    void set_stream_state(uint16_t stream_id, StreamState state);

    /** Get next available stream ID. */
    uint16_t next_stream_id() const;

    /** Get next available RTP port. */
    uint16_t next_rtp_port() const;

private:
    mutable std::mutex mutex_;
    std::map<uint16_t, StreamInfo> streams_;
    uint16_t next_id_ = 1;
    uint16_t next_port_ = 5004;
};

} // namespace soluna::control
