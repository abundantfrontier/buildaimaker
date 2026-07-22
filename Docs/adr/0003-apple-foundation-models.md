# ADR 0003 — Apple Foundation Models & LoRA adapters

**Status:** Accepted (strategy) — **Phase 1 + Phase 2 landed**  
**Date:** 2026-07-19  
**Updated:** 2026-07-21  
**Context:** macOS / Apple Intelligence era APIs for on-device LLMs and developer adapters

### Implementation status

| Phase | Status | Notes |
|-------|--------|--------|
| **Phase 1** | Done | Dual Train backend, export/import/stub, Playground FM adapter filter, `SystemLanguageModel.Adapter(fileURL:)` load |
| **Phase 2** | Done | Toolkit path + CLI train service, `JobModality.foundationAdapter`, `FoundationModelsAdapterRunner`, Composite third arm, signature mismatch warnings, persona pack `foundationAdapter` / `baseModelSignature` / `llm/foundation_adapter/` |
| **Later** | Open | Entitlement packaging, Background Assets CDN, in-queue GRDB artifact upsert, real-time toolkit progress NDJSON |

## Context

Apple ships (and continues to evolve) an **on-device foundation language model** used by Apple Intelligence, exposed to apps via the **Foundation Models** Swift framework. Developers can:

1. **Call** the system on-device model from apps (guided generation, tool calling, etc.).
2. **Load LoRA-style adapters** that specialize that model.
3. **Train adapters** using Apple’s **Adapter Training Toolkit** (Python workflow), packaging them for use with Foundation Models (e.g. `.fmadapter`-style artifacts).

This is **not** the same as open-model fine-tuning with MLX on arbitrary weights (BuildAIMaker v1 primary path).

Official entry points (URLs may move with OS releases):

- [Foundation Models adapter training](https://developer.apple.com/apple-intelligence/foundation-models-adapter/)
- WWDC sessions on the Foundation Models framework
- Apple ML research notes on foundation models and PEFT/LoRA

## Decision

| Layer | Decision |
|-------|----------|
| **v1 primary train path** | Remain **open models + managed Python mlx-lm** (ADR 0001) and **F5-TTS** voice (ADR 0002). |
| **Apple Foundation Models** | Treat as an **optional future backend**, not a replacement for open-model studio features. |
| **Product positioning** | “Train *your* models and personas” (open) **and later** “Specialize Apple’s on-device model for your app/character” (system adapters). |

We will **not** block v1 on Foundation Models availability, entitlements, or OS version churn.

## What Apple provides (product-relevant)

| Capability | Detail |
|------------|--------|
| On-device LLM for apps | System model via Swift Foundation Models API |
| Runtime adapters | Attach LoRA/PEFT-style adapters to the system model |
| Adapter training | Official **toolkit** (Python train → package for OS runtime) |
| Base model choice | **Apple’s** model only (not Qwen/Llama/etc.) |
| Version coupling | Adapters often **tied to a specific system model revision**; OS updates can require **retrain** |
| Production | May require **entitlement**; deployment guidance often favors downloadable assets (e.g. Background Assets), not huge embedded bundles |

## What Apple does **not** provide (vs BuildAIMaker)

- Fine-tuning **arbitrary open base models** in a general studio
- First-class **voice clone / persona pack** composition as a product surface
- A consumer “Install multi-GB open stack and train anything” App Store story (their path is system model + adapters)
- Full control over export/merge of foundation base weights

## Comparison

| | Open MLX path (v1) | Apple Foundation Models path |
|--|--------------------|------------------------------|
| Base model | Catalog (e.g. Qwen2.5 MLX) | System on-device FM |
| Train | In-app jobs → mlx-lm LoRA | Toolkit / external train → `.fmadapter` (or successor) |
| Run | Own infer process / playground | `SystemLanguageModel` + adapter |
| Voice | F5-TTS (etc.) | Separate (Speech / other); not this ADR |
| Store fit | Hard for full train | Better for **run + load adapter** |
| OS updates | You pin tooling | You retrain adapters when base signature changes |

## Implications for BuildAIMaker architecture

1. **Keep `TrainingRunner` / job types extensible**  
   - e.g. future `JobModality` or backend id: `openLora` | `foundationAdapter`
2. **Playground / Talk** can later select:
   - Open base + adapter artifact, **or**
   - System FM + Foundation adapter file
3. **Persona pack format** may gain an optional component:  
   `foundationAdapter` + `baseModelSignature` (in addition to open `lora_adapter`)
4. **App Store lite SKU** could emphasize Foundation Models + imported adapters while full open train stays Developer ID
5. **Docs / UX honesty:** “Fine-tune Apple’s on-device model” ≠ “Fine-tune any Hugging Face model”

## Non-goals for this ADR

- Implementing Foundation Models integration in the current code drop
- Replacing ADR 0001 as the default train path
- Guaranteeing App Store approval solely by using Foundation Models

## Consequences

**Positive**

- Clear story for OS-integrated on-device AI without multi-GB open runtimes  
- Path for Store-friendly specialization of system model  
- Complements (does not obsolete) open-model local studio

**Negative / risks**

- Dual backends increase product complexity  
- Adapter retrain tax on every Apple model update  
- Entitlement and beta signature mismatches (seen in developer forums during OS betas)

## Related

- [distribution-and-app-store.md](../distribution-and-app-store.md)  
- [native-vs-python-backends.md](../native-vs-python-backends.md)  
- [design-buildaimaker.md](../design-buildaimaker.md) — K5, K14, K17, K22  
- ADR 0001 (LLM runtime), ADR 0002 (voice engine)  
