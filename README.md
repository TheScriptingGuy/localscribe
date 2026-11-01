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

### AI backend model (the core abstraction)

Each pipeline (Transcription, Note AI, Ask-AI) is configured independently as one
of:

| Mode | Transcription | Note AI / Ask-AI |
|---|---|---|
| **On-device** | `whisper.cpp` (GGML model) | `llama.cpp` (GGUF model) |
| **Custom API URL** | OpenAI-compatible `/v1/audio/transcriptions` | OpenAI-compatible `/v1/chat/completions` **or** Anthropic `/v1/messages` |

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
- **Phase 4:** on-device `llama.cpp` (GGUF) notes + Ask-AI chat.
- **Phase 5:** Plaud BLE live capture (RSA handshake + ChaCha20-Poly1305 + Opus).

### Known risk — BLE pairing vs. "no Plaud servers"

We recovered the BLE crypto/framing, but not proof that a brand-new client can
**pair** without a Plaud cloud-issued device token/license. If the recorder
requires that, Phase 5 will need either a one-time online pairing or reuse of an
existing credential. Designed around, flagged as a discovery item.
