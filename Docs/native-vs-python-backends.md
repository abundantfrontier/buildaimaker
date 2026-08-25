# Native Swift vs managed Python backends

**Status:** Architecture guidance  
**Last updated:** 2026-08-25 — Alpha still uses managed Python for mlx-lm teach/generate and Kokoro; SwiftUI shell is native.

## Summary

You do **not** need to port everything to Swift to ship or sell the product (Developer ID).  
You **may** need native or split packaging if the goal is a **single full-training Mac App Store binary**.

| Goal | Python managed runtime OK? | Full Swift port required? |
|------|----------------------------|---------------------------|
| Local train + voice, direct download | **Yes (v1 design)** | No |
| Mac App Store full train-in-app | Poor fit | Either port **or** drop in-app train |
| Mac App Store personas/chat only | N/A | Not for train; Swift shell enough |
| Smaller install, no “Install runtime” | Helpful | Port or embed fixed binaries |

---

## Current v1 split (by design)

```text
Swift (app process)                    Managed Python (helpers + env)
───────────────────                    ─────────────────────────────
UI, GRDB library, jobs queue           mlx-lm LoRA (LLM train)
Consent, personas, playground shell    F5-TTS (voice clone)
Path jail, L1 helper spawn             Future: other engines
Protocol supervisor (NDJSON)           Worker entry modules
```

- **L1:** only TeamID-signed `Contents/Helpers/bam-*-worker`  
- **L2:** lockfile + entry hashes (`runtime-pins.json`); **not** TeamID on CPython  

See [adr/0001-llm-runtime.md](./adr/0001-llm-runtime.md) and design **K3 / K4 / K21**.

---

## What a “port to native” would mean

| Component today | Native direction | Difficulty | App Store help |
|-----------------|------------------|------------|----------------|
| LLM LoRA (`mlx-lm`) | Swift MLX train / Metal PEFT | **High** | High if no Python |
| LLM inference | Swift MLX / llama.cpp / Core ML | Medium | High |
| Voice clone (F5) | Core ML / MLX-Audio / other Mac stack | **High** | High |
| STT (Talk) | Speech framework / whisper.cpp | Lower | High |
| TTS playback | AVFoundation + engine | Medium | Medium |
| Jobs, datasets, personas, consent | Already Swift | Done | Already good |

Port **inference + STT** first if you want a Store-friendly shell.  
Port **train** only if product requires train *inside* the sandboxed binary.

---

## Decision guide

```text
Need App Store for FULL product including train?
  ├─ Yes → Split SKU (Store shell + external Train runtime)
  │         OR long-term native train port
  │         OR cloud/remote train
  └─ No  → Keep managed Python; optimize UX of runtime install
           (multi-GB accepted per K4 / founder decision)
```

**Do not** rewrite Python “just for purity” while the product is still validating MVP (M1–M8 in the design doc).

---

## Hybrid futures (compatible with architecture)

1. **`TrainingRunner` backends**
   - `MLXPythonRunner` / `LoRATrainService` (v1 open LoRA)
   - `FoundationModelsAdapterRunner` (Apple adapters — toolkit path or stub; in-app Playground load)
   - `RemoteRunner` (post-PMF)
2. **Same library / persona packs**, different materializers  
3. Feature flags: `ff.llmTraining`, `ff.voiceClone`, `ff.foundationModels` (on by default)

---

## Related docs

- [distribution-and-app-store.md](./distribution-and-app-store.md)  
- [adr/0003-apple-foundation-models.md](./adr/0003-apple-foundation-models.md)  
- [design-buildaimaker.md](./design-buildaimaker.md) — Goals / Non-Goals, K3–K5, K17  
