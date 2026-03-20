#pragma once

/**
 * Soluna — Session Token Utilities
 *
 * Token generation and validation.
 *
 * SPDX-License-Identifier: MIT
 */

#include <cstdint>
#include <string>
#include <vector>
#include <chrono>

namespace soluna {
namespace security {

/**
 * Token type identifiers.
 */
enum class TokenType : uint8_t {
    Session = 1,    // Normal session token
    Refresh = 2,    // Refresh token for renewal
    ApiKey = 3,     // Long-lived API key
};

/**
 * Parsed token information.
 */
struct TokenInfo {
    TokenType type;
    std::string device_id;
    std::chrono::system_clock::time_point issued_at;
    std::chrono::system_clock::time_point expires_at;
    std::vector<std::string> roles;
    bool valid = false;
};

/**
 * Token utilities.
 */
class Token {
public:
    /**
     * Generate a cryptographically secure random token.
     */
    static std::string generate(size_t length = 32);

    /**
     * Generate a URL-safe base64 token.
     */
    static std::string generate_base64(size_t bytes = 24);

    /**
     * Compute SHA-256 hash.
     */
    static std::string sha256(const std::string& input);

    /**
     * Compute SHA-256 hash as hex string.
     */
    static std::string sha256_hex(const std::string& input);

    /**
     * Compute HMAC-SHA256.
     */
    static std::string hmac_sha256(const std::string& key, const std::string& message);

    /**
     * Base64 encode.
     */
    static std::string base64_encode(const std::string& input);

    /**
     * Base64 decode.
     */
    static std::string base64_decode(const std::string& input);

    /**
     * URL-safe base64 encode.
     */
    static std::string base64url_encode(const std::string& input);

    /**
     * URL-safe base64 decode.
     */
    static std::string base64url_decode(const std::string& input);

    /**
     * Constant-time string comparison (prevents timing attacks).
     */
    static bool secure_compare(const std::string& a, const std::string& b);

    /**
     * Generate a nonce for challenge-response.
     */
    static std::string generate_nonce();
};

} // namespace security
} // namespace soluna
