import AppKit
import BAMAudioFX
import BAMCharacterStudio
import BAMModelCatalog
import BAMResourcesUI
import SwiftUI

/// Linear Create Character flow: Name → Model → Story → Voice → Done.
struct CreateCharacterWizardView: View {
    @EnvironmentObject private var controlPlane: ControlPlaneEnvironment
    @StateObject private var model: CreateCharacterViewModel
    @Binding var isPresented: Bool
    /// When set, resume this draft instead of starting blank.
    var resumeDraft: CharacterDraft? = nil
    /// Jump to Playground after finish, carrying character model + system prompt.
    var onGoPlayground: ((CharacterDraft) -> Void)?
    /// Jump to Train after finish, carrying character model + mind dataset.
    var onGoTrain: ((CharacterDraft) -> Void)?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name
        case customSpecies
        case vibe
        case story
    }

    init(
        isPresented: Binding<Bool>,
        resumeDraft: CharacterDraft? = nil,
        onGoPlayground: ((CharacterDraft) -> Void)? = nil,
        onGoTrain: ((CharacterDraft) -> Void)? = nil
    ) {
        self._isPresented = isPresented
        self.resumeDraft = resumeDraft
        self.onGoPlayground = onGoPlayground
        self.onGoTrain = onGoTrain
        // Seed ViewModel with the draft so the first frame already has name/species/etc.
        self._model = StateObject(wrappedValue: CreateCharacterViewModel(initialDraft: resumeDraft))
    }

    var body: some View {
        VStack(spacing: 0) {
            progressBar
            Divider()
            whatToDoNowBanner
            if model.step != .model {
                modelStatusBanner
                Divider()
            }

            // Scrollable middle — must shrink so the footer never leaves the sheet.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let err = model.lastError {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.08))
            }

            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(BAMColors.detailBackground)
        .navigationTitle(wizardNavigationTitle)
        // Actions live only in the bottom footer on every step (no duplicate toolbar buttons).
        .onAppear {
            activateKeyWindow()
            model.attachControlPlane(controlPlane)
            // Re-apply resume in case the sheet identity reused a ViewModel.
            model.load(draft: resumeDraft)
            if controlPlane.selectionMap["wizardStep"] == "voice" {
                model.step = .voice
            } else if controlPlane.selectionMap["wizardStep"] == "mind" {
                model.step = .mind
            } else if controlPlane.selectionMap["wizardStep"] == "model" {
                model.step = .model
            }
            focusedField = model.step == .mind ? .story : (model.step == .meet ? .name : nil)
        }
        .onDisappear {
            if model.step != .done {
                model.saveAndExit()
            }
        }
        .onChange(of: model.step) { _, newStep in
            activateKeyWindow()
            model.refreshModels()
            model.persistDraft()
            switch newStep {
            case .meet: focusedField = .name
            case .model: focusedField = nil
            case .mind: focusedField = .story
            case .voice, .done: focusedField = nil
            }
        }
        .onChange(of: model.draft.name) { _, _ in
            if model.canGoNextFromMeet {
                model.persistDraft()
            }
        }
    }

    private var wizardNavigationTitle: String {
        if resumeDraft == nil { return "Create a character" }
        if model.isEditingComplete || (resumeDraft?.isComplete == true && model.step != .done) {
            return "Edit character"
        }
        return "Continue character"
    }

    // MARK: - Progress

    private var progressBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(CreateCharacterViewModel.Step.userSteps.enumerated()), id: \.element.id) { index, s in
                let n = index + 1
                let active = model.step == s
                let done = model.step.rawValue > s.rawValue || (model.step == .done && s != .done)
                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(done || active ? Color.accentColor : Color.secondary.opacity(0.25))
                            .frame(width: 26, height: 26)
                        if done && !active {
                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                        } else {
                            Text("\(n)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(active || done ? .white : .secondary)
                        }
                    }
                    Text(s.shortTitle)
                        .font(.caption2.weight(active ? .semibold : .regular))
                        .foregroundStyle(active ? .primary : BAMColors.secondaryLabel)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                if s != .voice {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(BAMColors.tertiaryLabel)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var whatToDoNowBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.right.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("What to do now")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BAMColors.secondaryLabel)
                Text(model.step.instruction)
                    .font(.body.weight(.medium))
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08))
    }

    /// Compact strip: selected model / install status (hidden on dedicated Model step).
    private var modelStatusBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: model.draft.hasSelectedBaseModel ? "checkmark.circle.fill" : model.modelStatus.symbol)
                .font(.title3)
                .foregroundStyle(model.draft.hasSelectedBaseModel ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Base model for this character")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BAMColors.secondaryLabel)
                if model.draft.hasSelectedBaseModel {
                    Text(model.draft.baseModelName ?? "Selected model")
                        .font(.callout.weight(.semibold))
                    if let key = model.draft.baseModelSourceKey {
                        Text(key)
                            .font(.caption)
                            .foregroundStyle(BAMColors.secondaryLabel)
                            .textSelection(.enabled)
                    }
                } else {
                    Text(model.modelStatus.title)
                        .font(.callout.weight(.semibold))
                    Text(model.modelStatus.detail)
                        .font(.caption)
                        .foregroundStyle(BAMColors.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if model.step != .meet, !model.draft.hasSelectedBaseModel {
                Button("Choose model") {
                    model.step = .model
                    model.persistDraft()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((model.draft.hasSelectedBaseModel ? Color.green : Color.orange).opacity(0.08))
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            Group {
                switch model.step {
                case .meet:
                    meetStep
                case .model:
                    modelStep
                case .mind:
                    mindStep
                case .voice:
                    voiceStep
                case .done:
                    doneStep
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Steps

    private var meetStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Step 1 — Name & type")
                .font(.title2.weight(.semibold))

            LabeledContent("Name (required)") {
                TextField("e.g. Zorp, Swamp Priest, Unit-7", text: $model.draft.name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .name)
            }

            Text("What kind of creature?")
                .font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                ForEach(CreatureSpeciesPreset.allCases) { preset in
                    Button {
                        model.applySpeciesPreset(preset)
                    } label: {
                        Text(preset.title)
                            .frame(maxWidth: .infinity)
                            .padding(10)
                            .background(
                                model.draft.speciesPreset == preset
                                    ? Color.accentColor.opacity(0.2)
                                    : Color.secondary.opacity(0.08)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }

            if model.draft.speciesPreset == .custom {
                TextField("Describe the species", text: $model.draft.customSpecies)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .customSpecies)
            }

            Text("Vibe (optional)")
                .font(.headline)
            TextField("e.g. polite outsider, grumpy, curious", text: $model.draft.vibe)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .vibe)

            if !model.canGoNextFromMeet {
                tip("Type a name, then press Continue below.")
            }
        }
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Step 2 — Base model")
                .font(.title2.weight(.semibold))

            Text("Pick how this character will chat. Apple’s on-device model is preferred when ready (no download). Open MLX models are for optional fine-tune later.")
                .foregroundStyle(BAMColors.secondaryLabel)

            Text("Available models")
                .font(.headline)

            if model.installedModels.isEmpty {
                tip("Apple on-device model is not ready and nothing is installed under models/base. Enable Apple Intelligence, or Install a catalog row below.")
            } else {
                VStack(spacing: 8) {
                    ForEach(model.installedModels) { m in
                        Button {
                            model.selectModel(m)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: model.isSelected(m) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(model.isSelected(m) ? Color.accentColor : BAMColors.secondaryLabel)
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        if m.isAppleFoundation {
                                            Image(systemName: "apple.logo")
                                                .foregroundStyle(.primary)
                                        }
                                        Text(m.name)
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        if let badge = m.badge {
                                            Text(badge)
                                                .font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(
                                                    (m.isAppleFoundation ? Color.green : Color.orange).opacity(0.25),
                                                    in: Capsule()
                                                )
                                        }
                                    }
                                    Text(m.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(BAMColors.secondaryLabel)
                                        .textSelection(.enabled)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(model.isSelected(m)
                                          ? Color.accentColor.opacity(0.12)
                                          : Color.secondary.opacity(0.06))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(model.isSelected(m) ? Color.accentColor : Color.clear, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Catalog installs (open multi-model)
            Text("Open models — install more (optional)")
                .font(.headline)
                .padding(.top, 8)

            Text("For fine-tuning with open weights. Fixture/stubs install offline; real multi-GB weights via Models → Browse sources.")
                .font(.caption)
                .foregroundStyle(BAMColors.secondaryLabel)

            VStack(spacing: 8) {
                ForEach(model.catalogEntries) { entry in
                    catalogInstallRow(entry)
                }
            }

            if model.canGoNextFromModel {
                Label(
                    "Selected: \(model.draft.baseModelName ?? "model")",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
                .font(.callout)
            } else {
                tip("Select Apple on-device (when listed) or install/select an open model, then Continue.")
            }
        }
    }

    private func catalogInstallRow(_ entry: CatalogEntry) -> some View {
        let installed = model.isCatalogEntryInstalled(entry)
        let installing = model.installingSourceKey == entry.sourceKey
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(entry.name)
                        .font(.body.weight(.medium))
                    if entry.isFixture {
                        Text("Fixture")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.25), in: Capsule())
                    }
                    if installed {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                Text(entry.sourceKey)
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
                    .textSelection(.enabled)
                Text(String(format: "%gB · %d-bit · min %d GB RAM", entry.paramCountB, entry.quantBits, entry.minRamGB))
                    .font(.caption2)
                    .foregroundStyle(BAMColors.tertiaryLabel)
            }
            Spacer(minLength: 8)
            Button {
                model.installCatalogEntry(entry)
            } label: {
                if installing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 72)
                } else {
                    Text(installed ? "Reinstall" : "Install")
                        .frame(minWidth: 72)
                }
            }
            .buttonStyle(.bordered)
            .disabled(model.installingSourceKey != nil)
            .help(entry.isFixture
                  ? "Copy offline fixture into models/base"
                  : "Install offline dogfood stub (or real weights when HF Hub is on)")
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var mindStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Step 3 — How they talk")
                .font(.title2.weight(.semibold))

            Text("Paste a short story, lore, or sample lines. We turn that into practice dialogues (a dataset) for the base model you selected.")
                .foregroundStyle(BAMColors.secondaryLabel)

            MacTextEditor(text: $model.draft.storyPaste, minHeight: 120)
                .frame(minHeight: 120, maxHeight: 160)

            DisclosureGroup("Speech style (optional)") {
                FlowTags(tags: StyleTag.allCases, selection: $model.draft.styleTags)
                    .padding(.top, 8)
            }

            if model.mindBuilt {
                Label(
                    "Mind ready — \(model.draft.examples.count) practice lines saved.",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
                .font(.callout)

                // Outer wizard ScrollView handles overflow; avoid nested scroll traps.
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.draft.examples.prefix(4)) { ex in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("You: \(ex.user)")
                                .font(.caption.weight(.semibold))
                            Text(ex.assistant)
                                .font(.caption)
                                .foregroundStyle(BAMColors.secondaryLabel)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                HStack {
                    Button("Rebuild from paste") {
                        Task { await model.buildMindAndImport() }
                    }
                    .disabled(model.isWorking)
                    Button("Add more lines") {
                        Task { await model.riffMoreAndImport() }
                    }
                    .disabled(model.isWorking)
                }
                .font(.callout)
            } else {
                tip("Click the green button below: “Build how they talk”. You don’t need perfect writing.")
            }
        }
    }

    private var voiceStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Step 4 — How they sound")
                .font(.title2.weight(.semibold))

            Text("Tap a sound. Each card is a different speaker. Filters only dress up robots and creatures — they don’t invent a new person.")
                .foregroundStyle(BAMColors.secondaryLabel)

            VStack(alignment: .leading, spacing: 6) {
                Text("Overall range")
                    .font(.callout.weight(.semibold))
                Picker("Overall range", selection: registerBinding) {
                    ForEach(VoiceRegister.allCases) { reg in
                        Text(reg.title).tag(reg)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.isWorking)
                Text(
                    (VoiceRegister(rawValue: model.draft.voiceRegister) ?? .higher).detail
                    + ". The sound card still adds the character."
                )
                .font(.caption)
                .foregroundStyle(BAMColors.secondaryLabel)
            }

            GroupBox("They’ll say") {
                Text(model.voicePreviewSpeechText())
                    .font(.callout)
                    .foregroundStyle(BAMColors.secondaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                ForEach(CreatureVoicePreset.allCases) { preset in
                    let selected = model.draft.voicePreset == preset.rawValue
                    Button {
                        model.applyVoicePresetAndHear(preset)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(preset.title)
                                .font(.callout.weight(.semibold))
                            Text(preset.plainSummary)
                                .font(.caption)
                                .foregroundStyle(BAMColors.secondaryLabel)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(preset.catalogSpeakerLabel)
                                .font(.caption2)
                                .foregroundStyle(BAMColors.secondaryLabel.opacity(0.85))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(
                            selected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isWorking)
                    .help("Play a preview as \(preset.title)")
                }
            }

            if model.isWorking {
                Label("Playing a preview…", systemImage: "speaker.wave.2")
                    .font(.callout)
                    .foregroundStyle(BAMColors.secondaryLabel)
            } else if model.voiceReady {
                Label(
                    "That’s \(CreatureVoicePreset(rawValue: model.draft.voicePreset)?.title ?? "their") voice. Use Hear again after any tweak.",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
                .font(.callout)
            }

            DisclosureGroup("Tweak this voice") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Optional. Presets already set these. Hear again after you drag.")
                        .font(.caption)
                        .foregroundStyle(BAMColors.secondaryLabel)

                    voiceRangeSlider("How deep?", low: "Deeper", high: "Higher", keyPath: \.size)
                    voiceRangeSlider("How fast?", low: "Slower", high: "Faster", keyPath: \.speed)
                    voiceRangeSlider("How rough?", low: "Smooth", high: "Gravelly", keyPath: \.grit)
                    voiceRangeSlider("How much room?", low: "Close", high: "Echoey", keyPath: \.atmosphere)

                    DisclosureGroup("More color") {
                        VStack(alignment: .leading, spacing: 12) {
                            voiceRangeSlider("Tone", low: "Dark", high: "Bright", keyPath: \.formant)
                            voiceRangeSlider("Metal", low: "None", high: "Ringing", keyPath: \.metallic)
                            voiceRangeSlider("Robot", low: "Natural", high: "Digital", keyPath: \.robotize)
                            voiceRangeSlider("Wobble", low: "Steady", high: "Shaky", keyPath: \.tremble)
                            voiceRangeSlider("Breath", low: "Dry", high: "Airy", keyPath: \.breath)
                        }
                        .padding(.top, 8)
                    }

                    DisclosureGroup("Background noises") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Off at the left. Drag right to fold the noise into the voice itself — thunder in the chest, not a storm next door.")
                                .font(.caption)
                                .foregroundStyle(BAMColors.secondaryLabel)
                            ForEach(CreatureTextureID.allCases) { tex in
                                textureLevelSlider(tex)
                            }
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(.top, 8)
            }
            .font(.callout)
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("All set — \(model.draft.displayTitle)")
                .font(.title2.weight(.semibold))
            Text(model.draft.resolvedSpecies)
                .foregroundStyle(BAMColors.secondaryLabel)

            VStack(alignment: .leading, spacing: 8) {
                checkRow(model.draft.hasSelectedBaseModel, "Model: \(model.draft.baseModelName ?? "selected")")
                checkRow(model.draft.datasetId != nil, "Mind: practice lines saved (Datasets)")
                checkRow(model.draft.previewAudioPath != nil, "Voice: creature FX preview saved")
                checkRow(true, "Character card saved under Characters")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            GroupBox("Base model") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.draft.baseModelName ?? "None selected")
                        .font(.callout.weight(.semibold))
                    if let key = model.draft.baseModelSourceKey {
                        Text(key)
                            .font(.caption)
                            .foregroundStyle(BAMColors.secondaryLabel)
                            .textSelection(.enabled)
                    }
                    Text(
                        """
                        This character is bound to the model above for later Train / Playground. \
                        Offline stubs are for multi-model UX only — real fine-tuning needs full MLX weights \
                        (Advanced → Models when HF Hub is enabled, or manual placement under models/base).
                        """
                    )
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("What you can do next")
                .font(.headline)
                .padding(.top, 4)

            Text("Use the footer below: Playground, Train, Create another, or Close.")
                .font(.caption)
                .foregroundStyle(BAMColors.secondaryLabel)
        }
    }

    // MARK: - Footer (pinned: always visible under scroll content)

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let status = model.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
                    .lineLimit(2)
            }

            // Voice step: play / stop / re-render always pinned (not buried under texture grid).
            if model.step == .voice {
                HStack(spacing: 10) {
                    Button {
                        model.playPreview()
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.voiceReady || model.isWorking || model.isPlayingPreview)
                    .help("Play the last rendered preview")

                    Button {
                        model.stopPreview()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.isPlayingPreview)
                    .help("Stop the voice preview immediately")
                    .keyboardShortcut(.cancelAction)

                    Button {
                        model.stopPreview(clearStatus: false)
                        model.draft.previewAudioPath = nil
                        model.renderVoicePreview()
                    } label: {
                        if model.isWorking {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Render speech", systemImage: "waveform")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isWorking)
                    .help("System TTS + creature FX (new file every time)")

                    if model.isPlayingPreview {
                        Label("Playing…", systemImage: "speaker.wave.2.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if model.voiceReady {
                        Label("Ready", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Spacer(minLength: 0)
                }
            }

            HStack(alignment: .center, spacing: 12) {
                // Secondary / navigation — always in the bottom bar
                if model.step == .done {
                    Button("Edit character") {
                        model.beginEditing(from: .meet)
                        focusedField = .name
                    }
                    .help("Re-open Name → Model → Story → Voice to change this character")

                    Button("Create another") {
                        model.resetForAnother()
                        focusedField = .name
                    }
                    .help("Start a new character wizard")

                    Button(model.draft.usesAppleFoundationModel ? "Specialize (Apple)" : "Train") {
                        let draft = model.draft
                        isPresented = false
                        onGoTrain?(draft)
                    }
                    .help(
                        model.draft.usesAppleFoundationModel
                            ? "Open Train on the Apple Foundation adapter path"
                            : "Open Train with this character’s mind + open model (LoRA)"
                    )
                } else {
                    if model.step != .meet {
                        Button("Back") {
                            model.goBack()
                        }
                    }
                    Button("Save & close") {
                        model.saveAndExit()
                        isPresented = false
                    }
                    .help("Keeps progress. Open Characters and Continue anytime.")
                }

                Spacer(minLength: 8)

                // Primary action — always the rightmost control
                if model.step == .done {
                    Button("Close") {
                        isPresented = false
                    }
                    .buttonStyle(.bordered)

                    Button {
                        let draft = model.draft
                        isPresented = false
                        onGoPlayground?(draft)
                    } label: {
                        Text("Open Playground")
                            .frame(minWidth: 140)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .help("Chat with this character (Apple / selected model)")
                } else if model.step == .voice {
                    // On voice, primary is Finish when ready; Render is the dedicated button above.
                    Button {
                        if model.voiceReady {
                            Task { await model.saveCharacter() }
                        } else {
                            model.renderVoicePreview()
                        }
                    } label: {
                        if model.isWorking {
                            ProgressView()
                                .controlSize(.small)
                                .frame(minWidth: 140)
                        } else {
                            Text(model.voiceReady ? model.primaryActionTitle : "Hear their voice")
                                .frame(minWidth: 140)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isWorking)
                    .keyboardShortcut(.defaultAction)
                    .guideHighlight("wizard.hear")
                } else {
                    Button {
                        model.performPrimaryAction()
                    } label: {
                        if model.isWorking {
                            ProgressView()
                                .controlSize(.small)
                                .frame(minWidth: 140)
                        } else {
                            Text(model.primaryActionTitle)
                                .frame(minWidth: 140)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.primaryActionEnabled || model.isWorking)
                    .keyboardShortcut(.defaultAction)
                    .guideHighlight(model.step == .mind ? "wizard.buildMind" : (model.step == .model ? "wizard.model" : ""))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(BAMColors.detailBackground)
    }

    // MARK: - Helpers

    private func tip(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.callout)
                .foregroundStyle(BAMColors.secondaryLabel)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func checkRow(_ ok: Bool, _ text: String) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(ok ? .green : BAMColors.secondaryLabel)
            .font(.callout)
    }

    private var registerBinding: Binding<VoiceRegister> {
        Binding(
            get: { VoiceRegister(rawValue: model.draft.voiceRegister) ?? .higher },
            set: { model.applyVoiceRegister($0) }
        )
    }

    private func labeledSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.callout)
            Slider(value: value, in: 0...1)
        }
    }

    /// Voice knob that invalidates the preview WAV when dragged.
    private func voiceSlider(_ title: String, keyPath: WritableKeyPath<CharacterDraft, Double>) -> some View {
        voiceRangeSlider(title, low: "", high: "", keyPath: keyPath)
    }


    private func textureLevelSlider(_ tex: CreatureTextureID) -> some View {
        let binding = Binding<Double>(
            get: { model.textureLevel(tex) },
            set: { model.setTextureLevel(tex, $0) }
        )
        let amount = model.textureLevel(tex)
        let label = amount < 0.02 ? "Off" : "\(Int((amount * 100).rounded()))%"
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(tex.title)
                    .font(.callout.weight(.medium))
                Spacer()
                Text(label)
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
            }
            Slider(value: binding, in: 0...1)
            .help(tex.teachTip)
        }
    }

    private func voiceRangeSlider(
        _ title: String,
        low: String,
        high: String,
        keyPath: WritableKeyPath<CharacterDraft, Double>
    ) -> some View {
        let binding = Binding<Double>(
            get: { model.draft[keyPath: keyPath] },
            set: { model.setVoiceKnob(keyPath, to: $0) }
        )
        return VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.callout.weight(.medium))
            Slider(value: binding, in: 0...1)
            if !low.isEmpty || !high.isEmpty {
                HStack {
                    Text(low)
                    Spacer()
                    Text(high)
                }
                .font(.caption2)
                .foregroundStyle(BAMColors.tertiaryLabel)
            }
        }
    }

    private func activateKeyWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let key = NSApp.keyWindow {
            key.makeKeyAndOrderFront(nil)
        } else {
            NSApp.windows.first(where: \.isVisible)?.makeKeyAndOrderFront(nil)
        }
    }
}

private struct FlowTags: View {
    let tags: [StyleTag]
    @Binding var selection: [StyleTag]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
            ForEach(tags) { tag in
                let on = selection.contains(tag)
                Button {
                    if on {
                        selection.removeAll { $0 == tag }
                    } else {
                        selection.append(tag)
                    }
                } label: {
                    Text(tag.title)
                        .font(.caption.weight(.semibold))
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(on ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help(tag.hint)
            }
        }
    }
}
