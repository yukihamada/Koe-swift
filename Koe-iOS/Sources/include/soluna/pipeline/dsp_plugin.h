#pragma once

/**
 * DSP Plugin API — Runtime-loadable audio processing plugins
 *
 * Plugins are shared libraries (.so/.dylib/.dll) that implement
 * the C ABI entry points:
 *   extern "C" DspPlugin* soluna_plugin_create();
 *   extern "C" void soluna_plugin_destroy(DspPlugin*);
 *
 * Each plugin processes audio buffers in-place via process().
 *
 * SPDX-License-Identifier: MIT
 */

#include <cstdint>
#include <cstddef>
#include <memory>
#include <string>
#include <vector>

namespace soluna::pipeline {

/**
 * Base class for DSP plugins.
 * Plugin authors subclass this and implement process().
 */
class DspPlugin {
public:
    virtual ~DspPlugin() = default;

    /** Plugin display name. */
    virtual const char* name() const = 0;

    /**
     * Initialize with audio parameters.
     * Called once before any process() calls.
     */
    virtual bool init(uint32_t sample_rate, uint32_t channels) = 0;

    /**
     * Process audio in-place.
     * @param buffer  Interleaved float samples
     * @param frames  Number of audio frames
     * @param channels Number of channels
     */
    virtual void process(float* buffer, size_t frames, uint32_t channels) = 0;

    /** Reset internal state (e.g., when stream restarts). */
    virtual void reset() {}

    /** Get number of adjustable parameters. */
    virtual size_t param_count() const { return 0; }

    /** Get parameter name by index. */
    virtual const char* param_name(size_t /*index*/) const { return ""; }

    /** Get parameter value. */
    virtual float param_value(size_t /*index*/) const { return 0.0f; }

    /** Set parameter value. */
    virtual void set_param(size_t /*index*/, float /*value*/) {}
};

// C ABI types for plugin entry points
extern "C" {
    typedef DspPlugin* (*PluginCreateFunc)();
    typedef void (*PluginDestroyFunc)(DspPlugin*);
}

/**
 * PluginHost manages loading and running DSP plugins.
 */
class PluginHost {
public:
    PluginHost();
    ~PluginHost();

    PluginHost(const PluginHost&) = delete;
    PluginHost& operator=(const PluginHost&) = delete;

    /**
     * Load a plugin from a shared library path.
     * Returns true on success.
     */
    bool load(const std::string& path);

    /**
     * Unload all plugins.
     */
    void unload_all();

    /**
     * Initialize all plugins with audio parameters.
     */
    bool init_all(uint32_t sample_rate, uint32_t channels);

    /**
     * Process audio through all loaded plugins (in load order).
     */
    void process_all(float* buffer, size_t frames, uint32_t channels);

    /**
     * Get number of loaded plugins.
     */
    size_t plugin_count() const;

    /**
     * Get plugin by index.
     */
    DspPlugin* plugin(size_t index) const;

private:
    struct LoadedPlugin {
        void* handle = nullptr;          // dlopen handle
        DspPlugin* instance = nullptr;
        PluginDestroyFunc destroy_fn = nullptr;
        std::string path;
    };

    std::vector<LoadedPlugin> plugins_;
};

} // namespace soluna::pipeline
