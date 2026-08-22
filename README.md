# BuildAIMaker

Native macOS **character studio**: create a fictional creature, chat with it locally, teach it from a story, then optionally fine-tune.

| | |
|---|---|
| Platform | macOS 14+ (Apple Silicon recommended) |
| Apple on-device chat | Apple Intelligence / Foundation Models era OS (probe at runtime) |
| Min memory | 16 GB unified memory for open-model train |
| Stack | SwiftUI · Swift Package Manager |

**Novice loop:** Create a character → chat (Apple on-device when ready) → teach a mind dataset → optionally fine-tune (open MLX LoRA **or** Apple adapter).

**Train** is the sidebar destination. **Fine-tune** is the verb on a character. Both go through the same job queue as MCP.

## Repository layout

```text
buildaimaker/
├── Apps/BuildAIMaker/       # macOS SwiftUI app
├── Packages/
│   ├── BAMCore/             # Flags, paths, errors, onboarding
│   ├── BAMModels/           # JobSpec, Consent, Persona, modalities
│   ├── BAMPersistence/      # GRDB library.sqlite + migrations
│   ├── BAMDatasets/         # JSONL import, mind upsert / dedupe
│   ├── BAMModelCatalog/     # Catalog + fixture install + optional HF
│   ├── BAMJobs/             # Job queue, state machine, runners
│   ├── BAMRunners/          # Runner Protocol v1, process supervisor
│   ├── BAMRunnersMLX/       # LoRA materialize / dry-run / train
│   ├── BAMRunnersVoice/     # Voice clone (lab / stub)
│   ├── BAMInference/        # Playground backends (Apple / MLX / echo)
│   ├── BAMPersonas/         # Persona packs (Advanced)
│   ├── BAMCharacterStudio/  # Wizard drafts + corpus
│   ├── BAMAudioFX/          # Creature voice FX
│   ├── BAMConsent/          # Voice consent records
│   ├── BAMResourcesUI/      # Sidebar chrome
│   └── BAMControlPlane/     # Action API + App RPC types
├── Workers/
│   ├── bam-llm-worker / bam-echo-worker / bam-voice-worker
│   └── buildaimaker-mcp     # stdio MCP → Unix socket
├── Docs/                    # Design, ADRs, MCP bridge
└── Package.swift
```

## Documentation

| Doc | Topic |
|-----|--------|
| [Docs/README.md](Docs/README.md) | Index |
| [Docs/design-buildaimaker.md](Docs/design-buildaimaker.md) | System design & PR plan |
| [Docs/design-native-app-action-api-mcp.md](Docs/design-native-app-action-api-mcp.md) | Action API + MCP control plane |
| [Docs/mcp-bridge.md](Docs/mcp-bridge.md) | `buildaimaker-mcp` + Grok snippet |
| [Docs/character-studio-ux.md](Docs/character-studio-ux.md) | Character Studio UX |
| [Docs/adr/0003-apple-foundation-models.md](Docs/adr/0003-apple-foundation-models.md) | Apple on-device + adapters |
| [Docs/native-vs-python-backends.md](Docs/native-vs-python-backends.md) | Swift shell vs managed Python |
| [Docs/distribution-and-app-store.md](Docs/distribution-and-app-store.md) | Developer ID vs App Store |

## Requirements

- macOS 14 or later (Apple chat needs a Foundation Models–capable OS)
- Xcode 15+ (Xcode 16+ recommended)
- Apple Silicon Mac with **≥ 16 GB** unified memory for open LoRA

## Open & run

### Option A — Xcode (recommended)

```bash
open Package.swift
```

Select the **BuildAIMaker** scheme and press Run (⌘R).

### Option B — command line

```bash
swift build
swift run BuildAIMaker
swift test
```

### What you should see

**Studio:** Home, Characters, Playground, Settings  
**Advanced:** Datasets, Models, Train, Jobs, Voices, Personas, Actions

Home treats **Apple on-device** as enough to chat. Open MLX runtime + weights are optional for Train.

## Control plane + MCP

UI buttons and agents share one Action API (`BAMControlPlane`). The running app owns a Unix socket; `buildaimaker-mcp` is a stdio bridge.

| Surface | Same commands |
|---------|----------------|
| Characters wizard mind save | `character.importMind` |
| Datasets → Dedupe minds | `minds.dedupe` (dry-run, then confirm) |
| Train / Fine-tune | `finetune.start` → shared Jobs queue |
| Advanced → Actions | list + invoke (`app.getState`, `character.list`, …) |
| MCP host | `buildaimaker__character_list`, `finetune_start`, `job_get`, … |

**Expensive** (`finetune.start`) and **live destructive** (`minds.dedupe` with `dryRun: false`) from MCP pause for an orange **Allow / Deny** banner in the app. Agents cannot self-confirm.

Settings → **MCP / agents** shows socket + token paths and copies a Grok `config.toml` snippet. Details: [Docs/mcp-bridge.md](Docs/mcp-bridge.md).

```bash
swift build --product buildaimaker-mcp
```

## Offline fixture model

CI and offline dogfood use a **tiny bundled fixture**, not multi-GB weights:

| Path | Role |
|------|------|
| `Workers/fixtures/models/tiny-qwen-mlx/` | Living fixture |
| `Packages/BAMModelCatalog/.../Resources/fixtures/tiny-qwen-mlx/` | Bundled copy |
| Catalog `sourceKey` | `buildaimaker/tiny-qwen-mlx-fixture` |

**Install fixture** copies it to `~/Library/Application Support/BuildAIMaker/models/base/tiny-qwen-mlx-fixture/` with no network. Train will label **Start LoRA (fake)** until mlx-lm + a worker + real weights are present.

## Feature flags

`BAMCore.FeatureFlags` defaults:

| Key | Default | Purpose |
|-----|---------|---------|
| `ff.llmTraining` | **on** | Open LoRA train path |
| `ff.playground` | **on** | Text playground |
| `ff.voiceClone` | **on** | Advanced voice clone UI |
| `ff.personaPacks` | **on** | Persona pack import/export |
| `ff.foundationModels` | **on** | Apple FM chat + adapter path |
| `ff.controlPlane` | **on** | Action API + MCP socket |
| `ff.voiceFinetune` | off | Supervised voice fine-tune |
| `ff.talkMode` | off | Spoken conversation |
| `ff.cloudRunner` | off | Remote runner |
| `ff.knowledgePacks` | off | Knowledge/RAG packs |
| `ff.telemetryOptIn` | off | Opt-in diagnostics |
| `ff.hfHubDownload` | off | HF Hub download (CI stays offline) |

## Library root

```text
~/Library/Application Support/BuildAIMaker/
```

Includes `library.sqlite`, `characters/*.json`, models, jobs, `mcp.sock`, and `mcp.token`. See `BAMCore.LibraryPaths`.

## CI

GitHub Actions (`.github/workflows/ci.yml`) on macOS:

- `swift build`
- `swift test`

No codesigning. A notarized `.app` is not in this repo yet.
