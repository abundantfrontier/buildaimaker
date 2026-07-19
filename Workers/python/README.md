# Managed Python training runtime (spike)

This directory owns the **lockfile** and **entry modules** for the LLM (and later voice) managed environment.

## Layout

| Path | Role |
|------|------|
| `requirements.txt` | Loose constraints for humans |
| `requirements.lock` | Exact pins used for install + integrity hash |
| `runtime-pins.json` | L2 integrity pins (lock + entry hashes) |
| `runtime-pins.schema.json` | JSON Schema for `runtime-pins.json` |
| `llm_worker/main.py` | Python entry for `bam-llm-worker` |

## Size budget

| Scenario | Expected download | Notes |
|----------|-------------------|-------|
| LLM-only (mlx + mlx-lm + deps) | **~3–5 GB** | Apple Silicon wheels |
| LLM + voice stack (future) | **~5–8 GB** | Adds PyTorch MPS / F5-TTS class deps |
| CI | **0 GB** | Never install multi-GB wheels in CI |

Progress UI must show estimated size and bytes transferred (Settings → Install training runtime).

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
