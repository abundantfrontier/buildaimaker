# BuildAIMaker documentation

| Document | Purpose |
|----------|---------|
| [design-buildaimaker.md](./design-buildaimaker.md) | System design, PR plan, key decisions (K1–K26) |
| [distribution-and-app-store.md](./distribution-and-app-store.md) | Developer ID vs Mac App Store, monetization, packaging |
| [native-vs-python-backends.md](./native-vs-python-backends.md) | When to keep Python, when to go Swift/native |
| [adr/0001-llm-runtime.md](./adr/0001-llm-runtime.md) | Managed Python + mlx-lm train path |
| [adr/0002-voice-engine.md](./adr/0002-voice-engine.md) | F5-TTS voice clone engine |
| [adr/0003-apple-foundation-models.md](./adr/0003-apple-foundation-models.md) | Apple on-device LLM + LoRA adapters vs open MLX |

## Architecture snapshot

- **UI / domain:** SwiftUI + SPM packages (`BAMCore`, `BAMModels`, …)
- **Training (v1):** signed helpers → managed Python (mlx-lm LoRA, F5-TTS clone)
- **Distribution (v1):** Developer ID + notarization (direct download); App Store deferred
- **Future option:** Apple Foundation Models adapters as an additional backend (not a replacement for open-model train)
