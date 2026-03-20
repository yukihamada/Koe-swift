#pragma once

/**
 * Soluna — DSP Processing Chain
 *
 * Chain of DSP processors with bypass support.
 *
 * SPDX-License-Identifier: MIT
 */

#include <soluna/pipeline/dsp_plugin.h>
#include <memory>
#include <string>
#include <vector>
#include <mutex>
#include <cmath>

namespace soluna {
namespace pipeline {

/**
 * A single node in the DSP chain.
 */
struct DspNode {
    std::string name;
    std::unique_ptr<DspPlugin> plugin;
    bool bypassed = false;
    float input_gain = 1.0f;   // Pre-gain (linear)
    float output_gain = 1.0f;  // Post-gain (linear)
    size_t latency = 0;        // Latency in samples (set by caller)
};

/**
 * DSP processing chain.
 *
 * Manages a sequence of DSP processors that audio flows through.
 */
class DspChain {
public:
    DspChain();
    ~DspChain();

    /**
     * Initialize the chain with audio format.
     */
    void init(uint32_t sample_rate, uint32_t channels, uint32_t block_size);

    /**
     * Add a plugin to the end of the chain.
     *
     * @param name Unique name for this node
     * @param plugin The DSP plugin (ownership transferred)
     * @return Index of the added node, or -1 on failure
     */
    int add_plugin(const std::string& name, std::unique_ptr<DspPlugin> plugin);

    /**
     * Insert a plugin at a specific position.
     *
     * @param index Position to insert at
     * @param name Unique name for this node
     * @param plugin The DSP plugin
     * @return Index of the inserted node, or -1 on failure
     */
    int insert_plugin(size_t index, const std::string& name,
                      std::unique_ptr<DspPlugin> plugin);

    /**
     * Remove a plugin by name.
     *
     * @return true if removed, false if not found
     */
    bool remove_plugin(const std::string& name);

    /**
     * Remove a plugin by index.
     *
     * @return true if removed, false if invalid index
     */
    bool remove_plugin(size_t index);

    /**
     * Move a plugin to a new position.
     */
    bool move_plugin(size_t from_index, size_t to_index);

    /**
     * Get the number of plugins in the chain.
     */
    size_t size() const;

    /**
     * Get plugin by index.
     */
    DspPlugin* get_plugin(size_t index);

    /**
     * Get plugin by name.
     */
    DspPlugin* get_plugin(const std::string& name);

    /**
     * Find plugin index by name.
     *
     * @return Index or -1 if not found
     */
    int find_plugin(const std::string& name) const;

    /**
     * Get node info by index.
     */
    const DspNode* get_node(size_t index) const;

    /**
     * Set bypass state for a plugin.
     */
    bool set_bypass(const std::string& name, bool bypassed);
    bool set_bypass(size_t index, bool bypassed);

    /**
     * Get bypass state.
     */
    bool is_bypassed(const std::string& name) const;
    bool is_bypassed(size_t index) const;

    /**
     * Set pre-gain for a plugin (linear scale).
     */
    bool set_input_gain(const std::string& name, float gain);
    bool set_input_gain(size_t index, float gain);

    /**
     * Set post-gain for a plugin (linear scale).
     */
    bool set_output_gain(const std::string& name, float gain);
    bool set_output_gain(size_t index, float gain);

    /**
     * Bypass entire chain (all plugins).
     */
    void set_chain_bypass(bool bypassed);

    /**
     * Check if entire chain is bypassed.
     */
    bool is_chain_bypassed() const;

    /**
     * Process audio through the chain.
     *
     * @param buffer Interleaved audio buffer (modified in place)
     * @param frame_count Number of frames
     */
    void process(float* buffer, size_t frame_count);

    /**
     * Reset all plugins in the chain.
     */
    void reset();

    /**
     * Get latency of the chain in samples.
     */
    size_t get_latency() const;

    /**
     * Get list of plugin names in order.
     */
    std::vector<std::string> get_plugin_names() const;

    /**
     * Clear all plugins from the chain.
     */
    void clear();

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

/**
 * Utility: Convert dB to linear gain.
 */
inline float db_to_linear(float db) {
    return std::pow(10.0f, db / 20.0f);
}

/**
 * Utility: Convert linear gain to dB.
 */
inline float linear_to_db(float linear) {
    return 20.0f * std::log10(std::max(linear, 1e-10f));
}

} // namespace pipeline
} // namespace soluna
