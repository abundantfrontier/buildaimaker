# BuildAIMaker project review (August 2026)

> **Historical.** Written **2026-08-12**. Several verdicts are **obsolete**: Teach now uses the shared job queue and real mlx-lm (Gemma 4 unified helper); Settings Repair installs mlx-lm; Playground can chat Local MLX with full history and Kokoro Speak; Voices/Personas/Talk are hidden. Keep this file as an audit trail, not as a description of the public alpha. Current product surface: [README.md](../README.md).

| Field | Value |
|-------|-------|
| **Date** | 2026-08-12 |
| **Scope** | Whole repo (local clone; not a git diff) |
| **Method** | Read design docs, `Package.swift`, app shell, control plane, character wizard, Home, MCP bridge, job/train paths |
| **Code changed** | None (review only) |

This is a product-and-architecture review of what the tree *is*, versus what the docs *say* it is.

---

## Executive verdict

BuildAIMaker is a **serious dogfood prototype** of a local-first macOS character studio, not a shipping product and not a finished “train without a terminal” MVP.

The repo is far past the design doc’s July 18 “greenfield README only” snapshot. There is a real SwiftUI app, a modular BAM* SPM graph, GRDB library persistence, a job state machine, MLX worker protocol, Apple Foundation Models chat + adapter plumbing, a Character Studio wizard, and a working **stdio MCP bridge → Unix socket App RPC**. That is a lot of architecture landed in weeks.

It is **not** yet the product described by the success metrics:

- **M1 (in-app LoRA on a ≤3B model, no terminal)** is *architected* (`LoRATrainService`, `bam-llm-worker`, mlx-lm worker) but **not product-complete**. Home “Install runtime” creates an empty `python3 -m venv` and does **not** install mlx-lm. Catalog HF download is off by default (`ff.hfHubDownload`). Fixture/stub models force fake LoRA. The Train pane runs training **outside** the job queue. MCP `finetune.start` enqueues a **different** runner that is always `FakeTrainingRunner` for open LoRA.
- **M6 (Talk-mode persona turn)** is gated off (`ff.talkMode = false`) and STT/TTS are fakes.
- The **Character Studio** north star (name → model → story → voice → play) exists as a wizard, but Home, sidebar, checklist, Personas, and Voices still look like an ML research workbench bolted next to a toy.

The highest structural risk is **split-brain execution**, not missing UI chrome: three independent `JobQueueController` instances, Train UI bypassing the queue entirely, and a control plane that is a real transport but **not** the exclusive mutation path. Wizard mind-save now uses `upsertMindJSONL` (good). That is **not** the same as “all writes go through the Action API.”

**Honest one-liner:** excellent package skeleton and a usable Apple-first *chat* path on a modern Mac; open-model train, voice clone, Talk, and agent control are still prototypes that can lie to the user by succeeding with stubs.

---

## Goals alignment

### What the docs say the product is

[`Docs/design-buildaimaker.md`](design-buildaimaker.md) (approved 2026-07-19) defines a **native macOS graphical app** for local-first LLM + voice fine-tuning, with persona packs as the differentiator (“Talk to Socrates”). Phase-1 bar is explicit:

| Metric | Stated pass |
|--------|-------------|
| M1 | One LoRA on a bundled/downloaded ≤3B MLX model **without leaving the app / using a terminal**, ≥16 GB Apple Silicon |
| M2 | Cancel in 15 s; recover after force-quit |
| M3 | Playground base+adapter coherent reply &lt; 30 s cold |
| M4 | Dataset import rejects bad JSONL; ShareGPT/OpenAI fixtures in tests |
| M5 | Zero network during train/play except explicit download |
| M6–M8 | Persona + consent-bound voice + Talk + pack reimport (1.0) |

Key decisions still on the books: SwiftUI + SPM (K1), out-of-process trainers (K2), **managed Python mlx-lm as the primary train stack** (K3/K4), local-only (K5/K22), creator/prosumer wizard + Advanced (K10), 16 GB minimum (K16), Developer ID first (K14).

[`Docs/character-studio-ux.md`](character-studio-ux.md) then reframes the same app as a **Character Studio**: paste a story → mind corpus → creature voice → Play/Talk. Sidebar engineering names should recede under Advanced.

[`Docs/adr/0003-apple-foundation-models.md`](adr/0003-apple-foundation-models.md) says Apple FM is an **optional second backend**, not a replacement for open-model studio. Phase 1–2 “landed” in that ADR (dual Train backend, toolkit CLI, playground load).

[`Docs/design-native-app-action-api-mcp.md`](design-native-app-action-api-mcp.md) adds a third goal: **one Action API** so UI, MCP, and CLI cannot diverge (the “Robby mind” duplicate class of bugs).

### What the repo actually is

A **monorepo SPM app** (`Package.swift`) with more packages than the July design module map or the README layout list:

| Present in tree | In README layout? | In design module map? |
|-----------------|-------------------|------------------------|
| BAMCore, BAMModels, BAMPersistence, BAMJobs, BAMRunners, BAMPersonas, BAMResourcesUI | Yes | Yes |
| BAMDatasets, BAMModelCatalog, BAMConsent, BAMRunnersMLX, BAMRunnersVoice, BAMInference | Partial (later README bullets) | Yes |
| **BAMCharacterStudio, BAMAudioFX, BAMControlPlane** | **No** | **No** (control plane is a later design) |
| `buildaimaker-mcp` | **No** | Later design only |
| Characters sidebar destination | README still lists Home, Datasets, Models, Train, Jobs, Playground, Voices, Personas, Settings | UX doc wants Home / My characters / Playground |

The running product is a **hybrid**:

1. **Toy studio path:** `Characters` wizard (JSON file store) + Apple on-device chat in Playground + system-TTS creature FX.
2. **Research workbench path:** Datasets / Models / Train / Jobs / Voices / Personas — mostly independent of the wizard.
3. **Agent path:** in-process `BAMControlPlane` + `AppRPCServer` + `buildaimaker-mcp` stdio bridge. Thin: a handful of actions; UI almost never calls them.

