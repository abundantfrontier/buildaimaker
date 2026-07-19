import AppKit
import BAMCore
import BAMDatasets
import BAMModels
import BAMResourcesUI
import SwiftUI
import UniformTypeIdentifiers

/// Datasets library: list, import sheet, validation errors, and message preview.
struct DatasetsView: View {
    @StateObject private var model = DatasetsViewModel()

    var body: some View {
        Group {
            if model.loadError != nil {
                loadErrorPane
            } else {
                content
            }
        }
        .navigationTitle(SidebarDestination.datasets.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showImportSheet = true
                } label: {
                    Label("Import", systemImage: "plus")
                }
                .disabled(model.service == nil)
            }
        }
        .sheet(isPresented: $model.showImportSheet) {
            DatasetImportSheet(model: model)
        }
        .task {
            model.bootstrap()
        }
    }

    private var content: some View {
        HSplitView {
            listPane
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)
            detailPane
                .frame(minWidth: 360)
        }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            if model.datasets.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(BAMColors.secondaryLabel)
                    Text("No datasets yet")
                        .font(.headline)
                    Text("Import a ShareGPT or OpenAI-messages JSONL file to get started.")
                        .font(.callout)
                        .foregroundStyle(BAMColors.tertiaryLabel)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Import JSONL…") {
                        model.showImportSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selectedDatasetId) {
                    ForEach(model.datasets, id: \.id) { ds in
                        DatasetRowView(dataset: ds, rowCount: model.rowCount(for: ds.id))
                            .tag(ds.id)
                    }
                    .onDelete(perform: model.delete)
                }
                .listStyle(.sidebar)
            }
        }
        .background(BAMColors.detailBackground)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let selected = model.selectedDataset {
            DatasetDetailView(model: model, dataset: selected)
        } else {
            VStack(spacing: 12) {
                Image(systemName: SidebarDestination.datasets.systemImage)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(BAMColors.secondaryLabel)
                Text("Select a dataset")
                    .font(.title3.weight(.semibold))
                Text("Import and manage training datasets.")
                    .foregroundStyle(BAMColors.tertiaryLabel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BAMColors.detailBackground)
        }
    }

    private var loadErrorPane: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Could not open library")
                .font(.headline)
            Text(model.loadError ?? "")
                .font(.callout)
                .foregroundStyle(BAMColors.secondaryLabel)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Retry") { model.bootstrap() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BAMColors.detailBackground)
    }
}

// MARK: - Row / detail

