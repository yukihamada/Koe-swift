#pragma once

/**
 * Soluna — Abstract Codec Interface
 *
 * Provides unified interface for audio codecs.
 *
 * SPDX-License-Identifier: MIT
 */

#include <soluna/core/error.h>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace soluna {
namespace codec {

/**
 * Codec type identifiers.
 */
enum class CodecType {
    PCM,    // Uncompressed PCM
    Opus,   // Opus codec (for WiFi)
    AAC,    // AAC-LC/AAC-HE
    FLAC,   // Lossless
};

/**
 * Convert codec type to string.
 */
constexpr const char* codec_name(CodecType type) {
    switch (type) {
        case CodecType::PCM:  return "PCM";
        case CodecType::Opus: return "Opus";
        case CodecType::AAC:  return "AAC";
        case CodecType::FLAC: return "FLAC";
    }
    return "Unknown";
}

/**
 * Codec configuration.
 */
struct CodecConfig {
    CodecType type = CodecType::PCM;
    uint32_t sample_rate = 48000;
    uint32_t channels = 2;
    uint32_t bit_depth = 24;

    // For lossy codecs
    uint32_t bitrate = 128000;   // Target bitrate (bps)
    bool vbr = true;             // Variable bitrate

    // Opus-specific
    int opus_application = 2048; // OPUS_APPLICATION_AUDIO
    int opus_complexity = 10;

    // AAC-specific
    bool aac_sbr = false;        // Spectral Band Replication (HE-AAC)

    // FLAC-specific
    int flac_compression = 5;    // 0-8
};

/**
 * Encode result.
 */
struct EncodeResult {
    std::vector<uint8_t> data;
    size_t frames_encoded = 0;
    bool success = false;
};

/**
 * Decode result.
 */
struct DecodeResult {
    std::vector<float> samples;  // Interleaved float samples
    size_t frames_decoded = 0;
    bool success = false;
};

/**
 * Abstract encoder interface.
 */
class Encoder {
public:
    virtual ~Encoder() = default;

    /**
     * Get codec type.
     */
    virtual CodecType type() const = 0;

    /**
     * Get configuration.
     */
    virtual const CodecConfig& config() const = 0;

    /**
     * Encode audio frames.
     *
     * @param input Interleaved float samples [-1.0, 1.0]
     * @param frame_count Number of frames (samples / channels)
     * @return Encoded data
     */
    virtual EncodeResult encode(const float* input, size_t frame_count) = 0;

    /**
     * Flush any remaining data.
     */
    virtual EncodeResult flush() { return {}; }

    /**
     * Reset encoder state.
     */
    virtual void reset() {}

    /**
     * Get delay in frames (lookahead).
     */
    virtual size_t get_delay() const { return 0; }
};

/**
 * Abstract decoder interface.
 */
class Decoder {
public:
    virtual ~Decoder() = default;

    /**
     * Get codec type.
     */
    virtual CodecType type() const = 0;

    /**
     * Get configuration.
     */
    virtual const CodecConfig& config() const = 0;

    /**
     * Decode compressed data.
     *
     * @param input Compressed data
     * @param size Data size in bytes
     * @return Decoded float samples
     */
    virtual DecodeResult decode(const uint8_t* input, size_t size) = 0;

    /**
     * Handle packet loss (generate concealment).
     */
    virtual DecodeResult decode_plc(size_t frame_count) {
        DecodeResult result;
        result.samples.resize(frame_count * config().channels, 0.0f);
        result.frames_decoded = frame_count;
        result.success = true;
        return result;
    }

    /**
     * Reset decoder state.
     */
    virtual void reset() {}
};

/**
 * Codec factory.
 */
class CodecFactory {
public:
    /**
     * Create an encoder for the given configuration.
     */
    static Result<std::unique_ptr<Encoder>> create_encoder(const CodecConfig& config);

    /**
     * Create a decoder for the given configuration.
     */
    static Result<std::unique_ptr<Decoder>> create_decoder(const CodecConfig& config);

    /**
     * Check if a codec type is available.
     */
    static bool is_available(CodecType type);

    /**
     * List available codecs.
     */
    static std::vector<CodecType> available_codecs();
};

/**
 * PCM "codec" - passthrough with format conversion.
 */
class PcmEncoder : public Encoder {
public:
    explicit PcmEncoder(const CodecConfig& config);

    CodecType type() const override { return CodecType::PCM; }
    const CodecConfig& config() const override { return config_; }
    EncodeResult encode(const float* input, size_t frame_count) override;

private:
    CodecConfig config_;
};

class PcmDecoder : public Decoder {
public:
    explicit PcmDecoder(const CodecConfig& config);

    CodecType type() const override { return CodecType::PCM; }
    const CodecConfig& config() const override { return config_; }
    DecodeResult decode(const uint8_t* input, size_t size) override;

private:
    CodecConfig config_;
};

} // namespace codec
} // namespace soluna
