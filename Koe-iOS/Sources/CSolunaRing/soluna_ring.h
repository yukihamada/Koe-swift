#ifndef SOLUNA_RING_H
#define SOLUNA_RING_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle to a lock-free SPSC ring buffer.
/// Mirrors soluna::pipeline::RingBuffer from opensonic.
typedef struct SolunaRing SolunaRing;

/// Create a ring buffer. Capacity is rounded up to next power of 2.
SolunaRing* soluna_ring_create(size_t capacity_frames);

/// Destroy the ring buffer.
void soluna_ring_destroy(SolunaRing* ring);

/// Reset to empty state. Only safe when no concurrent access.
void soluna_ring_reset(SolunaRing* ring);

/// Write frames (producer side). Returns number actually written.
size_t soluna_ring_write(SolunaRing* ring, const float* data, size_t frame_count);

/// Read frames (consumer side). Returns number actually read.
size_t soluna_ring_read(SolunaRing* ring, float* data, size_t frame_count);

/// Number of frames available for reading.
size_t soluna_ring_available(const SolunaRing* ring);

/// Audio callback context — holds ring + prefill state
typedef struct SolunaAudioCtx SolunaAudioCtx;

SolunaAudioCtx* soluna_audio_ctx_create(SolunaRing* ring, size_t prefill_frames);
void soluna_audio_ctx_destroy(SolunaAudioCtx* ctx);

/// Audio render callback — call from AudioUnit render proc.
/// Reads from ring buffer with prefill gating, drift control, and fade-in.
/// Returns number of frames written to `dst`.
size_t soluna_audio_render(SolunaAudioCtx* ctx, float* dst, size_t frame_count);

/// Discard frames from ring buffer (advance read pointer).
size_t soluna_ring_discard(SolunaRing* ring, size_t frame_count);

#ifdef __cplusplus
}
#endif

#endif /* SOLUNA_RING_H */
