import SwiftUI
import BAMCore
import BAMModelCatalog
import BAMResourcesUI
import BAMRunnersMLX

/// Train wizard: select dataset + model → dry-run prepare or full LoRA train.
struct TrainView: View {
    @EnvironmentObject private var characterLaunch: CharacterStudioLaunchContext
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
        .onAppear {
            model.bootstrap()
            applyPendingCharacter()
        }
        .onChange(of: characterLaunch.pendingTrain?.token) { _, _ in
            applyPendingCharacter()
        }
        .onChange(of: model.selectedModelPath) {
            model.resolveModelSizeClass()
            model.recomputeHardwareFit()
        }
    }

    private func applyPendingCharacter() {
        if let target = characterLaunch.consumeTrain() {
            model.applyCharacterLaunch(target)
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
            .buttonStyle(.bordered)
            .disabled(!model.canDryRun)
            .help("Materialize job dir and invoke worker prepare only (no LoRA weight updates).")

            Button {
                model.startFullLoRATrain()
            } label: {
                if model.isRunning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label(
                        model.willUseFakeTrain ? "Start LoRA (fake)" : "Start LoRA train",
                        systemImage: "bolt.fill"
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canFullTrain)
            .help(
                model.willUseFakeTrain
                    ? "Fixture/stub model: runs fake LoRA and publishes an adapter stub."
                    : "Full LoRA via worker (real weights when mlx-lm is available)."
            )
        }
        .padding(12)
    }

    private var content: some View {
        Form {
            if let name = model.boundCharacterName {
                Section {
                    Label("Training for character: \(name)", systemImage: "theatermasks")
                        .font(.callout.weight(.semibold))
                    Text("Dataset and base model preselected from the character’s mind + model steps.")
                        .font(.caption)
                        .foregroundStyle(BAMColors.secondaryLabel)
                }
            }

            hardwareFitSection

            Section("Dataset") {
                if model.datasets.isEmpty {
                    Text("No ready text datasets. Finish a character Story step or import JSONL under Datasets.")
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
                if model.localModels.isEmpty && model.selectedModelPath == nil {
                    Text("No local base models under models/base. Install from Models or Create → Model.")
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
                    HStack(spacing: 8) {
                        Text(model.modelCapability.shortLabel)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                (model.modelCapability.isStub ? Color.orange : Color.green).opacity(0.2),
                                in: Capsule()
                            )
                        Text(
                            String(
                                format: "%gB · %d-bit",
                                model.fitParamCountB,
                                model.fitQuantBits
                            )
                        )
                        .font(.caption2)
                        .foregroundStyle(BAMColors.tertiaryLabel)
                    }
                    if model.modelCapability.isStub {
                        Text("Stub/fixture: Start LoRA will use fake train and publish an adapter stub for Playground plumbing.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text("Real weights detected: Start LoRA train runs the worker without BAM_LORA_FAKE (mlx-lm required).")
                            .font(.caption)
                            .foregroundStyle(BAMColors.secondaryLabel)
                    }
                }
            }

            Section("LoRA hyperparameters") {
                Stepper(value: $model.epochs, in: 1...10, step: 1) {
                    Text("Epochs: \(model.epochs)")
                }
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

            Section("Run") {
                Text(
                    "Dry-run only prepares the job. Start LoRA train materializes, runs the worker, and publishes an adapter under models/adapters for Playground."
                )
                .font(.callout)
                .foregroundStyle(BAMColors.secondaryLabel)

                if let status = model.statusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(BAMColors.secondaryLabel)
                }

                if let adapter = model.lastPublishedAdapterPath {
                    Text("Last adapter: \(adapter)")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .textSelection(.enabled)
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
            Text("Approximate peak unified-memory estimate for LoRA. Blocks train when clearly under-provisioned.")
                .font(.caption2)
        }
    }

    private var fitStatusBadge: some View {
        let label: String
        let color: Color
        switch model.fitStatus {
        case .ok:
            label = "OK"
            color = .green
        case .warning:
            label = "Warn"
            color = .orange
        case .refuse:
            label = "Blocked"
            color = .red
        }
        return Text(label)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    private var fitForeground: Color {
        switch model.fitStatus {
        case .ok: return BAMColors.secondaryLabel
        case .warning: return .orange
        case .refuse: return .red
        }
    }
}
