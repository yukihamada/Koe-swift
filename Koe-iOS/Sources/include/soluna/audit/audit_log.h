#pragma once

/**
 * Soluna — Audit Logger
 *
 * Structured logging for security-related events.
 *
 * SPDX-License-Identifier: MIT
 */

#include <soluna/core/error.h>
#include <soluna/config/config.h>
#include <cstdint>
#include <string>
#include <chrono>
#include <map>
#include <mutex>
#include <fstream>
#include <set>
#include <functional>
#include <atomic>

namespace soluna {
namespace audit {

/**
 * Audit event types.
 */
namespace events {
    // Authentication
    constexpr const char* AUTH_ATTEMPT = "auth_attempt";
    constexpr const char* AUTH_SUCCESS = "auth_success";
    constexpr const char* AUTH_FAILURE = "auth_failure";
    constexpr const char* LOGOUT = "logout";
    constexpr const char* TOKEN_EXPIRED = "token_expired";

    // Stream operations
    constexpr const char* STREAM_CREATED = "stream_created";
    constexpr const char* STREAM_DELETED = "stream_deleted";
    constexpr const char* STREAM_MODIFIED = "stream_modified";

    // Route operations
    constexpr const char* ROUTE_CREATED = "route_created";
    constexpr const char* ROUTE_DELETED = "route_deleted";
    constexpr const char* ROUTE_MODIFIED = "route_modified";

    // Configuration
    constexpr const char* CONFIG_CHANGED = "config_changed";
    constexpr const char* CONFIG_LOADED = "config_loaded";

    // Device management
    constexpr const char* DEVICE_CONNECTED = "device_connected";
    constexpr const char* DEVICE_DISCONNECTED = "device_disconnected";
    constexpr const char* DEVICE_ADDED = "device_added";
    constexpr const char* DEVICE_REMOVED = "device_removed";

    // System
    constexpr const char* STARTUP = "startup";
    constexpr const char* SHUTDOWN = "shutdown";
    constexpr const char* ERROR = "error";
}

/**
 * Audit log entry.
 */
struct AuditEntry {
    uint64_t timestamp_ns;          // Unix nanoseconds
    std::string event;              // Event type
    std::string actor;              // Who performed the action
    std::string target;             // What was affected
    bool success = true;            // Success/failure
    std::string details;            // Additional JSON details
    std::string remote_address;     // Client IP

    /**
     * Format as JSON line.
     */
    std::string to_json() const;

    /**
     * Parse from JSON line.
     */
    static Result<AuditEntry> from_json(const std::string& json);
};

/**
 * Audit log configuration.
 */
struct AuditConfig {
    bool enabled = false;
    std::string file_path = "/var/log/soluna/audit.jsonl";
    std::set<std::string> events;   // Events to log (empty = all)
    size_t max_file_size = 100 * 1024 * 1024;  // 100MB
    size_t max_files = 5;           // Rotation count
    bool async_write = true;        // Buffer writes
};

/**
 * Audit log callback for external handlers.
 */
using AuditCallback = std::function<void(const AuditEntry&)>;

/**
 * Audit logger for security events.
 *
 * Writes JSON Lines format to file with optional rotation.
 */
class AuditLog {
public:
    AuditLog();
    ~AuditLog();

    /**
     * Initialize with configuration.
     */
    Result<void> init(const config::AuditConfig& config);
    Result<void> init(const AuditConfig& config);

    /**
     * Check if audit logging is enabled.
     */
    bool is_enabled() const { return enabled_; }

    /**
     * Log an event.
     */
    void log(const std::string& event,
             const std::string& actor,
             const std::string& target = "",
             bool success = true,
             const std::string& details = "",
             const std::string& remote_address = "");

    /**
     * Log an event with structured details.
     */
    void log(const std::string& event,
             const std::string& actor,
             const std::string& target,
             bool success,
             const std::map<std::string, std::string>& details,
             const std::string& remote_address = "");

    /**
     * Log a raw entry.
     */
    void log(const AuditEntry& entry);

    /**
     * Flush buffered entries to disk.
     */
    void flush();

    /**
     * Get total entries logged.
     */
    uint64_t entry_count() const { return entry_count_.load(); }

    /**
     * Register external callback.
     */
    void set_callback(AuditCallback callback) { callback_ = std::move(callback); }

    /**
     * Check if event type should be logged.
     */
    bool should_log(const std::string& event) const;

    /**
     * Rotate log file if needed.
     */
    void rotate_if_needed();

private:
    void write_entry(const AuditEntry& entry);
    void rotate();

    bool enabled_ = false;
    AuditConfig config_;
    AuditCallback callback_;

    mutable std::mutex mutex_;
    std::ofstream file_;
    std::atomic<uint64_t> entry_count_{0};
    size_t current_file_size_ = 0;
};

/**
 * Global audit logger instance.
 */
AuditLog& audit_log();

/**
 * Convenience logging functions.
 */
void audit_auth_success(const std::string& device_id, const std::string& remote_address = "");
void audit_auth_failure(const std::string& device_id, const std::string& reason,
                        const std::string& remote_address = "");
void audit_logout(const std::string& device_id);

void audit_stream_created(const std::string& actor, const std::string& stream_id,
                          const std::map<std::string, std::string>& details = {});
void audit_stream_deleted(const std::string& actor, const std::string& stream_id);

void audit_route_created(const std::string& actor, const std::string& source,
                         const std::string& sink);
void audit_route_deleted(const std::string& actor, const std::string& source,
                         const std::string& sink);

void audit_config_changed(const std::string& actor, const std::string& key,
                          const std::string& old_value, const std::string& new_value);

void audit_device_connected(const std::string& device_id, const std::string& address);
void audit_device_disconnected(const std::string& device_id, const std::string& reason = "");

void audit_startup();
void audit_shutdown();
void audit_error(const std::string& error_code, const std::string& message);

} // namespace audit
} // namespace soluna
