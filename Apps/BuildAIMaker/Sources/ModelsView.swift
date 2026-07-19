import SwiftUI
import BAMCore
import BAMModelCatalog
import BAMResourcesUI
import BAMRunnersMLX

/// Models detail: living catalog, offline fixture install, local scan, adapter model cards.
struct ModelsView: View {
    @State private var catalogEntries: [CatalogEntry] = []
    @State private var localModels: [ScannedLocalModel] = []
    @State private var adapters: [AdapterCardRow] = []
    /// Full-page error only when the living catalog fails to load.
    @State private var catalogError: String?
    /// Section-local banner when local scan fails; catalog still shown.
    @State private var scanError: String?
    @State private var installMessage: String?
    @State private var installError: String?
    @State private var isInstallingFixture = false
    @State private var fixtureInstalled = false
    @State private var isLoading = true
    @State private var selectedAdapterPath: String?

    private let featureFlags = FeatureFlags.default

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading models…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let catalogError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(BAMColors.secondaryLabel)
                    Text("Could not load model catalog")
                        .font(.title3.weight(.semibold))
                    Text(catalogError)
                        .font(.callout)
                        .foregroundStyle(BAMColors.tertiaryLabel)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    Button("Retry") { reload() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                modelsList
            }
        }
        .background(BAMColors.detailBackground)
        .navigationTitle(SidebarDestination.models.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    reload()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Reload catalog and rescan local models")
            }
        }
        .onAppear { reload() }
    }

    private var modelsList: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Offline fixture for CI and protocol plumbing. Not real MLX train weights.")
                        .font(.callout)
                        .foregroundStyle(BAMColors.secondaryLabel)
                    HStack {
                        Button {
                            installFixture()
                        } label: {
                            if isInstallingFixture {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label(
                                    fixtureInstalled ? "Reinstall fixture model" : "Install fixture model",
                                    systemImage: fixtureInstalled ? "arrow.clockwise.circle" : "square.and.arrow.down"
                                )
                            }
                        }
                        .disabled(isInstallingFixture)
                        .help("Copy bundled tiny-qwen-mlx fixture into models/base (no network)")

                        if fixtureInstalled {
                            Label("Installed", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                    if let installMessage {
                        Text(installMessage)
                            .font(.caption)
                            .foregroundStyle(BAMColors.secondaryLabel)
                            .textSelection(.enabled)
                    }
                    if let installError {
                        Label(installError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if featureFlags.hfHubDownload {
                        Text("HF Hub download is enabled (ff.hfHubDownload). Real multi-GB weights download separately.")
                            .font(.caption2)
                            .foregroundStyle(BAMColors.tertiaryLabel)
                    } else {
                        Text("HF Hub download is off (ff.hfHubDownload). Dogfood may enable it later; CI stays offline.")
                            .font(.caption2)
                            .foregroundStyle(BAMColors.tertiaryLabel)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Fixture model")
            } footer: {
                Text("sourceKey: \(FixtureModel.sourceKey)")
                    .font(.caption2)
                    .textSelection(.enabled)
            }

            Section {
                if catalogEntries.isEmpty {
                    Text("No catalog entries.")
                        .foregroundStyle(BAMColors.secondaryLabel)
                } else {
                    ForEach(catalogEntries) { entry in
                        CatalogEntryRow(entry: entry)
                    }
                }
            } header: {
                Text("Catalog")
            } footer: {
                Text("Supported base models from Catalog/models.json. Fixture installs offline; real MLX weights via HF when enabled.")
            }

            Section {
                if let scanError {
                    Label(scanError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if localModels.isEmpty {
                    Text(
                        scanError == nil
                            ? "No local models under models/base. Use Install fixture model above."
                            : "Local scan failed; catalog is still available."
                    )
                    .foregroundStyle(BAMColors.secondaryLabel)
                } else {
                    ForEach(localModels) { model in
                        LocalModelRow(model: model)
                    }
                }
            } header: {
                Text("Local models")
            } footer: {
                Text(LibraryPaths.modelsBase.path)
                    .font(.caption2)
                    .textSelection(.enabled)
            }

            Section {
                if adapters.isEmpty {
                    Text("No LoRA adapters yet. Complete a train (or fake train) under Train.")
                        .foregroundStyle(BAMColors.secondaryLabel)
                } else {
                    ForEach(adapters) { row in
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { selectedAdapterPath == row.localPath },
                                set: { expanded in
                                    selectedAdapterPath = expanded ? row.localPath : nil
                                }
                            )
                        ) {
                            ModelCardDetailView(card: row.card)
                        } label: {
                            AdapterSummaryRow(row: row)
                        }
                    }
                }
            } header: {
                Text("Adapters (model cards)")
            } footer: {
                Text(
                    "K25 MVP eval: hold-out validation loss + sample generations on each adapter card. "
                        + LibraryPaths.modelsAdapters.path
                )
                .font(.caption2)
                .textSelection(.enabled)
            }
        }
        .listStyle(.inset)
    }

    private func reload() {
        isLoading = true
        catalogError = nil
        scanError = nil
        defer { isLoading = false }

        do {
            let catalog = try ModelCatalog.loadBundled()
            catalogEntries = catalog.entries
        } catch {
            catalogError = error.localizedDescription
            catalogEntries = []
        }

        let installer = ModelInstallService()
        fixtureInstalled = installer.isFixtureInstalled()

        do {
            let scanner = LocalModelScanner()
            localModels = try scanner.scan()
            scanError = nil
        } catch {
            scanError = error.localizedDescription
            localModels = []
        }

        adapters = Self.scanAdapterCards()
    }

    private static func scanAdapterCards(
        adaptersRoot: URL = LibraryPaths.modelsAdapters,
        fileManager: FileManager = .default
    ) -> [AdapterCardRow] {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: adaptersRoot.path, isDirectory: &isDir),
              isDir.boolValue
        else { return [] }
        guard let contents = try? fileManager.contentsOfDirectory(
            at: adaptersRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var rows: [AdapterCardRow] = []
        for url in contents {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            let name = url.lastPathComponent
            guard LibraryPaths.validatedPathComponent(name) != nil else { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            let card = ModelCardWriter.load(fromDirectory: resolved)
                ?? ModelCardContent(title: name)
            rows.append(
                AdapterCardRow(
                    directoryName: name,
                    localPath: resolved.path,
                    card: card
                )
            )
        }
        return rows.sorted {
            $0.directoryName.localizedCaseInsensitiveCompare($1.directoryName) == .orderedAscending
        }
    }

    private func installFixture() {
        isInstallingFixture = true
        installError = nil
        installMessage = nil
        defer { isInstallingFixture = false }

        do {
            let service = ModelInstallService()
            let result = try service.installFixture(overwrite: true)
            fixtureInstalled = true
            installMessage = result.alreadyPresent
                ? "Reinstalled fixture at \(result.modelRecord.localPath)"
                : "Installed fixture at \(result.modelRecord.localPath)"
            OnboardingStore().markCompleted(.installFixture)
            // Rescan local models only (keep catalog).
            do {
                localModels = try LocalModelScanner().scan()
                scanError = nil
            } catch {
                scanError = error.localizedDescription
            }
        } catch {
            installError = error.localizedDescription
            fixtureInstalled = ModelInstallService().isFixtureInstalled()
        }
    }
}

// MARK: - Rows

private struct CatalogEntryRow: View {
    let entry: CatalogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.name)
                    .font(.body.weight(.medium))
                Spacer()
                if entry.isFixture {
                    Text("Fixture")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.25), in: Capsule())
                }
                Text(entry.license)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(BAMColors.separator.opacity(0.35), in: Capsule())
            }
            Text(entry.sourceKey)
                .font(.caption)
                .foregroundStyle(BAMColors.secondaryLabel)
                .textSelection(.enabled)
            HStack(spacing: 12) {
                labeled("Params", value: String(format: "%gB", entry.paramCountB))
                labeled("Quant", value: "\(entry.quantBits)-bit")
                labeled("Min RAM", value: "\(entry.minRamGB) GB")
                labeled("Template", value: entry.chatTemplateId)
            }
            .font(.caption2)
            .foregroundStyle(BAMColors.tertiaryLabel)
        }
        .padding(.vertical, 2)
    }

    private func labeled(_ title: String, value: String) -> some View {
        Text("\(title): \(value)")
    }
}

