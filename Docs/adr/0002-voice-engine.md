# ADR 0002 — Voice engine: F5-TTS primary + license audit

| | |
|---|---|
| Status | Accepted (spike). **Alpha 2026-08:** shipping voice is **Kokoro catalog + FX**, not F5. Clone UI hidden; stub runner remains in-tree. |
| Date | 2026-07-19 |
| Decision owners | BuildAIMaker engineering |
| Related | K7, K7b, K11, K21, K24; PR-VoiceSpike; ADR 0001 |

## Context

BuildAIMaker dual-modality requires a **few-shot voice clone** path (seconds–minutes of reference audio) that:

1. Runs under the **managed Python** env already defined in ADR 0001 (post-install wheels, L1/L2 trust).
2. Produces a portable **`voice_profile`** artifact (`profile.json` + `reference.wav` + engine cache) under `voices/<id>/`.
3. Records **SPDX / license risk** for paid redistribution (K24 — not legal advice).
4. Does **not** pull multi-GB wheels or model weights in CI.

Candidate engines were surveyed in the design doc (A8). This ADR freezes the v1 primary pin and non-defaults.

## Decision

### Primary engine

| Item | Choice |
|------|--------|
| Engine id | `f5-tts` |
| Stack | **F5-TTS** via managed Python (PyTorch **MPS** preferred, CPU fallback) |
| Artifact | `engineId` + SHA-256 of reference WAV + engine-specific cache under `voices/<id>/` |
| Job modality | `voiceClone` only in 1.0 (few-shot); `voiceFinetune` reserved, unsupported |
| Worker | `bam-voice-worker` → managed `python -m voice_worker` |
| JobSpec paths | Reference audio **only** on `JobPaths.referenceAudioPath` (never free-form on `JobSpec`) |

### Fallbacks / non-defaults

| Engine | Status | Reason |
|--------|--------|--------|
| MLX-Audio-class | Future fallback when pin-stable | Prefer native MLX later; not primary in this spike |
| **XTTS-v2 (Coqui)** | **Non-default** | **AGPL** viral redistribution risk for a paid/shipped app; not installed by default; not offered in product UI |
| Apple Personal Voice | Out of scope | Not a general character-clone / export path |

XTTS must never be the default engine id. If ever exposed, it requires an explicit advanced opt-in and separate counsel review — **not** part of the default lockfile install.

### Install size budget (documented; not downloaded in CI)

| Scenario | Expected download | Notes |
|----------|-------------------|-------|
| LLM-only (ADR 0001) | **~3–5 GB** | mlx + mlx-lm |
| **LLM + voice (this ADR)** | **~5–8 GB** | Adds PyTorch MPS wheels + F5-TTS + audio deps |
| Voice-only incremental | **~2–4 GB** | On top of an existing LLM env |
| CI | **0 GB** | Never `pip install` multi-GB voice/LLM wheels |

Progress UX (Settings → Install training runtime) must surface the **combined** budget when voice is enabled. Spike helpers and unit tests use **stub clone** only.

### SPDX inventory (planned pins — spike placeholders)

> **Not legal advice.** Counsel review required before public paid launch (K24). Re-verify SPDX against the exact wheel/source/checkpoint artifact at ship time.
>
> **Critical split for F5-TTS:** upstream **code** is commonly declared **MIT**; default **Emilia-trained checkpoints** have been published under **CC-BY-NC-4.0** (non-commercial). A paid product must either (a) use weights with a commercial-compatible license, (b) train/fine-tune on permitted data, or (c) restrict features accordingly. Flag for counsel.