That is a coherent *direction*. It is **not** yet one product with one loop. Dual-modality is frozen in types (`JobModality`, voice `JobSpec`, persona JSON) as K12 required; **execution** of voice clone and Talk is stub/fake. Persona packs exist as a separate GRDB + zip feature, not as the save format of the character wizard.

### Goal-by-goal score

| Stated goal | Repo reality |
|-------------|--------------|
| Native SwiftUI macOS app | **Met as a shell.** `NavigationSplitView` in [`RootView.swift`](../Apps/BuildAIMaker/Sources/RootView.swift); no `.xcodeproj`, launch via `open Package.swift`. |
| Local-first training without terminal | **Partial / often fake.** Train UI can invoke `LoRATrainService` / Apple toolkit; runtime install does not pull wheels; fixture path advertises “Start LoRA (fake)”. |
| Dual modality day one | **Types yes, product no.** Voice Advanced pane is consent + stub clone. Wizard voice is creature FX, not F5. |
| Persona packs | **Implemented as Advanced feature**, not the wizard’s save artifact. Characters ≠ Personas. |
| Job system with cancel/recovery | **Implemented twice (or thrice)** — see Architecture. Train UI does not use it. |
| In-app playground | **Text path is real** (Apple FM when available, else MLX generate if present, else echo). Talk pane is flag-off + fake STT/TTS. |
| Extensible runners | **Yes** (`TrainingRunner`, `CompositeTrainingRunner`, protocol v1). |
| Security-aware (consent, path jail, L1/L2 trust) | **Skeleton yes.** Consent UI exists. L1 helper check is a Settings button. Runtime pins exist; empty venv still counts as “installed.” |
| Action API / MCP as single control plane | **Transport exists; product adoption does not.** See Architecture. |
| Apple FM as optional complement | **Product has inverted this.** Home treats Apple as the default *ready* path; open MLX is “optional train.” ADR 0003 still says the opposite for v1 primary train. |

**README staleness (do not treat README as current product spec):**

- Sidebar list omits **Characters** ([`README.md`](../README.md) “Open & run”).
- Package tree omits BAMCharacterStudio, BAMAudioFX, BAMControlPlane, BAMDatasets, BAMInference, MCP worker.
- Feature-flag table omits `ff.foundationModels` and `ff.controlPlane` (both default **on** in [`FeatureFlags.swift`](../Packages/BAMCore/Sources/BAMCore/FeatureFlags.swift)).
- “Default queue still uses `FakeTrainingRunner`” is still true for Jobs / MCP / Voices, but Train UI has a separate real/fake LoRA path.
- CI test list understates what `swift test` actually builds (many more test targets in `Package.swift`).
- [`Docs/README.md`](README.md) index omits `design-native-app-action-api-mcp.md` and `mcp-bridge.md`.
- Design doc Background still says the repo is greenfield with only a README.

---

## Usability

A novice opening the app does **not** see a single Character Studio. They see a **split personality**.

### What the user actually sees

[`SidebarChrome`](../Packages/BAMResourcesUI/Sources/BAMResourcesUI/SidebarChrome.swift) + [`SidebarDestination`](../Packages/BAMResourcesUI/Sources/BAMResourcesUI/SidebarDestination.swift):

| Section | Destinations |
|---------|----------------|
| **Studio** | Home, Characters, Playground, Settings |
| **Advanced** | Datasets, Models, Train, Jobs, Voices, Personas |

That is closer to the UX doc than the README, but Advanced is **always expanded** — six power-user destinations on first launch, equal visual weight to Studio. There is **no** 3-column studio (the Action API design assumes one). There is **no** “Fine-tune” destination. There is **no** Agent Actions panel.

### Home: two checklists that disagree

[`HomeOnboardingView.swift`](../Apps/BuildAIMaker/Sources/Home/HomeOnboardingView.swift) is the first screen. It contains **three** stacked systems:

1. **Marketing header** — “Make a fictional creature: name → model → story → voice → save.” CTA: *Start: Create a character*.
2. **Environment setup (3/3)** — Apple on-device model, Open MLX runtime, Open base model.
3. **Get started checklist (4/4)** — Import a dataset, Install a base model, Dry-run or train LoRA, Try the playground.

These are not the same product.

**Apple-ready vs checklist (important):**

`EnvironmentSetupStatus.needsAttention` is **false** as soon as `AppleFoundationModelSupport.probeStatus().isUsable` is true. Open runtime + open model become optional. `isReady` is Apple **or** (runtime ∧ local model). The prominent CTA unlocks. The green banner says “Apple on-device model ready · Playground defaults to Apple · open MLX optional.”

The **Get started** checklist is unchanged from the July ML-studio funnel ([`OnboardingChecklist.swift`](../Packages/BAMCore/Sources/BAMCore/OnboardingChecklist.swift)):

- “Import a dataset” → **Datasets** (not Characters). Completes if any ready **text** dataset exists *or* M4 `datasetImportOK` &gt; 0. Wizard mind-save creates a dataset but **does not** increment M4.
- “Install a base model” → **Models**. Probe is **local open models / fixture only**. Apple FM does **not** count. A user who is “environment ready” via Apple still has an empty circle here.
- “Dry-run or train LoRA” → **Train**. Apple-only users who never touch Train stay incomplete unless they publish a stub adapter (which the Apple train button will happily do).
- “Try the playground” → only completes on `playgroundReply` or a manual mark.

Home also shows **MVP metrics (M1–M5)** tiles. M1 (`trainCompleted`) is **never incremented** by Train UI or the job queue — only unit tests touch it. A successful fake/real LoRA will not move M1. That is a dogfood lie.

Home still tells a first-run user to finish setup before creating a character when Apple is *not* ready — even though the wizard can proceed with story/voice and even though Playground can fall back to echo. The orange “Setup required” copy says the app needs “a local training runtime and at least one base model before real chat or LoRA,” which is **false** for Apple chat.

### Character wizard vs the rest of the app

The wizard ([`CreateCharacterWizardView.swift`](../Apps/BuildAIMaker/Sources/Characters/CreateCharacterWizardView.swift), [`CreateCharacterViewModel.swift`](../Apps/BuildAIMaker/Sources/Characters/CreateCharacterViewModel.swift)) is the best novice flow in the tree:

