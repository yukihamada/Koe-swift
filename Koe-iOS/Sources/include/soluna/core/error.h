#pragma once

/**
 * Soluna — Structured Error System
 *
 * Provides rich error types for better error handling and debugging.
 *
 * SPDX-License-Identifier: MIT
 */

#include <cstdint>
#include <string>
#include <variant>
#include <optional>

namespace soluna {

/**
 * Error codes organized by category.
 * Categories:
 *   0xx: General
 *   1xx: Audio/Device
 *   2xx: Network
 *   3xx: Security
 *   4xx: Configuration
 *   5xx: Protocol
 *   6xx: Codec
 */
enum class ErrorCode : uint16_t {
    // General (0xx)
    OK = 0,
    Unknown = 1,
    InvalidArgument = 2,
    NotImplemented = 3,
    OutOfMemory = 4,
    Timeout = 5,
    Cancelled = 6,
    AlreadyExists = 7,
    NotFound = 8,
    PermissionDenied = 9,

    // Audio/Device (1xx)
    AudioDeviceNotFound = 100,
    AudioDeviceOpenFailed = 101,
    AudioDeviceBusy = 102,
    AudioFormatNotSupported = 103,
    AudioBufferUnderrun = 104,
    AudioBufferOverrun = 105,
    AudioDriverError = 106,

    // Network (2xx)
    SocketError = 200,
    SocketBindFailed = 201,
    SocketConnectFailed = 202,
    SocketSendFailed = 203,
    SocketRecvFailed = 204,
    AddressInvalid = 205,
    MulticastJoinFailed = 206,
    NetworkUnreachable = 207,
    ConnectionRefused = 208,
    ConnectionReset = 209,

    // Security (3xx)
    AuthenticationFailed = 300,
    AuthenticationRequired = 301,
    TokenExpired = 302,
    TokenInvalid = 303,
    AccessDenied = 304,
    CertificateError = 305,
    EncryptionError = 306,

    // Configuration (4xx)
    ConfigParseError = 400,
    ConfigValidationError = 401,
    ConfigFileNotFound = 402,
    ConfigWriteError = 403,
    ConfigKeyNotFound = 404,
    ConfigTypeMismatch = 405,

    // Protocol (5xx)
    ProtocolError = 500,
    ProtocolVersionMismatch = 501,
    PacketMalformed = 502,
    PacketTooLarge = 503,
    SequenceError = 504,
    SyncError = 505,

    // Codec (6xx)
    CodecNotFound = 600,
    CodecInitFailed = 601,
    CodecEncodeFailed = 602,
    CodecDecodeFailed = 603,
    CodecUnsupportedFormat = 604,

    // License (7xx)
    LicenseNotFound = 700,
    LicenseInvalid = 701,
    LicenseExpired = 702,
    LicenseTierExceeded = 703,
};

/**
 * Returns the category name for an error code.
 */
constexpr const char* error_category(ErrorCode code) {
    uint16_t val = static_cast<uint16_t>(code);
    if (val == 0) return "OK";
    if (val < 100) return "General";
    if (val < 200) return "Audio";
    if (val < 300) return "Network";
    if (val < 400) return "Security";
    if (val < 500) return "Config";
    if (val < 600) return "Protocol";
    if (val < 700) return "Codec";
    if (val < 800) return "License";
    return "Unknown";
}

/**
 * Returns a human-readable name for an error code.
 */
const char* error_name(ErrorCode code);

/**
 * Rich error type with code, message, and optional context.
 */
class Error {
public:
    Error() : code_(ErrorCode::OK) {}

    explicit Error(ErrorCode code)
        : code_(code) {}

    Error(ErrorCode code, std::string message)
        : code_(code), message_(std::move(message)) {}

    Error(ErrorCode code, std::string message, std::string context)
        : code_(code), message_(std::move(message)), context_(std::move(context)) {}

    ErrorCode code() const { return code_; }
    const std::string& message() const { return message_; }
    const std::string& context() const { return context_; }

    bool ok() const { return code_ == ErrorCode::OK; }
    explicit operator bool() const { return !ok(); }

    /**
     * Returns a formatted error string.
     * Format: "[Category::Name] message (context)"
     */
    std::string to_string() const;

    /**
     * Add additional context to the error.
     */
    Error& with_context(std::string ctx) {
        if (!context_.empty()) {
            context_ += " -> ";
        }
        context_ += std::move(ctx);
        return *this;
    }

private:
    ErrorCode code_;
    std::string message_;
    std::string context_;
};

/**
 * Result type that holds either a value or an error.
 *
 * Usage:
 *   Result<int> parse_int(const std::string& s);
 *
 *   auto result = parse_int("42");
 *   if (result.ok()) {
 *       int value = result.value();
 *   } else {
 *       log_error(result.error().to_string());
 *   }
 */
template<typename T>
class Result {
public:
    Result(T value) : data_(std::move(value)) {}
    Result(Error error) : data_(std::move(error)) {}
    Result(ErrorCode code) : data_(Error(code)) {}
    Result(ErrorCode code, std::string message)
        : data_(Error(code, std::move(message))) {}

    bool ok() const { return std::holds_alternative<T>(data_); }
    explicit operator bool() const { return ok(); }

    const T& value() const& { return std::get<T>(data_); }
    T& value() & { return std::get<T>(data_); }
    T&& value() && { return std::get<T>(std::move(data_)); }

    const Error& error() const& { return std::get<Error>(data_); }
    Error& error() & { return std::get<Error>(data_); }

    /**
     * Returns the value or a default if error.
     */
    T value_or(T default_value) const {
        if (ok()) return value();
        return default_value;
    }

    /**
     * Maps the value through a function if ok.
     */
    template<typename F>
    auto map(F&& f) const -> Result<decltype(f(std::declval<T>()))> {
        using U = decltype(f(std::declval<T>()));
        if (ok()) {
            return Result<U>(f(value()));
        }
        return Result<U>(error());
    }

    /**
     * Chains operations that return Result.
     */
    template<typename F>
    auto and_then(F&& f) const -> decltype(f(std::declval<T>())) {
        if (ok()) {
            return f(value());
        }
        return decltype(f(std::declval<T>()))(error());
    }

private:
    std::variant<T, Error> data_;
};

/**
 * Specialization for void results (success/failure only).
 */
template<>
class Result<void> {
public:
    Result() : error_(std::nullopt) {}
    Result(Error error) : error_(std::move(error)) {}
    Result(ErrorCode code) : error_(Error(code)) {}
    Result(ErrorCode code, std::string message)
        : error_(Error(code, std::move(message))) {}

    static Result success() { return Result(); }

    bool ok() const { return !error_.has_value(); }
    explicit operator bool() const { return ok(); }

    const Error& error() const { return *error_; }

private:
    std::optional<Error> error_;
};

// Convenience aliases
using VoidResult = Result<void>;

// Helper macros for early return on error
#define SOLUNA_TRY(expr) \
    do { \
        auto _result = (expr); \
        if (!_result.ok()) return _result.error(); \
    } while (0)

#define SOLUNA_TRY_ASSIGN(var, expr) \
    auto _result_##var = (expr); \
    if (!_result_##var.ok()) return _result_##var.error(); \
    auto var = std::move(_result_##var).value()

} // namespace soluna
