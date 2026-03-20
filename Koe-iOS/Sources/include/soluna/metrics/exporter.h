#pragma once

/**
 * Soluna — Metrics Exporter
 *
 * HTTP endpoint for Prometheus scraping.
 *
 * SPDX-License-Identifier: MIT
 */

#include <soluna/metrics/registry.h>
#include <soluna/core/error.h>
#include <cstdint>
#include <string>
#include <atomic>
#include <thread>
#include <functional>

namespace soluna {
namespace metrics {

/**
 * Configuration for metrics exporter.
 */
struct ExporterConfig {
    uint16_t port = 9100;
    std::string path = "/metrics";
    std::string bind_address = "0.0.0.0";
    bool enabled = true;
};

/**
 * HTTP server for exporting metrics in Prometheus format.
 *
 * Provides a simple HTTP endpoint that returns metrics in text format.
 */
class Exporter {
public:
    explicit Exporter(const ExporterConfig& config = {});
    ~Exporter();

    /**
     * Start the exporter HTTP server.
     */
    Result<void> start();

    /**
     * Stop the exporter.
     */
    void stop();

    /**
     * Check if exporter is running.
     */
    bool is_running() const { return running_.load(); }

    /**
     * Get current configuration.
     */
    const ExporterConfig& config() const { return config_; }

    /**
     * Set the registry to export (default: global instance).
     */
    void set_registry(Registry* registry) { registry_ = registry; }

    /**
     * Get the last scrape timestamp (Unix seconds).
     */
    uint64_t last_scrape_time() const { return last_scrape_.load(); }

    /**
     * Get total number of scrapes.
     */
    uint64_t scrape_count() const { return scrape_count_.load(); }

private:
    void server_thread();
    std::string handle_request(const std::string& request);
    std::string metrics_response();
    std::string not_found_response();
    std::string method_not_allowed_response();

    ExporterConfig config_;
    Registry* registry_ = nullptr;

    std::atomic<bool> running_{false};
    std::thread server_thread_;
    int server_socket_ = -1;

    std::atomic<uint64_t> last_scrape_{0};
    std::atomic<uint64_t> scrape_count_{0};
};

} // namespace metrics
} // namespace soluna