Name → Model → Story → Voice → Done.

Strengths:

- Progress persists as JSON under `characters/<id>.json` ([`CharacterLibraryStore`](../Packages/BAMCharacterStudio/Sources/BAMCharacterStudio/CharacterLibraryStore.swift)).
- Unfinished drafts show as “Continue creating.”
- Story step builds a template bible + JSONL and **upserts** a “`<name> mind`” dataset (`saveDataset` → `upsertMindJSONL` + `mergeByStableId`). Rebuilding the mind should not spawn a new library row if `draft.datasetId` is kept.
- Voice step is actually fun: system TTS + creature FX (`BAMAudioFX`), not a consent form.
- Done footer: Playground, **Train** or **Specialize (Apple)**, Create another.

Friction / confusion:

- Model step auto-selects **Apple** when `SystemLanguageModel` is usable. That is correct for chat. The same character’s Train button then becomes **“Specialize (Apple)”**, which opens the Apple adapter toolkit form — a Developer-Program Python CLI, not “press to make them smarter.” Without a toolkit path, **Start publishes a stub** that Playground will not actually apply (`isStubPackage`).
- Story “Build how they talk” is **template-v1** ([`CorpusBuilder`](../Packages/BAMCharacterStudio/Sources/BAMCharacterStudio/CorpusBuilder.swift)), not the UX doc’s local-LLM normalizer. Riff is synthetic, not a model call. Fine for offline; disappointing if the user just enabled Apple Intelligence.
- `riffMore()` updates examples on disk but **does not** re-upsert the dataset until the next `buildMind(importDataset: true)`.
- Saved “character” is **not** a persona pack. Advanced → Personas is a second identity system (GRDB `personas` table + zip). Novices will not discover it; power users will wonder why Characters and Personas both exist.
- Wizard voice (creature FX WAV) is **not** a Voices-pane profile. Advanced → Voices is F5-clone + consent on a stub runner.

### Train vs Fine-tune

There is **one** sidebar item: **Train**. There is **no** Fine-tune destination.

Naming in the wild:

| Surface | Word used |
|---------|-----------|
| Sidebar / Train header | Train |
| Train backend titles | “Open MLX LoRA” / “Apple Foundation Adapter” |
| `TrainBackend.shortHelp` | “**Fine-tune** an open base model…” |
| Characters list | “Train this character (LoRA)” |
| Wizard Done | “Train” or “Specialize (Apple)” |
| MCP / actions | `finetune.start`, tool `finetune_start` |
| Action API design | “Train vs Fine-tune naming” as a product assumption |

For a novice this is messy but survivable (one hammer icon). For agents it is worse: MCP speaks `finetune_*` while the UI speaks Train, and **those two paths do not run the same code** (see Architecture).

The Train pane itself is a **lab form**, not a wizard: backend segmented control, dataset picker, hardware-fit panel, LoRA hyperparameters, or toolkit path + Export/Import/Stub. Character handoff preselects dataset/model, which is good. A user arriving from Home checklist “Dry-run or train LoRA” with no character lands on empty pickers and “Start LoRA (fake)” if they only have the fixture.

### Apple vs open models (user-visible)

This is the sharpest UX honesty problem.

| Path | What the UI implies | What happens |
|------|---------------------|--------------|
| Home + Apple Intelligence on | App is ready; chat works | **True** for Playground if `SystemLanguageModel` is `.available` (macOS 26+ / Apple Intelligence era API in [`AppleFoundationModelSupport.swift`](../Packages/BAMInference/Sources/BAMInference/AppleFoundationModelSupport.swift)) |
| Wizard Model | Pick Apple *or* open MLX | Apple auto-selected; open models listed below as optional |
| Playground default | Automatic = Apple → MLX → Echo ([`LLMBackendFactory`](../Packages/BAMInference/Sources/BAMInference/LLMBackendFactory.swift)) | Echo if neither stack is live. Character handoff can force Apple or MLX |
| Train / open | “Start LoRA train” | Real only with **real weights + mlx-lm in some Python**. Fixture/stub → fake adapter published |
| Train / Apple | “Start Apple train” / “Start (stub)” | Real only if user downloaded Apple’s Adapter Training Toolkit and pointed Train at it. Else stub `.fmadapter` |
| Models catalog | Qwen 0.5B / 1.5B / 3B listed | `ff.hfHubDownload` **off**. Models pane install is fixture/stub unless the user uses **Browse sources**, which **forces** `hfHubDownloadEnabled: true` in [`ModelBrowserViewModel`](../Apps/BuildAIMaker/Sources/Models/ModelBrowserViewModel.swift) — a flag bypass |

Apple chat and open LoRA are **different products** sharing a window. The UI sometimes says that (Train help text is decent). Home setup copy still conflates them.

### Duplicate datasets (what a user can still do)

The infamous “every reimport creates a new Robby mind” bug is **mitigated on the wizard path**, not eliminated globally.

**Fixed (identity policy at domain layer):**

- [`MindDatasetUpsert.swift`](../Packages/BAMDatasets/Sources/BAMDatasets/MindDatasetUpsert.swift): `mergeByStableId` / `mergeByContentHash` / `replaceExisting` / `alwaysCreate`.
- Wizard `saveDataset` uses `mergeByStableId` + `existingDatasetId: draft.datasetId`.
- MCP/action `character.importMind` uses the same `upsertMindJSONL`.

**Still duplicate-capable:**

- Advanced → Datasets **Import** always calls `importDataset` ([`DatasetsView.swift`](../Apps/BuildAIMaker/Sources/Datasets/DatasetsView.swift) `performImport`). Same filename, same name, new UUID every time. That is fine for “I imported two files”; it is not mind identity.
- `alwaysCreate` is still a public policy (MCP can request it).
- If `draft.datasetId` is lost (manual JSON edit, failed persist, character copied without id), next Build creates a **new** “Robby mind.”
- Historical orphans: `minds.dedupe` exists (dry-run default **true**) but there is **no Home/Datasets button** for it — MCP/tests only.
- Wizard does **not** call `character.importMind`. State Store `selection.datasetId` is not updated when the human builds a mind. An agent listing state after a UI teach pass can be stale.

