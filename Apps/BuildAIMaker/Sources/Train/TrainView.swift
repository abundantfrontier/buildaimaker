import SwiftUI
import BAMCore
import BAMModelCatalog
import BAMResourcesUI
import BAMRunnersMLX

/// Train wizard: select dataset + model → Validate & dry-run (materialize + prepare only).
struct TrainView: View {
    @StateObject private var model = TrainViewModel()

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
        .navigationTitle(SidebarDestination.train.title)
        .onAppear { model.bootstrap() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("Train", systemImage: SidebarDestination.train.systemImage)
                .font(.headline)
            Spacer()
            Button {
                model.reload()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Reload datasets and local models")

            Button {
                model.validateAndDryRun()
            } label: {
                if model.isRunning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Validate & dry-run", systemImage: "checkmark.shield")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canDryRun)
            .help("Materialize job dir and invoke worker prepare only (no LoRA weight updates).")
        }
        .padding(12)
    }

    private var content: some View {
        Form {
            Section("Hardware") {
                if let hw = model.hardwareMessage {
                    Text(hw)
                        .font(.callout)
                        .foregroundStyle(model.hardwareOK ? BAMColors.secondaryLabel : .red)
                        .textSelection(.enabled)
                }
                Text("Approximate gate only — full Hardware Fit estimator ships in PR-HW-Fit.")
                    .font(.caption2)
                    .foregroundStyle(BAMColors.tertiaryLabel)
            }

            Section("Dataset") {
                if model.datasets.isEmpty {
                    Text("No ready text datasets. Import JSONL from the Datasets sidebar.")
                        .foregroundStyle(BAMColors.tertiaryLabel)
                } else {
                    Picker("Dataset", selection: $model.selectedDatasetId) {
                        ForEach(model.datasets, id: \.id) { ds in
                            Text(ds.name).tag(Optional(ds.id))
                        }
                    }
                }
            }

            Section("Base model") {
                if model.localModels.isEmpty {
                    Text("No local base models under models/base. Install the offline fixture from Models.")
                        .foregroundStyle(BAMColors.tertiaryLabel)
                } else {
                    Picker("Model", selection: $model.selectedModelPath) {
                        ForEach(model.localModels) { m in
                            Text(m.displayName).tag(Optional(m.localPath))
                        }
                    }
                    if let path = model.selectedModelPath {
                        Text(path)
                            .font(.caption2)
                            .foregroundStyle(BAMColors.tertiaryLabel)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                }
            }

            Section("Dry-run") {
                Text(
                    "Writes normalized JSONL + JobPaths under jobs/<id>/, then sends worker prepare only. "
                        + "Does not run LoRA or update weights (ff.llmTraining stays off)."
                )
                .font(.callout)
                .foregroundStyle(BAMColors.secondaryLabel)

                if let status = model.statusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(BAMColors.secondaryLabel)
                }

                if let summary = model.resultSummary {
                    Text(summary)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(BAMColors.sidebarBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .formStyle(.grouped)
    }
}
