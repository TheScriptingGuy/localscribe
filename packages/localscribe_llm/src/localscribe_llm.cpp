// LocalScribe on-device LLM: runs a GGUF chat model with llama.cpp for AI
// notes and Ask-AI chat. Exposed as a small C API for Dart FFI; see
// lib/localscribe_llm.dart.
//
// The model and its context stay loaded between calls: loading takes
// seconds, and a follow-up call that starts with the same text (Ask-AI: the
// transcript, then the conversation so far) only processes what's new.
// Generated text is buffered in the job and collected by Dart with
// lsl_job_take while generation runs.

#include <android/log.h>

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include "llama.h"

#define LS_API extern "C" __attribute__((visibility("default"))) __attribute__((used))

#define TAG "LocalScribeLLM"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

namespace {

struct Job {
    std::atomic<int> progress{0};  // prompt processing, permille
    std::atomic<bool> cancel{false};
    std::mutex mu;
    std::string pending;  // generated text not yet taken by Dart
};

// --- JSON helpers -----------------------------------------------------------

void json_str(std::string &out, const std::string &s) {
    out += '"';
    for (const unsigned char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    snprintf(buf, sizeof buf, "\\u%04x", c);
                    out += buf;
                } else {
                    out += (char)c;
                }
        }
    }
    out += '"';
}

char *json_error(const std::string &msg) {
    std::string out = "{\"error\":";
    json_str(out, msg);
    out += '}';
    return strdup(out.c_str());
}

// Length of the longest prefix of `s` that doesn't end in a partial UTF-8
// sequence (tokens can split a multi-byte character).
size_t utf8_complete(const std::string &s) {
    const size_t n = s.size();
    for (size_t back = 1; back <= 4 && back <= n; ++back) {
        const unsigned char c = (unsigned char)s[n - back];
        if ((c & 0xC0) == 0x80) continue;  // continuation byte
        size_t need = 1;
        if ((c & 0xE0) == 0xC0) need = 2;
        else if ((c & 0xF0) == 0xE0) need = 3;
        else if ((c & 0xF8) == 0xF0) need = 4;
        return back >= need ? n : n - back;
    }
    return n;
}

// --- model cache --------------------------------------------------------------

std::mutex g_mu;  // one generation at a time; guards everything below
llama_model *g_model = nullptr;
std::string g_model_path;
llama_context *g_ctx = nullptr;
std::vector<llama_token> g_ctx_tokens;  // what g_ctx's memory holds
std::once_flag g_init;

void free_context() {
    if (g_ctx) llama_free(g_ctx);
    g_ctx = nullptr;
    g_ctx_tokens.clear();
}

void on_log(ggml_log_level level, const char *text, void *) {
    if (level == GGML_LOG_LEVEL_ERROR) LOGE("%s", text);
}

llama_model *load_model(const std::string &path, std::string &err) {
    if (g_model && g_model_path == path) return g_model;
    free_context();
    if (g_model) {
        llama_model_free(g_model);
        g_model = nullptr;
        g_model_path.clear();
    }
    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = 0;
    g_model = llama_model_load_from_file(path.c_str(), mp);
    if (!g_model) {
        err = "Could not load the AI model. Try downloading it again.";
        return nullptr;
    }
    g_model_path = path;
    return g_model;
}

bool on_abort(void *user) { return ((Job *)user)->cancel.load(); }

llama_context *new_context(llama_model *model, uint32_t n_ctx, int threads, bool quantized_kv) {
    llama_context_params cp = llama_context_default_params();
    cp.n_ctx = n_ctx;
    cp.n_batch = 512;
    cp.n_ubatch = 512;
    cp.n_threads = threads;
    cp.n_threads_batch = threads;
    cp.no_perf = true;
    if (quantized_kv) {
        // Halves the memory for long transcripts; needs flash attention.
        cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED;
        cp.type_k = GGML_TYPE_Q8_0;
        cp.type_v = GGML_TYPE_Q8_0;
    }
    return llama_init_from_model(model, cp);
}

}  // namespace

