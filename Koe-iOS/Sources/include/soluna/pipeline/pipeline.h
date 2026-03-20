#pragma once

#include <soluna/soluna.h>
#include <soluna/pipeline/ring_buffer.h>
#include <cstdint>
#include <memory>

namespace soluna::pipeline {

/**
 * Format conversion utilities for the audio pipeline.
 */

// Convert interleaved float to 24-bit packed (in 32-bit LE container)
void float_to_s24(const float* src, int32_t* dst, size_t sample_count);

// Convert 24-bit packed to interleaved float
void s24_to_float(const int32_t* src, float* dst, size_t sample_count);

/**
 * Audio pipeline configuration for Phase 1.
 * Simple: capture → ring buffer → RTP TX, and RTP RX → ring buffer → playback.
 */
struct PipelineConfig {
    uint32_t sample_rate = kDefaultSampleRate;
    uint32_t channels = 1;
    uint32_t frames_per_buffer = 48;
    PacketTier tier = PacketTier::Standard;
    SampleFormat network_format = SampleFormat::S24_LE;

    // Ring buffer size in packets (both TX and RX sides)
    uint32_t ring_buffer_packets = 8;
};

} // namespace soluna::pipeline