### Other first-run papercuts

- **Jobs → “Start Fake Job”** is a developer toy on a user-facing Advanced pane.
- **Playground → Talk** is visible as a picker, then a “not enabled” placeholder (`ff.talkMode` off).
- **Settings** feature flags are **read-only**. User cannot turn on Talk or HF download without code/defaults.
- **Personas / Voices / Consent** are real UIs with stub backends — they look more finished than they are.
- Window minimum 800×500; wizard sheet 720×600. Fine on a 16" MacBook; cramped mental model, not cramped pixels.

---

## Feasibility

### Local LoRA (open MLX) on Apple Silicon

**Feasible as an engineering path; not yet a one-click product path.**

What exists:

- Job materializer, chat templates, `ProcessSupervisor`, `bam-llm-worker` L1 helper, Python `llm_worker` that can call `mlx_lm.lora` or fake ([`Workers/python/README.md`](../Workers/python/README.md)).
- [`LoRATrainService`](../Packages/BAMRunnersMLX/Sources/BAMRunnersMLX/LoRATrainService.swift) used by **Train UI only**.
- Hardware fit heuristic + K16 16 GB floor ([`HardwareFitGate`](../Packages/BAMRunnersMLX/Sources/BAMRunnersMLX/HardwareFitGate.swift)).
- Catalog targets Qwen2.5 Instruct 0.5B / 1.5B / 3B 4-bit ([`Catalog/models.json`](../Catalog/models.json)) — aligned with K15.

What blocks M1 for a normal user:

1. **Runtime install is a venv, not a train stack.** [`RuntimeInstaller.installManagedRuntime`](../Packages/BAMCore/Sources/BAMCore/RuntimeInstaller.swift) runs `python3 -m venv` and `pip install --upgrade pip`. Comment and Settings footer are honest; Home button label (“Install runtime”) is not. mlx-lm / torch / F5 are **not** installed. Documented size 3–8 GB is a budget, not an implemented download.
2. **Real weights are optional and easy to miss.** Fixture is a stub (`WEIGHTS_NOT_INCLUDED.txt`). Train then sets `willUseFakeTrain` and publishes an adapter stub. Playground on that “trained” character still echoes or uses Apple base without the open adapter.
3. **CI / worker default is fake** when `mlx_lm` import fails or `BAM_LORA_FAKE=1`. That is correct for CI; it is easy to dogfood a “green” train that learned nothing.
4. **Train UI does not go through the job queue**, so M2 cancel/recovery does not apply to the path a user actually presses.

On a **16 GB** machine, 0.5B–1.5B 4-bit LoRA is the honest target; 3B is the catalog max (`minRamGB: 16`) and will be tight with OS reserve (fit gate uses 6 GB reserve + 1.5 GB fudge). The design is right to refuse 8 GB.

### 128 GB M3 vs Apple FM-only

The repo **never mentions a 128 GB M3**. There is no SKU, no “workstation mode,” no larger-than-3B catalog family (Llama is explicitly post-Qwen in K15).

Interpretation for a high-RAM machine:

| Workload | 128 GB M3 | Apple FM-only (no open stack) |
|----------|-----------|--------------------------------|
| Playground chat | Overkill; Apple FM or small MLX both fine | **This is the path Home already prefers** when Apple Intelligence is available. No venv, no HF weights. |
| Open LoRA ≤3B | Comfortable; fit gate will say OK | N/A |
| Open LoRA of larger HF models | Hardware would allow it; **product will not** — no catalog entries, no materializer families beyond Qwen2.5/ChatML, HF flag off | N/A |
| Apple adapter train | RAM does not remove the **toolkit + Developer Program + OS signature** tax | Same. Toolkit is external Python. Stubs work on any Mac. Real `.fmadapter` needs Apple’s CLI and a matching system model revision. |
| Voice F5 / Talk | RAM helps PyTorch MPS if you ever install the wheels | Not used by FM-only chat |

**Conclusion:** A 128 GB M3 is a **great dogfood machine for the open path** once someone manually `pip install -r Workers/python/requirements.lock` and downloads real MLX weights. It does **not** change the fact that the default app is drifting toward **Apple-chat + stub-train**. Shipping an “FM-only” SKU is *more* feasible than shipping honest open LoRA, and closer to what Home already gates on — but that **contradicts** ADR 0003 / K3 (“v1 primary = open mlx-lm”) and the M1 metric as written.

Apple FM inference requires the FoundationModels framework and `SystemLanguageModel` availability (`#available(macOS 26.0, *)` in the probe). Older macOS / CI = `.unsupported`. Do not promise Apple chat on macOS 14 (README’s stated minimum) without a qualifier.

### Apple Adapter Training Toolkit

**Feasible as a power-user escape hatch; not feasible as the novice “Specialize” button.**

Implemented:

- Probe for `examples/train_adapter.py` + `export/export_fmadapter.py` ([`FoundationToolkitConfig`](../Packages/BAMRunnersMLX/Sources/BAMRunnersMLX/FoundationToolkitConfig.swift)).
- Export mind JSONL to a toolkit-shaped folder (Train → Export reveals in Finder).
- `FoundationToolkitTrainService` / `FoundationModelsAdapterRunner` (queue arm).
- Import `.fmadapter`, stub publish, Playground `SystemLanguageModel.Adapter(fileURL:)` with stub detection and signature mismatch warnings.

Hard constraints the UI cannot remove:

- Toolkit is an **Apple Developer Program download**, not redistributable in the app (Settings/Train copy is honest).
- Separate Python env from the managed mlx venv (user types a python path).
- Adapters **bind to a system model revision**; OS updates require retrain (ADR 0003). Signature is a coarse `macos-x.y` string, not Apple’s real base-model digest.
- ADR “Later” still open: entitlement packaging, Background Assets, in-queue GRDB artifact upsert, real-time toolkit NDJSON.

A novice who taps **Specialize (Apple)** after creating a goblin will get a **stub** and think they fine-tuned Apple’s model. That is the most dangerous feasibility lie in the app.

