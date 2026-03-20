#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <type_traits>

namespace soluna::pipeline {

/**
 * Lock-free Single-Producer Single-Consumer ring buffer.
 *
 * Designed for the audio path:
 * - No allocations after construction
 * - No locks, no syscalls
 * - Cache-line padding to avoid false sharing
 * - Power-of-two size for fast modulo (bitwise AND)
 */
class RingBuffer {
public:
    // capacity will be rounded up to next power of two
    explicit RingBuffer(size_t capacity_frames, size_t frame_size);
    ~RingBuffer();

    // Non-copyable, non-movable
    RingBuffer(const RingBuffer&) = delete;
    RingBuffer& operator=(const RingBuffer&) = delete;

    /**
     * Write frames into the buffer (producer side).
     * Returns number of frames actually written.
     */
    size_t write(const void* data, size_t frame_count);

    /**
     * Read frames from the buffer (consumer side).
     * Returns number of frames actually read.
     */
    size_t read(void* data, size_t frame_count);

    /**
     * Peek at available data without consuming.
     * Returns number of frames copied to data (up to frame_count).
     */
    size_t peek(void* data, size_t frame_count) const;

    /** Number of frames available for reading. */
    size_t available_read() const;

    /** Number of frames available for writing. */
    size_t available_write() const;

    /** Total capacity in frames. */
    size_t capacity() const { return capacity_; }

    /** Bytes per frame. */
    size_t frame_size() const { return frame_size_; }

    /**
     * Discard frames without copying data (advance read pointer).
     * Returns number of frames actually discarded.
     */
    size_t discard(size_t frame_count);

    /** Reset to empty state. Only safe when no concurrent access. */
    void reset();

private:
    static size_t next_power_of_two(size_t v);

    const size_t capacity_;
    const size_t mask_;
    const size_t frame_size_;

    std::unique_ptr<uint8_t[]> buffer_;

    // Separate cache lines to avoid false sharing
    alignas(64) std::atomic<size_t> write_pos_{0};
    alignas(64) std::atomic<size_t> read_pos_{0};
};

} // namespace soluna::pipeline
