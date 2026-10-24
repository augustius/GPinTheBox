#!/usr/bin/env python3
"""Local-only Community-1 worker. stdout is a bounded, versioned JSON protocol."""
import argparse
import contextlib
import json
import os
from pathlib import Path
import sys

# Set before importing any model/hub packages. No tokens or hosted services used.
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
os.environ["PYANNOTE_METRICS_ENABLED"] = "0"
for key in ("HF_TOKEN", "HUGGING_FACE_HUB_TOKEN"):
    os.environ.pop(key, None)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", required=True)
    parser.add_argument("--model", required=True)
    args = parser.parse_args()
    model = Path(args.model).resolve(strict=True)
    audio = Path(args.audio).resolve(strict=True)
    if not model.is_dir() or not (model / "config.yaml").is_file() or not audio.is_file():
        raise ValueError("Expected local audio file and complete local model directory")
    # All imports and third-party progress output go to stderr, never the JSON channel.
    with contextlib.redirect_stdout(sys.stderr):
        import soundfile as sf
        import torch
        from pyannote.audio import Pipeline
        from pyannote.audio.telemetry import set_telemetry_metrics
        set_telemetry_metrics(False, save_choice_as_default=False)
        pipeline = Pipeline.from_pretrained(str(model))
        # CPU is the portable baseline; do not assume CUDA or Apple GPU support.
        # The app records PCM CAF. Read it directly rather than relying on a system
        # FFmpeg installation through TorchCodec. pyannote supports waveform input.
        samples, sample_rate = sf.read(str(audio), dtype="float32", always_2d=True)
        if samples.shape[0] == 0:
            raise ValueError("Empty recording")
        waveform = torch.from_numpy(samples.T.copy())
        result = pipeline({"waveform": waveform, "sample_rate": sample_rate})
        annotation = result.speaker_diarization
        # Preserve overlapping intervals; the Swift UI must not fabricate a single speaker.
        intervals = [
            {"startSeconds": float(turn.start), "endSeconds": float(turn.end), "speakerID": str(speaker)}
            for turn, speaker in annotation
        ]
    intervals.sort(key=lambda item: (item["startSeconds"], item["endSeconds"], item["speakerID"]))
    if not intervals or len(intervals) > 20_000:
        raise ValueError("No speech or too many speaker segments")
    payload = json.dumps({"schemaVersion": 1, "intervals": intervals}, allow_nan=False)
    if len(payload.encode("utf-8")) > 2_000_000:
        raise ValueError("Result exceeds output limit")
    print(payload)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Never dump audio text, credentials, environment, or model internals into UI/logs.
        print("Local diarization failed; verify dependencies, model files and audio format.", file=sys.stderr)
        sys.exit(1)
