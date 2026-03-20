#pragma once

/**
 * Soluna — Configuration System
 *
 * YAML-based configuration for daemon and applications.
 *
 * SPDX-License-Identifier: MIT
 */

#include <soluna/core/error.h>
#include <soluna/soluna.h>
#include <cstdint>
#include <string>
#include <vector>
#include <optional>
#include <map>

namespace soluna {
namespace config {

/**
 * Device configuration section.
 */
struct DeviceConfig {
    std::string name = "soluna-device";
    std::string audio_device = "default";
    std::string interface;  // Network interface (empty = auto)
};

/**
 * Network configuration section.
 */
struct NetworkConfig {
    uint16_t control_port = 8400;
    uint16_t rtp_base_port = 5004;
    std::string multicast_audio = "239.69.0.1";
    std::string multicast_ptp = "224.0.1.129";
    int dscp = 46;  // EF (Expedited Forwarding)
};

/**
 * Audio configuration section.
 */
struct AudioConfig {
    uint32_t sample_rate = 48000;
    uint32_t channels = 2;
    uint32_t bit_depth = 24;
    uint32_t frames_per_packet = 48;  // 1ms at 48kHz
    uint32_t buffer_packets = 8;      // Ring buffer size
};

/**
 * Security configuration section.
 */
struct SecurityConfig {
    bool dtls_enabled = false;
    bool auth_enabled = false;
    std::string certificate_path;
    std::string private_key_path;

    struct DeviceCredential {
        std::string id;
        std::string psk_hash;  // SHA-256 hash of PSK
        std::vector<std::string> roles;
    };
    std::vector<DeviceCredential> devices;

    struct RolePermissions {
        std::string role;
        std::vector<std::string> permissions;
    };
    std::vector<RolePermissions> roles;
};

/**
 * Metrics configuration section.
 */
struct MetricsConfig {
    bool enabled = false;
    uint16_t port = 9100;
    std::string path = "/metrics";
    uint32_t scrape_interval_ms = 5000;
};

/**
 * Logging configuration section.
 */
struct LoggingConfig {
    std::string level = "info";  // debug, info, warn, error
    std::string file;            // Empty = stdout
    bool json_format = false;
    bool include_timestamp = true;
};

/**
 * Audit configuration section.
 */
struct AuditConfig {
    bool enabled = false;
    std::string file = "/var/log/soluna/audit.jsonl";
    std::vector<std::string> events;  // Events to log (empty = all)
};

/**
 * Plugin configuration.
 */
struct PluginConfig {
    std::string path;
    std::map<std::string, std::string> params;
};

/**
 * Auto-routing rule.
 */
struct AutoRouteRule {
    std::string name;
    struct Trigger {
        std::string type;     // device_connected, device_disconnected, etc.
        std::string pattern;  // Glob pattern for device matching
    } trigger;
    struct Action {
        std::string type;     // add_route, remove_route, set_gain
        std::string source;
        std::string sink;
        float gain_db = 0.0f;
    };
    std::vector<Action> actions;
};

/**
 * Routing configuration section.
 */
struct RoutingConfig {
    std::vector<AutoRouteRule> auto_rules;
};

/**
 * Complete Soluna configuration.
 */
struct Config {
    DeviceConfig device;
    NetworkConfig network;
    AudioConfig audio;
    SecurityConfig security;
    MetricsConfig metrics;
    LoggingConfig logging;
    AuditConfig audit;
    RoutingConfig routing;
    std::vector<PluginConfig> plugins;
    StreamMode mode = StreamMode::Sync;

    /**
     * Load configuration from a YAML file.
     */
    static Result<Config> load(const std::string& path);

    /**
     * Load configuration from YAML string.
     */
    static Result<Config> parse(const std::string& yaml_content);

    /**
     * Save configuration to a YAML file.
     */
    Result<void> save(const std::string& path) const;

    /**
     * Serialize to YAML string.
     */
    std::string to_yaml() const;

    /**
     * Validate configuration.
     */
    Result<void> validate() const;

    /**
     * Merge another config (non-empty values override).
     */
    void merge(const Config& other);

    /**
     * Create default configuration.
     */
    static Config defaults();
};

/**
 * Configuration loader with environment variable expansion.
 */
class ConfigLoader {
public:
    /**
     * Load configuration from file with env var expansion.
     * Supports ${VAR} and ${VAR:-default} syntax.
     */
    static Result<Config> load(const std::string& path);

    /**
     * Load with fallback paths (first existing file wins).
     */
    static Result<Config> load_with_fallbacks(
        const std::vector<std::string>& paths);

    /**
     * Expand environment variables in a string.
     */
    static std::string expand_env(const std::string& input);

    /**
     * Standard config search paths.
     */
    static std::vector<std::string> default_paths();
};

} // namespace config
} // namespace soluna
