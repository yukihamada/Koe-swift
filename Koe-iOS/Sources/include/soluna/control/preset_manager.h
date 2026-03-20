#pragma once

/**
 * Preset Manager — Routing configuration persistence
 *
 * Saves and loads routing presets as JSON files.
 * Default location: ~/.soluna/presets/
 *
 * SPDX-License-Identifier: MIT
 */

#include <soluna/control/routing.h>
#include <string>
#include <vector>
#include <memory>

namespace soluna::control {

struct PresetInfo {
    std::string name;
    std::string filename;
    size_t route_count = 0;
    int64_t modified_time = 0;  // Unix timestamp
};

class PresetManager {
public:
    /**
     * Create preset manager with specified directory.
     * If directory is empty, uses default (~/.soluna/presets/).
     */
    explicit PresetManager(const std::string& directory = "");

    /**
     * List all available presets.
     */
    std::vector<PresetInfo> list() const;

    /**
     * Save current routing configuration as a preset.
     *
     * @param name Preset name (will be sanitized for filesystem)
     * @param routing Current routing matrix
     * @return true if saved successfully
     */
    bool save(const std::string& name, const RoutingMatrix& routing);

    /**
     * Load a preset and apply it to the routing matrix.
     *
     * @param name Preset name
     * @param routing Routing matrix to update
     * @return true if loaded successfully
     */
    bool load(const std::string& name, RoutingMatrix& routing);

    /**
     * Delete a preset.
     *
     * @param name Preset name
     * @return true if deleted successfully
     */
    bool remove(const std::string& name);

    /**
     * Check if a preset exists.
     */
    bool exists(const std::string& name) const;

    /**
     * Get the preset directory path.
     */
    const std::string& directory() const { return directory_; }

private:
    std::string directory_;

    std::string sanitize_name(const std::string& name) const;
    std::string preset_path(const std::string& name) const;
    bool ensure_directory() const;
};

} // namespace soluna::control
