// LocalScribe native layer: decodes any audio file Android can play (NDK
// MediaCodec) to 16 kHz mono PCM and transcribes it with whisper.cpp. The
// decoder is also exposed on its own for speaker recognition (sherpa-onnx).
// Exposed as a small C API for Dart FFI; see lib/localscribe_native.dart.

#include <android/log.h>
#include <media/NdkMediaCodec.h>
#include <media/NdkMediaExtractor.h>
#include <media/NdkMediaFormat.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <mutex>
#include <string>
#include <vector>

#include "whisper.h"

#define LS_API extern "C" __attribute__((visibility("default"))) __attribute__((used))

#define TAG "LocalScribe"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

namespace {

constexpr int kRate = WHISPER_SAMPLE_RATE;   // 16 kHz
constexpr int64_t kChunk = kRate * 60 * 10;  // transcribe 10 minutes at a time
constexpr int64_t kSplitSearch = kRate * 10; // look back up to 10 s for a pause
constexpr int kFrame = kRate / 5;            // 200 ms energy window
constexpr int kHop = kRate / 20;             // 50 ms hop

// Progress is reported in permille: decoding 0-100, transcription 100-1000.
constexpr int kDecodeShare = 100;

struct Job {
    std::atomic<int> progress{0};
    std::atomic<bool> cancel{false};
};

// --- JSON helpers -----------------------------------------------------------

void json_str(std::string &out, const char *s) {
    out += '"';
    for (const unsigned char *p = (const unsigned char *)s; *p; ++p) {
        switch (*p) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (*p < 0x20) {
                    char buf[8];
                    snprintf(buf, sizeof buf, "\\u%04x", *p);
                    out += buf;
                } else {
                    out += (char)*p;
                }
        }
    }
    out += '"';
}

char *json_error(const std::string &msg) {
    std::string out = "{\"error\":";
    json_str(out, msg.c_str());
    out += '}';
    return strdup(out.c_str());
}

// --- decoding ---------------------------------------------------------------

// Downmixes to mono, resamples (linear) to 16 kHz and writes 16-bit PCM.
class PcmWriter {
public:
    explicit PcmWriter(FILE *f) : f_(f) {}

    void set_input(int rate, int channels) {
        if (rate > 0) ratio_ = (double)rate / kRate;
        if (channels > 0) channels_ = channels;
    }

    void push(const float *interleaved, size_t frames) {
        mono_.resize(frames);
        for (size_t i = 0; i < frames; ++i) {
            float s = 0;
            for (int c = 0; c < channels_; ++c) s += interleaved[i * channels_ + c];
            mono_[i] = s / channels_;
        }
        resample(mono_.data(), frames);
    }

    bool finish() {
        flush();
        return ferror(f_) == 0;
    }

    int64_t written() const { return written_; }
    int channels() const { return channels_; }

private:
    void resample(const float *x, size_t n) {
        if (n == 0) return;
        // Virtual input: prev_ at index -1, then x[0..n-1].
        while (pos_ < (double)n - 1.0) {
            const long i = (long)std::floor(pos_);
            const double frac = pos_ - i;
            const float a = i < 0 ? prev_ : x[i];
            const float b = x[i + 1];
            emit(a + (float)((b - a) * frac));
            pos_ += ratio_;
        }
        pos_ -= (double)n;
        prev_ = x[n - 1];
    }

    void emit(float v) {
        v = std::max(-1.0f, std::min(1.0f, v));
        buf_.push_back((int16_t)std::lrint(v * 32767.0f));
        if (buf_.size() >= 16384) flush();
    }

    void flush() {
        if (buf_.empty()) return;
        fwrite(buf_.data(), sizeof(int16_t), buf_.size(), f_);
        written_ += (int64_t)buf_.size();
        buf_.clear();
    }

    FILE *f_;
    double ratio_ = 1.0;
    int channels_ = 1;
    double pos_ = 0;
    float prev_ = 0;
    std::vector<float> mono_;
    std::vector<int16_t> buf_;
    int64_t written_ = 0;
};

constexpr int32_t kPcm16 = 2;   // AudioFormat.ENCODING_PCM_16BIT
constexpr int32_t kPcmFloat = 4; // AudioFormat.ENCODING_PCM_FLOAT

void read_output_format(AMediaFormat *fmt, PcmWriter &w, int32_t &encoding) {
    int32_t rate = 0, channels = 0, enc = 0;
    AMediaFormat_getInt32(fmt, AMEDIAFORMAT_KEY_SAMPLE_RATE, &rate);
    AMediaFormat_getInt32(fmt, AMEDIAFORMAT_KEY_CHANNEL_COUNT, &channels);
    if (AMediaFormat_getInt32(fmt, "pcm-encoding", &enc)) encoding = enc;
    w.set_input(rate, channels);
}