### MCP

**Feasible today as a local agent sidecar; not feasible as a headless product.**

[`Docs/mcp-bridge.md`](mcp-bridge.md) and [`Workers/buildaimaker-mcp/Sources/main.swift`](../Workers/buildaimaker-mcp/Sources/main.swift) match the design: **stdio MCP process**, connects to `~/Library/Application Support/BuildAIMaker/mcp.sock` with `mcp.token`. The **app must already be running**. If not, `tools/call` returns `APP_NOT_RUNNING` (bridge stays up). Tool list is **frozen** for the bridge process lifetime.

This is the right shape for Grok Build (`command = .../buildaimaker-mcp`). It is **not**:

- an in-app MCP server
- a headless daemon (explicitly deferred in the Action API design)
- a complete tool surface (`examples.propose`, `character.create`, `dataset.addExamples`, chat, confirmations are specified and **absent**)

v1 poll-only jobs is correctly implemented (no MCP streaming).

### Python venv

**Feasible and partially honest in Settings; oversold on Home.**

- Creates a real venv under `Application Support/BuildAIMaker/envs/python/<spikeAppVersion>/`.
- Integrity / pins / L2 story is designed; missing pins in a dev tree soft-pass.
- Repair = wipe + recreate empty venv.
- User-provided Python is not wired as an “advanced escape hatch” except the Apple toolkit python field.
- Voice + LLM **share one requirements.txt** that includes `f5-tts` and `torch` — if anyone ever automates `pip install -r requirements.lock`, the LLM-only user pays the 5–8 GB voice tax. No split lockfiles in the installer.

K4 (“accept multi-GB runtime download with progress UI”) is **not implemented**. The progress bar animates against a 3–8 GB *budget* while creating a ~20 MB venv.

---

## Architecture

### BAM* package graph (what is solid)

`Package.swift` is the real map. Dependency rule from the design (UI → domain → runners; runners never import SwiftUI) is largely held. GRDB is the only external Swift dependency.

| Package | Role in practice | Maturity |
|---------|------------------|----------|
| BAMCore | Flags, paths, errors, runtime installer, onboarding, metrics | Dogfood-ready |
| BAMModels | IDs, JobSpec, modalities, TrainBackend, consent/persona shapes | Good (v1 frozen) |
| BAMPersistence | `library.sqlite` migrator **v1 only** | Good for v1; characters are **not** in SQLite |
| BAMDatasets | Import, validate, upsert, dedupe | Strongest domain module |
| BAMModelCatalog | Bundled catalog, fixture, optional HF | Good offline; HF is a side door |
| BAMJobs | Single-slot queue, state machine, fake runner | Solid **if** one controller owns it |
| BAMRunners | Protocol v1, supervisor, path jail | Solid for CI fixtures |
| BAMRunnersMLX | Materialize, dry-run, LoRA train, Apple toolkit | Two call paths (service vs queue) |
| BAMRunnersVoice | Composite runner, stub clone | Prototype |
| BAMInference | Backend factory, Apple FM, echo, MLX generate, Talk fakes | Chat usable; Talk fake |
| BAMPersonas | Resolver + pack zip | Separate product surface |
| BAMConsent | Hash-bound records | Used by Voices, not wizard FX |
| BAMCharacterStudio | Draft + template corpus + JSON store | App-facing SoT for “characters” |
| BAMAudioFX | Creature FX + system TTS | Wizard-only |
| BAMResourcesUI | Sidebar + colors | Thin |
| BAMControlPlane | Registry, state, events, App RPC | Generic kernel; **zero** BAM* deps |

Handlers for domain actions live in the **app target** ([`DomainActionHandlers.swift`](../Apps/BuildAIMaker/Sources/ControlPlane/DomainActionHandlers.swift)), not in BAMControlPlane. That keeps the kernel portable and also makes it easy for the app to keep “quick paths” that never register.

### Job queue: designed as one slot, implemented as several

[`JobQueueController`](../Packages/BAMJobs/Sources/BAMJobs/JobQueueController.swift) is a well-structured actor: concurrency 1, heartbeat, cancel, recover stale, persist to GRDB.

Live app constructs **at least three** controllers on the **same** `library.sqlite`:

| Owner | File | Runner |
|-------|------|--------|
| Control plane / MCP | [`ControlPlaneEnvironment.makeJobQueue`](../Apps/BuildAIMaker/Sources/ControlPlane/ControlPlaneEnvironment.swift) | Composite: **Fake** LLM + stub voice + Foundation adapter (real toolkit or fake) |
| Jobs sidebar | [`JobsViewModel.makeDefault`](../Apps/BuildAIMaker/Sources/Jobs/JobsViewModel.swift) | Same composite shape, **new actor** |
| Voices | [`VoiceCloneService.makeDefault`](../Packages/BAMRunnersVoice/Sources/BAMRunnersVoice/VoiceCloneService.swift) | Composite **without** foundation arm |

They share **rows** (same `JobStore` / DB file) but **not** in-memory progress, cancel sets, or the processor task. `recoverStaleJobs()` is called from control-plane bootstrap **and** Jobs `start()`. Two processors can observe the same `queued` row.

[`CompositeTrainingRunner`](../Packages/BAMRunnersVoice/Sources/BAMRunnersVoice/CompositeTrainingRunner.swift) comments that it exists so a **single** controller can route modalities “without dual processors fighting over the queue slot.” The app then creates multiple controllers anyway.

**Train UI is a fourth execution world:** [`TrainViewModel.startFullLoRATrain`](../Apps/BuildAIMaker/Sources/Train/TrainViewModel.swift) / `startAppleAdapterTrain` call `LoRATrainService` / `FoundationToolkitTrainService` on a `Task` inside the view model. They write `jobs/<uuid>/` directories but **do not** `enqueue` on any `JobQueueController`. Jobs pane will not show a live Train run. Cancel in Jobs will not stop Train. MCP `job_get` will not see it.

MCP `finetune.start` **does** enqueue — onto the control-plane queue, whose LLM arm is **always** `FakeTrainingRunner`. So:

