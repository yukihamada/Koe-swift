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

// Simple transcription: returns number of segments, fills output buffer with text
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
    char *output,            // output buffer for transcribed text
    int output_size          // size of output buffer
);

// Transcribe with abort callback support (for speculative execution)
int whisper_bridge_transcribe_abortable(
    struct whisper_context *ctx,
    const float *samples,
    int n_samples,
    const char *language,
    const char *prompt,
    int n_threads,
    int best_of,
    bool *abort_flag,        // set to true to abort
    char *output,
    int output_size
);

#ifdef __cplusplus
}
#endif

#endif // WHISPER_BRIDGE_H
