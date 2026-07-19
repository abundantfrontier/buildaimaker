# Managed Python training runtime (spike)

This directory owns the **lockfile** and **entry modules** for the LLM and voice managed environment.

## Layout

| Path | Role |
|------|------|
| `requirements.txt` | Loose constraints for humans |
| `requirements.lock` | Exact pins used for install + integrity hash |
| `runtime-pins.json` | L2 integrity pins (lock + entry hashes) |
| `runtime-pins.schema.json` | JSON Schema for `runtime-pins.json` |
| `llm_worker/main.py` | Python entry for `bam-llm-worker` |
| `voice_worker/main.py` | Python entry for `bam-voice-worker` + stub clone CLI |

## Size budget

| Scenario | Expected download | Notes |
|----------|-------------------|-------|
| LLM-only (mlx + mlx-lm + deps) | **~3–5 GB** | Apple Silicon wheels |
| LLM + voice stack (F5-TTS) | **~5–8 GB** | Adds PyTorch MPS / F5-TTS class deps |
| CI | **0 GB** | Never install multi-GB wheels in CI |

Progress UI must show estimated size and bytes transferred (Settings → Install training runtime).

## Voice stub CLI (CI-safe)

No torch / F5-TTS download — copies a reference WAV and writes `profile.json`:

```bash
python -m voice_worker clone \
  --ref-wav /path/to/ref-15s.wav \
  --out-dir "$HOME/Library/Application Support/BuildAIMaker/voices/<id>" \
  --engine-id f5-tts
```

XTTS is rejected (`BAM_LICENSE_BLOCK`). See `Docs/adr/0002-voice-engine.md`.

## Two-layer trust (summary)

1. **L1** — UI/supervisor spawns only `Contents/Helpers/bam-*-worker` after TeamID `SecCode` match (dev-signed OK in debug).
2. **L2** — Helper verifies `runtime-pins.json` (lockfile hash, interpreter under managed env, entry module hashes), then execs managed Python.

Never TeamID-check CPython or venv dylibs. Fail closed with `BAM_RUNTIME_INTEGRITY`.

## Notarization

Wheels install **post-app-install** under Application Support (`envs/python/<appVersion>/`), not inside the notarized `.app` bundle. See `Docs/adr/0001-llm-runtime.md`.

## Install (user machine only)

```bash
# Example — not run in CI
python3.12 -m venv "$HOME/Library/Application Support/BuildAIMaker/envs/python/0.1.0"
source .../bin/activate
pip install -r requirements.lock
```

Regenerate pin hashes after changing lock or entry modules (helper / build step will automate later).

## LoRA train (PR-LLM-LoRA)

`llm_worker/main.py` speaks Runner Protocol v1 (`hello` → `prepare` → `run`) and writes:

```
jobs/<id>/artifacts/adapter/
  adapter_config.json
  adapters.safetensors
  metrics.json
  model_card.md          # K25: hold-out loss + sample generations
```

The app then publishes a copy under `models/adapters/<artifactId>/`.

### Fake train (CI / no wheels)

Forced when any of:

| Signal | Meaning |
|--------|---------|
| `BAM_LORA_FAKE=1` | Explicit fake |
| `mlx_lm` import fails | Package not installed |
| Swift helper `CI` / `BAM_SKIP_INTERPRETER_CHECK` without real override | Dogfood CI path |

Fake train emits synthetic progress and writes a **stub** adapter + model card (same layout as real).

### Real mlx-lm train

When the managed env has `mlx-lm` and fake is not forced:

```bash
# Documented CLI shape (exact flags depend on the pinned mlx-lm version):
python -m mlx_lm lora \
  --model "$BASE_MODEL_PATH" \
  --train \
  --data "$DATA_DIR" \
  --adapter-path "$JOB_DIR/artifacts/adapter" \
  --batch-size 1 \
  --iters 100
```

The Python worker prefers an in-process `mlx_lm.lora` train helper when present, otherwise shells out to the module CLI above. Set `BAM_LORA_REAL=1` and leave `BAM_LORA_FAKE` unset to prefer the real path from the Swift helper when a managed interpreter exists.

### Env vars

| Var | Role |
|-----|------|
| `BAM_LORA_FAKE=1` | Force stub train |
| `BAM_LORA_REAL=1` | Prefer managed Python + mlx-lm (helper) |
| `BAM_PYTHON_BIN` | Override interpreter path |
| `BAM_PYTHON_PINS_ROOT` | Pins / entry module root |
| `BAM_SKIP_INTERPRETER_CHECK=1` | CI: skip managed env interpreter presence check |