// Decodes the first audio track of `path` into `pcm_path`. Returns the
// number of 16 kHz samples written, or -1 with `err` set.
int64_t decode_to_pcm(const char *path, const char *pcm_path, Job *job, std::string &err) {
    const int fd = open(path, O_RDONLY);
    if (fd < 0) {
        err = "Cannot open the audio file.";
        return -1;
    }
    struct stat st{};
    fstat(fd, &st);

    AMediaExtractor *ex = AMediaExtractor_new();
    AMediaCodec *codec = nullptr;
    FILE *out = nullptr;
    int64_t result = -1;

    do {
        if (AMediaExtractor_setDataSourceFd(ex, fd, 0, st.st_size) != AMEDIA_OK) {
            err = "Unsupported or damaged audio file.";
            break;
        }
        AMediaFormat *fmt = nullptr;
        const char *mime = nullptr;
        const size_t tracks = AMediaExtractor_getTrackCount(ex);
        for (size_t i = 0; i < tracks; ++i) {
            AMediaFormat *f = AMediaExtractor_getTrackFormat(ex, i);
            const char *m = nullptr;
            if (AMediaFormat_getString(f, AMEDIAFORMAT_KEY_MIME, &m) && strncmp(m, "audio/", 6) == 0) {
                AMediaExtractor_selectTrack(ex, i);
                fmt = f;
                mime = m;
                break;
            }
            AMediaFormat_delete(f);
        }
        if (!fmt) {
            err = "The file has no audio track.";
            break;
        }

        int64_t duration_us = 0;
        AMediaFormat_getInt64(fmt, AMEDIAFORMAT_KEY_DURATION, &duration_us);

        codec = AMediaCodec_createDecoderByType(mime);
        if (!codec || AMediaCodec_configure(codec, fmt, nullptr, nullptr, 0) != AMEDIA_OK ||
            AMediaCodec_start(codec) != AMEDIA_OK) {
            err = std::string("No decoder for ") + mime + ".";
            AMediaFormat_delete(fmt);
            break;
        }

        out = fopen(pcm_path, "wb");
        if (!out) {
            err = "Cannot write the temporary audio file.";
            AMediaFormat_delete(fmt);
            break;
        }

        PcmWriter writer(out);
        int32_t encoding = kPcm16;
        read_output_format(fmt, writer, encoding);
        AMediaFormat_delete(fmt);

        std::vector<float> samples;
        bool input_done = false, output_done = false, failed = false;
        int idle = 0;
        while (!output_done && !failed) {
            if (job->cancel.load()) {
                err = "cancelled";
                failed = true;
                break;
            }
            if (!input_done) {
                const ssize_t ib = AMediaCodec_dequeueInputBuffer(codec, 10000);
                if (ib >= 0) {
                    size_t cap = 0;
                    uint8_t *buf = AMediaCodec_getInputBuffer(codec, ib, &cap);
                    const ssize_t n = AMediaExtractor_readSampleData(ex, buf, cap);
                    if (n < 0) {
                        AMediaCodec_queueInputBuffer(codec, ib, 0, 0, 0,
                                                     AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
                        input_done = true;
                    } else {
                        const int64_t pts = AMediaExtractor_getSampleTime(ex);
                        AMediaCodec_queueInputBuffer(codec, ib, 0, n, pts, 0);
                        AMediaExtractor_advance(ex);
                        if (duration_us > 0) {
                            job->progress = (int)std::min<int64_t>(
                                kDecodeShare, kDecodeShare * pts / duration_us);
                        }
                    }
                }
            }

            AMediaCodecBufferInfo info;
            const ssize_t ob = AMediaCodec_dequeueOutputBuffer(codec, &info, 10000);
            if (ob >= 0) {
                idle = 0;
                size_t size = 0;
                uint8_t *data = AMediaCodec_getOutputBuffer(codec, ob, &size);
                if (data && info.size > 0) {
                    const uint8_t *p = data + info.offset;
                    const int ch = writer.channels();
                    if (encoding == kPcmFloat) {
                        writer.push((const float *)p, info.size / sizeof(float) / ch);
                    } else {
                        const size_t n = info.size / sizeof(int16_t);
                        samples.resize(n);
                        const int16_t *s = (const int16_t *)p;
                        for (size_t i = 0; i < n; ++i) samples[i] = s[i] / 32768.0f;
                        writer.push(samples.data(), n / ch);
                    }
                }
                AMediaCodec_releaseOutputBuffer(codec, ob, false);
                if (info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM) output_done = true;
            } else if (ob == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
                AMediaFormat *of = AMediaCodec_getOutputFormat(codec);
                read_output_format(of, writer, encoding);
                AMediaFormat_delete(of);
            } else if (ob == AMEDIACODEC_INFO_TRY_AGAIN_LATER && input_done) {
                // Some decoders never flag EOS on output; give up after ~3 s idle.
                if (++idle > 300) output_done = true;
            }
        }

        if (!writer.finish() && !failed) {
            err = "Cannot write the temporary audio file (storage full?).";
            failed = true;
        }
        if (!failed) result = writer.written();
    } while (false);

    if (out) fclose(out);
    if (codec) {
        AMediaCodec_stop(codec);
        AMediaCodec_delete(codec);
    }
    AMediaExtractor_delete(ex);
    close(fd);
    return result;
}

// --- transcription ----------------------------------------------------------

// Picks the quietest 200 ms in the last 10 s of `buf` as the chunk boundary
// so chunked transcription doesn't cut words in half.
size_t quiet_split(const std::vector<float> &buf, size_t n) {
    const size_t from = n > (size_t)kSplitSearch ? n - kSplitSearch : 0;
    size_t best = n;
    double best_energy = std::numeric_limits<double>::max();
    for (size_t s = from; s + kFrame <= n; s += kHop) {
        double e = 0;
        for (size_t k = 0; k < (size_t)kFrame; ++k) e += (double)buf[s + k] * buf[s + k];
        if (e < best_energy) {
            best_energy = e;
            best = s + kFrame / 2;
        }
    }
    return best;
}

struct ProgressCtx {
    Job *job;
    int base;
    int span;
};

void on_progress(whisper_context *, whisper_state *, int p, void *user) {
    auto *c = (ProgressCtx *)user;
    c->job->progress = c->base + c->span * p / 100;
}

bool on_abort(void *user) { return ((Job *)user)->cancel.load(); }

// Appends `,"words":[[start,end,"text"],...]` for segment `seg`. Tokens that
// begin with a space start a new word; punctuation sticks to its word.
// Speaker recognition uses these to split a segment where the voice changes.
void append_words(std::string &out, whisper_context *ctx, int seg, double offset) {
    const whisper_token eot = whisper_token_eot(ctx);
    out += ",\"words\":[";
    std::string word;
    double w0 = -1, w1 = 0;
    bool first = true;
    auto flush = [&] {
        const size_t b = word.find_first_not_of(' ');
        if (b != std::string::npos && w0 >= 0) {
            char t[64];
            snprintf(t, sizeof t, "%s[%.2f,%.2f,", first ? "" : ",", w0, w1);
            out += t;
            json_str(out, word.c_str() + b);
            out += ']';
            first = false;
        }
        word.clear();
        w0 = -1;
    };
    const int n = whisper_full_n_tokens(ctx, seg);
    for (int j = 0; j < n; ++j) {
        const whisper_token_data td = whisper_full_get_token_data(ctx, seg, j);
        if (td.id >= eot) continue; // special and timestamp tokens
        const char *txt = whisper_full_get_token_text(ctx, seg, j);
        if (!txt || !*txt) continue;
        if (txt[0] == ' ' && !word.empty()) flush();
        if (w0 < 0) w0 = offset + td.t0 / 100.0;
        w1 = offset + td.t1 / 100.0;
        word += txt;
    }
    flush();
    out += ']';
}

void on_log(ggml_log_level level, const char *text, void *) {
    if (level == GGML_LOG_LEVEL_ERROR) {
        LOGE("%s", text);
    } else if (level == GGML_LOG_LEVEL_WARN || level == GGML_LOG_LEVEL_INFO) {
        LOGI("%s", text);
    }
}

std::once_flag g_log_once;

} // namespace

