"""LocalScribe speaker-recognition server.

A small self-hostable HTTP service that answers "who spoke when" for an audio
file. LocalScribe calls it when Options > Speaker recognition is set to
"API URL", e.g. to run diarization on a home server instead of the phone.

API
---
POST /diarize   (multipart/form-data)
    file          the audio file (any format ffmpeg can read; WAV without ffmpeg)
    num_speakers  optional int; omit or 0 to detect the number automatically
Header `Authorization: Bearer <key>` is required when the server has a key.

200 -> {"segments": [{"start": 0.0, "end": 6.8, "speaker": 0}, ...]}

GET /health -> {"ok": true, "backend": "sherpa-onnx"}

Backends
--------
sherpa-onnx (default): the same models the app uses on-device (pyannote
    segmentation 3.0 + WeSpeaker ResNet34-LM embeddings). CPU only, no account.
pyannote: pyannote.audio's community-1 pipeline. Usually more accurate,
    fast on a GPU. Needs `pip install pyannote.audio` and a Hugging Face token
    with the model's terms accepted (env HF_TOKEN).

Usage
-----
    pip install -r requirements.txt
    python diarize_server.py --port 8090 --api-key change-me
    python diarize_server.py --test meeting.wav        # run once, print JSON

Needs Python 3.10+.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import urllib.request
import wave
from pathlib import Path

import numpy as np

RATE = 16000
MODEL_DIR = Path(os.environ.get("LS_MODEL_DIR", Path(__file__).parent / "models"))
SHERPA_MODELS = {
    "pyannote-segmentation-3.0.onnx": "https://huggingface.co/csukuangfj/"
    "sherpa-onnx-pyannote-segmentation-3-0/resolve/main/model.onnx",
    "wespeaker_en_voxceleb_resnet34_LM.onnx": "https://huggingface.co/csukuangfj/"
    "speaker-embedding-models/resolve/main/wespeaker_en_voxceleb_resnet34_LM.onnx",
}


# --- audio ---------------------------------------------------------------------

def load_audio(path: str) -> np.ndarray:
    """Returns mono float32 samples at 16 kHz."""
    if shutil.which("ffmpeg"):
        out = subprocess.run(
            ["ffmpeg", "-nostdin", "-v", "error", "-i", path, "-ac", "1",
             "-ar", str(RATE), "-f", "f32le", "-"],
            check=True, capture_output=True,
        ).stdout
        return np.frombuffer(out, dtype=np.float32)
    # No ffmpeg: plain PCM WAV only.
    with wave.open(path) as w:
        if w.getsampwidth() != 2:
            raise ValueError("Install ffmpeg to read this file (only 16-bit WAV without it).")
        x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768
        x = x.reshape(-1, w.getnchannels()).mean(axis=1)
        if w.getframerate() != RATE:
            n = int(len(x) * RATE / w.getframerate())
            x = np.interp(np.linspace(0, len(x) - 1, n), np.arange(len(x)), x).astype(np.float32)
        return x


# --- backends ------------------------------------------------------------------

class SherpaBackend:
    name = "sherpa-onnx"

    def __init__(self, threshold: float, threads: int):
        import sherpa_onnx  # noqa: F401  (fail early if missing)

        MODEL_DIR.mkdir(parents=True, exist_ok=True)
        for file, url in SHERPA_MODELS.items():
            target = MODEL_DIR / file
            if not target.exists():
                print(f"Downloading {file} ...", file=sys.stderr)
                urllib.request.urlretrieve(url, target.with_suffix(".part"))
                target.with_suffix(".part").rename(target)
        self.threshold = threshold
        self.threads = threads
        self.lock = threading.Lock()

    def diarize(self, samples: np.ndarray, num_speakers: int) -> list[dict]:
        import sherpa_onnx

        config = sherpa_onnx.OfflineSpeakerDiarizationConfig(
            segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
                pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(
                    model=str(MODEL_DIR / "pyannote-segmentation-3.0.onnx")),
                num_threads=self.threads,
            ),
            embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(
                model=str(MODEL_DIR / "wespeaker_en_voxceleb_resnet34_LM.onnx"),
                num_threads=self.threads,
            ),
            clustering=sherpa_onnx.FastClusteringConfig(
                num_clusters=num_speakers if num_speakers > 0 else -1,
                threshold=self.threshold,
            ),
            min_duration_on=0.3,
            min_duration_off=0.5,
        )
        if not config.validate():
            raise RuntimeError("Invalid sherpa-onnx diarization config")
        with self.lock:  # one job at a time; each uses all threads
            sd = sherpa_onnx.OfflineSpeakerDiarization(config)
            result = sd.process(samples).sort_by_start_time()
        return [{"start": round(r.start, 2), "end": round(r.end, 2), "speaker": r.speaker}
                for r in result]


class PyannoteBackend:
    name = "pyannote"

    def __init__(self):
        import torch
        from pyannote.audio import Pipeline

        token = os.environ.get("HF_TOKEN")
        model = os.environ.get("LS_PYANNOTE_MODEL", "pyannote/speaker-diarization-community-1")
        try:
            self.pipeline = Pipeline.from_pretrained(model, token=token)
        except TypeError:  # pyannote.audio 3.x
            self.pipeline = Pipeline.from_pretrained(model, use_auth_token=token)
        if self.pipeline is None:
            raise RuntimeError(f"Could not load {model}; set HF_TOKEN and accept its terms.")
        if torch.cuda.is_available():
            self.pipeline.to(torch.device("cuda"))
        self.torch = torch
        self.lock = threading.Lock()

    def diarize(self, samples: np.ndarray, num_speakers: int) -> list[dict]:
        audio = {"waveform": self.torch.from_numpy(samples.copy())[None], "sample_rate": RATE}
        kwargs = {"num_speakers": num_speakers} if num_speakers > 0 else {}
        with self.lock:
            out = self.pipeline(audio, **kwargs)
        annotation = getattr(out, "speaker_diarization", out)  # 4.x wraps the result
        labels: dict[str, int] = {}
        segments = []
        for turn, _, label in annotation.itertracks(yield_label=True):
            speaker = labels.setdefault(label, len(labels))
            segments.append({"start": round(turn.start, 2), "end": round(turn.end, 2),
                             "speaker": speaker})
        return sorted(segments, key=lambda s: s["start"])


# --- HTTP ----------------------------------------------------------------------

def build_app(backend, api_key: str | None):
    from fastapi import FastAPI, File, Form, Header, HTTPException, UploadFile

    app = FastAPI(title="LocalScribe speaker recognition")

    @app.get("/health")
    def health():
        return {"ok": True, "backend": backend.name}

    @app.post("/diarize")
    def diarize(file: UploadFile = File(...), num_speakers: int = Form(0),
                authorization: str | None = Header(None)):
        if api_key and authorization != f"Bearer {api_key}":
            raise HTTPException(401, "Invalid or missing API key")
        suffix = Path(file.filename or "audio").suffix
        with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
            shutil.copyfileobj(file.file, tmp)
        try:
            samples = load_audio(tmp.name)
        except Exception as e:  # noqa: BLE001
            raise HTTPException(400, f"Could not read the audio: {e}") from e
        finally:
            os.unlink(tmp.name)
        return {"segments": backend.diarize(samples, max(0, num_speakers))}

    return app


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--backend", choices=["sherpa", "pyannote"], default="sherpa")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8090)
    ap.add_argument("--api-key", default=os.environ.get("LS_API_KEY"),
                    help="require 'Authorization: Bearer <key>' (or env LS_API_KEY)")
    ap.add_argument("--threshold", type=float, default=0.5,
                    help="sherpa clustering threshold; higher = fewer speakers")
    ap.add_argument("--threads", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--num-speakers", type=int, default=0, help="for --test")
    ap.add_argument("--test", metavar="AUDIO", help="diarize one file, print JSON, exit")
    args = ap.parse_args()

    backend = (PyannoteBackend() if args.backend == "pyannote"
               else SherpaBackend(args.threshold, args.threads))
    if args.test:
        print(json.dumps({"segments": backend.diarize(load_audio(args.test), args.num_speakers)},
                         indent=1))
        return

    import uvicorn

    if not args.api_key:
        print("Warning: no --api-key set; anyone who can reach this port can use it.",
              file=sys.stderr)
    uvicorn.run(build_app(backend, args.api_key), host=args.host, port=args.port)


if __name__ == "__main__":
    main()
