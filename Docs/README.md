# BuildAIMaker documentation

**Alpha (2026-08):** shipping loop is Character → Teach (mlx-lm LoRA) → Playground (Apple or Local MLX + LoRA) → Kokoro Speak. Voices clone, persona packs, and Talk mode are **not** in the sidebar.

| Document | Role |
|----------|------|
| [../README.md](../README.md) | Public product README (start here) |
| [mcp-bridge.md](./mcp-bridge.md) | `buildaimaker-mcp` tools (keep in sync with the app) |
| [character-studio-ux.md](./character-studio-ux.md) | UX north star; header notes what alpha actually shows |
| [creature-voice-pipeline.md](./creature-voice-pipeline.md) | Voice stages A/B (shipping) vs C / F5 (later) |
| [design-buildaimaker.md](./design-buildaimaker.md) | July 2026 system design (historical + still the long-term map) |
| [design-native-app-action-api-mcp.md](./design-native-app-action-api-mcp.md) | Action API + confirmation gate |
| [adr/0001-llm-runtime.md](./adr/0001-llm-runtime.md) | Managed Python + mlx-lm |
| [adr/0002-voice-engine.md](./adr/0002-voice-engine.md) | F5-TTS **plan**; alpha voice is Kokoro, not F5 |
| [adr/0003-apple-foundation-models.md](./adr/0003-apple-foundation-models.md) | Apple on-device + adapters |
| [native-vs-python-backends.md](./native-vs-python-backends.md) | Swift shell vs managed Python |
| [distribution-and-app-store.md](./distribution-and-app-store.md) | Developer ID vs Store (no `.app` in-repo yet) |
| [dogfood-test-data.md](./dogfood-test-data.md) | Fixtures and import formats |
| [review-project-2026-08.md](./review-project-2026-08.md) | **Historical** 2026-08-12 review — several claims are obsolete |
| [pushing-to-github.md](./pushing-to-github.md) | Clone / remote after the abundantfrontier transfer |

## Architecture snapshot (alpha)

- **UI / domain:** SwiftUI + SPM (`BAMCore`, `BAMInference`, `BAMControlPlane`, …)
- **Teach:** `bam-llm-worker` → managed venv `mlx-lm` LoRA (Gemma 4 unified aliased to `gemma4`)
- **Chat:** Apple Foundation Models **or** `generate_cli.py` (full history, thinking off)
- **Voice:** Kokoro catalog + creature FX; F5 clone runner is a stub and hidden
- **Distribution:** source + `swift run`; notarized `.app` not in this repository
