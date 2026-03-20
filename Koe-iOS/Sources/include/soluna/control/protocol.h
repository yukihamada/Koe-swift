#pragma once

/**
 * Control Protocol — JSON-based command/response protocol
 *
 * Used over WebSocket (TCP 8400) for CLI and Web UI control.
 * Request/response pattern with optional event subscriptions.
 *
 * SPDX-License-Identifier: MIT
 */

#include <cstdint>
#include <functional>
#include <string>
#include <map>
#include <vector>

namespace soluna::control {

// Command types
enum class CommandType {
    // Device
    DeviceList,
    DeviceInfo,

    // Stream
    StreamList,
    StreamCreate,
    StreamDestroy,

    // Route
    RouteList,
    RouteAdd,
    RouteRemove,
    RouteSetGain,
    RouteSetMute,

    // Meter
    MeterGet,
    MeterSubscribe,
    MeterUnsubscribe,
    MeterGetAll,

    // System
    Status,
    Version,
    SystemStats,

    // Preset
    PresetList,
    PresetSave,
    PresetLoad,
    PresetDelete,

    // Security/DTLS
    SecurityStatus,
    SecuritySetDtls,

    // Mode
    ModeGet,
    ModeSet,

    Unknown,
};

struct ControlRequest {
    uint32_t id = 0;             // request ID for matching responses
    CommandType command = CommandType::Unknown;
    std::map<std::string, std::string> params;

    std::string get_param(const std::string& key, const std::string& default_val = "") const {
        auto it = params.find(key);
        return (it != params.end()) ? it->second : default_val;
    }
};

struct ControlResponse {
    uint32_t id = 0;             // matching request ID
    bool success = true;
    std::string error;
    std::string data;            // JSON payload
};

/**
 * Serialize a request to JSON string.
 */
std::string serialize_request(const ControlRequest& req);

/**
 * Parse a JSON string into a request.
 */
bool parse_request(const std::string& json, ControlRequest& req);

/**
 * Serialize a response to JSON string.
 */
std::string serialize_response(const ControlResponse& resp);

/**
 * Parse a JSON string into a response.
 */
bool parse_response(const std::string& json, ControlResponse& resp);

/**
 * Command name <-> CommandType conversion.
 */
const char* command_to_string(CommandType cmd);
CommandType string_to_command(const std::string& s);

} // namespace soluna::control
