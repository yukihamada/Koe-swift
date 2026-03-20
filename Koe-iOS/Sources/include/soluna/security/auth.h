#pragma once

/**
 * Soluna — Authentication Manager
 *
 * PSK-based device authentication.
 *
 * SPDX-License-Identifier: MIT
 */

#include <soluna/core/error.h>
#include <soluna/config/config.h>
#include <cstdint>
#include <string>
#include <vector>
#include <memory>
#include <chrono>
#include <map>
#include <mutex>
#include <functional>

namespace soluna {
namespace security {

/**
 * Authentication result.
 */
struct AuthResult {
    bool success = false;
    std::string device_id;
    std::string session_token;
    std::vector<std::string> roles;
    std::string error_message;
};

/**
 * Device credential.
 */
struct DeviceCredential {
    std::string id;
    std::string psk_hash;           // SHA-256 hash of PSK
    std::vector<std::string> roles;
    bool enabled = true;
};

/**
 * Active session information.
 */
struct Session {
    std::string token;
    std::string device_id;
    std::vector<std::string> roles;
    std::chrono::steady_clock::time_point created_at;
    std::chrono::steady_clock::time_point last_activity;
    std::chrono::seconds ttl{3600};  // 1 hour default
    std::string remote_address;
};

/**
 * Authentication event types.
 */
enum class AuthEvent {
    LoginAttempt,
    LoginSuccess,
    LoginFailed,
    Logout,
    TokenExpired,
    SessionCreated,
    SessionDestroyed,
};

/**
 * Authentication event callback.
 */
using AuthEventCallback = std::function<void(AuthEvent event, const std::string& device_id,
                                              const std::string& details)>;

/**
 * Authentication manager for device authentication.
 *
 * Supports:
 * - PSK (Pre-Shared Key) authentication
 * - Challenge-response protocol
 * - Session management
 * - Event callbacks for audit logging
 */
class AuthManager {
public:
    AuthManager();
    ~AuthManager();

    /**
     * Initialize with configuration.
     */
    Result<void> init(const config::SecurityConfig& config);

    /**
     * Check if authentication is enabled.
     */
    bool is_enabled() const { return enabled_; }

    /**
     * Add a device credential.
     */
    Result<void> add_device(const DeviceCredential& credential);

    /**
     * Remove a device credential.
     */
    Result<void> remove_device(const std::string& device_id);

    /**
     * Get device credential (for admin operations).
     */
    const DeviceCredential* get_device(const std::string& device_id) const;

    /**
     * List all registered devices.
     */
    std::vector<std::string> list_devices() const;

    /**
     * Generate a challenge for authentication.
     */
    std::string generate_challenge(const std::string& device_id);

    /**
     * Authenticate with challenge-response.
     *
     * @param device_id Device identifier
     * @param challenge The challenge string
     * @param response SHA-256(challenge + psk)
     * @param remote_address Client IP address
     */
    AuthResult authenticate(const std::string& device_id,
                            const std::string& challenge,
                            const std::string& response,
                            const std::string& remote_address = "");

    /**
     * Authenticate with raw PSK (less secure, for simple setups).
     */
    AuthResult authenticate_psk(const std::string& device_id,
                                const std::string& psk,
                                const std::string& remote_address = "");

    /**
     * Validate a session token.
     */
    Result<Session> validate_token(const std::string& token);

    /**
     * Refresh session TTL.
     */
    Result<void> touch_session(const std::string& token);

    /**
     * Invalidate a session.
     */
    Result<void> logout(const std::string& token);

    /**
     * Invalidate all sessions for a device.
     */
    Result<void> logout_device(const std::string& device_id);

    /**
     * Get active session count.
     */
    size_t active_session_count() const;

    /**
     * Clean up expired sessions.
     */
    void cleanup_expired_sessions();

    /**
     * Set session TTL for new sessions.
     */
    void set_session_ttl(std::chrono::seconds ttl) { default_ttl_ = ttl; }

    /**
     * Register authentication event callback.
     */
    void set_event_callback(AuthEventCallback callback) { event_callback_ = std::move(callback); }

    /**
     * Hash a PSK for storage.
     */
    static std::string hash_psk(const std::string& psk);

    /**
     * Verify a PSK against its hash.
     */
    static bool verify_psk(const std::string& psk, const std::string& hash);

    /**
     * Generate a random token.
     */
    static std::string generate_token(size_t length = 32);

private:
    void emit_event(AuthEvent event, const std::string& device_id, const std::string& details = "");

    bool enabled_ = false;
    std::chrono::seconds default_ttl_{3600};
    AuthEventCallback event_callback_;

    mutable std::mutex mutex_;
    std::map<std::string, DeviceCredential> devices_;
    std::map<std::string, std::string> pending_challenges_;  // device_id -> challenge
    std::map<std::string, Session> sessions_;                // token -> session
};

/**
 * Request authentication context.
 *
 * Attached to each request for authorization checks.
 */
struct AuthContext {
    bool authenticated = false;
    std::string device_id;
    std::vector<std::string> roles;
    std::string session_token;

    bool has_role(const std::string& role) const;
    bool has_any_role(const std::vector<std::string>& roles) const;
};

} // namespace security
} // namespace soluna
