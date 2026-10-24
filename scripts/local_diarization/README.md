# Optional Python speaker separation prototype

**The app now uses native FluidAudio/Core ML speaker separation.** Use Recording → Speech glossary & setup → Download speaker model. No Python or Hugging Face account is needed for that path. The instructions below describe the retained command-line prototype only; it is not launched by the app.

This optional worker runs **pyannote Community-1 on CPU locally**, alongside Apple's on-device transcription. It does not use pyannote's hosted API, send recordings to a server, identify people by name, or remember voiceprints across consultations. Model/runtime installation needs internet; normal processing uses local files with Hugging Face offline mode and telemetry disabled.

## One-time setup (user action)

Use a Python 3.11 or 3.12 installation and an environment accessible to the app. The worker reads the app’s PCM CAF/WAV files through SoundFile and supplies waveform input to pyannote, so this path does not require a separate FFmpeg installation. A virtual environment alone may reference Python frameworks or libraries outside the selected directory: these paths may be denied by the app sandbox. A self-contained signed helper/runtime is required for a distributable build; **do not turn off the sandbox to work around this**.

From the repository root, for example:

```sh
python3.11 -m venv .venv-pyannote
.venv-pyannote/bin/python3 -m pip install 'pyannote.audio>=4,<5' huggingface_hub soundfile
.venv-pyannote/bin/hf auth login
```

Open https://huggingface.co/pyannote/speaker-diarization-community-1 and accept the model conditions yourself. The model is CC-BY-4.0; keep the downloaded license/attribution. Login credentials are used only for installation, never passed by the app to the worker.

```sh
.venv-pyannote/bin/hf download pyannote/speaker-diarization-community-1 --local-dir models/community-1
```

In GP settings, select the Python environment folder and the downloaded model folder containing `config.yaml`. The app bundles `diarize.py`. If testing from a terminal first:

```sh
.venv-pyannote/bin/python3 -I scripts/local_diarization/diarize.py --audio /absolute/path/to/synthetic-test.wav --model "$PWD/models/community-1"
```

Use synthetic audio with two real voices for validation. The output is JSON with `schemaVersion: 1` and an `intervals` array. Each interval has `startSeconds`, `endSeconds`, and anonymous `speakerID`. Test with networking unavailable after installation; missing weights must fail rather than download. CPU inference may take longer than the recording; the app limits each attempt to five minutes by default.

## Integration and behavior

- Swift launches a selected executable directly; it never invokes a shell. Worker stdout/stderr are temporary files capped at 2 MB and removed after completion.
- Cancellation stops the subprocess. A timeout or invalid result leaves the saved transcript/audio available for retry or explicit transcript-only completion.
- Overlapping speech is preserved. Timestamp matching assigns a speaker only if a single speaker covers at least 60% of a transcript segment and no competing speaker intersects it; otherwise it remains unassigned.
- The GP must map anonymous speakers to Doctor/Patient/Other and correct wrong turn assignments. Similar voices, interruptions, one person acting both roles, and distant microphones can produce errors.
- Run both transcription and speaker processing before deleting audio. No automatic gender/role inference, cross-visit identification, or persistent speaker embeddings.
- The app sandbox remains enabled. A successful terminal probe does not establish that the same external Python environment can run inside the sandbox; test the packaged app and report this separately.

## Validation status

Protocol validation, conservative alignment, missing-runtime handling, and cancellation have automated tests. Actual Community-1 inference and sandboxed external-Python startup require the model download and a suitable local runtime; they must not be reported as verified until tested on the intended Mac.

References: https://github.com/pyannote/pyannote-audio and https://huggingface.co/pyannote/speaker-diarization-community-1
