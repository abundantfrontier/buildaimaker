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
├── Workers/                 # Helpers: echo, llm, voice (+ managed Python pins)
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

## Feature flags

All flags live in `BAMCore.FeatureFlags`. Most default **off**; ship-enabled features flip on in their PR:

| Key | Default | Purpose |
|-----|---------|---------|
| `ff.llmTraining` | off | LLM LoRA training UI/path |
| `ff.voiceClone` | **on** | Voice clone UI/path (PR-Voice-UI) |
| `ff.voiceFinetune` | off | Supervised voice fine-tune (future) |
| `ff.personaPacks` | off | Persona pack import/export |
| `ff.talkMode` | off | Spoken conversation mode |
| `ff.cloudRunner` | off | Remote/cloud runner (kept off in v1) |
| `ff.knowledgePacks` | off | Knowledge/RAG packs (Phase 2+) |
| `ff.telemetryOptIn` | off | Opt-in diagnostics |

## Library root

App data is stored under:

```text
~/Library/Application Support/BuildAIMaker/
```

See `BAMCore.LibraryPaths` for the full on-disk layout.

## CI

GitHub Actions (`.github/workflows/ci.yml`) runs on macOS:

- `swift build` — packages + app target
- `swift test` — BAMCore, BAMModels, BAMPersistence, BAMJobs, BAMRunners, BAMRunnersVoice (no GPU)

No codesigning secrets are required for package builds. A full `.app` bundle / Developer ID notarization path will land with distribution work.

## Domain packages

- **BAMModels** — `JobModality` / `DatasetModality`, `JobSpec` / `JobPaths`, `ConsentRecord` + canonical `contentHash`, persona JSON (no knowledge keys), fixtures.
- **BAMPersistence** — GRDB `library.sqlite` migration v1 (datasets, jobs, personas, consent, …).
- **BAMJobs** — Queue controller (concurrency 1), v1 state machine (no pause), heartbeat interrupt, `FakeTrainingRunner` synthetic progress, `VoiceCloneMaterializer`, Jobs UI.
- **BAMRunners** — Runner Protocol v1 (NDJSON), `ProcessSupervisor`, path jail, `cancel.flag` + SIGTERM/SIGKILL, golden NDJSON fixtures.
- **BAMRunnersVoice** — Stub voice-clone runner (no F5 download), `VoiceProfileStore`, `VoiceCloneService` (import ref audio → consent → `JobPaths.referenceAudioPath` only → enqueue), Voices UI.

## Non-goals (current tree)

No real mlx-lm / F5-TTS training yet (stubs + pin/license ADRs only). Voice product UI uses the **stub** clone path. Talk mode is not enabled (`ff.talkMode` remains off).
