import AppKit
import BAMAudioFX
import BAMCharacterStudio
import BAMResourcesUI
import SwiftUI

/// Linear Create Character flow: Name → Story → Voice → Done (no dead ends).
struct CreateCharacterWizardView: View {
    @StateObject private var model = CreateCharacterViewModel()
    @Binding var isPresented: Bool
    /// When set, resume this draft instead of starting blank.
    var resumeDraft: CharacterDraft? = nil
    /// Optional: jump to Playground after finish.
    var onGoPlayground: (() -> Void)?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name
        case customSpecies
        case vibe
        case story
    }

    var body: some View {
        VStack(spacing: 0) {
            progressBar
            Divider()
            whatToDoNowBanner
            modelStatusBanner
            Divider()
            content
            if let err = model.lastError {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
            }
            if let status = model.statusMessage {
                Text(status)
                    .foregroundStyle(BAMColors.secondaryLabel)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
            }
            Divider()
            footer
        }
        .background(BAMColors.detailBackground)
        .navigationTitle(resumeDraft == nil ? "Create a character" : "Continue character")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(model.step == .done ? "Close" : "Save & close") {
                    if model.step != .done {
                        model.saveAndExit()
                    }
                    isPresented = false
                }
            }
        }
        .onAppear {
            activateKeyWindow()
            model.load(draft: resumeDraft)
            model.refreshModelStatus()
            focusedField = model.step == .mind ? .story : .name
        }
        .onDisappear {
            if model.step != .done {
                model.saveAndExit()
            }
        }
        .onChange(of: model.step) { _, newStep in
            activateKeyWindow()
            model.refreshModelStatus()
            model.persistDraft()
            switch newStep {
            case .meet: focusedField = .name
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

    // MARK: - Progress

    private var progressBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(CreateCharacterViewModel.Step.userSteps.enumerated()), id: \.element.id) { index, s in
                let n = index + 1
                let active = model.step == s
                let done = model.step.rawValue > s.rawValue || (model.step == .done && s != .done)
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(done || active ? Color.accentColor : Color.secondary.opacity(0.25))
                            .frame(width: 28, height: 28)
                        if done && !active {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                        } else {
                            Text("\(n)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(active || done ? .white : .secondary)
                        }
                    }
                    Text(s.shortTitle)
                        .font(.caption.weight(active ? .semibold : .regular))
                        .foregroundStyle(active ? .primary : BAMColors.secondaryLabel)
                }
                .frame(maxWidth: .infinity)
                if s != .voice {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(BAMColors.tertiaryLabel)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
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

    /// Always-visible: wizard does not enable/load a chat or train model by default.
    private var modelStatusBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.modelStatus.symbol)
                    .font(.title3)
                    .foregroundStyle(model.modelStatus.isReadyForRealTrain ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI model for chat / fine-tune")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BAMColors.secondaryLabel)
                    Text(model.modelStatus.title)
                        .font(.callout.weight(.semibold))
                    Text(model.modelStatus.detail)
                        .font(.caption)
                        .foregroundStyle(BAMColors.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 12) {
                if case .noneInstalled = model.modelStatus {
                    Button {
                        model.installFixtureForLater()
                    } label: {
                        if model.isInstallingFixture {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Install test fixture (optional)")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isInstallingFixture)
                    .help("Copies a tiny offline model for Advanced → Train tests. Does not start chatting.")
                }
                Text("This wizard: story data + voice FX only")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch model.step {
            case .meet:
                ScrollView {
                    meetStep
                        .padding(24)
                        .frame(maxWidth: 720, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            case .mind:
                mindStep
                    .padding(24)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .voice:
                ScrollView {
                    voiceStep
                        .padding(24)
                        .frame(maxWidth: 720, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            case .done:
                ScrollView {
                    doneStep
                        .padding(24)
                        .frame(maxWidth: 720, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
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

    private var mindStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Step 2 — How they talk")
                .font(.title2.weight(.semibold))

            Text("Paste a short story, lore, or sample lines. We turn that into practice dialogues (a dataset). No language model is selected or loaded here.")
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

                ScrollView {
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
                }
                .frame(maxHeight: 160)

                HStack {
                    Button("Rebuild from paste") {
                        model.buildMind(importDataset: true)
                    }
                    .disabled(model.isWorking)
                    Button("Add more lines") {
                        model.riffMore()
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
            Text("Step 3 — How they sound")
                .font(.title2.weight(.semibold))

            Text("Pick a preset (or tweak sliders), then hear a short creature sound. This is audio FX only — not a neural speech model and not tied to a chat model.")
                .foregroundStyle(BAMColors.secondaryLabel)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                ForEach(CreatureVoicePreset.allCases) { preset in
                    Button {
                        model.applyVoicePreset(preset)
                    } label: {
                        Text(preset.title)
                            .font(.callout.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(10)
                            .background(
                                model.draft.voicePreset == preset.rawValue
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.secondary.opacity(0.08)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help(preset.teachTip)
                }
            }

            if let teach = CreatureVoicePreset(rawValue: model.draft.voicePreset)?.teachTip {
                tip(teach)
            }

            let fx = model.currentFXParams()
            labeledSlider("Size — \(fx.sizeLabel)", value: $model.draft.size)
            labeledSlider("Grit — \(fx.gritLabel)", value: $model.draft.grit)
            labeledSlider("Atmosphere — \(fx.atmosphereLabel)", value: $model.draft.atmosphere)

            DisclosureGroup("Textures under the voice (optional)") {
                VStack(alignment: .leading) {
                    Toggle("Buzz saw", isOn: $model.draft.textureBuzzSaw)
                    Toggle("Songbird", isOn: $model.draft.textureSongbird)
                    Toggle("Drip", isOn: $model.draft.textureDrip)
                    Toggle("Servo", isOn: $model.draft.textureServo)
                }
                .padding(.top, 6)
            }

            if model.voiceReady {
                Label("Voice preview ready — you can finish.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Play again") { model.playPreview() }
            } else {
                tip("Click the green button below to generate and hear their voice, then you’ll save.")
            }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("All set — \(model.draft.displayTitle)")
                .font(.title2.weight(.semibold))
            Text(model.draft.resolvedSpecies)
                .foregroundStyle(BAMColors.secondaryLabel)

            VStack(alignment: .leading, spacing: 8) {
                checkRow(model.draft.datasetId != nil, "Mind: practice lines saved (Datasets)")
                checkRow(model.draft.previewAudioPath != nil, "Voice: creature FX preview saved")
                checkRow(true, "Character card saved under Characters")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            GroupBox("About models") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.modelStatus.title)
                        .font(.callout.weight(.semibold))
                    Text(
                        """
                        The wizard never enables a chat model by default. \
                        You built training text (mind) and a FX voice preview. \
                        To actually fine-tune: Advanced → Models (install weights) → Train (pick dataset + model).
                        """
                    )
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("What you can do next")
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    isPresented = false
                    onGoPlayground?()
                } label: {
                    Label("Open Playground (stub chat unless you set a model later)", systemImage: "bubble.left.and.bubble.right")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    isPresented = false
                } label: {
                    Label("Back to Characters list", systemImage: "theatermasks")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    model.resetForAnother()
                    focusedField = .name
                } label: {
                    Label("Create another character", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    // MARK: - Footer (single primary action)

    private var footer: some View {
        HStack(alignment: .center, spacing: 16) {
            if model.step != .meet && model.step != .done {
                Button("Back") {
                    model.goBack()
                }
            }
            if model.step != .done {
                Button("Save & close") {
                    model.saveAndExit()
                    isPresented = false
                }
                .help("Keeps progress. Open Characters and Continue anytime.")
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(model.primaryActionHint)
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
                    .multilineTextAlignment(.trailing)
                if model.step != .done {
                    Button {
                        model.performPrimaryAction()
                    } label: {
                        if model.isWorking {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.horizontal, 12)
                        } else {
                            Text(model.primaryActionTitle)
                                .frame(minWidth: 160)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.primaryActionEnabled || model.isWorking)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
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

    private func labeledSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Slider(value: value, in: 0...1)
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
