#pragma once

/**
 * Soluna — AAC Codec Wrapper
 *
 * Optional AAC encoder/decoder using FDK-AAC or FFmpeg.
 *
 * SPDX-License-Identifier: MIT
 */

#include <soluna/codec/codec.h>

namespace soluna {
namespace codec {

#ifdef SOLUNA_ENABLE_AAC

/**
 * AAC encoder using FDK-AAC.
 */
class AacEncoder : public Encoder {
public:
    explicit AacEncoder(const CodecConfig& config);
    ~AacEncoder() override;

    CodecType type() const override { return CodecType::AAC; }
    const CodecConfig& config() const override { return config_; }

    EncodeResult encode(const float* input, size_t frame_count) override;
    EncodeResult flush() override;
    void reset() override;
    size_t get_delay() const override;

private:
    CodecConfig config_;
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

/**
 * AAC decoder using FDK-AAC.
 */
class AacDecoder : public Decoder {
public:
    explicit AacDecoder(const CodecConfig& config);
    ~AacDecoder() override;

    CodecType type() const override { return CodecType::AAC; }
    const CodecConfig& config() const override { return config_; }

    DecodeResult decode(const uint8_t* input, size_t size) override;
    void reset() override;

private:
    CodecConfig config_;
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

#else

// Stub implementations when AAC is disabled
class AacEncoder : public Encoder {
public:
    explicit AacEncoder(const CodecConfig& config) : config_(config) {}
    CodecType type() const override { return CodecType::AAC; }
    const CodecConfig& config() const override { return config_; }
    EncodeResult encode(const float*, size_t) override { return {}; }
private:
    CodecConfig config_;
};

class AacDecoder : public Decoder {
public:
    explicit AacDecoder(const CodecConfig& config) : config_(config) {}
    CodecType type() const override { return CodecType::AAC; }
    const CodecConfig& config() const override { return config_; }
    DecodeResult decode(const uint8_t*, size_t) override { return {}; }
private:
    CodecConfig config_;
};

#endif // SOLUNA_ENABLE_AAC

} // namespace codec
} // namespace soluna
