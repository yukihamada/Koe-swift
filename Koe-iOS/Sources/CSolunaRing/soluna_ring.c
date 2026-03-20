/// Lock-free Single-Producer Single-Consumer ring buffer.
/// Direct C port of soluna::pipeline::RingBuffer (opensonic).
///
/// Uses C11 <stdatomic.h> for proper acquire/release memory ordering.
/// This is the PROVEN approach — identical to the working Soluna iOS app.

#include "soluna_ring.h"
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>

struct SolunaRing {
    size_t capacity;    // power of 2
    size_t mask;        // capacity - 1
    float* buffer;

    // Separate cache lines to avoid false sharing (64-byte alignment)
    _Alignas(64) _Atomic size_t write_pos;
    _Alignas(64) _Atomic size_t read_pos;
};

static size_t next_power_of_two(size_t v) {
    if (v < 2) v = 2;
    v--;
    v |= v >> 1;
    v |= v >> 2;
    v |= v >> 4;
    v |= v >> 8;
    v |= v >> 16;
    v |= v >> 32;
    v++;
    return v;
}

SolunaRing* soluna_ring_create(size_t capacity_frames) {
    SolunaRing* ring = (SolunaRing*)calloc(1, sizeof(SolunaRing));
    if (!ring) return NULL;

    ring->capacity = next_power_of_two(capacity_frames);
    ring->mask = ring->capacity - 1;
    ring->buffer = (float*)calloc(ring->capacity, sizeof(float));
    if (!ring->buffer) {
        free(ring);
        return NULL;
    }

    atomic_init(&ring->write_pos, 0);
    atomic_init(&ring->read_pos, 0);
    return ring;
}

void soluna_ring_destroy(SolunaRing* ring) {
    if (!ring) return;
    free(ring->buffer);
    free(ring);
}

void soluna_ring_reset(SolunaRing* ring) {
    if (!ring) return;
    atomic_store_explicit(&ring->write_pos, 0, memory_order_seq_cst);
    atomic_store_explicit(&ring->read_pos, 0, memory_order_seq_cst);
}

size_t soluna_ring_write(SolunaRing* ring, const float* data, size_t frame_count) {
    // Producer reads own write_pos (relaxed) and consumer's read_pos (acquire)
    const size_t wr = atomic_load_explicit(&ring->write_pos, memory_order_relaxed);
    const size_t rd = atomic_load_explicit(&ring->read_pos, memory_order_acquire);

    const size_t avail = ring->capacity - (wr - rd);
    size_t to_write = frame_count < avail ? frame_count : avail;
    if (to_write == 0) return 0;

    const size_t wr_idx = wr & ring->mask;

    // Copy in up to 2 chunks (handle wrap-around)
    const size_t first_chunk = to_write < (ring->capacity - wr_idx) ? to_write : (ring->capacity - wr_idx);
    memcpy(ring->buffer + wr_idx, data, first_chunk * sizeof(float));

    if (first_chunk < to_write) {
        const size_t second_chunk = to_write - first_chunk;
        memcpy(ring->buffer, data + first_chunk, second_chunk * sizeof(float));
    }

    // Release: ensure data is visible before advancing write position
    atomic_store_explicit(&ring->write_pos, wr + to_write, memory_order_release);
    return to_write;
}

size_t soluna_ring_read(SolunaRing* ring, float* data, size_t frame_count) {
    // Consumer reads producer's write_pos (acquire) and own read_pos (relaxed)
    const size_t wr = atomic_load_explicit(&ring->write_pos, memory_order_acquire);
    const size_t rd = atomic_load_explicit(&ring->read_pos, memory_order_relaxed);

    const size_t avail = wr - rd;
    size_t to_read = frame_count < avail ? frame_count : avail;
    if (to_read == 0) return 0;

    const size_t rd_idx = rd & ring->mask;

    // Copy in up to 2 chunks
    const size_t first_chunk = to_read < (ring->capacity - rd_idx) ? to_read : (ring->capacity - rd_idx);
    memcpy(data, ring->buffer + rd_idx, first_chunk * sizeof(float));

    if (first_chunk < to_read) {
        const size_t second_chunk = to_read - first_chunk;
        memcpy(data + first_chunk, ring->buffer, second_chunk * sizeof(float));
    }

    // Release: ensure data is read before advancing read position
    atomic_store_explicit(&ring->read_pos, rd + to_read, memory_order_release);
    return to_read;
}

size_t soluna_ring_available(const SolunaRing* ring) {
    const size_t wr = atomic_load_explicit(&ring->write_pos, memory_order_acquire);
    const size_t rd = atomic_load_explicit(&ring->read_pos, memory_order_relaxed);
    return wr - rd;
}

// ============================================================================
// Audio render context (prefill + fade-in, matches C++ audio_callback pattern)
// ============================================================================

struct SolunaAudioCtx {
    SolunaRing* ring;
    size_t prefill_frames;
    int prefilled;    // 0 = waiting for prefill, 1 = playing
    float ramp;       // fade-in ramp (0..1)
};

SolunaAudioCtx* soluna_audio_ctx_create(SolunaRing* ring, size_t prefill_frames) {
    SolunaAudioCtx* ctx = (SolunaAudioCtx*)calloc(1, sizeof(SolunaAudioCtx));
    if (!ctx) return NULL;
    ctx->ring = ring;
    ctx->prefill_frames = prefill_frames;
    ctx->prefilled = 0;
    ctx->ramp = 0.0f;
    return ctx;
}

void soluna_audio_ctx_destroy(SolunaAudioCtx* ctx) {
    free(ctx);
}

size_t soluna_ring_discard(SolunaRing* ring, size_t frame_count) {
    const size_t wr = atomic_load_explicit(&ring->write_pos, memory_order_acquire);
    const size_t rd = atomic_load_explicit(&ring->read_pos, memory_order_relaxed);
    const size_t avail = wr - rd;
    size_t to_discard = frame_count < avail ? frame_count : avail;
    if (to_discard == 0) return 0;
    atomic_store_explicit(&ring->read_pos, rd + to_discard, memory_order_release);
    return to_discard;
}

size_t soluna_audio_render(SolunaAudioCtx* ctx, float* dst, size_t frame_count) {
    SolunaRing* ring = ctx->ring;
    size_t avail = soluna_ring_available(ring);

    // Prefill: wait for enough data ONCE (matches C++ prefilled_ pattern)
    if (!ctx->prefilled) {
        if (avail < ctx->prefill_frames) {
            memset(dst, 0, frame_count * sizeof(float));
            return frame_count;
        }
        ctx->prefilled = 1;
        ctx->ramp = 0.0f;
    }

    // Drift correction: if buffer is 3x overfilled, discard excess gradually
    // (matches C++ audio_callback drift correction)
    size_t target = ctx->prefill_frames;
    if (avail > target * 3) {
        size_t excess = avail - target * 2;
        size_t drift = excess < (frame_count / 80 + 1) ? excess : (frame_count / 80 + 1);
        soluna_ring_discard(ring, drift);
    }

    // Read what we can
    size_t got = soluna_ring_read(ring, dst, frame_count);

    // Fade-in to avoid clicks (C++ ramp_ pattern)
    if (ctx->ramp < 0.999f) {
        for (size_t i = 0; i < got; i++) {
            ctx->ramp += 0.002f * (1.0f - ctx->ramp);
            dst[i] *= ctx->ramp;
        }
    }

    // Zero-fill remainder on underrun (don't re-enter prefill mode!)
    if (got < frame_count) {
        memset(dst + got, 0, (frame_count - got) * sizeof(float));
    }

    return frame_count;
}
