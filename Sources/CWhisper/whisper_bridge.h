// whisper_bridge.h — Simple C bridge to whisper.cpp
// Avoids struct layout issues by hiding whisper_full_params from Swift

#ifndef WHISPER_BRIDGE_H
#define WHISPER_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque context type
struct whisper_context;

// Thread-safe (real C11 atomic) boolean flag, for signals that get written
// from one thread (e.g. the app-termination path) and read from a different
// thread (e.g. the whisper_full worker thread) without any other
// synchronization between them.
//
// Opaque from Swift's side: Swift's ClangImporter can't cleanly expose C11
// _Atomic-qualified struct fields, so the real definition (atomic_bool)
// lives privately in whisper_bridge.c — every other translation unit /
// Swift file only ever holds and passes the pointer around via these
// functions.
//
// 2026-09-26 round-5: replaces a plain `UnsafeMutablePointer<Bool>` that
// ThreadSanitizer flagged as a genuine data race (written from the
// termination thread, read from the whisper_full worker thread with no
// synchronization at all).
typedef struct koe_abort_flag koe_abort_flag;

koe_abort_flag *koe_abort_flag_create(void);
void koe_abort_flag_set(koe_abort_flag *flag, bool value);
bool koe_abort_flag_get(koe_abort_flag *flag);
void koe_abort_flag_destroy(koe_abort_flag *flag);

// whisper_full_params.abort_callback-compatible function that checks a
// koe_abort_flag — for callers that build whisper_full_params directly in
// Swift (e.g. WhisperContext.transcribeWithSpeakers) instead of going
// through one of the whisper_bridge_transcribe* helpers below.
bool koe_whisper_abort_callback(void *user_data);

// Simple transcription: returns number of segments, fills output buffer with text
// abort_flag: optional (NULL = no abort support). Set it via
// koe_abort_flag_set() from another thread (e.g. app termination) to make
// whisper_full return early — this is what lets
// AppDelegate.applicationWillTerminate interrupt a long in-flight
// recognition within ~100ms instead of waiting for it to finish.
int whisper_bridge_transcribe(
    struct whisper_context *ctx,
    const float *samples,
    int n_samples,
    const char *language,    // "ja", "en", etc. NULL for auto
    const char *prompt,      // initial prompt, NULL if none
    int n_threads,
    int best_of,             // greedy best_of (default 5)
    bool suppress_blank,
    float temperature,
    float temperature_inc,
    float entropy_thold,
    float logprob_thold,
    float no_speech_thold,
    koe_abort_flag *abort_flag,  // optional; NULL = no abort support
    char *output,            // output buffer for transcribed text
    int output_size          // size of output buffer
);

// Transcribe with abort callback support (for speculative execution).
// cancel_flag: plain, non-atomic bool* — written and read by the SAME
// thread pair every time (the caller thread that starts/cancels a
// speculative transcribe, and this function's own worker queue), reset at
// the start of every transcribe() call, so it intentionally stays a plain
// pointer (see WhisperContext.cancelFlag's doc comment for why it must NOT
// be shared with termination_flag).
// termination_flag: optional koe_abort_flag* — honored in ADDITION to
// cancel_flag, so a long-running speculative transcribe can also be
// interrupted by app termination, not just by a newer recognition
// cancelling it.
int whisper_bridge_transcribe_abortable(
    struct whisper_context *ctx,
    const float *samples,
    int n_samples,
    const char *language,
    const char *prompt,
    int n_threads,
    int best_of,
    bool *cancel_flag,               // set to true to abort
    koe_abort_flag *termination_flag, // optional; NULL = not honored
    char *output,
    int output_size
);

#ifdef __cplusplus
}
#endif

#endif // WHISPER_BRIDGE_H
