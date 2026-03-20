#pragma once

/**
 * Soluna — FLAC Codec Wrapper
 *
 * Optional FLAC encoder/decoder using libFLAC.
 *
 * SPDX-License-Identifier: MIT
 */

#include <soluna/codec/codec.h>

namespace soluna {
namespace codec {

#ifdef SOLUNA_ENABLE_FLAC

/**
 * FLAC encoder using libFLAC.
 */
class FlacEncoder : public Encoder {
public:
    explicit FlacEncoder(const CodecConfig& config);
    ~FlacEncoder() override;

    CodecType type() const override { return CodecType::FLAC; }
    const CodecConfig& config() const override { return config_; }

    EncodeResult encode(const float* input, size_t frame_count) override;
    EncodeResult flush() override;
    void reset() override;

private:
    CodecConfig config_;
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

/**
 * FLAC decoder using libFLAC.
 */
class FlacDecoder : public Decoder {
public:
    explicit FlacDecoder(const CodecConfig& config);
    ~FlacDecoder() override;

    CodecType type() const override { return CodecType::FLAC; }
    const CodecConfig& config() const override { return config_; }

    DecodeResult decode(const uint8_t* input, size_t size) override;
    void reset() override;

private:
    CodecConfig config_;
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

#else

// Stub implementations when FLAC is disabled
class FlacEncoder : public Encoder {
public:
    explicit FlacEncoder(const CodecConfig& config) : config_(config) {}
    CodecType type() const override { return CodecType::FLAC; }
    const CodecConfig& config() const override { return config_; }
    EncodeResult encode(const float*, size_t) override { return {}; }
private:
    CodecConfig config_;
};

class FlacDecoder : public Decoder {
public:
    explicit FlacDecoder(const CodecConfig& config) : config_(config) {}
    CodecType type() const override { return CodecType::FLAC; }
    const CodecConfig& config() const override { return config_; }
    DecodeResult decode(const uint8_t*, size_t) override { return {}; }
private:
    CodecConfig config_;
};

#endif // SOLUNA_ENABLE_FLAC

} // namespace codec
} // namespace soluna
