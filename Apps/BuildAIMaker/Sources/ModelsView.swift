import SwiftUI
import BAMCore
import BAMModelCatalog
import BAMResourcesUI

/// Models detail: living catalog entries plus on-disk base models under the library root.
struct ModelsView: View {
    @State private var catalogEntries: [CatalogEntry] = []
    @State private var localModels: [ScannedLocalModel] = []
    /// Full-page error only when the living catalog fails to load.
    @State private var catalogError: String?
    /// Section-local banner when local scan fails; catalog still shown.
    @State private var scanError: String?
    @State private var isLoading = true

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
                Text("Supported base models from Catalog/models.json. Download lands in a later PR.")
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
                            ? "No local models under models/base."
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
            // Still attempt scan so a later retry of catalog alone is not the only path.
        }

        do {
            let scanner = LocalModelScanner()
            localModels = try scanner.scan()
            scanError = nil
        } catch {
            // Keep catalog if only scan fails — section-local error, not full-page.
            scanError = error.localizedDescription
            localModels = []
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
