#pragma once

/**
 * mDNS/DNS-SD Device Discovery
 *
 * Advertises and discovers Soluna devices on the local network
 * using _soluna._udp service type.
 *
 * SPDX-License-Identifier: MIT
 */

#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#include <map>

namespace soluna::control {

struct DeviceInfo {
    std::string id;              // unique device ID (from PTP clock ID)
    std::string name;            // human-readable name
    std::string host;            // hostname or IP
    uint16_t control_port = 8400;
    uint32_t input_channels = 0;
    uint32_t output_channels = 0;
    uint32_t sample_rate = 48000;
    std::string firmware_version;
    int64_t last_seen_ns = 0;    // monotonic timestamp
    bool is_local = false;
};

enum class DiscoveryEvent {
    DeviceAdded,
    DeviceRemoved,
    DeviceUpdated,
};

using DiscoveryCallback = std::function<void(DiscoveryEvent event, const DeviceInfo& device)>;

class Discovery {
public:
    Discovery();
    ~Discovery();

    Discovery(const Discovery&) = delete;
    Discovery& operator=(const Discovery&) = delete;

    /** Set local device info for advertisement. */
    void set_local_device(const DeviceInfo& info);

    /** Start advertising and browsing. */
    bool start();

    /** Stop discovery. */
    void stop();

    /** Set callback for device events. */
    void set_callback(DiscoveryCallback cb);

    /** Get all currently known devices. */
    std::vector<DeviceInfo> devices() const;

    /** Get a specific device by ID. Returns nullptr if not found. */
    std::unique_ptr<DeviceInfo> find_device(const std::string& id) const;

    /** Manually add/update a device (for testing or static config). */
    void add_device(const DeviceInfo& info);

    /** Remove a device. */
    void remove_device(const std::string& id);

    /** Check for stale devices (not seen within timeout). */
    void prune_stale(int64_t timeout_ns);

    bool is_running() const { return running_; }

    static constexpr const char* kServiceType = "_soluna._udp";

private:
    mutable std::mutex mutex_;
    std::map<std::string, DeviceInfo> devices_;
    DeviceInfo local_device_;
    DiscoveryCallback callback_;
    bool running_ = false;

    void notify(DiscoveryEvent event, const DeviceInfo& device);
};

} // namespace soluna::control
