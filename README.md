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
│   └── BAMResourcesUI/      # Shared UI chrome (sidebar, colors)
├── Workers/                 # Training workers (future)
├── Catalog/                 # Model catalog (future)
├── Docs/                    # Design docs
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

## Library root

App data is stored under:

```text
~/Library/Application Support/BuildAIMaker/
```

See `BAMCore.LibraryPaths` for the full on-disk layout.

## CI

GitHub Actions (`.github/workflows/ci.yml`) runs on macOS:

- `swift build` — packages + app target
- `swift test` — BAMCore tests

No codesigning secrets are required for package builds. A full `.app` bundle / Developer ID notarization path will land with distribution work.

## Non-goals (this scaffold)

No GRDB, no training runners, no Python env, no real datasets. Domain packages arrive in subsequent PRs.