LS_API void *ls_job_new() { return new Job(); }
LS_API int ls_job_progress(void *job) { return ((Job *)job)->progress.load(); }
LS_API void ls_job_cancel(void *job) { ((Job *)job)->cancel = true; }
LS_API int ls_job_cancelled(void *job) { return ((Job *)job)->cancel.load() ? 1 : 0; }
LS_API void ls_job_set_progress(void *job, int permille) {
    ((Job *)job)->progress = std::max(0, std::min(1000, permille));
}
LS_API void ls_job_free(void *job) { delete (Job *)job; }
LS_API void ls_free_string(char *s) { free(s); }
LS_API const char *ls_system_info() { return whisper_print_system_info(); }

// Decodes `audio_path` to 16 kHz mono 16-bit PCM in `pcm_path` (kept for the
// caller to read and delete). Progress goes 0-100 permille. Returns
// {"samples":N} or {"error":"…"}; free with ls_free_string.
LS_API char *ls_decode(const char *audio_path, const char *pcm_path, void *job_ptr) {
    Job local;
    Job *job = job_ptr ? (Job *)job_ptr : &local;
    std::string err;
    const int64_t total = decode_to_pcm(audio_path, pcm_path, job, err);
    if (total < 0) {
        unlink(pcm_path);
        return json_error(err);
    }
    char buf[48];
    snprintf(buf, sizeof buf, "{\"samples\":%lld}", (long long)total);
    return strdup(buf);
}

