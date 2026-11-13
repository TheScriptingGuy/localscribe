// LocalScribe native layer: decodes any audio file Android can play (NDK
// MediaCodec) to 16 kHz mono PCM and transcribes it with whisper.cpp. The
// decoder is also exposed on its own for speaker recognition (sherpa-onnx).
// Exposed as a small C API for Dart FFI; see lib/localscribe_native.dart.

#include <android/log.h>
#include <media/NdkMediaCodec.h>
#include <media/NdkMediaExtractor.h>
#include <media/NdkMediaFormat.h>
#include <cerrno>
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
#include <numeric>
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
constexpr int64_t kShortTurn = kRate * 3;    // too short to detect a language

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
    double rms() const { return written_ ? std::sqrt(sumSq_ / (double)written_) : 0.0; }
    int16_t peak() const { return peak_; }

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
        const int16_t s = (int16_t)std::lrint(v * 32767.0f);
        buf_.push_back(s);
        sumSq_ += (double)s * (double)s;
        const int16_t a = (int16_t)std::abs((int)s);
        if (a > peak_) peak_ = a;
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
    double sumSq_ = 0;
    int16_t peak_ = 0;
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

// TEMP DEBUG: dumps the raw 16 kHz mono PCM whisper actually consumes to a
// WAV file under /sdcard/Download so it can be pulled and listened to.
// Remove once the whisper mis-transcription is diagnosed.
void debug_dump_wav(const char *pcm_path, int64_t samples) {
    FILE *in = fopen(pcm_path, "rb");
    if (!in) return;
    // App's own external-files dir needs no permission (scoped storage) and
    // is reachable via `adb pull` even though the app itself isn't debuggable.
    FILE *out = fopen(
        "/storage/emulated/0/Android/data/ai.localscribe.localscribe/files/ls_whisper_debug.wav",
        "wb");
    if (!out) { fclose(in); LOGE("debug_dump_wav: fopen failed: %s", strerror(errno)); return; }
    const int32_t byteRate = kRate * 2;
    const int16_t blockAlign = 2;
    const int32_t dataSize = (int32_t)(samples * 2);
    const int32_t riffSize = 36 + dataSize;
    fwrite("RIFF", 1, 4, out);
    fwrite(&riffSize, 4, 1, out);
    fwrite("WAVE", 1, 4, out);
    fwrite("fmt ", 1, 4, out);
    int32_t fmtSize = 16; fwrite(&fmtSize, 4, 1, out);
    int16_t audioFormat = 1; fwrite(&audioFormat, 2, 1, out);
    int16_t numChannels = 1; fwrite(&numChannels, 2, 1, out);
    int32_t sampleRate = kRate; fwrite(&sampleRate, 4, 1, out);
    fwrite(&byteRate, 4, 1, out);
    fwrite(&blockAlign, 2, 1, out);
    int16_t bitsPerSample = 16; fwrite(&bitsPerSample, 2, 1, out);
    fwrite("data", 1, 4, out);
    fwrite(&dataSize, 4, 1, out);
    char buf[16384];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, in)) > 0) fwrite(buf, 1, n, out);
    fclose(in);
    fclose(out);
    LOGI("debug_dump_wav: wrote %lld samples to /sdcard/Download/ls_whisper_debug.wav",
         (long long)samples);
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
        if (!failed) {
            result = writer.written();
            LOGI("decoded pcm: %lld samples (%.2fs @16kHz), rms=%.1f peak=%d",
                 (long long)result, result / 16000.0, writer.rms(), writer.peak());
        }
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

// A stretch of the decoded audio to transcribe, in samples.
struct Span {
    int64_t from, to;
    int speaker;       // -1 when unknown
    std::string lang;  // in: ISO code or "auto"; out: the language used
    std::string json;  // out: comma-separated segment objects
};

