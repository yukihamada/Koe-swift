#pragma once

/**
 * Soluna — Metrics Registry
 *
 * Central registry for all metrics with thread-safe access.
 *
 * SPDX-License-Identifier: MIT
 */

#include <soluna/metrics/metrics.h>
#include <memory>
#include <unordered_map>
#include <mutex>
#include <functional>

namespace soluna {
namespace metrics {

/**
 * Central metric registry.
 *
 * Thread-safe singleton for registering and accessing metrics.
 */
class Registry {
public:
    /**
     * Get the global registry instance.
     */
    static Registry& instance();

    /**
     * Register a counter.
     */
    Counter& counter(const std::string& name, const std::string& help);

    /**
     * Register a labeled counter.
     */
    LabeledCounter& labeled_counter(const std::string& name, const std::string& help,
                                    const std::vector<std::string>& label_names);

    /**
     * Register a gauge.
     */
    Gauge& gauge(const std::string& name, const std::string& help);

    /**
     * Register a labeled gauge.
     */
    LabeledGauge& labeled_gauge(const std::string& name, const std::string& help,
                                 const std::vector<std::string>& label_names);

    /**
     * Register a histogram with default buckets.
     */
    Histogram& histogram(const std::string& name, const std::string& help);

    /**
     * Register a histogram with custom buckets.
     */
    Histogram& histogram(const std::string& name, const std::string& help,
                         const std::vector<double>& buckets);

    /**
     * Get a metric by name (returns nullptr if not found).
     */
    Metric* get(const std::string& name);

    /**
     * Format all metrics in Prometheus text format.
     */
    std::string format_all() const;

    /**
     * Visit all registered metrics.
     */
    void for_each(const std::function<void(const Metric&)>& visitor) const;

    /**
     * Clear all metrics (for testing).
     */
    void clear();

private:
    Registry() = default;

    mutable std::mutex mutex_;
    std::unordered_map<std::string, std::unique_ptr<Metric>> metrics_;
};

/**
 * Standard Soluna metrics.
 *
 * Pre-defined metrics for common operations.
 */
namespace standard {

// Audio metrics
Counter& audio_frames_processed_total();
Counter& audio_buffer_underruns_total();
Counter& audio_buffer_overruns_total();

// RTP metrics
Counter& rtp_packets_sent_total();
Counter& rtp_packets_received_total();
Counter& rtp_packets_lost_total();
Counter& rtp_bytes_sent_total();
Counter& rtp_bytes_received_total();

// PTP metrics
Gauge& ptp_offset_ns();
Gauge& ptp_synced();
Gauge& ptp_delay_ns();

// Session metrics
Gauge& active_streams();
Gauge& active_connections();

// System metrics
Gauge& uptime_seconds();
Gauge& cpu_usage_percent();
Gauge& memory_usage_bytes();

// Latency histograms
Histogram& audio_latency_seconds();
Histogram& network_latency_seconds();
Histogram& processing_latency_seconds();

} // namespace standard

} // namespace metrics
} // namespace soluna
