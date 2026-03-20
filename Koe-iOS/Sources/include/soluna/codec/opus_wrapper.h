#pragma once

/**
 * Opus Codec Wrapper — Optional compression for WiFi paths
 *
 * Wraps the Opus codec for encoding/decoding audio.
 * Used when WiFi bandwidth or reliability requires compression.
 *
 * SPDX-License-Identifier: MIT
 */

#include <cstdint>
#include <cstddef>
#include <vector>
#include <memory>

namespace soluna::codec {

enum class OpusApplication : uint8_t {
    Audio = 0,      // OPUS_APPLICATION_AUDIO (music, high quality)
    VoIP = 1,       // OPUS_APPLICATION_VOIP (speech, low latency)
    LowDelay = 2,   // OPUS_APPLICATION_RESTRICTED_LOWDELAY
};

struct OpusEncoderConfig {
    uint32_t sample_rate = 48000;
    uint32_t channels = 1;
    uint32_t bitrate = 96000;          // bits per second
    OpusApplication application = OpusApplication::Audio;
    uint32_t frame_size_samples = 96;  // 2ms at 48kHz (WiFi tier)
    bool use_fec = false;              // Opus in-band FEC
    int packet_loss_pct = 0;           // expected packet loss %
    int complexity = 10;               // 0-10, higher = better quality / more CPU
};

struct OpusDecoderConfig {
    uint32_t sample_rate = 48000;
    uint32_t channels = 1;
};

struct OpusEncodeResult {
    std::vector<uint8_t> data;
    size_t frames_encoded = 0;
    bool success = false;
};

struct OpusDecodeResult {
    std::vector<float> samples;        // interleaved float samples
    size_t frames_decoded = 0;
    bool success = false;
    bool plc_used = false;             // packet loss concealment was used
};

/**
 * Opus Encoder
 *
 * When SOLUNA_HAS_OPUS is defined, uses libopus.
 * Otherwise, provides a passthrough stub for build compatibility.
 */
class OpusEncoder {
public:
    explicit OpusEncoder(const OpusEncoderConfig& config = {});
    ~OpusEncoder();

    OpusEncoder(const OpusEncoder&) = delete;
    OpusEncoder& operator=(const OpusEncoder&) = delete;

    /**
     * Encode float audio samples to Opus.
     * input: interleaved float samples, frame_count frames
     * Returns encoded data.
     */
    OpusEncodeResult encode(const float* input, size_t frame_count);

    /**
     * Set bitrate dynamically (for adaptive bitrate).
     */
    void set_bitrate(uint32_t bitrate);

    /**
     * Set expected packet loss percentage (for Opus FEC tuning).
     */
    void set_packet_loss_pct(int pct);

    bool is_initialized() const { return initialized_; }
    const OpusEncoderConfig& config() const { return config_; }

private:
    OpusEncoderConfig config_;
    bool initialized_ = false;
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

/**
 * Opus Decoder
 */
class OpusDecoder {
public:
    explicit OpusDecoder(const OpusDecoderConfig& config = {});
    ~OpusDecoder();

    OpusDecoder(const OpusDecoder&) = delete;
    OpusDecoder& operator=(const OpusDecoder&) = delete;

    /**
     * Decode Opus data to float samples.
     * input/size: Opus encoded data
     * frame_count: expected number of output frames
     */
    OpusDecodeResult decode(const void* input, size_t size, size_t frame_count);

    /**
     * Decode with FEC recovery from the *current* packet.
     * When a previous packet was lost, call this with the current
     * (next) packet's data to recover the lost frame using Opus FEC.
     * Then call decode() normally for the current packet.
     */
    OpusDecodeResult decode_fec(const void* input, size_t size, size_t frame_count);

    /**
     * Decode with packet loss concealment (no input data).
     * Generates concealment audio for frame_count frames.
     */
    OpusDecodeResult decode_plc(size_t frame_count);

    bool is_initialized() const { return initialized_; }
    const OpusDecoderConfig& config() const { return config_; }

private:
    OpusDecoderConfig config_;
    bool initialized_ = false;
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace soluna::codec
