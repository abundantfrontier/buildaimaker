import AppKit
import BAMAudioFX
import BAMCharacterStudio
import BAMResourcesUI
import SwiftUI

/// CS-1…CS-3: Meet → Story (paste→corpus) → Voice (presets/FX) → Done.
struct CreateCharacterWizardView: View {
    @StateObject private var model = CreateCharacterViewModel()
    @Binding var isPresented: Bool
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name
        case customSpecies
        case vibe
        case story
    }

    var body: some View {
        VStack(spacing: 0) {
            stepHeader
            Divider()
            // Avoid ScrollView wrapping primary text fields on macOS — it steals focus.
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
            if let err = model.lastError {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .padding(.horizontal, 24)
            }
            if let status = model.statusMessage {
                Text(status)
                    .foregroundStyle(BAMColors.secondaryLabel)
                    .font(.callout)
                    .padding(.horizontal, 24)
            }
            Divider()
            footer
        }
        .background(BAMColors.detailBackground)
        .navigationTitle("Create a character")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { isPresented = false }
            }
        }
        .onAppear {
            activateKeyWindow()
            focusedField = model.step == .mind ? .story : .name
        }
        .onChange(of: model.step) { _, newStep in
            activateKeyWindow()
            switch newStep {
            case .meet: focusedField = .name
            case .mind: focusedField = .story
            case .voice, .done: focusedField = nil
            }
        }
    }

    private func activateKeyWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // Prefer the sheet/window hosting this view.
        if let key = NSApp.keyWindow {
            key.makeKeyAndOrderFront(nil)
        } else {
            NSApp.windows.first(where: \.isVisible)?.makeKeyAndOrderFront(nil)
        }
    }

    private var stepHeader: some View {
        HStack(spacing: 12) {
            ForEach(CreateCharacterViewModel.Step.allCases.filter { $0 != .done }) { s in
                VStack(spacing: 4) {
                    Circle()
                        .fill(s.rawValue <= model.step.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 10, height: 10)
                    Text(s.title)
                        .font(.caption2)
                        .foregroundStyle(s == model.step ? .primary : BAMColors.secondaryLabel)
                }
                if s != .voice {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(height: 1)
                        .frame(maxWidth: 40)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    // MARK: - Steps

    private var meetStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Meet them")
                .font(.title2.weight(.semibold))
            Text("Name your character and pick a creature vibe. You can change the voice later.")
                .foregroundStyle(BAMColors.secondaryLabel)

            TextField("Name", text: $model.draft.name)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .name)

            Text("Species / vibe")
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
                TextField("Custom species", text: $model.draft.customSpecies)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .customSpecies)
            }

            TextField("Vibe (optional)", text: $model.draft.vibe, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .vibe)
        }
    }

    private var mindStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Their story")
                .font(.title2.weight(.semibold))
            Text("Paste lore, backstory, or sample lines. We’ll turn it into practice dialogues (how they talk).")
                .foregroundStyle(BAMColors.secondaryLabel)

            MacTextEditor(text: $model.draft.storyPaste, minHeight: 160)
                .frame(minHeight: 160, maxHeight: 220)
                .focused($focusedField, equals: .story)

            Text("How they talk")
                .font(.headline)
            FlowTags(
                tags: StyleTag.allCases,
                selection: $model.draft.styleTags
            )

            Stepper("Extra riff lines: \(model.draft.riffCount)", value: $model.draft.riffCount, in: 0...8)

            HStack {
                Button("Build how they talk") {
                    model.buildMind(importDataset: true)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking || !model.canBuildMind)

                Button("More like this") {
                    model.riffMore()
                }
                .disabled(model.draft.examples.isEmpty || model.isWorking)
            }

            if !model.draft.examples.isEmpty {
                Text("Preview (\(model.draft.examples.count) lines)")
                    .font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.draft.examples.prefix(6)) { ex in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("You: \(ex.user)")
                                    .font(.callout.weight(.semibold))
                                Text(ex.assistant)
                                    .font(.callout)
                                    .foregroundStyle(BAMColors.secondaryLabel)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        if let rules = model.draft.bible?.speechRules, !rules.isEmpty {
                            Text("Speech rules: \(rules.joined(separator: " "))")
                                .font(.caption)
                                .foregroundStyle(BAMColors.secondaryLabel)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
    }

    private var voiceStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Their voice")
                .font(.title2.weight(.semibold))
            Text("Presets + simple sliders. Textures layer under speech (ducked so words stay clear).")
                .foregroundStyle(BAMColors.secondaryLabel)

            Text("Preset")
                .font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                ForEach(CreatureVoicePreset.allCases) { preset in
                    Button {
                        model.applyVoicePreset(preset)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(preset.title).font(.callout.weight(.semibold))
                            Text(preset.teachTip)
                                .font(.caption2)
                                .foregroundStyle(BAMColors.secondaryLabel)
                                .lineLimit(3)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            model.draft.voicePreset == preset.rawValue
                                ? Color.accentColor.opacity(0.15)
                                : Color.secondary.opacity(0.08)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }

            let fx = model.currentFXParams()
            labeledSlider("Size — \(fx.sizeLabel)", value: $model.draft.size, tip: "Lower = bigger creature.")
            labeledSlider("Grit — \(fx.gritLabel)", value: $model.draft.grit, tip: "Adds metal, dirt, or edge.")
            labeledSlider("Atmosphere — \(fx.atmosphereLabel)", value: $model.draft.atmosphere, tip: "If words get muddy, turn this down.")

            Text("Textures")
                .font(.headline)
            Toggle(isOn: $model.draft.textureBuzzSaw) {
                textureLabel(.buzzSaw)
            }
            Toggle(isOn: $model.draft.textureSongbird) {
                textureLabel(.songbird)
            }
            Toggle(isOn: $model.draft.textureDrip) {
                textureLabel(.drip)
            }
            Toggle(isOn: $model.draft.textureServo) {
                textureLabel(.servo)
            }

            HStack {
                Button("Preview voice") {
                    model.renderVoicePreview()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking)

                if model.draft.previewAudioPath != nil {
                    Button("Play again") {
                        model.playPreview()
                    }
                }
            }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Character ready")
                .font(.title2.weight(.semibold))
            Text(model.draft.displayTitle)
                .font(.title3)
            Text(model.draft.resolvedSpecies)
                .foregroundStyle(BAMColors.secondaryLabel)
            if model.draft.datasetId != nil {
                Label("Mind saved to Datasets", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if model.draft.previewAudioPath != nil {
                Label("Voice preview rendered", systemImage: "waveform")
                    .foregroundStyle(.green)
            }
            Text("Next (later): Teach (fine-tune) and Talk. For now open Playground or Advanced → Datasets / Train.")
                .font(.callout)
                .foregroundStyle(BAMColors.secondaryLabel)
            Button("Done") { isPresented = false }
                .buttonStyle(.borderedProminent)
        }
    }

    private var footer: some View {
        HStack {
            if model.step != .meet && model.step != .done {
                Button("Back") {
                    if let prev = CreateCharacterViewModel.Step(rawValue: model.step.rawValue - 1) {
                        model.step = prev
                    }
                }
            }
            Spacer()
            if model.step == .meet {
                Button("Next") { model.step = .mind }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canGoNextFromMeet)
            } else if model.step == .mind {
                Button("Next") { model.step = .voice }
                    .buttonStyle(.borderedProminent)
            } else if model.step == .voice {
                Button("Save character") {
                    model.saveCharacter()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, tip: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Slider(value: value, in: 0...1)
            Text(tip)
                .font(.caption)
                .foregroundStyle(BAMColors.secondaryLabel)
        }
    }

    private func textureLabel(_ id: CreatureTextureID) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(id.title)
            Text(id.teachTip)
                .font(.caption)
                .foregroundStyle(BAMColors.secondaryLabel)
        }
    }
}

// Simple wrapping chip selector
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tag.title)
                            .font(.caption.weight(.semibold))
                        Text(tag.hint)
                            .font(.caption2)
                            .foregroundStyle(BAMColors.secondaryLabel)
                            .lineLimit(2)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(on ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