private struct DatasetRowView: View {
    let dataset: DatasetRecord
    let rowCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(dataset.name)
                .font(.body.weight(.medium))
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(dataset.importMode.rawValue)
                Text("·")
                Text(dataset.status.rawValue)
                if let rowCount {
                    Text("·")
                    Text("\(rowCount) rows")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct DatasetDetailView: View {
    @ObservedObject var model: DatasetsViewModel
    let dataset: DatasetRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let previewError = model.previewError {
                    Label(previewError, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
                previewSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(BAMColors.detailBackground)
        .task(id: dataset.id) {
            model.loadPreview(for: dataset.id)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(dataset.name)
                .font(.title2.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("ID").foregroundStyle(.secondary)
                    Text(dataset.id).textSelection(.enabled)
                }
                GridRow {
                    Text("Modality").foregroundStyle(.secondary)
                    Text(dataset.modality.rawValue)
                }
                GridRow {
                    Text("Import").foregroundStyle(.secondary)
                    Text(dataset.importMode.rawValue)
                }
                GridRow {
                    Text("Status").foregroundStyle(.secondary)
                    Text(dataset.status.rawValue)
                }
                GridRow {
                    Text("Path").foregroundStyle(.secondary)
                    Text(dataset.rootPath)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                GridRow {
                    Text("Created").foregroundStyle(.secondary)
                    Text(dataset.createdAt)
                }
                if let version = model.selectedVersion {
                    GridRow {
                        Text("Rows").foregroundStyle(.secondary)
                        Text("\(version.rowCount ?? 0)")
                    }
                    if let meta = DatasetVersionMeta.parse(version.metaJSON) {
                        GridRow {
                            Text("Format").foregroundStyle(.secondary)
                            Text(meta.format)
                        }
                    }
                }
            }
            .font(.callout)
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preview")
                .font(.headline)
            if model.isLoadingPreview {
                ProgressView()
                    .controlSize(.small)
            } else if let preview = model.preview, !preview.examples.isEmpty {
                Text("First \(preview.exampleCount) example(s), \(preview.messageCount) message(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(preview.examples.enumerated()), id: \.offset) { index, example in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Example \(index + 1)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(Array(example.messages.enumerated()), id: \.offset) { _, message in
                            HStack(alignment: .top, spacing: 8) {
                                Text(message.role)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(roleColor(message.role), in: Capsule())
                                Text(message.content)
                                    .font(.callout)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(8)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            } else {
                Text("No preview available.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func roleColor(_ role: String) -> Color {
        switch role {
        case "system": return .gray
        case "user": return .blue
        case "assistant": return .green
        default: return .purple
        }
    }
}

// MARK: - Import sheet

private struct DatasetImportSheet: View {
    @ObservedObject var model: DatasetsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Import dataset")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Cancel") {
                    model.resetImportForm()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()

            Form {
                TextField("Name", text: $model.importName)
                Picker("Import mode", selection: $model.importMode) {
                    Text("Copy into library").tag(DatasetImportMode.copy)
                    Text("Reference original file").tag(DatasetImportMode.reference)
                }
                .pickerStyle(.radioGroup)

                HStack {
                    Text(model.importFileURL?.path ?? "No file selected")
                        .lineLimit(2)
                        .foregroundStyle(model.importFileURL == nil ? .secondary : .primary)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Choose JSONL…") {
                        model.pickImportFile()
                    }
                }

                if model.isValidating {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Validating…")
                            .foregroundStyle(.secondary)
                    }
                }

                if let validation = model.importValidation {
                    if validation.isValid {
                        Label(
                            "Valid \(validation.format?.rawValue ?? "chat") JSONL — \(validation.rowCount) row(s)",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Validation failed", systemImage: "xmark.octagon.fill")
                                .foregroundStyle(.red)
                                .font(.headline)
                            ForEach(validation.issues) { issue in
                                Text(issueLine(issue))
                                    .font(.callout)
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                if let importError = model.importError {
                    Text(importError)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal)

            HStack {
                Spacer()
                Button("Import") {
                    model.performImport()
                    if model.importError == nil, model.importValidation?.isValid == true {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canImport)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    private func issueLine(_ issue: DatasetValidationIssue) -> String {
        let line = issue.line.map { "Line \($0): " } ?? ""
        return "\(issue.code.rawValue) — \(line)\(issue.message)"
    }
}

// MARK: - View model

@MainActor
final class DatasetsViewModel: ObservableObject {
    @Published var datasets: [DatasetRecord] = []
    @Published var versionsByDatasetId: [String: DatasetVersionRecord] = [:]
    @Published var selectedDatasetId: String?
    @Published var preview: DatasetPreview?
    @Published var isLoadingPreview = false
    @Published var previewError: String?
    @Published var loadError: String?

    @Published var showImportSheet = false
    @Published var importName = ""
    @Published var importMode: DatasetImportMode = .copy
    @Published var importFileURL: URL?
    @Published var importValidation: DatasetValidationResult?
    @Published var importError: String?
    @Published var isValidating = false

    private(set) var service: DatasetLibraryService?

    var selectedDataset: DatasetRecord? {
        guard let selectedDatasetId else { return nil }
        return datasets.first { $0.id == selectedDatasetId }
    }

    var selectedVersion: DatasetVersionRecord? {
        guard let selectedDatasetId else { return nil }
        return versionsByDatasetId[selectedDatasetId]
    }

    var canImport: Bool {
        service != nil
            && !(importName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && importFileURL != nil
            && importValidation?.isValid == true
            && !isValidating
    }

    func bootstrap() {
        do {
            let svc = try DatasetLibraryService.openDefault()
            service = svc
            loadError = nil
            reload()
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func reload() {
        guard let service else { return }
        do {
            datasets = try service.listDatasets()
            var versions: [String: DatasetVersionRecord] = [:]
            for ds in datasets {
                if let v = try service.latestVersion(datasetId: ds.id) {
                    versions[ds.id] = v
                }
            }
            versionsByDatasetId = versions
            if let selectedDatasetId, !datasets.contains(where: { $0.id == selectedDatasetId }) {
                self.selectedDatasetId = datasets.first?.id
            } else if selectedDatasetId == nil {
                selectedDatasetId = datasets.first?.id
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func rowCount(for id: String) -> Int? {
        versionsByDatasetId[id]?.rowCount
    }

    func loadPreview(for datasetId: String) {
        guard let service else { return }
        isLoadingPreview = true
        previewError = nil
        preview = nil
        do {
            preview = try service.preview(datasetId: datasetId, maxExamples: 5)
        } catch {
            previewError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoadingPreview = false
    }

    func delete(at offsets: IndexSet) {
        guard let service else { return }
        for index in offsets {
            let id = datasets[index].id
            try? service.deleteDataset(id: id)
        }
        reload()
    }

    func resetImportForm() {
        importName = ""
        importMode = .copy
        importFileURL = nil
        importValidation = nil
        importError = nil
        isValidating = false
    }

    func pickImportFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .init(filenameExtension: "jsonl")!,
            .json,
            .plainText,
        ].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a ShareGPT or OpenAI-messages JSONL file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFileURL = url
        if importName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            importName = url.deletingPathExtension().lastPathComponent
        }
        revalidateImportFile()
    }

    func revalidateImportFile() {
        guard let service, let url = importFileURL else {
            importValidation = nil
            return
        }
        isValidating = true
        importError = nil
        defer { isValidating = false }
        do {
            importValidation = try service.validate(fileURL: url)
        } catch {
            importValidation = DatasetValidationResult(
                isValid: false,
                format: nil,
                rowCount: 0,
                issues: [
                    DatasetValidationIssue(
                        line: nil,
                        message: error.localizedDescription
                    ),
                ]
            )
        }
    }

    func performImport() {
        guard let service, let url = importFileURL else { return }
        importError = nil
        do {
            // Re-validate right before import for actionable multi-issue UI.
            let validation = try service.validate(fileURL: url)
            importValidation = validation
            guard validation.isValid else {
                importError = validation.issues.first.map {
                    let line = $0.line.map { "Line \($0): " } ?? ""
                    return "\($0.code.rawValue): \(line)\($0.message)"
                } ?? "Validation failed"
                return
            }
            let result = try service.importDataset(
                sourceURL: url,
                name: importName,
                importMode: importMode
            )
            reload()
            selectedDatasetId = result.dataset.id
            resetImportForm()
            showImportSheet = false
        } catch {
            importError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