| Package | Placeholder pin | SPDX (planned) | Role |
|---------|-----------------|----------------|------|
| f5-tts | 1.1.1 | MIT (code) | Primary clone / TTS entry |
| F5-TTS Emilia ckpt (default weights) | n/a (HF asset) | **CC-BY-NC-4.0** (typical) | Default pretrained weights — **NC risk** |
| torch | 2.5.1 | BSD-3-Clause | Autograd / MPS runtime |
| torchaudio | 2.5.1 | BSD-3-Clause | Audio I/O |
| numpy | 2.1.3 | BSD-3-Clause | Shared with LLM env |
| scipy | 1.14.1 | BSD-3-Clause | Signal helpers |
| soundfile | 0.12.1 | BSD-3-Clause | WAV read/write |
| librosa | 0.10.2 | ISC | Optional analysis / VAD helpers |
| huggingface-hub | 0.26.5 | Apache-2.0 | Weight download (user-initiated) |
| einops | 0.8.0 | MIT | Tensor ops (F5 graph) |
| tqdm | 4.67.1 | MPL-2.0 AND MIT | Progress |
| PyYAML | 6.0.2 | MIT | Config |

**Explicitly not pinned (non-default):**

| Package | SPDX risk | Policy |
|---------|-----------|--------|
| TTS / coqui-ai-TTS (XTTS-v2) | **AGPL-3.0** | Do not add to default `requirements.lock`; product default remains `f5-tts` |

LLM pins remain in ADR 0001 / the shared lock sketch. Voice pins are additive comments + rows in `Workers/python/requirements.lock`.

### Worker trust (inherits ADR 0001)

```text
UI / supervisor
  → L1: SecCode TeamID on Helpers/bam-voice-worker
  → helper verifies runtime-pins.json          # L2 (lock + voice_worker.main hash)
  → exec managed env bin/python3 -m voice_worker
```

Pin entry id: `voice_worker.main` → `voice_worker/main.py`.

### Stub CLI (this spike)

```bash
# CI-safe: copies ref wav + writes profile.json; no torch/F5 download
python -m voice_worker clone \
  --ref-wav /path/to/ref-15s.wav \
  --out-dir "$LIBRARY/voices/<id>" \
  --engine-id f5-tts
```

Recommended reference clip: **~5–60 s** clean speech; design dogfood uses **~15 s**.

### Consent binding (K11)

Every `voice_profile` **must** store `consentRecordId` + `consentContentHash` when leaving the spike path into product (PR-Consent / PR-Voice-UI). The stub CLI accepts optional consent fields so later PRs can wire them without schema churn.

## Consequences

### Positive

- Clear primary engine id for `JobSpec.engineId` and runner `caps.engineIds`.
- License risk (especially AGPL XTTS and NC weights) is documented before product UI.
- Size budget aligns with ADR 0001 combined 3–8 GB envelope.
- CI stays green without multi-GB downloads via stub clone + helper hello.

### Negative / residual risk

- Default Emilia checkpoints may be **non-commercial**; shipping paid TTS needs counsel + possible alternate weights.
- PyTorch MPS stack increases install size and repair surface.
- Quality/latency of F5-TTS on Apple Silicon must be dogfooded after real pin freeze (post-spike).

## Non-goals (this spike)

- Product Voices UI (`ff.voiceClone` remains off)
- Real F5-TTS inference or multi-GB pip install in CI
- XTTS / Coqui as default or advertised path
- Supervised multi-speaker voice fine-tune (`voiceFinetune`)
- Talk mode STT/TTS product path (PR-Talk)

## Implementation map

| Artifact | Path |
|----------|------|
| ADR | `Docs/adr/0002-voice-engine.md` |
| Lock sketch (+ voice pin comments) | `Workers/python/requirements.lock` |
| Pins | `Workers/python/runtime-pins.json` (`voice_worker.main`) |
| Python entry + stub CLI | `Workers/python/voice_worker/main.py` |
| Helper stub | `Workers/bam-voice-worker` |
| JobPaths materializer stub | `BAMJobs.VoiceCloneMaterializer` |
| Domain fixtures | `BAMModels.DomainFixtures.voiceCloneJobSpec` / `voiceCloneJobPaths` |
