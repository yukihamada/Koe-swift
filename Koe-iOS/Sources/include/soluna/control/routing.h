#pragma once

/**
 * Routing Matrix — Audio signal routing with gain control
 *
 * Maps source channels to destination channels with per-crosspoint
 * gain control and metering. Supports crossfade on route changes.
 *
 * SPDX-License-Identifier: MIT
 */

#include <soluna/soluna.h>
#include <cstdint>
#include <cstddef>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <vector>
#include <cmath>
#include <atomic>

namespace soluna::control {

struct ChannelId {
    std::string device;
    uint32_t channel = 0;

    bool operator==(const ChannelId& o) const {
        return device == o.device && channel == o.channel;
    }
    bool operator<(const ChannelId& o) const {
        if (device != o.device) return device < o.device;
        return channel < o.channel;
    }

    std::string to_string() const {
        return device + ":" + std::to_string(channel);
    }

    static ChannelId parse(const std::string& s) {
        ChannelId id;
        auto colon = s.rfind(':');
        if (colon != std::string::npos) {
            id.device = s.substr(0, colon);
            id.channel = static_cast<uint32_t>(std::stoi(s.substr(colon + 1)));
        }
        return id;
    }
};

struct Route {
    ChannelId source;
    ChannelId sink;
    float gain_db = 0.0f;       // gain in dB (0 = unity)
    bool muted = false;

    float gain_linear() const {
        if (muted) return 0.0f;
        return std::pow(10.0f, gain_db / 20.0f);
    }
};

struct MeterValues {
    float peak_db = -144.0f;    // peak level in dBFS
    float rms_db = -144.0f;     // RMS level in dBFS
    uint64_t clip_count = 0;
};

using RouteChangeCallback = std::function<void(const Route& route, bool added)>;

class RoutingMatrix {
public:
    RoutingMatrix();
    ~RoutingMatrix();

    RoutingMatrix(const RoutingMatrix&) = delete;
    RoutingMatrix& operator=(const RoutingMatrix&) = delete;

    /** Add a route from source to sink. Returns true on success. */
    bool add_route(const ChannelId& source, const ChannelId& sink,
                   float gain_db = 0.0f);

    /** Remove a route. */
    bool remove_route(const ChannelId& source, const ChannelId& sink);

    /** Remove all routes involving a device. */
    void remove_device_routes(const std::string& device);

    /** Set gain for a route. */
    bool set_gain(const ChannelId& source, const ChannelId& sink, float gain_db);

    /** Set mute for a route. */
    bool set_mute(const ChannelId& source, const ChannelId& sink, bool muted);

    /** Get all routes. */
    std::vector<Route> list_routes() const;

    /** Get routes for a specific source. */
    std::vector<Route> get_source_routes(const ChannelId& source) const;

    /** Get routes for a specific sink. */
    std::vector<Route> get_sink_routes(const ChannelId& sink) const;

    /** Check if a route exists. */
    bool has_route(const ChannelId& source, const ChannelId& sink) const;

    /** Get route count. */
    size_t route_count() const;

    /**
     * Apply routing: mix source samples to output buffer.
     * sources: map of device:channel → sample buffer (float, frame_count frames)
     * sinks: map of device:channel → output buffer (float, frame_count frames)
     * Applies gain and sums all sources routed to each sink.
     */
    void apply(const std::map<ChannelId, const float*>& sources,
               std::map<ChannelId, float*>& sinks,
               size_t frame_count);

    /** Get meter values for a channel. */
    MeterValues get_meter(const ChannelId& channel) const;

    /** Update meters from audio data. Call after apply(). */
    void update_meters(const ChannelId& channel, const float* data,
                       size_t frame_count);

    /** Reset all meters. */
    void reset_meters();

    /** Set callback for route changes. */
    void set_change_callback(RouteChangeCallback cb);

    /** Clear all routes. */
    void clear();

private:
    using RouteKey = std::pair<ChannelId, ChannelId>;

    mutable std::mutex mutex_;
    std::map<RouteKey, Route> routes_;
    mutable std::map<ChannelId, MeterValues> meters_;
    RouteChangeCallback change_callback_;

    void notify(const Route& route, bool added);
};

// Crossfade helper: linear crossfade over N frames
void crossfade(const float* old_buf, const float* new_buf, float* output,
               size_t frame_count);

} // namespace soluna::control