// Transcribes `audio_path` with the GGML model at `model_path`. `pcm_path` is a
// scratch file for the decoded audio (deleted afterwards). `language` is an
// ISO code or "auto". Returns a malloc'd JSON string, free with ls_free_string:
//   {"language":"en","segments":[{"start":0.0,"end":2.5,"text":"…",
//                                 "words":[[0.0,0.4,"Hello"],…]}]}
// or {"error":"…"} ("cancelled" after ls_job_cancel).
LS_API char *ls_transcribe(const char *model_path, const char *audio_path, const char *pcm_path,
                           const char *language, int n_threads, void *job_ptr) {
    std::call_once(g_log_once, [] { whisper_log_set(on_log, nullptr); });

    Job local;
    Job *job = job_ptr ? (Job *)job_ptr : &local;
    std::string err;

    const int64_t total = decode_to_pcm(audio_path, pcm_path, job, err);
    if (total < 0) {
        unlink(pcm_path);
        return json_error(err);
    }
    if (total < kRate / 2) {
        unlink(pcm_path);
        return strdup("{\"language\":null,\"segments\":[]}");
    }
    LOGI("decoded %.1f s of audio", (double)total / kRate);

    whisper_context_params cparams = whisper_context_default_params();
    cparams.use_gpu = false;
    whisper_context *ctx = whisper_init_from_file_with_params(model_path, cparams);
    if (!ctx) {
        unlink(pcm_path);
        return json_error("Could not load the whisper model. Try downloading it again.");
    }

    FILE *f = fopen(pcm_path, "rb");
    std::string lang = (language && *language) ? language : "auto";
    std::string out = "{\"segments\":[";
    bool first = true;
    std::vector<int16_t> raw;
    std::vector<float> buf;
    int64_t pos = 0;
    bool ok = f != nullptr;

    while (ok && pos < total) {
        const size_t n = (size_t)std::min(kChunk, total - pos);
        raw.resize(n);
        buf.resize(n);
        if (fseeko(f, (off_t)pos * (off_t)sizeof(int16_t), SEEK_SET) != 0 ||
            fread(raw.data(), sizeof(int16_t), n, f) != n) {
            ok = false;
            break;
        }
        for (size_t i = 0; i < n; ++i) buf[i] = raw[i] / 32768.0f;
        const size_t use = (pos + (int64_t)n < total) ? quiet_split(buf, n) : n;

        whisper_full_params wp = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
        wp.n_threads = n_threads > 0 ? n_threads : 4;
        wp.language = lang.c_str();
        wp.translate = false;
        wp.print_progress = false;
        wp.print_realtime = false;
        wp.print_timestamps = false;
        wp.print_special = false;
        wp.token_timestamps = true;

        ProgressCtx pc{job, kDecodeShare + (int)((1000 - kDecodeShare) * pos / total),
                       (int)((1000 - kDecodeShare) * (int64_t)use / total)};
        wp.progress_callback = on_progress;
        wp.progress_callback_user_data = &pc;
        wp.abort_callback = on_abort;
        wp.abort_callback_user_data = job;

        if (whisper_full(ctx, wp, buf.data(), (int)use) != 0) {
            ok = false;
            break;
        }
        if (lang == "auto") {
            // Keep later chunks in the language detected for the first one.
            const char *detected = whisper_lang_str(whisper_full_lang_id(ctx));
            if (detected) lang = detected;
        }

        const double offset = (double)pos / kRate;
        const int segments = whisper_full_n_segments(ctx);
        for (int i = 0; i < segments; ++i) {
            char times[64];
            snprintf(times, sizeof times, "{\"start\":%.2f,\"end\":%.2f,\"text\":",
                     offset + whisper_full_get_segment_t0(ctx, i) / 100.0,
                     offset + whisper_full_get_segment_t1(ctx, i) / 100.0);
            if (!first) out += ',';
            first = false;
            out += times;
            json_str(out, whisper_full_get_segment_text(ctx, i));
            append_words(out, ctx, i, offset);
            out += '}';
        }
        pos += (int64_t)use;
    }

    if (f) fclose(f);
    unlink(pcm_path);
    whisper_free(ctx);

    if (!ok) return json_error(job->cancel.load() ? "cancelled" : "Transcription failed.");

    out += "],\"language\":";
    if (lang == "auto") {
        out += "null";
    } else {
        json_str(out, lang.c_str());
    }
    out += '}';
    job->progress = 1000;
    return strdup(out.c_str());
}
