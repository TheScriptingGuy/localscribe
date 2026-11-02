# LocalScribe

A **local-first** voice-recording → transcription → AI-notes app for Android,
inspired by the Plaud Note app's feature set but **talking to no Plaud servers**.
All processing happens either **on-device** or against an **AI API URL you
configure** (OpenAI / Anthropic / Whisper-compatible).

This project is a clean-room **reimplementation from protocol knowledge**, not a
copy of Plaud's code. Interoperability research on the author's own device
informs two things only: the default note **templates** (their section/outline
schemas) and the optional **Plaud BLE device** integration (GATT layout + crypto
construction).

> **Disclaimer — study project, not affiliated with Plaud**
>
> LocalScribe is an independent, non-commercial **study/educational project**.
> It is **not affiliated with, endorsed by, sponsored by, or connected to**
> Plaud Inc. or any of its subsidiaries. "Plaud" and "Plaud Note" are
> trademarks of their respective owners and are used here only to describe
> compatibility (nominative use). This project contains no Plaud source code,
> binaries, assets, or credentials, and it does not connect to Plaud servers.
> Use it only with devices and accounts you own, and at your own risk; it is
> provided "as is" without warranty of any kind (see `LICENSE`).

## What it does

- **Record** from the phone mic, **import** existing audio files, and
  (optionally) capture from a nearby **Plaud Note** recorder over BLE.
- **Transcribe** audio — on-device via `whisper.cpp`, or via a Whisper-compatible
  HTTP API URL.
- **Recognise speakers** (Speaker 1, Speaker 2, … renamable to real names) in
  any language — on-device via `sherpa-onnx`, or via a speaker-recognition
  server you host (`server/diarization/`).
- **Generate AI notes** from a transcript using **templates** (Plaud-style
  defaults + your own), either on-device via `llama.cpp` (GGUF) or via an
  OpenAI-/Anthropic-compatible API URL.
- **Ask-AI chat** grounded in a note's transcript.
- **Options screen** to configure both AI pipelines independently: on-device
  model (with an in-app model downloader) **or** a custom API URL + key + model.

Nothing leaves the device except calls to the exact AI API URL you configure.

## Architecture

```
lib/
  main.dart                      app entry, providers, nav shell
  models/                        plain data (Recording, Note, Template, AiBackend, …)
  settings/                      Settings model + Options UI
  services/
    ai/                          AiBackend abstraction (local | remote)
    transcription/               TranscriptionService: whisper.cpp | remote Whisper URL
    notes/                       NoteAiService: llama.cpp | OpenAI URL | Anthropic URL
    templates/                   bundled + user templates, prompt synthesis
    recording/                   phone-mic capture + file import
    ble/                         Plaud BLE client (RSA handshake + ChaCha20-Poly1305)
    storage/                     local DB (recordings, transcripts, notes)
  ui/                            screens + widgets
assets/templates/*.json          default note templates
packages/localscribe_native/     FFI plugin: whisper.cpp (git submodule) +
                                 NDK MediaCodec audio decoding, built by CMake
server/diarization/              optional self-hosted speaker-recognition API
```

### On-device transcription

`packages/localscribe_native` compiles whisper.cpp (pinned submodule in
`third_party/whisper.cpp`) and a small C++ bridge into `liblocalscribe_native.so`.
The bridge decodes any audio Android can play (m4a/AAC, mp3, wav, ogg/opus,
flac) with the NDK `AMediaCodec` API, resamples to 16 kHz mono into a scratch
file, and transcribes in 10-minute chunks split at the quietest moment, so
memory stays flat for long recordings. Dart calls it from a background isolate.

Models (GGML, multilingual) download in-app from the whisper.cpp project's
Hugging Face repository, resume if interrupted, and are verified by SHA-256.
The arm64 build targets ARMv8.2-A + FP16 (most phones from 2018 on); the app
checks `/proc/cpuinfo` and explains when a phone can't run it.

### Speaker recognition

Optional (Options → Speaker recognition). After whisper produces the text,
a separate step works out **who spoke when** from the voices alone, so it
works for every language whisper supports, mixed-language meetings included:

1. **pyannote segmentation 3.0** finds speech and the points where the voice
   changes;
2. **WeSpeaker ResNet34-LM** turns each stretch into a voice fingerprint;
3. clustering groups the fingerprints into speakers (count detected
   automatically, or set it when you know it).