private struct LocalModelRow: View {
    let model: ScannedLocalModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(model.displayName)
                    .font(.body.weight(.medium))
                Spacer()
                if let license = model.license, !license.isEmpty {
                    Text(license)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(BAMColors.separator.opacity(0.35), in: Capsule())
                }
            }
            Text(model.localPath)
                .font(.caption)
                .foregroundStyle(BAMColors.secondaryLabel)
                .textSelection(.enabled)
            HStack(spacing: 12) {
                status("config.json", present: model.hasConfigJSON)
                status("adapter_config.json", present: model.hasAdapterConfigJSON)
            }
            .font(.caption2)
            .foregroundStyle(BAMColors.tertiaryLabel)
        }
        .padding(.vertical, 2)
    }

    private func status(_ name: String, present: Bool) -> some View {
        Label(
            name,
            systemImage: present ? "checkmark.circle.fill" : "circle"
        )
    }
}

// MARK: - Adapter model cards (K25)

struct AdapterCardRow: Identifiable, Equatable {
    var directoryName: String
    var localPath: String
    var card: ModelCardContent

    var id: String { localPath }
}

private struct AdapterSummaryRow: View {
    let row: AdapterCardRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.card.title)
                    .font(.body.weight(.medium))
                Spacer()
                if row.card.fakeTrain {
                    Text("Fake")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.25), in: Capsule())
                }
                Text(row.card.method)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(BAMColors.separator.opacity(0.35), in: Capsule())
            }
            Text(row.localPath)
                .font(.caption)
                .foregroundStyle(BAMColors.secondaryLabel)
                .textSelection(.enabled)
            HStack(spacing: 12) {
                if let hold = row.card.holdOutLoss {
                    Text(String(format: "Hold-out: %.4f", hold))
                } else {
                    Text("Hold-out: n/a")
                }
                if let train = row.card.trainLoss {
                    Text(String(format: "Train: %.4f", train))
                }
                Text("Samples: \(row.card.sampleGenerations.count)")
            }
            .font(.caption2)
            .foregroundStyle(BAMColors.tertiaryLabel)
        }
        .padding(.vertical, 2)
    }
}

