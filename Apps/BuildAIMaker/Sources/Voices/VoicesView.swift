import SwiftUI
import UniformTypeIdentifiers
import BAMConsent
import BAMCore
import BAMModels
import BAMResourcesUI
import BAMRunnersVoice

/// Voices pane: list profiles, import reference audio, require consent, start clone job.
struct VoicesView: View {
    let featureFlags: FeatureFlags
    @StateObject private var model: VoicesViewModel
    @State private var showFileImporter = false
    @State private var showConsent = false
    private let loadError: String?

    init(featureFlags: FeatureFlags) {
        self.featureFlags = featureFlags
        do {
            let vm = try VoicesViewModel.makeDefault()
            _model = StateObject(wrappedValue: vm)
            loadError = nil
        } catch {
            // Fail closed for product clone path; still render an error shell.
            if let svc = try? VoiceCloneService.makeInMemoryForTesting().service {
                _model = StateObject(wrappedValue: VoicesViewModel(service: svc))
                loadError = "Library open failed; using in-memory store. \(error.localizedDescription)"
            } else {
                // Last resort empty VM is not constructible without service — rethrow via dummy.
                let pair = try! VoiceCloneService.makeInMemoryForTesting()
                _model = StateObject(wrappedValue: VoicesViewModel(service: pair.service))
                loadError = error.localizedDescription
            }
        }
    }

    var body: some View {
        Group {
            if showConsent {
                ConsentLibraryShell(
                    onDismiss: {
                        showConsent = false
                        model.refresh()
                    },
                    onCreated: { record in
                        model.selectedConsentId = record.id
                        model.refresh()
                    }
                )
            } else if !featureFlags.voiceClone {
                disabledState
            } else {
                mainContent
            }
        }
        .background(BAMColors.detailBackground)
        .navigationTitle(SidebarDestination.voices.title)
        .onAppear { model.refresh() }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: audioImportTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    model.importReferenceAudio(from: url)
                }
            case .failure(let error):
                model.statusMessage = error.localizedDescription
            }
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            if let status = model.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            HSplitView {
                profileList
                    .frame(minWidth: 240)
                cloneForm
                    .frame(minWidth: 320)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Label("Voices", systemImage: SidebarDestination.voices.systemImage)
                .font(.headline)
            Spacer()
            Button {
                showConsent = true
            } label: {
                Label("Consent…", systemImage: "checkmark.shield")
            }
            .help("Create or review voice consent records (required before cloning).")
            Button {
                model.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .padding(12)
    }

    private var profileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Voice profiles")
                .font(.subheadline.weight(.semibold))
                .padding(12)
            Divider()
            if model.profiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(BAMColors.secondaryLabel)
                    Text("No voice profiles yet")
                        .font(.callout.weight(.medium))
                    Text("Import a ~15 s reference WAV, attach consent, and start a clone job.")
                        .font(.caption)
                        .foregroundStyle(BAMColors.tertiaryLabel)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 260)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.profiles, id: \.id) { profile in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.engineId)
                            .font(.body.weight(.medium))
                        Text(profile.id)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(BAMColors.secondaryLabel)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("consent \(profile.consentRecordId.prefix(8))…")
                            .font(.caption2)
                            .foregroundStyle(BAMColors.tertiaryLabel)
                        Text(profile.createdAt)
                            .font(.caption2)
                            .foregroundStyle(BAMColors.tertiaryLabel)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
    }

    private var cloneForm: some View {
        Form {
            Section {
                Text(
                    "Reference audio is copied under the library and passed only via JobPaths.referenceAudioPath (never free-form on JobSpec). Clone uses the stub F5-TTS path when the real engine is not installed."
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                if let name = model.importedDisplayName, let path = model.importedReferencePath {
                    LabeledContent("Reference") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(name)
                            Text(path)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                } else {
                    LabeledContent("Reference") {
                        Text("None selected")
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    showFileImporter = true
                } label: {
                    Label("Import reference WAV…", systemImage: "waveform.badge.plus")
                }
                .disabled(model.isBusy)
            } header: {
                Text("Reference audio")
            }

            Section {
                if model.consentRecords.isEmpty {
                    Text("No consent records. Create one before cloning.")
                        .foregroundStyle(.secondary)
                    Button("Create consent…") {
                        showConsent = true
                    }
                } else {
                    Picker("Consent record", selection: Binding(
                        get: { model.selectedConsentId ?? "" },
                        set: { model.selectedConsentId = $0.isEmpty ? nil : $0 }
                    )) {
                        ForEach(model.consentRecords, id: \.id) { row in
                            Text("\(row.id.prefix(8))…  \(row.createdAt)")
                                .tag(row.id)
                        }
                    }
                }
            } header: {
                Text("Consent (required)")
            } footer: {
                Text("Every voice_profile stores consentRecordId + consentContentHash (K11).")
            }

            Section("Sample text") {
                TextField("Preview phrase", text: $model.sampleText, axis: .vertical)
                    .lineLimit(2 ... 4)
            }

            Section {
                if let jobId = model.activeJobId {
                    LabeledContent("Job") {
                        Text("\(jobId.prefix(8))… \(model.activeJobStatus?.rawValue ?? "")")
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                Button {
                    model.startClone()
                } label: {
                    Label("Start clone job", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canStartClone)
                .help("Enqueue a voiceClone job (stub runner writes voice_profile artifacts).")
            } header: {
                Text("Clone")
            }
        }
        .formStyle(.grouped)
    }

    private var disabledState: some View {
        VStack(spacing: 16) {
            Image(systemName: SidebarDestination.voices.systemImage)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text("Voice cloning is off")
                .font(.title2.weight(.semibold))
            Text("ff.voiceClone is disabled. Enable the feature flag to manage voice profiles and start clone jobs.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Manage consent records…") {
                showConsent = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private var audioImportTypes: [UTType] {
    var types: [UTType] = [.audio]
    if let wav = UTType(filenameExtension: "wav") {
        types.insert(wav, at: 0)
    }
    return types
}
