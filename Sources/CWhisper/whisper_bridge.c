// whisper_bridge.c — C bridge to whisper.cpp
// Uses shim.h which matches the installed library (v1.8.3) struct layout

#include "shim.h"
#include "whisper_bridge.h"
#include <string.h>
#include <stdatomic.h>
#include <stdlib.h>

// Real definition of koe_abort_flag (see whisper_bridge.h for why this is
// kept private to this translation unit / opaque from Swift's side).
struct koe_abort_flag {
    atomic_bool value;
};

koe_abort_flag *koe_abort_flag_create(void) {
    koe_abort_flag *f = (koe_abort_flag *)malloc(sizeof(koe_abort_flag));
    if (f) atomic_init(&f->value, false);
    return f;
}

void koe_abort_flag_set(koe_abort_flag *flag, bool value) {
    if (!flag) return;
    atomic_store_explicit(&flag->value, value, memory_order_release);
}

bool koe_abort_flag_get(koe_abort_flag *flag) {
    if (!flag) return false;
    return atomic_load_explicit(&flag->value, memory_order_acquire);
}

void koe_abort_flag_destroy(koe_abort_flag *flag) {
    free(flag);
}

bool koe_whisper_abort_callback(void *user_data) {
    if (!user_data) return false;
    return koe_abort_flag_get((koe_abort_flag *)user_data);
}

// Combines a plain (non-atomic, single-thread-pair) speculative-cancel flag
// with an (atomic, cross-thread) termination flag — used by
// whisper_bridge_transcribe_abortable so a long speculative transcribe can
// be interrupted by EITHER a newer recognition cancelling it OR the app
// terminating.
typedef struct {
    bool *cancel_flag;
    koe_abort_flag *termination_flag;
} koe_dual_abort_ctx;

static bool koe_dual_abort_callback(void *user_data) {
    if (!user_data) return false;
    koe_dual_abort_ctx *ctx = (koe_dual_abort_ctx *)user_data;
    if (ctx->cancel_flag && *ctx->cancel_flag) return true;
    if (ctx->termination_flag && koe_abort_flag_get(ctx->termination_flag)) return true;
    return false;
}

int whisper_bridge_transcribe(
    struct whisper_context *ctx,
    const float *samples,
    int n_samples,
    const char *language,
    const char *prompt,
    int n_threads,
    int best_of,
    bool suppress_blank,
    float temperature,
    float temperature_inc,
    float entropy_thold,
    float logprob_thold,
    float no_speech_thold,
    koe_abort_flag *abort_flag,
    char *output,
    int output_size
) {
    if (!ctx || !samples || !output || output_size <= 0) return -1;

    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);

    params.n_threads        = n_threads;
    params.print_progress   = false;
    params.print_special    = false;
    params.print_realtime   = false;
    params.print_timestamps = false;
    params.no_timestamps    = true;
    params.single_segment   = true;   // Speed: skip segment splitting
    params.suppress_blank   = suppress_blank;
    params.suppress_nst     = false;
    params.no_context       = false;
    params.token_timestamps = false;
    params.temperature      = temperature;
    params.temperature_inc  = temperature_inc;
    params.entropy_thold    = entropy_thold;
    params.logprob_thold    = logprob_thold;
    params.no_speech_thold  = no_speech_thold;
    params.greedy.best_of   = best_of;
    params.vad              = false;

    if (language) {
        params.language = language;
        params.detect_language = false;
    }

    if (prompt && prompt[0] != '\0') {
        params.initial_prompt = prompt;
    }

    if (abort_flag) {
        params.abort_callback = koe_whisper_abort_callback;
        params.abort_callback_user_data = abort_flag;
    }

    int ret = whisper_full(ctx, params, samples, n_samples);
    if (ret != 0) {
        output[0] = '\0';
        return ret;
    }

    int n_segments = whisper_full_n_segments(ctx);
    output[0] = '\0';
    int pos = 0;

    for (int i = 0; i < n_segments; i++) {
        const char *seg = whisper_full_get_segment_text(ctx, i);
        if (seg) {
            int len = (int)strlen(seg);
            if (pos + len < output_size - 1) {
                memcpy(output + pos, seg, len);
                pos += len;
            }
        }
    }
    output[pos] = '\0';

    return n_segments;
}

int whisper_bridge_transcribe_abortable(
    struct whisper_context *ctx,
    const float *samples,
    int n_samples,
    const char *language,
    const char *prompt,
    int n_threads,
    int best_of,
    bool *cancel_flag,
    koe_abort_flag *termination_flag,
    char *output,
    int output_size
) {
    if (!ctx || !samples || !output || output_size <= 0) return -1;

    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);

    params.n_threads        = n_threads;
    params.print_progress   = false;
    params.print_special    = false;
    params.print_realtime   = false;
    params.print_timestamps = false;
    params.suppress_blank   = true;
    params.no_context       = false;
    params.temperature      = 0.0f;
    params.temperature_inc  = 0.2f;
    params.entropy_thold    = 2.4f;
    params.logprob_thold    = -1.0f;
    params.no_speech_thold  = 0.6f;
    params.greedy.best_of   = best_of;
    params.vad              = false;

    if (language) {
        params.language = language;
        params.detect_language = false;
    }

    if (prompt && prompt[0] != '\0') {
        params.initial_prompt = prompt;
    }

    // `ctx_dual` is stack-local but whisper_full() below is synchronous —
    // it (and anything it calls, including abort_callback) never outlives
    // this function call, so pointing abort_callback_user_data at it is safe.
    koe_dual_abort_ctx ctx_dual = { cancel_flag, termination_flag };
    if (cancel_flag || termination_flag) {
        params.abort_callback = koe_dual_abort_callback;
        params.abort_callback_user_data = &ctx_dual;
    }

    int ret = whisper_full(ctx, params, samples, n_samples);
    if (ret != 0) {
        output[0] = '\0';
        return ret;
    }

    int n_segments = whisper_full_n_segments(ctx);
    output[0] = '\0';
    int pos = 0;

    for (int i = 0; i < n_segments; i++) {
        const char *seg = whisper_full_get_segment_text(ctx, i);
        if (seg) {
            int len = (int)strlen(seg);
            if (pos + len < output_size - 1) {
                memcpy(output + pos, seg, len);
                pos += len;
            }
        }
    }
    output[pos] = '\0';

    return n_segments;
}
