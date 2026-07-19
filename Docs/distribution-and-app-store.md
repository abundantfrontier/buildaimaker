# Distribution: Developer ID vs Mac App Store

**Status:** Product guidance (aligns with design K14, K21, K23)  
**Last updated:** 2026-07-19

## Summary

| Channel | Full product (local LoRA + managed Python + voice engines)? | Recommended for v1? |
|---------|--------------------------------------------------------------|---------------------|
| **Direct download** (Developer ID + notarization) | **Yes** | **Yes — primary** |
| **Mac App Store** (full train-in-sandbox) | **No, not as currently designed** | Deferred |
| **Mac App Store “lite”** (personas / chat / import adapters) | **Yes with product split** | Optional Phase N |

Design decision **K14**: ship **Developer ID + notarization** first; App Store later, not v1.

---

## Why App Store is hard for the full product

Mac App Store apps are typically:

1. **Sandboxed** (strict entitlements)
2. **Self-contained and reviewable** (post-install multi-GB ML runtimes draw scrutiny)
3. Limited in **arbitrary subprocess + interpreter** patterns

BuildAIMaker v1 intentionally uses:

| Design choice | Product benefit | Store friction |
|---------------|-----------------|----------------|
| Managed Python under Application Support | Real mlx-lm / F5 on Apple Silicon | Post-install wheels, signing, review |
| Out-of-process helpers (`bam-*-worker`) | Train crashes don’t kill UI | OK if signed helpers only; hard if they exec free-form Python |
| L2 integrity = hash pins (not TeamID on CPython) | Honest packaging for post-install envs | Store prefers a simpler signed binary story |
| User datasets / model folders | Local-first creative workflow | Needs security-scoped bookmarks (doable) |
| Microphone (Talk mode) | Spoken personas | Fine with TCC + usage strings |

**SwiftUI shell, GRDB library, jobs UI, personas, consent** are Store-friendly.  
**Training backend packaging** is what blocks a full-Store SKU today.

---

## What would make Store easier (without rewriting everything)

### Option A — Split SKUs (recommended if Store is desired)

```text
Mac App Store app                          Outside Store (Developer ID)
─────────────────                          ───────────────────────────
Personas, playground, Talk                 Train runtime (Python/MLX/F5)
Import adapters / packs                    Heavy LoRA + voice clone jobs
Foundation Models adapters (optional)      Same protocol / library layout
```

Communication: XPC, localhost with user consent, or file drop of artifacts.  
Fits existing `TrainingRunner` / library layout.

### Option B — Store client + cloud/remote train

Store app orchestrates; training on remote Mac / GPU (after product decisions K22+).  
`RemoteRunner` interface was designed for this later path.

### Option C — Full native train in one App Store binary

Port heavy paths to Swift/MLX/Core ML-only, no post-install CPython.  
Highest cost; see [native-vs-python-backends.md](./native-vs-python-backends.md).

### Option D — Stay Developer ID only for full product

Ship paid app via direct download / license key (K23).  
**Best fit for v1 ML studio.**

---

## Monetization without Store (v1)

- **K23:** paid one-time and/or subscription; **no account** required for local train/play
- Commerce: Stripe/Paddle/license key, or later Store IAP for a lite SKU
- **K24:** OSS license compliance still required for paid redistribution of pinned deps

---

## Checklist if targeting App Store later

- [ ] Define Store SKU scope (inference/personas vs full train)
- [ ] Sandbox entitlements + security-scoped bookmarks for library import
- [ ] Mic usage description for Talk
- [ ] No multi-GB post-install Python as primary path (or isolate to non-Store runtime)
- [ ] Background Assets / entitlement plan if using Apple Foundation Models adapters in production
- [ ] Counsel review of SPDX pins (K24) before public paid launch

---

## Related docs

- [design-buildaimaker.md](./design-buildaimaker.md) — K14, K21–K24  
- [native-vs-python-backends.md](./native-vs-python-backends.md)  
- [adr/0003-apple-foundation-models.md](./adr/0003-apple-foundation-models.md)  
- [adr/0001-llm-runtime.md](./adr/0001-llm-runtime.md)  
