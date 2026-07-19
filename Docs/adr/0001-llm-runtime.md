# ADR 0001 — Managed Python LLM runtime & two-layer trust

| | |
|---|---|
| Status | Accepted (spike) |
| Date | 2026-07-19 |
| Decision owners | BuildAIMaker engineering |
| Related | K3, K4, K14, K21, K24; PR-PyEnv |

## Context

BuildAIMaker v1 trains LLMs via **Python `mlx-lm`** (pinned) under a **managed venv**, supervised by a thin native helper. Post-install wheels live under Application Support and are **not** part of the notarized app bundle. We need an integrity model that:

1. Keeps notarization tractable (Developer ID on the `.app`, not on every wheel).
2. Prevents the UI process from exec’ing arbitrary `python3` on `$PATH`.
3. Records SPDX for planned pins for paid-distribution compliance (K24 — not legal advice).

## Decision

### Managed environment

| Item | Choice |
|------|--------|
| Location | `~/Library/Application Support/BuildAIMaker/envs/python/<appVersion>/` |
| Lockfile | `Workers/python/requirements.lock` (repo-owned; hashed) |
| Install UX | Settings → **Install training runtime** with multi-GB progress |
| Size budget | **3–8 GB** download (LLM-only ~3–5 GB; +voice later ~5–8 GB) |
| CI | **Never** install multi-GB wheels |

### Notarization (two-layer packaging)

- **Inside notarized `.app`:** SwiftUI app, `Contents/Helpers/bam-*-worker` thin native helpers, embedded `runtime-pins.json` (and optionally pin source artifacts for offline verify).
- **Outside (post-install):** CPython venv + wheels under Application Support.
- Wheels are **not** TeamID-signed and are **not** re-notarized with the app.
- Repair re-downloads from pinned URLs / lockfile after integrity failure.

### Two-layer worker trust (K21)

```text
UI / supervisor
  → L1: SecCode TeamID match on Helpers/bam-*-worker only
      (debug: ad-hoc / dev-signed matching current process OK)
  → helper validates runtime-pins.json          # L2
  → exec managed env bin/python3 -m …         # never system python
```

| Layer | What | How | Not |
|-------|------|-----|-----|
| **L1** | Process entry | `SecCode` TeamID on `Helpers/bam-*-worker` | TeamID on venv / `.so` |
| **L2** | Managed runtime | `runtime-pins.json`: lockfile SHA-256, interpreter under env root, entry module hashes | Trusting `$PATH` python |

On L2 failure → `BAM_RUNTIME_INTEGRITY` and Settings CTA **Repair training runtime**. No silent fallback.

### Pin file

Schema: `Workers/python/runtime-pins.schema.json`  
Example: `Workers/python/runtime-pins.json`

Fields: `version`, `appVersion`, `lockfile{relativePath,sha256}`, `interpreterRelativePath`, `entries[{id,relativePath,sha256}]`, optional `sizeBudgetBytes` / `sizeBudgetLabel`.

### Helper

`Workers/bam-llm-worker` builds the thin native stub that will ship as `Contents/Helpers/bam-llm-worker`. Spike prints JSON `hello` after L2 verify (no real training).

## SPDX inventory (planned pins — spike placeholders)

> **Not legal advice.** Counsel review required before public paid launch (K24). SPDX strings below reflect common upstream declarations for the **placeholder** lock versions; re-verify against the exact wheel/source artifact at ship time.

| Package | Placeholder pin | SPDX (planned) | Role |
|---------|-----------------|----------------|------|
| mlx | 0.22.1 | MIT | MLX runtime |
| mlx-lm | 0.21.5 | MIT | LoRA / LM train & gen |
| mlx-metal | 0.22.1 | MIT | Metal backend |
| numpy | 2.1.3 | BSD-3-Clause | Numerics |
| huggingface-hub | 0.26.5 | Apache-2.0 | Model hub client |
| safetensors | 0.4.5 | Apache-2.0 | Weight I/O |
| sentencepiece | 0.2.0 | Apache-2.0 | Tokenization |
| protobuf | 5.28.3 | BSD-3-Clause | Serialization |
| transformers | 4.46.3 | Apache-2.0 | Tokenizer / model utils |
| tokenizers | 0.20.3 | Apache-2.0 | Fast tokenizers |
| requests | 2.32.3 | Apache-2.0 | HTTP |
| tqdm | 4.67.1 | MPL-2.0 AND MIT | Progress |
| pyyaml | 6.0.2 | MIT | Config |
| certifi | 2024.8.30 | MPL-2.0 | CA bundle |
| urllib3 | 2.2.3 | MIT | HTTP transport |
| jinja2 | 3.1.4 | BSD-3-Clause | Templates |
| typing-extensions | 4.12.2 | PSF-2.0 | Typing |

Voice pins (F5-TTS, etc.) land in a separate ADR after PR-VoiceSpike.

## Consequences

### Positive

- Notarization surface stays the app + thin helpers.
- Integrity is explicit and fail-closed (`BAM_RUNTIME_INTEGRITY`).
- Size budget and progress UX are product requirements, not afterthoughts.
- SPDX table feeds counsel checklist.

### Negative / residual risk

- Same-UID attacker can rewrite Application Support until next pin check; Repair reinstalls from pins (accepted v1 threat model).
- Multi-GB first-run download is required for training.
- Placeholder lock versions must be replaced with real freeze output before production.

## Non-goals (this spike)

- Downloading multi-GB wheels in CI
- Real mlx-lm training
- F5-TTS / voice runtime
- App Store sandbox packaging

## Implementation map

| Artifact | Path |
|----------|------|
| Lock sketch | `Workers/python/requirements.lock` |
| Pins + schema | `Workers/python/runtime-pins.json`, `runtime-pins.schema.json` |
| Entry stub | `Workers/python/llm_worker/main.py` |
| Helper stub | `Workers/bam-llm-worker` |
| Integrity API | `BAMCore.RuntimeIntegrity`, `RuntimePins`, `RuntimePaths` |
| L1 TeamID API | `BAMCore.WorkerTrust` |
| Installer stub | `BAMCore.RuntimeInstaller` |
| Settings CTA | App Settings → Install training runtime |