- Human Train button → possibly real mlx-lm (if weights + wheels exist).
- Agent `finetune_start` → synthetic progress, no weight updates.

That is the opposite of “UI and MCP cannot diverge.”

### Control plane vs dual-write

Design invariant ([`design-native-app-action-api-mcp.md`](design-native-app-action-api-mcp.md)): *UI must not write domain state except by invoking handlers.*

**What landed (Layer A / parts of PR1–6, 8a–8b):**

- `ControlPlane` facade: registry + `StateStore` + `EventBus`.
- Builtins: `app.ping`, `app.getState`, `app.listActions`, `nav.go`, `selection.set`.
- Domain: `character.list`, `character.importMind`, `minds.dedupe`, `finetune.start`, `job.get` / `job.list` / `job.cancel`.
- App RPC Unix socket + token + pid lock ([`AppRPCServer`](../Packages/BAMControlPlane/Sources/BAMControlPlane/AppRPCServer.swift)).
- stdio bridge with a **known-map** of snake_case tools → action ids.

**What did not land (called out in that design’s own PR plan):**

| PR | Intent | Status |
|----|--------|--------|
| PR5b | Migrate import UI to handler; **kill dual path** | **Not done.** Wizard calls `DatasetLibraryService` directly. |
| PR6b | Jobs UI via handlers | **Not done.** JobsView owns its own controller. |
| PR7 | `examples.propose` + dataset writes | **Absent** |
| PR8d | Confirmations + allowlist profiles | Types exist (`confirmToken`, `ConfirmationChallenge`); **no enforcement** |
| PR9 | Agent Actions panel | **Absent** |
| PR10–11 | Headless + AGY CLI | **Absent** |

**UI → control plane usage today:**

- [`RootView`](../Apps/BuildAIMaker/Sources/RootView.swift) invokes `nav.go` on sidebar change (session projection only).
- [`BuildAIMakerApp`](../Apps/BuildAIMaker/Sources/BuildAIMakerApp.swift) always bootstraps the plane. `ff.controlPlane` is **not consulted**.
- No other SwiftUI view calls `controlPlane.invoke`.

So dual-write is **not** “wizard still alwaysCreates.” Dual-write is:

1. **Same domain function, two callers** (wizard upsert vs `character.importMind` upsert) — identity is shared; **audit, state projection, and future policy are not**.
2. **Datasets import** is a third writer with no identity policy.
3. **Train / Jobs / Voices / Personas / Character JSON save** all mutate SoT without actions.
4. **Two SoTs for “who is this character?”** — `CharacterLibraryStore` JSON vs GRDB `personas`.
5. **State Store is a write-through cache of whatever handlers ran**, not a rebuild-from-disk of the library (bootstrap only sets `counts.characters` once). Design said rebuild on launch; code does not.

MCP tool schemas are `additionalProperties: true` empty objects. Hosts cannot discover required params without reading `mcp-bridge.md`.

### Persistence split

```
~/Library/Application Support/BuildAIMaker/
  library.sqlite          # datasets, jobs, personas, consent, models, voices, …
  characters/*.json       # wizard drafts (not in GRDB)
  characters/<id>/        # FX wavs
  models/base|adapters|foundation-adapters/
  jobs/<id>/
  envs/python/…
  mcp.sock / mcp.token
```

Schema version is still **1** ([`ProtocolVersions`](../Packages/BAMCore/Sources/BAMCore/ProtocolVersions.swift)). Characters as JSON files was a fast studio decision; it will hurt Action API identity, backup, and “one library” stories until migrated.

### MCP as stdio bridge (do not over-claim)

Correct mental model:

```
Grok / MCP host
  --stdio-->  buildaimaker-mcp  (Workers/buildaimaker-mcp)
                 --Unix socket + token-->  AppRPCServer in BuildAIMaker.app
                                              --> ControlPlane.invoke
```

The app owns the plane. The bridge is a translator (`ListTools` / `Invoke`). No streaming. No app → no mutations. Token file is 0600; socket is 0600. Good enough for same-user local dogfood; not a multi-user security review.

---

## Implementation

### What is production-shaped (keep)

These pieces have tests, clear types, and look like they can survive a v1:

- Dataset validation + ShareGPT/OpenAI JSONL parser + import copy/reference ([`BAMDatasets`](../Packages/BAMDatasets/Sources/BAMDatasets), fixtures under `Tests/BAMDatasetsTests/Fixtures` and `Workers/fixtures/datasets`).
- Mind upsert + dedupe **domain** API and unit tests.
- GRDB v1 migrator + pre-migration `.bak`.
- Job **state machine** + heartbeat + fake runner tests.
- Runner protocol golden NDJSON + path jail (BAMRunners tests).
- Feature flags as a real config object (even if Settings cannot toggle them).
- Apple FM probe + playground backend factory + stub-adapter refusal.
- Character wizard persistence / resume / delete (CS-1 quality is high for a prototype).
- Creature FX renderer tests.
- Control-plane unit tests for ping/nav/state and App RPC tests.
- CI: `macos-14` `swift build` + `swift test` ([`.github/workflows/ci.yml`](../.github/workflows/ci.yml)). Honest about no codesign.

### What is dogfood / prototype (label it)

- **Train UI E2E** — works as a scripted Task, not as a job.
- **Fake/stub success paths** — Jobs “Start Fake Job”, Apple “Start (stub)”, LoRA “Start LoRA (fake)”, Talk fakes, Voice stub clone, echo playground. Too many greens.
- **Managed runtime** — venv only.
- **HF Hub** — real client exists; default flag off; Model Browser enables it anyway.
- **Personas pack zip** — likely the most complete “1.0 artifact” after datasets, but disconnected from Characters.
- **Consent** — real records; not bound to wizard voice.
- **MCP bridge** — usable for `app_get_state` / list / importMind / dedupe / fake finetune / job poll.
- **Home metrics** — incomplete instrumentation (M1 never fires; wizard import does not bump M4).

### What is missing or hollow

