#pragma once

/**
 * Built-in DSP Plugins — Factory functions
 *
 * Creates instances of the built-in Compressor, EQ, and Reverb plugins.
 *
 * SPDX-License-Identifier: MIT
 */

#include <soluna/pipeline/dsp_plugin.h>
#include <memory>

namespace soluna {
namespace pipeline {

/** Create a dynamics compressor plugin. */
std::unique_ptr<DspPlugin> create_compressor();

/** Create a 3-band parametric EQ plugin. */
std::unique_ptr<DspPlugin> create_eq();

/** Create a Schroeder reverb plugin. */
std::unique_ptr<DspPlugin> create_reverb();

} // namespace pipeline
} // namespace soluna
