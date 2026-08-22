import SwiftUI
import BAMCharacterStudio
import BAMCore
import BAMInference
import BAMModelCatalog
import BAMModels
import BAMResourcesUI
import BAMRunnersMLX

/// Teach a character from their stories. Expert knobs stay under Advanced.
struct TrainView: View {
    @EnvironmentObject private var characterLaunch: CharacterStudioLaunchContext
    @EnvironmentObject private var controlPlane: ControlPlaneEnvironment
    @StateObject private var model = TrainViewModel()
    @State private var lastSessionNonce = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let loadError = model.loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            content
        }
        .background(BAMColors.detailBackground)
        .navigationTitle("Teach")
        .task {
            // Re-run every time this page is shown (sidebar switch does not
            // always fire onAppear again). Do not invalidate the mlx-lm cache
            // here — that forced a multi-second `import mlx_lm` on the main
            // thread and made Start teaching ignore the first clicks.
            model.bootstrap()
            rebindCharacterFromSession()
            applyPendingCharacter()
            async let tools: Void = model.warmupTeachingTools()
            async let leftover: Void = model.loadLeftoverRun(via: controlPlane)
            _ = await (tools, leftover)
        }
        .onChange(of: characterLaunch.pendingTrain?.token) { _, _ in
            applyPendingCharacter()
        }
        .onChange(of: controlPlane.sessionNonce) { _, _ in
            applySessionFromControlPlane()
        }
        .onChange(of: model.selectedModelPath) {
            model.resolveModelSizeClass()
            model.recomputeHardwareFit()
        }
    }

    private func rebindCharacterFromSession() {
        if let id = controlPlane.selectionMap["characterId"],
           let draft = try? CharacterLibraryStore().load(id: id)
        {
            characterLaunch.bindTrain(from: draft)
        }
    }

    private func applySessionFromControlPlane() {
        let nonce = controlPlane.sessionNonce
        guard !nonce.isEmpty, nonce != lastSessionNonce else { return }
        lastSessionNonce = nonce
        if let id = controlPlane.selectionMap["characterId"],
           let draft = try? CharacterLibraryStore().load(id: id)
        {
            characterLaunch.bindTrain(from: draft)
            applyPendingCharacter()
        }
    }

    private func applyPendingCharacter() {
        if let target = characterLaunch.consumeTrain() {
            model.applyCharacterLaunch(target)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Teach this character")
                    .font(.headline)
                Text("Uses the stories you already saved. Takes a while.")
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
            }
            Spacer()
            Button {
                Task {
                    model.reload()
                    async let tools: Void = model.warmupTeachingTools()
                    async let leftover: Void = model.loadLeftoverRun(via: controlPlane)
                    _ = await (tools, leftover)
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Reload stories and models")

            if model.trainBackend == .openMlxLora {
                Button {
                    model.startQueuedTrain(via: controlPlane)
                } label: {
                    if model.isRunning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(model.openLoRAStartTitle, systemImage: "sparkles")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canStartTeaching)
                .guideHighlight("train.start")
                .help("Reads the stories and updates how the character talks.")
            } else {
                Button {
                    model.startQueuedTrain(via: controlPlane)
                } label: {
                    if model.isRunning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(model.appleStartTitle, systemImage: "sparkles")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canFullTrain)
                .guideHighlight("train.start")
            }
        }
        .padding(12)
    }

    private var content: some View {
        Form {
            Section {
                Text(
                    "Teaching means: take this character’s stories, practice on a starting model, and save a small add-on so Playground sounds more like them. You do not need to set numbers unless you want to."
                )
                .font(.callout)
                .foregroundStyle(BAMColors.secondaryLabel)
            }

            if let name = model.boundCharacterName {
                Section {
                    Label("Teaching \(name)", systemImage: "theatermasks")
                        .font(.callout.weight(.semibold))
                }
            }

            Section("Before you start") {
                checklistRow(
                    ok: model.storiesReady,
                    title: "Stories ready",
                    detail: model.storiesReady
                        ? model.selectedDatasetName
                        : "Finish a character’s Story step, or pick a dataset below."
                )
                checklistRow(
                    ok: model.modelReady,
                    title: "Starting model downloaded",
                    detail: model.modelReady
                        ? model.selectedModelName
                        : "Install a model from Models, or pick one in the character wizard."
                )
                checklistRow(
                    ok: model.toolsReady,
                    title: "Teaching tools ready",
                    detail: model.toolsReady
                        ? "This Mac can really update the character (not a practice run)."
                        : (!model.teachingToolsChecked
                           ? "Checking the teaching tools…"
                           : (model.openLoRABlockerMessage
                              ?? "Open Settings and tap Repair, then come back."))
                )
                checklistRow(
                    ok: model.macReady,
                    title: "This Mac looks big enough",
                    detail: model.hardwareMessage
                        ?? (model.macReady ? "Memory estimate is OK." : "This Mac may be too small.")
                )
            }

            lastRunSection

            Section("Stories to learn from") {
                if model.datasets.isEmpty {
                    Text("No stories yet. Open a character and finish the Story step, or import a dataset.")
                        .foregroundStyle(BAMColors.tertiaryLabel)
                } else {
                    Picker("Stories", selection: $model.selectedDatasetId) {
                        ForEach(model.mindPicks) { pick in
                            Text(pick.title).tag(Optional(pick.datasetId))
                        }
                    }
                    .onChange(of: model.selectedDatasetId) { _, _ in
                        model.syncModelToSelectedMind()
                    }
                    if let note = model.pairNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(BAMColors.secondaryLabel)
                    }
                }
            }

            if model.trainBackend == .openMlxLora {
                Section("Starting model") {
                    if model.localModels.isEmpty && model.selectedModelPath == nil {
                        Text("No models downloaded yet. Open Models and install one.")
                            .foregroundStyle(BAMColors.tertiaryLabel)
                    } else {
                        Picker("Model", selection: $model.selectedModelPath) {
                            ForEach(model.localModels) { m in
                                Text(model.friendlyModelName(path: m.localPath)).tag(Optional(m.localPath))
                            }
                        }
                        Text("Stays with the stories’ character unless you change it here.")
                            .font(.caption)
                            .foregroundStyle(BAMColors.tertiaryLabel)
                    }
                }
            }

            DisclosureGroup(isExpanded: $model.showAdvanced) {
                advancedSections
            } label: {
                Text("Advanced (optional)")
                    .font(.callout.weight(.semibold))
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var lastRunSection: some View {
        if let run = model.lastRun {
            Section {
                HStack(spacing: 8) {
                    Text(runBadge(run))
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(runColor(run).opacity(0.2), in: Capsule())
                        .foregroundStyle(runColor(run))
                    Text(run.whenLabel)
                        .font(.caption)
                        .foregroundStyle(BAMColors.secondaryLabel)
                }
                Text(run.headline)
                    .font(.callout.weight(.semibold))
                Text(run.explanation)
                    .font(.callout)
                    .foregroundStyle(BAMColors.secondaryLabel)
                Text(run.nextStep)
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
                if let raw = run.rawDetail {
                    DisclosureGroup("Technical details") {
                        Text(raw)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                }
            } header: {
                Text(run.isFromThisVisit ? "This visit" : "Last time (not running now)")
            }
        }
    }

    @ViewBuilder
    private var advancedSections: some View {
        Section("How you teach") {
            Picker("Method", selection: $model.trainBackend) {
                ForEach(TrainBackend.allCases) { backend in
                    Text(backend.noviceTitle).tag(backend)
                }
            }
            .pickerStyle(.segmented)
            Text(model.trainBackend.noviceHelp)
                .font(.caption)
                .foregroundStyle(BAMColors.secondaryLabel)
        }

        if model.trainBackend == .openMlxLora {
            Section {
                Text("If you’re learning: pick a starter, then change one thing at a time. Leave the rest.")
                    .font(.callout)
                    .foregroundStyle(BAMColors.secondaryLabel)
                Picker("Starter", selection: Binding(
                    get: { model.teachStarter },
                    set: { model.applyTeachStarter($0) }
                )) {
                    ForEach(TeachStarter.allCases) { starter in
                        Text(starter.title).tag(starter)
                    }
                }
                .pickerStyle(.segmented)
                Text(model.teachCoachLine)
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 4) {
                    Stepper(value: $model.epochs, in: 1...10, step: 1) {
                        Text("Reread the stories \(model.epochs) time\(model.epochs == 1 ? "" : "s")")
                    }
                    Text(TeachAdvice.epochs(model.epochs))
                        .font(.caption)
                        .foregroundStyle(BAMColors.tertiaryLabel)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Stepper(value: $model.loraRank, in: 4...64, step: 4) {
                        Text("How much they can change: \(model.loraRank)")
                    }
                    Text(TeachAdvice.changeAmount(model.loraRank))
                        .font(.caption)
                        .foregroundStyle(BAMColors.tertiaryLabel)
                }

                DisclosureGroup("More numbers") {
                    VStack(alignment: .leading, spacing: 4) {
                        Stepper(value: $model.maxSeqLen, in: 512...8192, step: 512) {
                            Text("How long a memory snippet: \(model.maxSeqLen)")
                        }
                        Text(TeachAdvice.snippet(model.maxSeqLen))
                            .font(.caption)
                            .foregroundStyle(BAMColors.tertiaryLabel)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Stepper(value: $model.batchSize, in: 1...8, step: 1) {
                            Text("How many stories at once: \(model.batchSize)")
                        }
                        Text(TeachAdvice.batch(model.batchSize))
                            .font(.caption)
                            .foregroundStyle(BAMColors.tertiaryLabel)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Stepper(value: $model.gradAccum, in: 1...16, step: 1) {
                            Text("How carefully to step: \(model.gradAccum)")
                        }
                        Text(TeachAdvice.careful(model.gradAccum))
                            .font(.caption)
                            .foregroundStyle(BAMColors.tertiaryLabel)
                    }
                    if let path = model.selectedModelPath {
                        Text(path)
                            .font(.caption2)
                            .foregroundStyle(BAMColors.tertiaryLabel)
                            .textSelection(.enabled)
                    }
                    Text(
                        String(
                            format: "About %gB · %d-bit · %@",
                            model.fitParamCountB,
                            model.fitQuantBits,
                            model.modelCapability.shortLabel
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(BAMColors.tertiaryLabel)
                }
            }

            hardwareFitSection

            Section {
                Button {
                    model.validateAndDryRun()
                } label: {
                    Label("Check setup (don’t teach yet)", systemImage: "checkmark.shield")
                }
                .disabled(!model.canDryRun)
                Text("Writes a practice folder and asks the helper to wake up. Does not change the character.")
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
                if let adapter = model.lastPublishedAdapterPath {
                    Text("Saved add-on: \(adapter)")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .textSelection(.enabled)
                }
                if let summary = model.resultSummary, model.lastRun == nil {
                    Text(summary)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        } else {
            appleFoundationSections
        }
    }

    private func checklistRow(ok: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? .green : BAMColors.tertiaryLabel)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(ok ? BAMColors.secondaryLabel : .orange)
            }
        }
    }

    private func runBadge(_ run: TeachRunStatus) -> String {
        switch run.phase {
        case .working: return run.isFromThisVisit ? "Running" : "Still running"
        case .succeeded: return "Worked"
        case .failed: return "Failed"
        case .cancelled: return "Stopped"
        }
    }

    private func runColor(_ run: TeachRunStatus) -> Color {
        switch run.phase {
        case .working: return .blue
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }

    @ViewBuilder
    private var appleFoundationSections: some View {
        Section("Apple on-device model") {
            Label(model.appleModelStatus.title, systemImage: model.appleModelStatus.isUsable ? "checkmark.circle.fill" : "exclamationmark.triangle")
                .foregroundStyle(model.appleModelStatus.isUsable ? .green : .orange)
            Text(model.appleModelStatus.detail)
                .font(.caption)
                .foregroundStyle(BAMColors.secondaryLabel)
        }

        Section("Apple Adapter Training Toolkit") {
            HStack {
                TextField("Toolkit folder", text: $model.toolkitRootPath)
                    .textFieldStyle(.roundedBorder)
                Button("Browse…") { model.chooseToolkitFolder() }
            }
            TextField("Python (optional)", text: $model.toolkitPythonPath)
                .textFieldStyle(.roundedBorder)
            Label(
                model.toolkitInstalled ? "Toolkit detected" : "Toolkit not ready",
                systemImage: model.toolkitInstalled ? "checkmark.circle.fill" : "exclamationmark.triangle"
            )
            .foregroundStyle(model.toolkitInstalled ? .green : .orange)
            Text(model.toolkitProbeDetail)
                .font(.caption)
                .foregroundStyle(BAMColors.secondaryLabel)
            Stepper(value: $model.epochs, in: 1...10, step: 1) {
                Text("Reread the stories \(model.epochs) time\(model.epochs == 1 ? "" : "s")")
            }
        }

        Section("Installed Apple add-ons") {
            if model.foundationAdapters.isEmpty {
                Text("None yet.")
                    .foregroundStyle(BAMColors.tertiaryLabel)
            } else {
                ForEach(model.foundationAdapters) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.displayName)
                            .font(.callout.weight(.semibold))
                        Text(row.directoryURL.path)
                            .font(.caption2)
                            .foregroundStyle(BAMColors.tertiaryLabel)
                            .lineLimit(1)
                    }
                }
            }
            HStack {
                Button("Export stories") { model.exportForAppleToolkit() }
                    .disabled(!model.canExportAppleToolkit)
                Button("Import add-on") { model.importAppleFMAdapter() }
                Button("Practice stub") { model.publishAppleAdapterStub() }
                    .disabled(!model.canPublishAppleStub)
            }
        }
    }

    private var hardwareFitSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                fitStatusBadge
                VStack(alignment: .leading, spacing: 4) {
                    if let peak = model.fitPeakGB, let required = model.fitRequiredGB,
                       let available = model.fitAvailableGB
                    {
                        Text(
                            String(
                                format: "This job wants about %@ GB. This Mac has about %@ GB free to work with (peak ~%@ GB).",
                                HardwareFitGate.formatGB(required),
                                HardwareFitGate.formatGB(available),
                                HardwareFitGate.formatGB(peak)
                            )
                        )
                        .font(.callout)
                        .foregroundStyle(fitForeground)
                    }
                    if let message = model.hardwareMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(fitForeground)
                    }
                }
            }
            if !model.fitSuggestions.isEmpty {
                ForEach(model.fitSuggestions, id: \.self) { tip in
                    Text("• \(tip)")
                        .font(.caption2)
                        .foregroundStyle(BAMColors.secondaryLabel)
                }
            }
        } header: {
            Text("Memory check")
        }
    }

    private var fitStatusBadge: some View {
        let label: String
        let color: Color
        switch model.fitStatus {
        case .ok:
            label = "OK"
            color = .green
        case .warning:
            label = "Tight"
            color = .orange
        case .refuse:
            label = "Too small"
            color = .red
        }
        return Text(label)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    private var fitForeground: Color {
        switch model.fitStatus {
        case .ok: return BAMColors.secondaryLabel
        case .warning: return .orange
        case .refuse: return .red
        }
    }
}

private extension TrainBackend {
    var noviceTitle: String {
        switch self {
        case .openMlxLora: return "This Mac"
        case .appleFoundationAdapter: return "Apple Intelligence"
        }
    }

    var noviceHelp: String {
        switch self {
        case .openMlxLora:
            return "Recommended. Teaches the model you already downloaded."
        case .appleFoundationAdapter:
            return "Special path for Apple’s on-device model. Needs Apple’s toolkit."
        }
    }
}
