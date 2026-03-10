// CLlama shim — expose only the llama.cpp C API functions needed by Swift
// Minimal subset for chat completion (load model, tokenize, decode, sample)

#ifndef CLLAMA_SHIM_H
#define CLLAMA_SHIM_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque types
struct llama_model;
struct llama_context;
struct llama_sampler;
struct llama_vocab;

typedef int32_t llama_pos;
typedef int32_t llama_token;
typedef int32_t llama_seq_id;

// --- Model params ---
struct llama_model_params {
    int32_t n_gpu_layers;
    int32_t split_mode;      // enum llama_split_mode
    int32_t main_gpu;
    const float * tensor_split;
    void * progress_callback;  // llama_progress_callback
    void * progress_callback_user_data;
    void * kv_overrides;     // const struct llama_model_kv_override *
    const char * hf_token;
    bool vocab_only;
    bool use_mmap;
    bool use_mlock;
    bool check_tensors;
};

// --- Context params (simplified — only fields we set) ---
// The actual struct has many fields; we use default_params and only modify what we need
struct llama_context_params {
    uint32_t n_ctx;
    uint32_t n_batch;
    uint32_t n_ubatch;
    uint32_t n_seq_max;
    uint32_t n_threads;
    uint32_t n_threads_batch;
    int32_t  rope_scaling_type;
    uint32_t n_ctx_orig_yarn;
    float    rope_freq_base;
    float    rope_freq_scale;
    float    yarn_ext_factor;
    float    yarn_attn_factor;
    float    yarn_beta_fast;
    float    yarn_beta_slow;
    uint32_t defrag_thold_u32;  // stored as uint32 for ABI compatibility
    void   * cb_eval;
    void   * cb_eval_user_data;
    int32_t  type_k;  // enum ggml_type
    int32_t  type_v;  // enum ggml_type
    bool     logits_all;
    bool     embeddings;
    bool     offload_kqv;
    int32_t  flash_attn;  // enum llama_flash_attn_type
    bool     no_perf;
    void   * abort_callback;
    void   * abort_callback_user_data;
    // Sampler seq configs
    void   * samplers;
    int32_t  n_samplers;
};

// --- Batch ---
struct llama_batch {
    int32_t    n_tokens;
    llama_token  * token;
    float        * embd;
    llama_pos    * pos;
    int32_t      * n_seq_id;
    llama_seq_id ** seq_id;
    int8_t       * logits;
};

// --- Chat message ---
struct llama_chat_message {
    const char * role;
    const char * content;
};

// --- Sampler chain params ---
struct llama_sampler_chain_params {
    bool no_perf;
};

// --- Default params ---
struct llama_model_params   llama_model_default_params(void);
struct llama_context_params llama_context_default_params(void);
struct llama_sampler_chain_params llama_sampler_chain_default_params(void);

// --- Model ---
struct llama_model * llama_model_load_from_file(const char * path_model, struct llama_model_params params);
void llama_model_free(struct llama_model * model);
const struct llama_vocab * llama_model_get_vocab(const struct llama_model * model);

// --- Context ---
struct llama_context * llama_init_from_model(struct llama_model * model, struct llama_context_params params);
void llama_free(struct llama_context * ctx);

// --- Vocab ---
llama_token llama_vocab_bos(const struct llama_vocab * vocab);
llama_token llama_vocab_eos(const struct llama_vocab * vocab);
bool llama_vocab_get_add_bos(const struct llama_vocab * vocab);

// --- Tokenize ---
int32_t llama_tokenize(
    const struct llama_vocab * vocab,
    const char * text,
    int32_t text_len,
    llama_token * tokens,
    int32_t n_tokens_max,
    bool add_special,
    bool parse_special);

// --- Detokenize ---
int32_t llama_token_to_piece(
    const struct llama_vocab * vocab,
    llama_token token,
    char * buf,
    int32_t length,
    int32_t lstrip,
    bool special);

// --- Chat template ---
int32_t llama_chat_apply_template(
    const char * tmpl,
    const struct llama_chat_message * chat,
    size_t n_msg,
    bool add_ass,
    char * buf,
    int32_t length);

// --- Batch ---
struct llama_batch llama_batch_get_one(llama_token * tokens, int32_t n_tokens);
struct llama_batch llama_batch_init(int32_t n_tokens, int32_t embd, int32_t n_seq_max);
void llama_batch_free(struct llama_batch batch);

// --- Decode ---
int32_t llama_decode(struct llama_context * ctx, struct llama_batch batch);

// --- Logits ---
float * llama_get_logits_ith(struct llama_context * ctx, int32_t i);

// --- Sampler ---
struct llama_sampler * llama_sampler_chain_init(struct llama_sampler_chain_params params);
void llama_sampler_chain_add(struct llama_sampler * chain, struct llama_sampler * smpl);
struct llama_sampler * llama_sampler_init_greedy(void);
struct llama_sampler * llama_sampler_init_temp(float t);
struct llama_sampler * llama_sampler_init_top_k(int32_t k);
struct llama_sampler * llama_sampler_init_top_p(float p, size_t min_keep);
struct llama_sampler * llama_sampler_init_min_p(float p, size_t min_keep);
llama_token llama_sampler_sample(struct llama_sampler * smpl, struct llama_context * ctx, int32_t idx);
void llama_sampler_free(struct llama_sampler * smpl);

// --- Memory (KV cache) ---
typedef struct llama_memory_i * llama_memory_t;
llama_memory_t llama_get_memory(const struct llama_context * ctx);
void llama_memory_clear(llama_memory_t mem, bool data);

// --- Backend init ---
void ggml_backend_load_all(void);

#ifdef __cplusplus
}
#endif

#endif // CLLAMA_SHIM_H
