/**
 * WavWriter -- Reusable, thread-safe WAV file writer
 *
 * Supports 8/16/24/32-bit PCM.  Writes an empty 44-byte header on open(),
 * appends sample data via write(), and finalises the RIFF/data chunk sizes
 * on close().
 *
 * Thread safety: a std::mutex guards every public method so that concurrent
 * audio callbacks can safely push samples.
 *
 * SPDX-License-Identifier: OpenSonic-Community-1.0
 */
#pragma once

#include <cstdint>
#include <cstdio>
#include <mutex>
#include <string>

namespace soluna {
namespace util {

class WavWriter {
public:
    WavWriter() = default;
    ~WavWriter();

    // Non-copyable, movable
    WavWriter(const WavWriter&) = delete;
    WavWriter& operator=(const WavWriter&) = delete;
    WavWriter(WavWriter&& other) noexcept;
    WavWriter& operator=(WavWriter&& other) noexcept;

    /// Open a new WAV file for writing.
    /// @param path           Output file path
    /// @param sample_rate    Sample rate in Hz (e.g. 48000)
    /// @param channels       Number of audio channels (1 = mono, 2 = stereo, ...)
    /// @param bits_per_sample  Bit depth: 8, 16, 24, or 32
    /// @return true on success
    bool open(const std::string& path, uint32_t sample_rate,
              uint32_t channels, uint32_t bits_per_sample = 16);

    /// Write interleaved PCM frames.
    /// The caller must ensure that `data` contains at least
    ///   frames * channels * (bits_per_sample/8) bytes.
    /// @param data   Pointer to raw PCM samples (interleaved)
    /// @param frames Number of frames (1 frame = 1 sample per channel)
    /// @return number of frames actually written
    size_t write(const void* data, size_t frames);

    /// Finalise the WAV header and close the file.
    void close();

    /// @return true if the file is currently open
    bool is_open() const;

    /// @return total number of frames written so far
    uint64_t frames_written() const;

    /// @return the file path (empty if not open)
    const std::string& path() const { return path_; }

private:
    void write_header();

    mutable std::mutex mutex_;
    FILE*       fp_              = nullptr;
    std::string path_;
    uint32_t    sample_rate_     = 0;
    uint32_t    channels_        = 0;
    uint32_t    bits_per_sample_ = 16;
    uint32_t    data_bytes_      = 0;
    uint64_t    frames_written_  = 0;
};

} // namespace util
} // namespace soluna
