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
        .onChange(of: model.selectedModelPath) {
            model.resolveModelSizeClass()
            model.recomputeHardwareFit()
        }
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
            hardwareFitSection

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
                    Text(
                        String(
                            format: "Size class: %gB · %d-bit (catalog / default)",
                            model.fitParamCountB,
                            model.fitQuantBits
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(BAMColors.tertiaryLabel)
                }
            }

            Section("LoRA knobs (estimator)") {
                Stepper(value: $model.loraRank, in: 4...64, step: 4) {
                    Text("LoRA rank: \(model.loraRank)")
                }
                Stepper(value: $model.maxSeqLen, in: 512...8192, step: 512) {
                    Text("Max seq len: \(model.maxSeqLen)")
                }
                Stepper(value: $model.batchSize, in: 1...8, step: 1) {
                    Text("Batch size: \(model.batchSize)")
                }
                Stepper(value: $model.gradAccum, in: 1...16, step: 1) {
                    Text("Grad accum: \(model.gradAccum)")
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

    // MARK: - Hardware Fit panel

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
                                format: "Peak ~%@ GB · need ~%@ GB (incl. OS reserve) of ~%@ GB",
                                HardwareFitGate.formatGB(peak),
                                HardwareFitGate.formatGB(required),
                                HardwareFitGate.formatGB(available)
                            )
                        )
                        .font(.callout)
                        .foregroundStyle(fitForeground)
                        .textSelection(.enabled)
                    }
                    if let message = model.hardwareMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(fitForeground)
                            .textSelection(.enabled)
                    }
                }
            }

            if !model.fitSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Suggestions")
                        .font(.caption)
                        .foregroundStyle(BAMColors.secondaryLabel)
                    ForEach(model.fitSuggestions, id: \.self) { tip in
                        Text("• \(tip)")
                            .font(.caption2)
                            .foregroundStyle(BAMColors.secondaryLabel)
                    }
                }
            }

            Text(HardwareFitGate.approximateLabel)
                .font(.caption2)
                .foregroundStyle(BAMColors.tertiaryLabel)
        } header: {
            Text("Hardware Fit")
        } footer: {
            if !model.hardwareOK {
                Text("Training is blocked until hardware requirements are met (minimum 16 GB unified memory, and estimated peak must fit).")
                    .font(.caption2)
            } else if model.hardwareWarning {
                Text("Soft warning only — you may continue, but consider lowering knobs or closing other apps.")
                    .font(.caption2)
            }
        }
    }

    private var fitStatusBadge: some View {
        Text(fitStatusTitle)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(fitBadgeBackground)
            .foregroundStyle(fitBadgeForeground)
            .clipShape(Capsule())
    }

    private var fitStatusTitle: String {
        switch model.fitStatus {
        case .ok: return "OK"
        case .warning: return "Warning"
        case .refuse: return "Refuse"
        }
    }

    private var fitForeground: Color {
        switch model.fitStatus {
        case .ok: return BAMColors.secondaryLabel
        case .warning: return .orange
        case .refuse: return .red
        }
    }

    private var fitBadgeBackground: Color {
        switch model.fitStatus {
        case .ok: return Color.green.opacity(0.2)
        case .warning: return Color.orange.opacity(0.2)
        case .refuse: return Color.red.opacity(0.2)
        }
    }

    private var fitBadgeForeground: Color {
        switch model.fitStatus {
        case .ok: return .green
        case .warning: return .orange
        case .refuse: return .red
        }
    }
}