- No notarized `.app` / Helper embedding story in CI (design K14/K21). `swift run BuildAIMaker` is the distribution.
- No `character.create` / `character.save` / `character.delete` actions (UI deletes JSON directly).
- No `examples.propose` (UX doc Lab/LLM riff).
- Talk STT/TTS always fake ([`TalkBackendFactory`](../Packages/BAMInference/Sources/BAMInference/TalkBackendFactory.swift) `forceFake` ignored).
- `ff.voiceFinetune`, `ff.cloudRunner`, `ff.knowledgePacks`, `ff.talkMode` off — flags match design; UIs still visible.
- Confirmation policy, audit log persistence, CAS `expectedRevision` enforcement — types only.
- Library schema has not grown for characters, foundation adapter artifacts, or control-plane audit (ADR 0003 “in-queue GRDB artifact upsert” still open).
- README / Docs index / design Background not revised after the Character Studio + control-plane work.

### Quality risks (implementation-level)

1. **Success that is not learning** — stub adapters, fake jobs, echo backends, empty venvs marked installed.
2. **Queue races** — multiple `JobQueueController`s + `recoverStaleJobs` on one SQLite file.
3. **Train cancel / crash** — Train `Task` is not the job state machine; force-quit mid-LoRA is undefined vs M2.
4. **macOS version split** — README macOS 14+ vs Apple FM `macOS 26.0` availability vs CI macos-14 (FM unsupported in CI — OK if tests don’t require it).
5. **Model Browser flag bypass** — can perform network downloads while Home M5 claims “no network during train/play” (M5 increment sites: **none** in app code; the tile will always “pass”).
6. **Control plane handlers open their own `DatasetLibraryService` / `CharacterLibraryStore`** per invoke — fine for dogfood; not a unit-of-work with the job queue’s DB connection.
7. **Wizard encode JSONL vs handler encode JSONL** — two copies of messages[] encoding ([`CreateCharacterViewModel.encodeCurrentJSONL`](../Apps/BuildAIMaker/Sources/Characters/CreateCharacterViewModel.swift) vs `CharacterImportMindHandler.encodeJSONL`). Drift risk.
8. **Settings flags read-only** — dogfood cannot toggle Talk/HF/control plane without a rebuild.

### Production-ready vs prototype (blunt)

| Surface | Verdict |
|---------|---------|
| App launches, sidebar, library root | Dogfood-ready |
| Character create / resume / creature voice preview | Dogfood-ready (toy) |
| Playground text + Apple FM | Dogfood-ready **on a Mac where Apple Intelligence FM API is available** |
| Dataset import/validate | Closest to production |
| Open LoRA “for real” | Prototype + manual Python/weights |
| Apple adapter “for real” | Prototype + external toolkit |
| Jobs UI | Prototype (fake button, wrong queue) |
| Voices clone | Prototype (stub runner) |
| Personas packs | Mid (isolated) |
| Talk mode | Scaffold |
| MCP | Dogfood-ready as a **bridge**, incomplete as a **product API** |
| Control plane as single writer | Not adopted |
| Distribution / App Store / paid entitlement | Docs only |

---

## Highest-leverage next work (ranked)

1. **One job orchestrator for the whole app.** Inject `ControlPlaneEnvironment.jobQueue` into Jobs, Voices, and Train. Delete `JobsViewModel.makeDefault` / `VoiceCloneService.makeDefault` queue construction. Make Train `startFullLoRATrain` / `startAppleAdapterTrain` call `finetune.start` (or a shared domain service the handler also calls) so MCP and the hammer button are the same pipeline. Until this lands, every other train/UX fix is building on sand.

2. **Tell the truth in Home + Train + runtime.** Split “ready to chat” (Apple **or** echo/MLX) from “ready to train open LoRA” (venv **with mlx-lm** + real weights). Stop calling empty venv “runtime installed.” Either implement K4 (`pip install -r requirements.lock` with real byte progress) or relabel the button “Create Python venv (no ML packages).” Hide or disable “Start LoRA train” when `willUseFakeTrain` unless the user opts into “stub for plumbing.” Same for Apple “Start (stub).”

3. **Finish PR5b for real: wizard + Datasets write only through handlers.** `buildMind` should `invoke(character.importMind)`. Add `character.save` / `character.create` so drafts are not a silent JSON side-car. Expose `minds.dedupe` in Datasets (dry-run first). This is how “Robby mind” stays dead when agents arrive.

4. **Reconcile the two products in the sidebar and checklist.** Checklist should be: Create character → Hear voice → Chat in Playground → (optional) Train. Do not deep-link first-run to Datasets/Models/Train. Collapse or hide Advanced until a “Show lab surfaces” setting. Decide whether Personas **are** saved Characters (pack export from Done) or remain a power-user composition tool — then say so in UI copy.

5. **Replace `FakeTrainingRunner` on the control-plane LLM arm** with the same `LoRATrainService` / supervised mlx worker Train already uses (still allowing explicit fake for fixture). Otherwise MCP fine-tune is a demo.

6. **Instrument M1–M5 or remove the Home tiles.** Increment `trainCompleted` only on `didTrain && !fakeTrain` (or show a separate “stub runs” count). Increment M4 on wizard upsert. Increment or drop M5 (currently always pass).

7. **Apple FM-only SKU decision.** If Home’s gate is the future, update ADR 0003 / M1 / README (macOS version, no-Python chat SKU). If open LoRA remains v1 primary, stop auto-selecting Apple as the only selected model without an explicit “also pick an open model for train” step.

8. **Docs pass.** Refresh README package list, sidebar, flags, CI test list. Point `Docs/README.md` at MCP + Action API docs. Strike “repository is greenfield” from the system design Background.

9. **Migrate `characters/*.json` into GRDB** (library schema v2) so backup, Action API, and personas can share IDs. Not first if (1) is not done, but do it before packing a persona from a wizard character.

10. **Talk / F5 / Agent Actions** — only after (1)+(2)+(3). Shipping more surfaces that succeed via fakes will make dogfood feedback unusable.

---

## Risks (severity + mitigation)

