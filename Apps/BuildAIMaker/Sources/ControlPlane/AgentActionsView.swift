import BAMControlPlane
import BAMResourcesUI
import SwiftUI

/// Same Action catalog MCP sees — list + invoke for dogfood.
struct AgentActionsView: View {
    @EnvironmentObject private var controlPlane: ControlPlaneEnvironment
    @StateObject private var model = AgentActionsViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(BAMColors.detailBackground)
        .navigationTitle("Agent Actions")
        .task {
            await model.reload(via: controlPlane)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("Actions", systemImage: SidebarDestination.actions.systemImage)
                .font(.headline)
            Spacer()
            Button {
                Task { await model.reload(via: controlPlane) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isInvoking)
        }
        .padding(12)
    }

    private var content: some View {
        HSplitView {
            actionList
                .frame(minWidth: 240, idealWidth: 300, maxWidth: 380)
            invokePane
                .frame(minWidth: 360)
        }
    }

    private var actionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let loadError = model.loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
            }
            List(selection: $model.selectedId) {
                ForEach(model.actions) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(row.title)
                                .font(.body.weight(.medium))
                            Spacer()
                            Text(row.risk)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(riskColor(row.risk).opacity(0.18), in: Capsule())
                        }
                        Text(row.id)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(row.mcpTool)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .tag(Optional(row.id))
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var invokePane: some View {
        Form {
            Section("Presets (same handlers as MCP)") {
                HStack {
                    Button("Get state") {
                        Task { await model.invokePreset(.getState, via: controlPlane) }
                    }
                    Button("List characters") {
                        Task { await model.invokePreset(.listCharacters, via: controlPlane) }
                    }
                    Button("Dedupe minds (dry-run)") {
                        Task { await model.invokePreset(.dedupeDryRun, via: controlPlane) }
                    }
                }
                .disabled(model.isInvoking || !controlPlane.isReady)
            }

            Section("Selected action") {
                if let selected = model.selectedAction {
                    Text(selected.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("MCP tool: \(selected.mcpTool)")
                        .font(.caption.monospaced())
                    TextEditor(text: $model.paramsText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 88)
                    Button {
                        Task { await model.invokeSelected(via: controlPlane) }
                    } label: {
                        if model.isInvoking {
                            ProgressView()
                        } else {
                            Text("Invoke")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isInvoking || !controlPlane.isReady)
                } else {
                    Text("Select an action, or use a preset.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Last outcome") {
                if model.lastOutput.isEmpty {
                    Text("Nothing invoked yet.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(model.lastOutput)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func riskColor(_ risk: String) -> Color {
        switch risk {
        case "destructive": return .red
        case "expensive": return .orange
        case "write": return .blue
        default: return .secondary
        }
    }
}

@MainActor
final class AgentActionsViewModel: ObservableObject {
    struct ActionRow: Identifiable, Equatable {
        var id: String
        var title: String
        var description: String
        var risk: String
        var mcpTool: String
    }

    enum Preset {
        case getState
        case listCharacters
        case dedupeDryRun

        var actionId: ActionID {
            switch self {
            case .getState: return AppGetStateHandler.id
            case .listCharacters: return CharacterListHandler.id
            case .dedupeDryRun: return MindsDedupeHandler.id
            }
        }

        var params: JSONValue {
            switch self {
            case .getState: return .object([:])
            case .listCharacters: return .object(["limit": .number(20)])
            case .dedupeDryRun: return .object(["dryRun": .bool(true)])
            }
        }
    }

    @Published var actions: [ActionRow] = []
    @Published var selectedId: String?
    @Published var paramsText = "{}"
    @Published var lastOutput = ""
    @Published var isInvoking = false
    @Published var loadError: String?

    var selectedAction: ActionRow? {
        guard let selectedId else { return nil }
        return actions.first { $0.id == selectedId }
    }

    func reload(via plane: ControlPlaneEnvironment) async {
        let outcome = await plane.invoke(AppListActionsHandler.id)
        guard outcome.ok, case .array(let items) = outcome.data?["actions"] else {
            loadError = outcome.error?.message ?? "Could not list actions"
            return
        }
        loadError = nil
        actions = items.compactMap { item in
            guard let id = item["id"]?.stringValue else { return nil }
            return ActionRow(
                id: id,
                title: item["title"]?.stringValue ?? id,
                description: item["description"]?.stringValue ?? "",
                risk: item["risk"]?.stringValue ?? "",
                mcpTool: item["mcpToolName"]?.stringValue ?? ""
            )
        }
        if selectedId == nil {
            selectedId = actions.first?.id
        }
    }

    func invokePreset(_ preset: Preset, via plane: ControlPlaneEnvironment) async {
        selectedId = preset.actionId.rawValue
        paramsText = prettyJSON(preset.params)
        await run(id: preset.actionId, params: preset.params, via: plane)
    }

    func invokeSelected(via plane: ControlPlaneEnvironment) async {
        guard let id = selectedId else { return }
        let params: JSONValue
        if let data = paramsText.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
        {
            params = decoded
        } else {
            lastOutput = "Params must be JSON (object)."
            return
        }
        await run(id: ActionID(id), params: params, via: plane)
    }

    private func run(id: ActionID, params: JSONValue, via plane: ControlPlaneEnvironment) async {
        isInvoking = true
        defer { isInvoking = false }
        let outcome = await plane.invoke(id, params: params)
        lastOutput = prettyJSON(outcome.asJSONValue())
    }

    private func prettyJSON(_ value: JSONValue) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(value),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }
}
