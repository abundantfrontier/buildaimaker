# BuildAIMaker

Native macOS app for **local-first AI fine-tuning** (LLM + voice later) on Apple Silicon.

| | |
|---|---|
| Platform | macOS 14+ (Apple Silicon recommended) |
| Min memory | 16 GB unified memory |
| Stack | SwiftUI · Swift Package Manager |

## Repository layout

```text
buildaimaker/
├── Apps/BuildAIMaker/       # macOS SwiftUI app shell
├── Packages/
│   ├── BAMCore/             # Feature flags, paths, errors, protocol versions
│   ├── BAMModels/           # Domain models (JobSpec, Consent, Persona, modalities)
│   ├── BAMPersistence/      # GRDB library.sqlite + migrations
│   ├── BAMJobs/             # Job queue, state machine, fake TrainingRunner
│   ├── BAMRunners/          # Runner Protocol v1, process supervisor, path jail
│   └── BAMResourcesUI/      # Shared UI chrome (sidebar, colors)
├── Workers/                 # Helpers (bam-echo-worker for protocol CI; llm later)
├── Catalog/                 # Model catalog (future)
├── Docs/                    # Design docs + ADRs
└── Package.swift            # Root SPM package
```

## Requirements

- macOS 14 or later
- Xcode 15+ (Xcode 16+ recommended)
- Apple Silicon Mac with **≥ 16 GB** unified memory for training workflows

## Open & run

### Option A — Xcode (recommended)

1. Open the package:
   ```bash
   open Package.swift
   ```
2. In Xcode, select the **BuildAIMaker** scheme.
3. Press **Run** (⌘R).

You should see a `NavigationSplitView` shell with sidebar destinations:
Home, Datasets, Models, Train, Jobs, Playground, Voices, Personas, Settings.

### Option B — command line

Build libraries and the app executable:

```bash
swift build
```

Run the app binary (opens a SwiftUI window when run from a GUI session):

```bash
swift run BuildAIMaker
```

Run unit tests:

```bash
swift test
```

## Offline fixture model

CI and offline dogfood use a **tiny bundled fixture**, not multi-GB weights:

| Path | Role |
|------|------|
| `Workers/fixtures/models/tiny-qwen-mlx/` | Living fixture (stub config + tokenizer JSON) |
| `Packages/BAMModelCatalog/.../Resources/fixtures/tiny-qwen-mlx/` | Same files, bundled for install |
| Catalog `sourceKey` | `buildaimaker/tiny-qwen-mlx-fixture` |

**Real MLX weights** (e.g. `mlx-community/Qwen2.5-*-Instruct-4bit`) download separately via the optional Hugging Face Hub path when `ff.hfHubDownload` is on, or by placing files under `models/base/`. The fixture’s `model.safetensors` is a placeholder only (`WEIGHTS_NOT_INCLUDED.txt`).

In the Models UI, **Install fixture model** copies the fixture into:

```text
~/Library/Application Support/BuildAIMaker/models/base/tiny-qwen-mlx-fixture/
```

with **no network**. Unit tests cover this offline path only.

## Feature flags

All flags live in `BAMCore.FeatureFlags` and **default to off**:

| Key | Purpose |
|-----|---------|
| `ff.llmTraining` | LLM LoRA training UI/path |
| `ff.voiceClone` | Voice clone UI/path |
| `ff.voiceFinetune` | Supervised voice fine-tune (future) |
| `ff.personaPacks` | Persona pack import/export |
| `ff.talkMode` | Spoken conversation mode |
| `ff.cloudRunner` | Remote/cloud runner (kept off in v1) |
| `ff.knowledgePacks` | Knowledge/RAG packs (Phase 2+) |
| `ff.telemetryOptIn` | Opt-in diagnostics |
| `ff.hfHubDownload` | Optional HF Hub model download (dogfood; CI stays offline) |

## Library root

App data is stored under:

```text
~/Library/Application Support/BuildAIMaker/
```

See `BAMCore.LibraryPaths` for the full on-disk layout.

## CI

GitHub Actions (`.github/workflows/ci.yml`) runs on macOS:

- `swift build` — packages + app target
- `swift test` — BAMCore, BAMModels, BAMPersistence, BAMJobs, BAMRunners (no GPU)

No codesigning secrets are required for package builds. A full `.app` bundle / Developer ID notarization path will land with distribution work.

## Domain packages

- **BAMModels** — `JobModality` / `DatasetModality`, `JobSpec` / `JobPaths`, `ConsentRecord` + canonical `contentHash`, persona JSON (no knowledge keys), fixtures.
- **BAMPersistence** — GRDB `library.sqlite` migration v1 (datasets, jobs, personas, consent, …).
- **BAMJobs** — Queue controller (concurrency 1), v1 state machine (no pause), heartbeat interrupt, `FakeTrainingRunner` synthetic progress, Jobs UI.
- **BAMRunners** — Runner Protocol v1 (NDJSON), `ProcessSupervisor`, path jail, `cancel.flag` + SIGTERM/SIGKILL, golden NDJSON fixtures. Default queue still uses `FakeTrainingRunner`; optional `JobQueueController.makeWithSupervisedRunner`.

## Non-goals (current tree)

No real mlx-lm / F5-TTS training yet (see PR-LLM-Materialize / PR-VoiceSpike). No real dataset import UI yet.

## Merged stack note
This branch base merges Protocol + Datasets + Catalog/Fixture + PyEnv for LLM materialization.


## Merged stack
Base merges Protocol + Datasets + Catalog/Fixture for materialize work.