| Risk | Severity | Why it matters | Mitigation |
|------|----------|----------------|------------|
| Split job queues + Train bypass | **Critical** | Lost jobs, double execution, MCP ≠ UI, M2 is theater | Single `JobQueueController` owned by the app; all starts go through it |
| Stub/fake success indistinguishable from learning | **Critical** | Users (and agents) will believe a goblin was fine-tuned | Hard-gate real vs stub in UI, adapter badges, `finetune.start` result (`fake: true`), refuse to mark M1 |
| Control plane not the write path | **High** | Next agent feature reintroduces Robby-mind and train races | PR5b/PR6b: delete direct service calls from views; handlers only |
| Home Apple-ready vs LoRA checklist | **High** | Novices bounce between Characters, Datasets, Models, Train | Two readiness states; rewrite `OnboardingStep` to the wizard loop |
| Empty venv advertised as train runtime | **High** | M1 cannot pass; support burden | Install wheels or rename; show `mlx_lm` import probe |
| Apple “Specialize” → stub adapter | **High** | Trust hit; Playground ignores stub | Disable Start unless toolkit probe passes; Export-only otherwise |
| Model Browser ignores `ff.hfHubDownload` | **Med** | Surprise network; M5 story broken | Honor the flag; require explicit Settings opt-in |
| Characters JSON vs Personas GRDB | **Med** | Two identities; pack export won’t include the wizard creature | One entity type, or explicit “Promote character to persona” |
| Creature FX vs F5 Voices | **Med** | User thinks they cloned a voice; they applied a filter | Rename Advanced Voices to “Voice clone (lab)”; wizard stays “Creature voice” |
| README / design staleness | **Med** | New contributors implement the wrong app | Doc refresh (item 8) |
| macOS 14 README vs FM macOS 26 API | **Med** | Apple-default Home is empty on stated minimum OS | Document two tiers: workbench on 14+, Apple chat on FM-capable OS |
| MCP tool list frozen + empty schemas | **Med** | Agents guess params; miss new actions until restart | Generate inputSchema from `ActionDefinition`; refresh tools on hello |
| Confirmation/allowlist not implemented | **Med** | `minds.dedupe` dryRun=false and `finetune.start` are MCP-callable with no UI confirm | Implement PR8d before advertising MCP write tools |
| 128 GB machine used as an excuse to skip product gates | **Low–Med** | Hardware hides missing installer/catalog work | Keep K16/K15; don’t add huge models until the 0.5B path is truly one-click |
| Paid + OSS compliance (K24) | **Low now, High at launch** | mlx-lm / F5 / torch licenses | Counsel review before any paid build; already flagged in design |
| Multiple SQLite connections + recover races | **Med** | Corrupt job status, stuck `running` | One `LibraryDatabase` in the app environment, passed down |
| Talk pane visible but fake/off | **Low** | Looks broken | Hide Talk until `ff.talkMode` and a real STT |

---

## Appendix — files this review is grounded in

- [`README.md`](../README.md), [`Docs/README.md`](README.md), [`Docs/design-buildaimaker.md`](design-buildaimaker.md) (goals + K-decisions), [`Docs/design-native-app-action-api-mcp.md`](design-native-app-action-api-mcp.md), [`Docs/mcp-bridge.md`](mcp-bridge.md), [`Docs/character-studio-ux.md`](character-studio-ux.md), [`Docs/adr/0003-apple-foundation-models.md`](adr/0003-apple-foundation-models.md), [`Docs/native-vs-python-backends.md`](native-vs-python-backends.md)
- [`Package.swift`](../Package.swift)
- App: [`RootView.swift`](../Apps/BuildAIMaker/Sources/RootView.swift), [`BuildAIMakerApp.swift`](../Apps/BuildAIMaker/Sources/BuildAIMakerApp.swift), [`HomeOnboardingView.swift`](../Apps/BuildAIMaker/Sources/Home/HomeOnboardingView.swift), [`CreateCharacterViewModel.swift`](../Apps/BuildAIMaker/Sources/Characters/CreateCharacterViewModel.swift), [`CreateCharacterWizardView.swift`](../Apps/BuildAIMaker/Sources/Characters/CreateCharacterWizardView.swift), [`CharactersView.swift`](../Apps/BuildAIMaker/Sources/Characters/CharactersView.swift), [`TrainView.swift`](../Apps/BuildAIMaker/Sources/Train/TrainView.swift), [`TrainViewModel.swift`](../Apps/BuildAIMaker/Sources/Train/TrainViewModel.swift), [`JobsView.swift`](../Apps/BuildAIMaker/Sources/Jobs/JobsView.swift), [`JobsViewModel.swift`](../Apps/BuildAIMaker/Sources/Jobs/JobsViewModel.swift), [`DatasetsView.swift`](../Apps/BuildAIMaker/Sources/Datasets/DatasetsView.swift), [`PlaygroundView.swift`](../Apps/BuildAIMaker/Sources/Playground/PlaygroundView.swift), [`SettingsView.swift`](../Apps/BuildAIMaker/Sources/SettingsView.swift)
- Control plane: [`ControlPlaneEnvironment.swift`](../Apps/BuildAIMaker/Sources/ControlPlane/ControlPlaneEnvironment.swift), [`DomainActionHandlers.swift`](../Apps/BuildAIMaker/Sources/ControlPlane/DomainActionHandlers.swift), [`Packages/BAMControlPlane`](../Packages/BAMControlPlane/Sources/BAMControlPlane)
- [`Workers/buildaimaker-mcp/Sources/main.swift`](../Workers/buildaimaker-mcp/Sources/main.swift)
- Domain: [`MindDatasetUpsert.swift`](../Packages/BAMDatasets/Sources/BAMDatasets/MindDatasetUpsert.swift), [`OnboardingChecklist.swift`](../Packages/BAMCore/Sources/BAMCore/OnboardingChecklist.swift), [`FeatureFlags.swift`](../Packages/BAMCore/Sources/BAMCore/FeatureFlags.swift), [`RuntimeInstaller.swift`](../Packages/BAMCore/Sources/BAMCore/RuntimeInstaller.swift), [`SidebarDestination.swift`](../Packages/BAMResourcesUI/Sources/BAMResourcesUI/SidebarDestination.swift)
