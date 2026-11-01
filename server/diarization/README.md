# Speaker recognition server

A small HTTP service that tells LocalScribe **who spoke when**. Use it to
run speaker recognition on a PC or home server instead of the phone: set
*Options → Speaker recognition → Custom API URL* to `http://<host>:8090`.

The phone still transcribes with whisper (on-device or via your Whisper API).
This server only labels the voices; the app matches its answer to the
transcript.

## Run

```sh
pip install -r requirements.txt
# ffmpeg is needed for compressed audio (the app records .m4a)
python diarize_server.py --port 8090 --api-key choose-a-secret
```

Put the same key in the app's *API key* field. Without `--api-key` anyone
who can reach the port can use the server.

Try it on a file without the app:

```sh
python diarize_server.py --test meeting.m4a [--num-speakers 2]
```

### Backends

| `--backend` | Models | Needs |
| --- | --- | --- |
| `sherpa` (default) | pyannote segmentation 3.0 + WeSpeaker ResNet34-LM (same as the app on-device) | CPU only; models (32 MB) download on first start |
| `pyannote` | pyannote.audio `speaker-diarization-community-1` | `pip install pyannote.audio`, env `HF_TOKEN` with the model's terms accepted on Hugging Face; a GPU makes it fast |

`--threshold` (sherpa, default 0.5): higher merges similar voices into
fewer speakers, lower splits more.

## API

`POST /diarize` — `multipart/form-data`

| field | |
| --- | --- |
| `file` | the audio |
| `num_speakers` | optional; omit or `0` to detect automatically |

Header `Authorization: Bearer <key>` when the server has a key.

```json
{"segments": [{"start": 0.03, "end": 5.89, "speaker": 0},
              {"start": 7.27, "end": 12.47, "speaker": 1}]}
```

`speaker` may be a number or a string; the app only uses it to tell voices
apart. Any service that returns this shape works, so you can also put your
own wrapper around another diarization tool.

`GET /health` → `{"ok": true, "backend": "sherpa-onnx"}`
