#pragma once

/**
 * Soluna — Automatic Routing Engine
 *
 * Rule-based automatic routing for device connections.
 *
 * SPDX-License-Identifier: MIT
 */

#include <soluna/core/error.h>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <regex>
#include <string>
#include <vector>

namespace soluna {
namespace control {

/**
 * Trigger types for routing rules.
 */
enum class TriggerType {
    DeviceConnected,    // Device joins the network
    DeviceDisconnected, // Device leaves the network
    StreamCreated,      // New stream is created
    StreamEnded,        // Stream terminates
    Manual,             // Manually triggered
};

/**
 * Action types for routing rules.
 */
enum class ActionType {
    AddRoute,           // Create a new route
    RemoveRoute,        // Remove an existing route
    SetGain,            // Set gain on a route
    Mute,               // Mute a route
    Unmute,             // Unmute a route
    RunScript,          // Execute an external script
};

/**
 * A routing action to perform.
 */
struct RouteAction {
    ActionType type = ActionType::AddRoute;
    std::string source;         // Source pattern (may contain $device)
    std::string sink;           // Sink pattern (may contain $device)
    float gain_db = 0.0f;       // Gain in dB
    std::string script_path;    // For RunScript action
};

/**
 * A routing rule that triggers on events.
 */
struct RouteRule {
    std::string name;
    bool enabled = true;

    // Trigger
    TriggerType trigger = TriggerType::DeviceConnected;
    std::string pattern;        // Device name pattern (regex)

    // Actions to perform when triggered
    std::vector<RouteAction> actions;

    // Conditions
    int priority = 0;           // Higher priority rules execute first
    bool stop_on_match = false; // Don't process further rules if this matches
};

/**
 * Event context for rule evaluation.
 */
struct RouteEvent {
    TriggerType type;
    std::string device_id;
    std::string device_name;
    std::string stream_id;

    // Extra context for variable substitution
    std::map<std::string, std::string> variables;
};

/**
 * Callback for executing routing actions.
 */
using ActionCallback = std::function<Result<void>(const RouteAction& action,
                                                   const RouteEvent& event)>;

/**
 * Automatic routing engine.
 *
 * Monitors events and applies routing rules automatically.
 */
class AutoRouter {
public:
    AutoRouter();
    ~AutoRouter();

    /**
     * Add a routing rule.
     */
    void add_rule(const RouteRule& rule);

    /**
     * Remove a rule by name.
     */
    bool remove_rule(const std::string& name);

    /**
     * Clear all rules.
     */
    void clear_rules();

    /**
     * Get all rules.
     */
    std::vector<RouteRule> get_rules() const;

    /**
     * Enable or disable a rule.
     */
    bool set_rule_enabled(const std::string& name, bool enabled);

    /**
     * Process an event against all rules.
     *
     * @param event The event to process
     * @return Number of rules that matched and executed
     */
    int process_event(const RouteEvent& event);

    /**
     * Set callback for executing actions.
     */
    void set_action_callback(ActionCallback callback);

    /**
     * Load rules from YAML configuration.
     */
    Result<void> load_rules(const std::string& yaml_config);

    /**
     * Substitute variables in a pattern.
     * Variables like $device are replaced with actual values.
     */
    static std::string substitute_variables(const std::string& pattern,
                                            const RouteEvent& event);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

/**
 * Convert trigger type to string.
 */
constexpr const char* trigger_name(TriggerType type) {
    switch (type) {
        case TriggerType::DeviceConnected:    return "device_connected";
        case TriggerType::DeviceDisconnected: return "device_disconnected";
        case TriggerType::StreamCreated:      return "stream_created";
        case TriggerType::StreamEnded:        return "stream_ended";
        case TriggerType::Manual:             return "manual";
    }
    return "unknown";
}

/**
 * Parse trigger type from string.
 */
inline TriggerType parse_trigger_type(const std::string& str) {
    if (str == "device_connected") return TriggerType::DeviceConnected;
    if (str == "device_disconnected") return TriggerType::DeviceDisconnected;
    if (str == "stream_created") return TriggerType::StreamCreated;
    if (str == "stream_ended") return TriggerType::StreamEnded;
    if (str == "manual") return TriggerType::Manual;
    return TriggerType::Manual;
}

/**
 * Convert action type to string.
 */
constexpr const char* action_name(ActionType type) {
    switch (type) {
        case ActionType::AddRoute:    return "add_route";
        case ActionType::RemoveRoute: return "remove_route";
        case ActionType::SetGain:     return "set_gain";
        case ActionType::Mute:        return "mute";
        case ActionType::Unmute:      return "unmute";
        case ActionType::RunScript:   return "run_script";
    }
    return "unknown";
}

/**
 * Parse action type from string.
 */
inline ActionType parse_action_type(const std::string& str) {
    if (str == "add_route") return ActionType::AddRoute;
    if (str == "remove_route") return ActionType::RemoveRoute;
    if (str == "set_gain") return ActionType::SetGain;
    if (str == "mute") return ActionType::Mute;
    if (str == "unmute") return ActionType::Unmute;
    if (str == "run_script") return ActionType::RunScript;
    return ActionType::AddRoute;
}

} // namespace control
} // namespace soluna