On-device this runs through [`sherpa-onnx`](https://github.com/k2-fsa/sherpa-onnx);
the two models (32 MB) download in-app like the whisper models. With **Custom
API URL** the app uploads the audio to a server you run instead — see
[`server/diarization/`](server/diarization/) for a ready-made one (same
models on CPU, or pyannote's own pipeline on a GPU) and the small JSON API.

The app then matches the voices to the transcript: whisper's word timings let
it split a sentence exactly where the speaker changes. Tap a speaker label to
name them; picking another speaker's name merges the two. Notes and Ask-AI get
the transcript as `Name: text` lines.

**Mixed-language conversations.** Whisper picks one language per recording,
so in a meeting that switches between, say, English and German it writes
everything in one of them. Set *Spoken language* to **Mixed — detect per
speaker turn**: speakers are then identified first and each turn is
transcribed on its own, in its own language. Turns under 3 s ("Ja.", "OK")
reuse the language their speaker used in longer turns. This costs time when
there are many short turns, since whisper processes at least 30 s of audio
per call. It works on-device and with a Whisper API URL (the phone then
uploads each turn as a small WAV).

Speakers are per recording (Speaker 1 in two recordings may be different
people). Overlapping speech and very short replies are the usual mistakes.

### AI backend model (the core abstraction)

Each pipeline (Transcription, Note AI, Ask-AI) is configured independently as one
of:

| Mode | Transcription | Speaker recognition | Note AI / Ask-AI |
|---|---|---|---|
| **On-device** | `whisper.cpp` (GGML model) | `sherpa-onnx` (pyannote + WeSpeaker) | `llama.cpp` (GGUF model) |
| **Custom API URL** | OpenAI-compatible `/v1/audio/transcriptions` | `POST /diarize` ([server/diarization](server/diarization/)) | OpenAI-compatible `/v1/chat/completions` **or** Anthropic `/v1/messages` |

The OpenAI-compatible option also covers Ollama, LM Studio, llama.cpp `server`,
vLLM, LocalAI, OpenRouter, Groq — just change the base URL.

### Templates → prompts

Plaud ships template **metadata** (name, description, and an `outline` of the
sections to produce); the actual LLM prompt is server-side and never shipped. So
LocalScribe stores the same `outline`/section schema and **synthesizes the LLM
prompt locally** from it (see `services/templates/prompt_builder.dart`). Default
templates live in `assets/templates/`; `meeting_minutes.json` uses the outline
recovered verbatim, the rest are reconstructed from their published descriptions.

## Build (cloud CI)

Pushing to GitHub runs `.github/workflows/build.yml`, which materializes the
Android platform files, builds a release APK, and uploads it as the
**`localscribe-apk`** artifact. Download it from the workflow run's *Artifacts*
section and install on the phone (allow "install unknown apps").

Clone with `--recurse-submodules` (or run `git submodule update --init`) to get
whisper.cpp. To build locally: install Flutter (stable) + Android SDK + NDK, then
`flutter create --platforms=android --org ai.localscribe --project-name localscribe .`
, copy `ci/AndroidManifest.xml` over `android/app/src/main/AndroidManifest.xml`,
and run `flutter build apk --release`.

## Roadmap (phased)

- **Phase 1 ✅ foundation.** Repo + CI, settings, the AI-backend
  abstraction, **working remote (URL) clients** for Whisper / OpenAI / Anthropic,
  bundled templates + local prompt synthesis, storage, and the UI shell.
- **Phase 2 ✅** phone-mic recording (background service) + file import wired to
  the transcribe→note flow, Ask-AI chat.
- **Phase 3 ✅** on-device `whisper.cpp` (FFI + NDK build in CI) + model downloader.
  Speaker recognition on-device (`sherpa-onnx`) or via a self-hosted API.
- **Phase 4:** on-device `llama.cpp` (GGUF) notes + Ask-AI chat.
- **Phase 5:** Plaud BLE live capture (RSA handshake + ChaCha20-Poly1305 + Opus).

### Known risk — BLE pairing vs. "no Plaud servers"

We recovered the BLE crypto/framing, but not proof that a brand-new client can
**pair** without a Plaud cloud-issued device token/license. If the recorder
requires that, Phase 5 will need either a one-time online pairing or reuse of an
existing credential. Designed around, flagged as a discovery item.