// Transcribes samples [s.from, s.to) of the PCM file in chunks of up to
// kChunk, cut at quiet points. With lang "auto" the first chunk's detected
// language is kept for the rest. Progress covers `work` samples in total, of
// which `done` were finished before this span.
bool transcribe_span(whisper_context *ctx, FILE *f, Span &s, int n_threads, Job *job,
                     int64_t done, int64_t work) {
    std::vector<int16_t> raw;
    std::vector<float> buf;
    int64_t pos = s.from;
    while (pos < s.to) {
        const size_t n = (size_t)std::min(kChunk, s.to - pos);
        raw.resize(n);
        buf.resize(n);
        if (fseeko(f, (off_t)pos * (off_t)sizeof(int16_t), SEEK_SET) != 0 ||
            fread(raw.data(), sizeof(int16_t), n, f) != n) {
            return false;
        }
        for (size_t i = 0; i < n; ++i) buf[i] = raw[i] / 32768.0f;
        const size_t use = (pos + (int64_t)n < s.to) ? quiet_split(buf, n) : n;
        // whisper skips input under 1 s; pad short replies with silence.
        const size_t feed = std::max(use, (size_t)(kRate * 11 / 10));
        buf.resize(use);
        buf.resize(feed, 0.0f);

        whisper_full_params wp = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
        wp.n_threads = n_threads > 0 ? n_threads : 4;
        wp.language = s.lang.c_str();
        wp.translate = false;
        wp.print_progress = false;
        wp.print_realtime = false;
        wp.print_timestamps = false;
        wp.print_special = false;
        wp.token_timestamps = true;

        ProgressCtx pc{job, kDecodeShare + (int)((1000 - kDecodeShare) * (done + pos - s.from) / work),
                       (int)((1000 - kDecodeShare) * (int64_t)use / work)};
        wp.progress_callback = on_progress;
        wp.progress_callback_user_data = &pc;
        wp.abort_callback = on_abort;
        wp.abort_callback_user_data = job;

        if (whisper_full(ctx, wp, buf.data(), (int)feed) != 0) return false;
        if (s.lang == "auto") {
            const char *detected = whisper_lang_str(whisper_full_lang_id(ctx));
            if (detected) s.lang = detected;
        }

        const double offset = (double)pos / kRate;
        const double limit = (double)s.to / kRate;
        const int segments = whisper_full_n_segments(ctx);
        for (int i = 0; i < segments; ++i) {
            char times[64];
            snprintf(times, sizeof times, "{\"start\":%.2f,\"end\":%.2f,\"text\":",
                     offset + whisper_full_get_segment_t0(ctx, i) / 100.0,
                     std::min(limit, offset + whisper_full_get_segment_t1(ctx, i) / 100.0));
            if (!s.json.empty()) s.json += ',';
            s.json += times;
            json_str(s.json, whisper_full_get_segment_text(ctx, i));
            append_words(s.json, ctx, i, offset);
            s.json += '}';
        }
        pos += (int64_t)use;
    }
    return true;
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
//
// With `n_ranges` > 0, only the given stretches are transcribed, each on its
// own so each detects its own language (speaker turns of a mixed-language
// conversation). `ranges` holds n_ranges triples [start s, end s, speaker].
// Turns under 3 s reuse the language their speaker used in longer turns.
// Returns {"pieces":[{"language":"en","segments":[…]},…]}, one per range.
LS_API char *ls_transcribe(const char *model_path, const char *audio_path, const char *pcm_path,
                           const char *language, int n_threads, const float *ranges,
                           int n_ranges, void *job_ptr) {
    std::call_once(g_log_once, [] { whisper_log_set(on_log, nullptr); });

    Job local;
    Job *job = job_ptr ? (Job *)job_ptr : &local;
    std::string err;

    const int64_t total = decode_to_pcm(audio_path, pcm_path, job, err);
    if (total < 0) {
        unlink(pcm_path);
        return json_error(err);
    }
    debug_dump_wav(pcm_path, total);
    const bool pieces = ranges && n_ranges > 0;
    if (!pieces && total < kRate / 2) {
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

    const std::string lang = (language && *language) ? language : "auto";
    std::vector<Span> spans;
    if (pieces) {
        for (int i = 0; i < n_ranges; ++i) {
            const int64_t a = std::max<int64_t>(0, std::llround(ranges[3 * i] * kRate));
            const int64_t b = std::min<int64_t>(total, std::llround(ranges[3 * i + 1] * kRate));
            spans.push_back({std::min(a, total), std::max(a, b), (int)ranges[3 * i + 2], lang, ""});
        }
    } else {
        spans.push_back({0, total, -1, lang, ""});
    }
    int64_t work = 0;
    for (const Span &s : spans) work += s.to - s.from;
    work = std::max<int64_t>(work, 1);

    // Long turns first, so a short reply can reuse its speaker's language.
    std::vector<size_t> order(spans.size());
    std::iota(order.begin(), order.end(), 0);
    std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b) {
        return (spans[a].to - spans[a].from >= kShortTurn) >
               (spans[b].to - spans[b].from >= kShortTurn);
    });
    std::vector<std::string> speaker_lang;

    FILE *f = fopen(pcm_path, "rb");
    bool ok = f != nullptr;
    int64_t done = 0;
    for (size_t k = 0; ok && k < order.size(); ++k) {
        Span &s = spans[order[k]];
        const int64_t len = s.to - s.from;
        if (len < kRate / 5) continue; // nothing to hear
        const bool known = s.speaker >= 0 && s.speaker < (int)speaker_lang.size() &&
                           !speaker_lang[s.speaker].empty();
        if (pieces && s.lang == "auto" && len < kShortTurn && known) {
            s.lang = speaker_lang[s.speaker];
        }
        ok = transcribe_span(ctx, f, s, n_threads, job, done, work);
        done += len;
        if (ok && pieces && len >= kShortTurn && s.speaker >= 0 && s.lang != "auto") {
            if (s.speaker >= (int)speaker_lang.size()) speaker_lang.resize(s.speaker + 1);
            speaker_lang[s.speaker] = s.lang;
        }
    }

    if (f) fclose(f);
    unlink(pcm_path);
    whisper_free(ctx);

    if (!ok) return json_error(job->cancel.load() ? "cancelled" : "Transcription failed.");

    auto append_lang = [](std::string &out, const std::string &l) {
        if (l == "auto") {
            out += "null";
        } else {
            json_str(out, l.c_str());
        }
    };
    std::string out;
    if (pieces) {
        out = "{\"pieces\":[";
        for (size_t i = 0; i < spans.size(); ++i) {
            if (i) out += ',';
            out += "{\"language\":";
            append_lang(out, spans[i].lang);
            out += ",\"segments\":[" + spans[i].json + "]}";
        }
        out += "]}";
    } else {
        out = "{\"segments\":[" + spans[0].json + "],\"language\":";
        append_lang(out, spans[0].lang);
        out += '}';
    }
    job->progress = 1000;
    return strdup(out.c_str());
}
