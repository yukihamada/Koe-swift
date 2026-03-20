/**
 * FileSource — Decodes MP3/WAV audio files and feeds S24_LE PCM into a ring buffer.
 *
 * Supported formats:
 *   - WAV  : PCM 16/24/32-bit, float32 (built-in RIFF parser, no deps)
 *   - MP3  : MPEG-1/2/2.5 Layer 3 via minimp3 (requires SOLUNA_HAS_MINIMP3)
 *
 * Output: interleaved int32_t (S24_LE — 24-bit value in 32-bit container)
 *   int32_t s24 = (int32_t)(sample_float * 8388607.0f)
 *
 * SPDX-License-Identifier: MIT
 */
#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

namespace soluna::pipeline {

enum class FileAudioFormat { Unknown, WAV, MP3 };

struct FileSourceInfo {
    FileAudioFormat format    = FileAudioFormat::Unknown;
    uint32_t        native_rate = 0;
    uint32_t        native_ch   = 0;
    uint64_t        total_frames = 0;  // 0 = unknown (e.g. VBR MP3)
    double          duration_sec = 0.0;
};

/**
 * FileSource: streaming audio file decoder.
 *
 * Usage:
 *   FileSource src;
 *   src.open("/tmp/track.mp3", 48000, 2);
 *   std::vector<int32_t> buf(480 * 2);
 *   while (!src.is_eof()) {
 *       size_t n = src.read_frames(buf.data(), 480);
 *       ring.write(buf.data(), n);
 *   }
 */
class FileSource {
public:
    FileSource();
    ~FileSource();

    FileSource(const FileSource&) = delete;
    FileSource& operator=(const FileSource&) = delete;

    /**
     * Open file for reading.
     * @param path         Absolute path to audio file.
     * @param target_rate  Desired output sample rate (0 = use file's native rate).
     * @param target_ch    Desired channel count (1 or 2; 0 = use file's native count).
     * @return true on success.
     */
    bool open(const std::string& path,
              uint32_t target_rate = 48000,
              uint32_t target_ch   = 2);

    /**
     * Read up to frame_count decoded frames into buf (S24_LE int32_t interleaved).
     * @return Number of frames actually written (< frame_count at EOF).
     */
    size_t read_frames(int32_t* buf, size_t frame_count);

    /**
     * Seek to approximate position (best-effort for MP3).
     */
    bool seek_ms(uint64_t ms);

    /** Current playback position in milliseconds. */
    uint64_t position_ms() const;

    /** Total duration in milliseconds (0 if unknown). */
    uint64_t duration_ms() const;

    bool is_open() const;
    bool is_eof() const;
    void close();

    /** Output sample rate (after resampling, if any). */
    uint32_t sample_rate() const;

    /** Output channel count. */
    uint32_t channels() const;

    /** Human-readable format name ("WAV", "MP3", "Unknown"). */
    const char* format_name() const;

    const FileSourceInfo& info() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace soluna::pipeline