LS_API void *lsl_job_new() { return new Job(); }
LS_API int lsl_job_progress(void *job) { return ((Job *)job)->progress.load(); }
LS_API void lsl_job_cancel(void *job) { ((Job *)job)->cancel = true; }
LS_API void lsl_job_free(void *job) { delete (Job *)job; }
LS_API void lsl_free_string(char *s) { free(s); }

// Text generated since the last call (malloc'd, possibly empty).
LS_API char *lsl_job_take(void *job_ptr) {
    Job *job = (Job *)job_ptr;
    std::lock_guard<std::mutex> lock(job->mu);
    const size_t n = utf8_complete(job->pending);
    char *out = strndup(job->pending.data(), n);
    job->pending.erase(0, n);
    return out;
}

// Frees the cached model (waits for a running generation to finish).
LS_API void lsl_unload() {
    std::lock_guard<std::mutex> lock(g_mu);
    free_context();
    if (g_model) llama_model_free(g_model);
    g_model = nullptr;
    g_model_path.clear();
}

// Runs the chat `roles`/`contents` (n_msg messages) through the model's own
// chat template and generates up to `max_tokens`. The context is sized to
// the prompt, at most `max_ctx` tokens. Returns a malloc'd JSON string, free
// with lsl_free_string:
//   {"text":"…","prompt_tokens":N,"tokens":M,"truncated":false}
//   {"error":"too_long","prompt_tokens":N,"max_prompt":P}
//   {"error":"…"} ("cancelled" after lsl_job_cancel)
LS_API char *lsl_generate(const char *model_path, const char **roles, const char **contents,
                          int n_msg, int max_ctx, int max_tokens, float temperature,
                          int n_threads, void *job_ptr) {
    std::call_once(g_init, [] {
        llama_log_set(on_log, nullptr);
        llama_backend_init();
    });
    Job local;
    Job *job = job_ptr ? (Job *)job_ptr : &local;
    std::lock_guard<std::mutex> lock(g_mu);
    if (job->cancel.load()) return json_error("cancelled");

    std::string err;
    llama_model *model = load_model(model_path, err);
    if (!model) return json_error(err);
    const llama_vocab *vocab = llama_model_get_vocab(model);

    // Prompt via the chat template stored in the GGUF.
    std::vector<llama_chat_message> chat;
    size_t chars = 0;
    for (int i = 0; i < n_msg; ++i) {
        chat.push_back({roles[i], contents[i]});
        chars += strlen(contents[i]);
    }
    const char *tmpl = llama_model_chat_template(model, nullptr);
    std::vector<char> buf(chars * 2 + 1024);
    int len = llama_chat_apply_template(tmpl, chat.data(), chat.size(), true, buf.data(),
                                        (int32_t)buf.size());
    if (len > (int)buf.size()) {
        buf.resize(len + 1);
        len = llama_chat_apply_template(tmpl, chat.data(), chat.size(), true, buf.data(),
                                        (int32_t)buf.size());
    }
    if (len < 0) return json_error("This model's chat format is not supported.");
    const std::string prompt(buf.data(), len);

    int n_prompt = -llama_tokenize(vocab, prompt.c_str(), (int32_t)prompt.size(), nullptr, 0,
                                   true, true);
    std::vector<llama_token> tokens(std::max(n_prompt, 0));
    if (n_prompt <= 0 ||
        llama_tokenize(vocab, prompt.c_str(), (int32_t)prompt.size(), tokens.data(),
                       n_prompt, true, true) < 0) {
        return json_error("Could not tokenize the prompt.");
    }

    const int ctx_limit = std::min(max_ctx, llama_model_n_ctx_train(model));
    max_tokens = std::max(16, std::min(max_tokens, ctx_limit / 2));
    if (n_prompt + max_tokens > ctx_limit) {
        char out[128];
        snprintf(out, sizeof out, "{\"error\":\"too_long\",\"prompt_tokens\":%d,\"max_prompt\":%d}",
                 n_prompt, ctx_limit - max_tokens);
        return strdup(out);
    }
    const int needed = n_prompt + max_tokens + 8;
    if (g_ctx && (int)llama_n_ctx(g_ctx) < needed) free_context();
    if (!g_ctx) {
        // Headroom so a growing chat can keep reusing the context.
        const uint32_t n_ctx = (uint32_t)std::min(ctx_limit, needed + 1024);
        const int threads = n_threads > 0 ? n_threads : 4;
        g_ctx = new_context(model, n_ctx, threads, true);
        if (!g_ctx) g_ctx = new_context(model, n_ctx, threads, false);
        if (!g_ctx) return json_error("Not enough memory for the AI model. Try a smaller model.");
    }
    llama_context *ctx = g_ctx;
    llama_set_abort_callback(ctx, on_abort, job);

    // Keep what the context already holds of this prompt.
    size_t keep = 0;
    while (keep < g_ctx_tokens.size() && keep < tokens.size() &&
           g_ctx_tokens[keep] == tokens[keep]) {
        ++keep;
    }
    if (keep == tokens.size()) --keep;  // decode at least one token for logits
    llama_memory_t mem = llama_get_memory(ctx);
    if (!llama_memory_seq_rm(mem, 0, (llama_pos)keep, -1)) {
        llama_memory_clear(mem, true);
        keep = 0;
    }
    g_ctx_tokens.resize(keep);
    LOGI("prompt %d tokens, %zu reused", n_prompt, keep);

    llama_sampler *smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
    // Small models loop without a repetition penalty.
    llama_sampler_chain_add(smpl, llama_sampler_init_penalties(
                                      llama_vocab_n_tokens(vocab), 64, 1.1f, 0.0f, 0.0f));
    if (temperature <= 0) {
        llama_sampler_chain_add(smpl, llama_sampler_init_greedy());
    } else {
        llama_sampler_chain_add(smpl, llama_sampler_init_top_k(40));
        llama_sampler_chain_add(smpl, llama_sampler_init_top_p(0.9f, 1));
        llama_sampler_chain_add(smpl, llama_sampler_init_min_p(0.05f, 1));
        llama_sampler_chain_add(smpl, llama_sampler_init_temp(temperature));
        llama_sampler_chain_add(smpl, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
    }

    bool ok = true;
    // The rest of the prompt, a batch at a time for progress.
    const int n_batch = (int)llama_n_batch(ctx);
    for (int i = (int)keep; i < n_prompt && ok; i += n_batch) {
        const int n = std::min(n_batch, n_prompt - i);
        if (llama_decode(ctx, llama_batch_get_one(tokens.data() + i, n)) != 0) {
            ok = false;
        } else {
            g_ctx_tokens.insert(g_ctx_tokens.end(), tokens.begin() + i, tokens.begin() + i + n);
        }
        job->progress = (int)(1000LL * (i + n) / n_prompt);
    }

    std::string text;
    int generated = 0;
    bool truncated = false;
    while (ok) {
        if (generated >= max_tokens) {
            truncated = true;
            break;
        }
        llama_token tok = llama_sampler_sample(smpl, ctx, -1);
        if (llama_vocab_is_eog(vocab, tok)) break;
        char piece[256];
        const int n = llama_token_to_piece(vocab, tok, piece, sizeof piece, 0, false);
        if (n > 0) {
            text.append(piece, n);
            std::lock_guard<std::mutex> l(job->mu);
            job->pending.append(piece, n);
        }
        ++generated;
        if (llama_decode(ctx, llama_batch_get_one(&tok, 1)) != 0) {
            ok = false;
        } else {
            g_ctx_tokens.push_back(tok);
        }
    }

    llama_sampler_free(smpl);
    llama_set_abort_callback(ctx, nullptr, nullptr);
    // After an abort or error the memory may hold a partial batch.
    if (!ok) free_context();

    if (!ok) {
        return json_error(job->cancel.load() ? "cancelled" : "The AI model stopped unexpectedly.");
    }
    std::string out = "{\"text\":";
    json_str(out, text);
    char tail[96];
    snprintf(tail, sizeof tail, ",\"prompt_tokens\":%d,\"tokens\":%d,\"truncated\":%s}", n_prompt,
             generated, truncated ? "true" : "false");
    out += tail;
    return strdup(out.c_str());
}