/// Displays K25 hold-out loss + sample generations from an adapter model card.
struct ModelCardDetailView: View {
    let card: ModelCardContent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                LabeledContent("Method", value: card.method)
                if let jobId = card.jobId {
                    LabeledContent("Job", value: jobId)
                }
                if let artifact = card.adapterArtifactId {
                    LabeledContent("Artifact", value: artifact)
                }
                if let base = card.baseModelSourceKey ?? card.baseModelId {
                    LabeledContent("Base", value: base)
                }
                if let hp = card.hyperparametersSummary {
                    LabeledContent("Hyperparams", value: hp)
                }
            }
            .font(.caption)

            Divider()

            Text("Evaluation (MVP / K25)")
                .font(.caption.weight(.semibold))
            if let hold = card.holdOutLoss {
                Text(String(format: "Hold-out validation loss: %.6f", hold))
                    .font(.callout.monospacedDigit())
            } else {
                Text("Hold-out validation loss: n/a (no val split)")
                    .font(.callout)
                    .foregroundStyle(BAMColors.secondaryLabel)
            }
            if let train = card.trainLoss {
                Text(String(format: "Final train loss: %.6f", train))
                    .font(.callout.monospacedDigit())
            }

            Text("Sample generations")
                .font(.caption.weight(.semibold))
                .padding(.top, 4)
            if card.sampleGenerations.isEmpty {
                Text("None recorded.")
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
            } else {
                ForEach(Array(card.sampleGenerations.enumerated()), id: \.offset) { idx, sample in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(idx + 1). Prompt")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(BAMColors.tertiaryLabel)
                        Text(sample.prompt)
                            .font(.caption)
                            .textSelection(.enabled)
                        Text("Completion")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(BAMColors.tertiaryLabel)
                        Text(sample.completion)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(BAMColors.separator.opacity(0.15))
                    )
                }
            }

            if !card.notes.isEmpty {
                Text("Notes")
                    .font(.caption.weight(.semibold))
                ForEach(card.notes, id: \.self) { note in
                    Text("• \(note)")
                        .font(.caption2)
                        .foregroundStyle(BAMColors.secondaryLabel)
                }
            }
        }
        .padding(.vertical, 6)
    }
}
