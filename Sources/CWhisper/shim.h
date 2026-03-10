// CWhisper shim — expose only the whisper C API functions needed by Swift
// This avoids pulling in ggml.h and all its transitive dependencies.

#ifndef CWHISPER_SHIM_H
#define CWHISPER_SHIM_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque types
struct whisper_context;

// Sampling strategies
enum whisper_sampling_strategy {
    WHISPER_SAMPLING_GREEDY,
    WHISPER_SAMPLING_BEAM_SEARCH,
};

// Context params
struct whisper_context_params {
    bool  use_gpu;
    bool  flash_attn;
    int   gpu_device;
    bool  dtw_token_timestamps;
    int   dtw_aheads_preset;
    int   dtw_n_top;
    void *dtw_aheads_heads;   // simplified
    size_t dtw_aheads_n_heads;
    size_t dtw_mem_size;
};

// Callback types (unused in our wrapper, but needed for struct layout)
typedef void (*whisper_new_segment_callback)(struct whisper_context *ctx, void *state, int n_new, void *user_data);
typedef void (*whisper_progress_callback)(struct whisper_context *ctx, void *state, int progress, void *user_data);
typedef bool (*whisper_encoder_begin_callback)(struct whisper_context *ctx, void *state, void *user_data);
typedef bool (*whisper_abort_callback)(void *user_data);
typedef void (*whisper_logits_filter_callback)(struct whisper_context *ctx, void *state, void *tokens, int n_tokens, float *logits, void *user_data);

// Grammar element (opaque)
struct whisper_grammar_element;

// Full params — must match whisper.h layout exactly
struct whisper_full_params {
    enum whisper_sampling_strategy strategy;

    int n_threads;
    int n_max_text_ctx;
    int offset_ms;
    int duration_ms;

    bool translate;
    bool no_context;
    bool no_timestamps;
    bool single_segment;
    bool print_special;
    bool print_progress;
    bool print_realtime;
    bool print_timestamps;

    bool  token_timestamps;
    float thold_pt;
    float thold_ptsum;
    int   max_len;
    bool  split_on_word;
    int   max_tokens;

    bool debug_mode;
    int  audio_ctx;

    bool tdrz_enable;

    const char *suppress_regex;

    const char *initial_prompt;
    const int32_t *prompt_tokens;
    int prompt_n_tokens;

    const char *language;
    bool detect_language;

    bool suppress_blank;
    bool suppress_nst;

    float temperature;
    float max_initial_ts;
    float length_penalty;

    float temperature_inc;
    float entropy_thold;
    float logprob_thold;
    float no_speech_thold;

    struct { int best_of; } greedy;
    struct { int beam_size; float patience; } beam_search;

    whisper_new_segment_callback    new_segment_callback;
    void *new_segment_callback_user_data;

    whisper_progress_callback       progress_callback;
    void *progress_callback_user_data;

    whisper_encoder_begin_callback  encoder_begin_callback;
    void *encoder_begin_callback_user_data;

    whisper_abort_callback          abort_callback;
    void *abort_callback_user_data;

    whisper_logits_filter_callback  logits_filter_callback;
    void *logits_filter_callback_user_data;

    const struct whisper_grammar_element **grammar_rules;
    size_t n_grammar_rules;
    size_t i_start_rule;
    float  grammar_penalty;
};

// --- API functions ---

// Init / free
struct whisper_context_params whisper_context_default_params(void);
struct whisper_context *whisper_init_from_file_with_params(const char *path_model, struct whisper_context_params params);
void whisper_free(struct whisper_context *ctx);

// Default params
struct whisper_full_params whisper_full_default_params(enum whisper_sampling_strategy strategy);

// Run inference
int whisper_full(struct whisper_context *ctx, struct whisper_full_params params, const float *samples, int n_samples);
int whisper_full_parallel(struct whisper_context *ctx, struct whisper_full_params params, const float *samples, int n_samples, int n_processors);

// Results
int whisper_full_n_segments(struct whisper_context *ctx);
const char *whisper_full_get_segment_text(struct whisper_context *ctx, int i_segment);

// Language
int whisper_lang_id(const char *lang);

#ifdef __cplusplus
}
#endif

#endif // CWHISPER_SHIM_H
