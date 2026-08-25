# BuildAIMaker

**0.1.0 alpha** — local macOS studio for **fictional** characters: name them, teach how they talk, chat, and hear a creature voice. No cloud account required.

| | |
|---|---|
| Platform | macOS 14+ (Apple Silicon recommended) |
| Chat | Apple on-device **or** local MLX (e.g. Gemma 4) + optional LoRA |
| Teach | Real **mlx-lm LoRA** after Settings → Repair (or a labeled practice run on the fixture) |
| Voice | **Kokoro catalog** speakers + FX (Character → Voice). Clone UI is not in the sidebar. |
| Memory | **≥ 16 GB** unified for open-model teach (12B 4-bit is hungry) |
| License | [MIT](LICENSE) |
| Repo | [github.com/abundantfrontier/buildaimaker](https://github.com/abundantfrontier/buildaimaker) |

**Novice loop:** Create a character → Model → Story (mind) → Voice → **Playground** (chat + optional Speak) → **Teach** when you have a real MLX model and mlx-lm.

This is a dogfood alpha: the character loop works. It is not a notarized `.app`, Mac App Store build, or celebrity-voice product.

## What you should see

**Studio:** Home, Characters, Playground, Settings  
**Advanced:** Datasets, Models, Train (Teach), Jobs, Actions

**Not in the sidebar (code kept for later):** Voices (F5 clone stub), Personas (pack zip), Talk mode (mic loop). Hear a character from **Voice** or Playground **Speak replies**.

## Open & run

```bash
git clone https://github.com/abundantfrontier/buildaimaker.git
cd buildaimaker
swift build
swift run BuildAIMaker
```

Or `open Package.swift` in Xcode, scheme **BuildAIMaker**, Run (⌘R).

There is no signed app bundle in this repo. Last window closed quits.

After a first build, the debug binary is:

```text
.build/arm64-apple-macosx/debug/BuildAIMaker
```

Settings → **Repair** installs the managed Python env and **mlx-lm** so Teach can be real, not a stub.

## Repository layout

```text
buildaimaker/
├── Apps/BuildAIMaker/       # macOS SwiftUI app
├── Packages/                # BAM* libraries (core, jobs, inference, audio, MCP types, …)
├── Workers/
│   ├── bam-llm-worker / bam-echo-worker / bam-voice-worker
│   ├── python/              # llm_worker, generate_cli, catalog TTS, runtime-pins
│   └── buildaimaker-mcp     # stdio MCP → Unix socket
├── Docs/                    # Design ADRs + alpha notes
└── Package.swift
```

Library data (characters, models, jobs, MCP socket) stays in:

```text
~/Library/Application Support/BuildAIMaker/
```

Do not commit that folder.

## Teach & Playground (alpha)

- **Teach** enqueues the same job queue as MCP `finetune.start`. Gemma 4 “unified” checkpoints are remapped for mlx-lm; vision weights are dropped for text LoRA.
- **Playground → Local MLX** uses the same compatibility helper, **full chat history** (system + turns), thinking off. Caption **Local MLX** vs **Apple on-device**.
- Speak replies uses the bound character’s Kokoro speaker + FX. **How-fast** drives Kokoro speed.
- **MCP `chat_send`** still prefers Apple when it is available; use the Playground UI for Gemma + LoRA.

### Known limitations

| Item | Reality |
|------|---------|
| LoRA “how much they can change” | UI rank is **not** passed through; mlx-lm default **rank 8** |
| Jobs loss / hold-out | Placeholder numbers after mlx-lm; not parsed from the trainer |
| Talk mode | Off. Speak replies is the spoken path |
| Voice clone / persona packs | Hidden; clone runner is a stub |
| Apple adapter toolkit | Optional second path; not required for Gemma teach |
| Packaging | No notarized `.app` |

## Control plane + MCP

UI and agents share one Action API. The **running app** owns `mcp.sock` + `mcp.token`. `buildaimaker-mcp` is a stdio bridge. See [Docs/mcp-bridge.md](Docs/mcp-bridge.md).

Expensive (`finetune.start`) and live-destructive (`minds.dedupe` with `dryRun: false`) actions from MCP wait on an orange **Allow / Deny** in the app. Agents cannot self-confirm.

```bash
swift build --product buildaimaker-mcp
```

## Offline fixture

CI uses a **tiny bundled stub model**, not multi-GB weights (`Workers/fixtures/models/tiny-qwen-mlx/`). **Install fixture** is for UI/CI. Teach will say **practice run** until mlx-lm + real weights are present.

## Feature flags

| Key | Default | Notes |
|-----|---------|--------|
| `ff.llmTraining` | on | Open LoRA teach |
| `ff.playground` | on | Text playground |
| `ff.foundationModels` | on | Apple on-device chat |
| `ff.controlPlane` | on | Action API + MCP |
| `ff.voiceClone` / `ff.personaPacks` | on in code | **Sidebar hidden**; not a shipping studio path |
| `ff.talkMode` | **off** | Mic Talk pane |
| `ff.hfHubDownload` | **off** | CI stays offline |
| `ff.voiceFinetune` / `ff.cloudRunner` / `ff.knowledgePacks` | off | Future |

## Documentation

| Doc | Role |
|-----|------|
| [Docs/README.md](Docs/README.md) | Index + what is historical |
| [Docs/mcp-bridge.md](Docs/mcp-bridge.md) | MCP tools (current) |
| [Docs/character-studio-ux.md](Docs/character-studio-ux.md) | UX north star vs alpha |
| [Docs/creature-voice-pipeline.md](Docs/creature-voice-pipeline.md) | Kokoro + FX; clone later |
| [Docs/design-buildaimaker.md](Docs/design-buildaimaker.md) | Original system design (July 2026) |
| [SECURITY.md](SECURITY.md) | Tokens, MCP, reporting |

## CI

GitHub Actions (`.github/workflows/ci.yml`) on macOS: `swift build` and `swift test`. No codesign.

## Ethics

Fictional characters only. No celebrity catalog, no non-consensual clone, no scraped audiobook as a voice target.
