import SwiftUI
import UniformTypeIdentifiers
import BAMCore
import BAMModels
import BAMPersonas
import BAMResourcesUI

/// Personas pane: create/list personas and export/import Pack Format v1 zips.
///
/// Not in the sidebar. Packs do not drive Playground yet (that binds a Character).
/// Keep this view for a later ship.
struct PersonasView: View {
    let featureFlags: FeatureFlags
    @StateObject private var model: PersonasViewModel
    @State private var showImporter = false
    private let loadError: String?

    init(featureFlags: FeatureFlags) {
        self.featureFlags = featureFlags
        do {
            let vm = try PersonasViewModel.makeDefault()
            _model = StateObject(wrappedValue: vm)
            loadError = nil
        } catch {
            // Fail closed for product path: ephemeral in-memory for display only.
            if let pair = try? PersonaService.makeInMemoryForTesting() {
                _model = StateObject(
                    wrappedValue: PersonasViewModel(
                        service: pair.service,
                        libraryRoot: pair.libraryRoot
                    )
                )
                loadError = "Library open failed; using temporary store. \(error.localizedDescription)"
            } else {
                let pair = try! PersonaService.makeInMemoryForTesting()
                _model = StateObject(
                    wrappedValue: PersonasViewModel(
                        service: pair.service,
                        libraryRoot: pair.libraryRoot
                    )
                )
                loadError = error.localizedDescription
            }
        }
    }

    var body: some View {
        Group {
            if !featureFlags.personaPacks {
                disabledState
            } else {
                mainContent
            }
        }
        .background(BAMColors.detailBackground)
        .navigationTitle(SidebarDestination.personas.title)
        .onAppear { model.refresh() }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    model.importPack(from: url)
                }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private var disabledState: some View {
        VStack(spacing: 12) {
            Image(systemName: SidebarDestination.personas.systemImage)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(BAMColors.secondaryLabel)
            Text("Persona packs are not enabled")
                .font(.title3.weight(.semibold))
            Text("ff.personaPacks is off.")
                .font(.callout)
                .foregroundStyle(BAMColors.secondaryLabel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            if let err = model.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            HSplitView {
                personaList
                    .frame(minWidth: 260)
                editor
                    .frame(minWidth: 340)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Label("Personas", systemImage: SidebarDestination.personas.systemImage)
                .font(.headline)
            Spacer()
            Button {
                showImporter = true
            } label: {
                Label("Import pack…", systemImage: "square.and.arrow.down")
            }
            .help("Import a Pack Format v1 .bam.persona.zip")
            Button {
                model.exportSelected()
            } label: {
                Label("Export pack…", systemImage: "square.and.arrow.up")
            }
            .disabled(model.selectedPersonaId == nil || model.isBusy)
            .help("Export selected persona as Pack Format v1 zip")
            Button {
                model.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .padding(12)
    }

    private var personaList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Library")
                .font(.subheadline.weight(.semibold))
                .padding(12)
            Divider()
            if model.personas.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.2")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(BAMColors.secondaryLabel)
                    Text("No personas yet")
                        .font(.callout.weight(.medium))
                    Text("Compose a persona from a base model, optional adapter, and optional consent-bound voice — then export a portable pack.")
                        .font(.caption)
                        .foregroundStyle(BAMColors.tertiaryLabel)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.personas, id: \.id, selection: $model.selectedPersonaId) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.name)
                            .font(.body.weight(.medium))
                        Text("v\(row.version) · \(model.resolveSummary(for: row))")
                            .font(.caption)
                            .foregroundStyle(BAMColors.secondaryLabel)
                        Text(row.id)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(BAMColors.tertiaryLabel)
                            .textSelection(.enabled)
                    }
                    .tag(row.id)
                    .padding(.vertical, 2)
                }
            }
            Divider()
            HStack {
                Button(role: .destructive) {
                    model.deleteSelected()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(model.selectedPersonaId == nil)
                Spacer()
            }
            .padding(8)
        }
    }

    private var editor: some View {
        Form {
            Section("Create persona") {
                TextField("Name", text: $model.draftName)
                TextField("Version", text: $model.draftVersion)
                TextField("System prompt", text: $model.draftSystemPrompt, axis: .vertical)
                    .lineLimit(3...8)

                Picker("Base model", selection: $model.selectedBaseModelId) {
                    Text("None").tag(String?.none)
                    ForEach(model.baseModels) { m in
                        Text(m.name).tag(Optional(m.id))
                    }
                }
                Picker("Adapter (optional)", selection: $model.selectedAdapterId) {
                    Text("None").tag(String?.none)
                    ForEach(model.adapters) { a in
                        Text(a.name).tag(Optional(a.id))
                    }
                }
                Picker("Voice profile (optional)", selection: $model.selectedVoiceId) {
                    Text("None").tag(String?.none)
                    ForEach(model.voiceProfiles, id: \.id) { v in
                        Text("\(v.engineId) · \(v.id.prefix(8))…").tag(Optional(v.id))
                    }
                }

                Text("At least one of base/adapter or voice is required. Knowledge pack keys are not supported in v1.")
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)

                Button {
                    model.createPersona()
                } label: {
                    Label("Create", systemImage: "plus.circle.fill")
                }
                .disabled(model.isBusy || model.draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .guideHighlight("personas.create")
            }

            Section("Pack Format v1") {
                Text(
                    "Export writes manifest.json + persona.json + optional llm/, voice/, consent/, licenses/ into a portable zip. Import verifies SHA-256 digests and consent content hash."
                )
                .font(.callout)
                .foregroundStyle(BAMColors.secondaryLabel)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
    }
}
