import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import BAMCharacterStudio
import BAMCore
import BAMInference
import BAMModelCatalog

/// Scanned LoRA adapter under `models/adapters`.
struct ScannedAdapter: Identifiable, Equatable, Sendable {
    var directoryName: String
    var localPath: String
    var displayName: String
    var hasAdapterConfig: Bool

    var id: String { localPath }
}

/// Text playground: base vs adapter chat with A/B toggle and JSONL export.
///
/// Uses real `mlx-lm generate` when the managed/system Python has mlx_lm **and**
/// the selected base model is not a fixture/stub. Otherwise falls back to echo
/// (character system prompt still applies).
@MainActor
final class PlaygroundViewModel: ObservableObject {
    @Published private(set) var baseModels: [ScannedLocalModel] = []
    @Published private(set) var adapters: [ScannedAdapter] = []
    @Published var selectedBasePath: String?
    @Published var selectedAdapterPath: String?
    /// A/B: when false, completions ignore the selected adapter (base only).
    @Published var adapterEnabled: Bool = true
    @Published var systemPrompt: String = "You are a helpful assistant."
    @Published var draft: String = ""
    @Published private(set) var messages: [InferenceChatMessage] = []
    @Published private(set) var isGenerating = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published private(set) var backendId: String = "echo"
    @Published private(set) var lastLatencyMs: Double?
    @Published private(set) var lastWasStub: Bool?
    @Published private(set) var playgroundEnabled: Bool = FeatureFlags.default.playground
    @Published var exportMessage: String?
    @Published private(set) var lastTracePath: String?
    /// Character handoff banner.
    @Published private(set) var boundCharacterName: String?
    @Published private(set) var modelCapability: LocalModelCapability = .stub(reason: "No model selected")
    @Published private(set) var mlxAvailable: Bool = false
    @Published private(set) var usingRealGenerate: Bool = false
    /// Backend preference: Apple on-device first when available.
    @Published var backendPreference: LLMBackendPreference = .automatic {
        didSet { resolveBackend() }
    }
    @Published private(set) var appleModelStatus: AppleFoundationModelStatus = .unknown
    @Published private(set) var mlxPythonAvailable: Bool = false

    private let libraryRoot: URL
    private let featureFlags: FeatureFlags
    private var backend: any LLMBackend
    private let forceEcho: Bool
    private let baseScanner: LocalModelScanner
    private let metricsStore: MVPMetricsStore
    private var traceRecorder: PlaygroundTraceRecorder
    private var lastAppliedPlaygroundToken: UUID?

    init(
        libraryRoot: URL = LibraryPaths.libraryRoot,
        featureFlags: FeatureFlags = .default,
        backend: (any LLMBackend)? = nil,
        forceEcho: Bool = false,
        metricsStore: MVPMetricsStore = .shared
    ) {
        self.libraryRoot = libraryRoot
        self.featureFlags = featureFlags
        self.playgroundEnabled = featureFlags.playground
        self.forceEcho = forceEcho
        self.backend = backend ?? LLMBackendFactory.makeDefault(preference: .automatic, forceEcho: forceEcho)
        self.backendId = self.backend.backendId
        self.baseScanner = LocalModelScanner(
            modelsBaseURL: libraryRoot.appendingPathComponent("models/base", isDirectory: true)
        )
        self.metricsStore = metricsStore
        self.traceRecorder = PlaygroundTraceRecorder.underLibraryRoot(
            libraryRoot,
            enabled: PlaygroundTraceRecorder.isEnabled()
        )
        self.appleModelStatus = AppleFoundationModelSupport.probeStatus()
        self.mlxPythonAvailable = MLXGenerateBackend.isAvailable()
        self.usingRealGenerate = !self.backend.backendId.contains("echo")
    }

    func bootstrap() {
        reload()
    }

    /// Apply character wizard / list handoff (model path + system prompt).
    func applyCharacterLaunch(_ target: CharacterStudioLaunchContext.PlaygroundTarget) {
        guard lastAppliedPlaygroundToken != target.token else { return }
        lastAppliedPlaygroundToken = target.token
        boundCharacterName = target.characterName

        let usesApple = target.baseModelSourceKey == CharacterDraft.appleFoundationSourceKey
            || target.baseModelPath == CharacterDraft.appleFoundationPath
        if usesApple {
            backendPreference = .appleFoundation
            // Don't force a non-existent disk path into the MLX picker.
            if let path = target.baseModelPath,
               path != CharacterDraft.appleFoundationPath,
               !path.isEmpty
            {
                selectedBasePath = path
            }
        } else if let path = target.baseModelPath, !path.isEmpty,
                  path != CharacterDraft.appleFoundationPath
        {
            selectedBasePath = path
            if backendPreference == .automatic || backendPreference == .appleFoundation {
                backendPreference = .mlx
            }
        }

        if let prompt = target.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prompt.isEmpty
        {
            systemPrompt = prompt
        } else if !target.characterName.isEmpty {
            systemPrompt = "You are \(target.characterName). Stay in character."
        }
        messages = []
        reload()
        statusMessage = "Bound to character “\(target.characterName)”"
            + (target.baseModelName.map { " · \($0)" } ?? "")
            + (usesApple ? " · Apple on-device" : "")
    }

    func reload() {
        errorMessage = nil
        do {
            baseModels = try baseScanner.scan()
            adapters = try Self.scanAdapters(
                at: libraryRoot.appendingPathComponent("models/adapters", isDirectory: true)
            )
            if selectedBasePath == nil {
                selectedBasePath = baseModels.first?.localPath
            } else if let path = selectedBasePath,
                      !baseModels.contains(where: { $0.localPath == path })
            {
                // Keep explicit character path even if scan missed it briefly.
                if !FileManager.default.fileExists(atPath: path) {
                    selectedBasePath = baseModels.first?.localPath
                }
            }
            if let path = selectedAdapterPath,
               !adapters.contains(where: { $0.localPath == path })
            {
                selectedAdapterPath = nil
            }

            onSelectedBaseModelChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Re-probe model capability + backend when the user changes the base model picker.
    func onSelectedBaseModelChanged() {
        modelCapability = LocalModelCapabilityProbe.probe(path: selectedBasePath)
        resolveBackend()
        updateStatusBanner()
    }

    /// Re-pick backend: Apple FM (default) → MLX → echo.
    private func resolveBackend() {
        appleModelStatus = AppleFoundationModelSupport.probeStatus()
        mlxPythonAvailable = MLXGenerateBackend.isAvailable()
        mlxAvailable = mlxPythonAvailable

        if forceEcho {
            backend = EchoLLMBackend()
            backendId = backend.backendId
            usingRealGenerate = false
            return
        }

        switch backendPreference {
        case .echo:
            backend = EchoLLMBackend()
        case .appleFoundation:
            backend = AppleFoundationLLMBackend.makeIfAvailable() ?? EchoLLMBackend()
        case .mlx:
            // Only use MLX when weights look real; otherwise echo with message.
            if !modelCapability.isStub, let mlx = MLXGenerateBackend.makeIfAvailable() {
                backend = mlx
            } else {
                backend = EchoLLMBackend()
            }
        case .automatic:
            if let apple = AppleFoundationLLMBackend.makeIfAvailable() {
                backend = apple
            } else if !modelCapability.isStub, let mlx = MLXGenerateBackend.makeIfAvailable() {
                backend = mlx
            } else {
                backend = EchoLLMBackend()
            }
        }
        backendId = backend.backendId
        usingRealGenerate = backendId != EchoLLMBackend.id
    }

    private func updateStatusBanner() {
        var parts: [String] = []
        if let name = boundCharacterName {
            parts.append("Character: \(name)")
        }
        switch backendId {
        case AppleFoundationLLMBackend.id:
            parts.append("Apple on-device model (default)")
        case MLXGenerateBackend.id:
            parts.append("MLX generate")
        case EchoLLMBackend.id:
            if appleModelStatus == .available {
                parts.append("Echo — pick Automatic/Apple in backend menu")
            } else if modelCapability.isStub {
                parts.append("Echo — stub weights; Apple FM unavailable or MLX needs real weights")
            } else {
                parts.append("Echo stub")
            }
        default:
            parts.append("Backend: \(backendId)")
        }
        parts.append("Apple FM: \(appleModelStatus.rawValue)")
        statusMessage = parts.joined(separator: " · ")
    }

    /// Apple FM needs no local base path; MLX does.
    var canSend: Bool {
        let hasDraft = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard playgroundEnabled, !isGenerating, hasDraft else { return false }
        if backendId == AppleFoundationLLMBackend.id { return true }
        if backendPreference == .automatic, appleModelStatus == .available { return true }
        if backendId == MLXGenerateBackend.id { return selectedBasePath != nil }
        // Echo / other: allow without base so Apple-default path still works mid-resolve.
        return true
    }

    var canExport: Bool {
        !messages.isEmpty && messages.contains(where: { $0.role == "user" })
    }

    func send() {
        guard canSend else { return }
        modelCapability = LocalModelCapabilityProbe.probe(path: selectedBasePath)
        resolveBackend()
        let base = selectedBasePath

        let text = draft
        draft = ""
        isGenerating = true
        errorMessage = nil
        exportMessage = nil
        traceRecorder.enabled = PlaygroundTraceRecorder.isEnabled()

        let activeBackend = backend

        Task {
            defer { isGenerating = false }
            do {
                let formatStarted = Date()
                var session = PlaygroundSession(
                    systemPrompt: systemPrompt,
                    messages: messages,
                    baseModelPath: base,
                    adapterPath: selectedAdapterPath,
                    adapterEnabled: adapterEnabled
                )
                let completeStarted = Date()
                let result = try await session.send(userText: text, backend: activeBackend)
                let completeEnded = Date()
                messages = session.messages
                lastLatencyMs = result.latencyMs
                lastWasStub = result.isStub
                backendId = result.backendId
                statusMessage = result.isStub
                    ? "Echo reply (\(Int(result.latencyMs)) ms) — not a real model completion"
                    : "Real generate via \(result.backendId) (\(Int(result.latencyMs)) ms)"

                metricsStore.increment(.playgroundReply)
                OnboardingStore().markCompleted(.playgroundChat)

                let stages = PlaygroundTraceRecorder.stagesForCompletion(
                    formatStarted: formatStarted,
                    completeStarted: completeStarted,
                    completeEnded: completeEnded,
                    totalEnded: completeEnded
                )
                if let url = try? traceRecorder.recordTurn(
                    stages: stages,
                    backendId: result.backendId,
                    latencyMs: result.latencyMs,
                    isStub: result.isStub,
                    baseModelPath: base,
                    adapterPath: selectedAdapterPath,
                    adapterEnabled: adapterEnabled
                ) {
                    lastTracePath = url.path
                }
            } catch {
                draft = text
                errorMessage = error.localizedDescription
                if backendId == AppleFoundationLLMBackend.id {
                    statusMessage = "Apple model failed — check Apple Intelligence status."
                } else if usingRealGenerate {
                    statusMessage = "Generate failed — check MLX weights / runtime."
                }
            }
        }
    }

    func clearTranscript() {
        messages = []
        lastLatencyMs = nil
        lastWasStub = nil
        exportMessage = nil
        statusMessage = "Transcript cleared."
    }

    /// Export full conversation as JSONL dataset candidate via save panel.
    func exportTranscript(paired: Bool = false) {
        guard canExport else {
            exportMessage = "Nothing to export yet — send at least one user message."
            return
        }
        var exportMsgs: [InferenceChatMessage] = []
        let trimmed = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            exportMsgs.append(.system(trimmed))
        }
        exportMsgs.append(contentsOf: messages.filter { $0.role != "system" })

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = paired ? "playground-pairs.jsonl" : "playground-transcript.jsonl"
        panel.title = "Export transcript as dataset candidate"
        panel.message = "OpenAI-messages JSONL for re-import under Datasets."
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else {
            exportMessage = "Export cancelled."
            return
        }
        var outURL = url
        if outURL.pathExtension.lowercased() != "jsonl" {
            outURL = outURL.deletingPathExtension().appendingPathExtension("jsonl")
        }
        do {
            try TranscriptExporter.write(messages: exportMsgs, to: outURL, paired: paired)
            exportMessage = "Exported to \(outURL.path)"
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Adapter scan

    static func scanAdapters(at adaptersRoot: URL, fileManager: FileManager = .default) throws -> [ScannedAdapter] {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: adaptersRoot.path, isDirectory: &isDir),
              isDir.boolValue
        else {
            return []
        }
        let contents = try fileManager.contentsOfDirectory(
            at: adaptersRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var results: [ScannedAdapter] = []
        for url in contents {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            let name = url.lastPathComponent
            guard LibraryPaths.validatedPathComponent(name) != nil else { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            let config = resolved.appendingPathComponent("adapter_config.json")
            let hasConfig = fileManager.fileExists(atPath: config.path)
            results.append(
                ScannedAdapter(
                    directoryName: name,
                    localPath: resolved.path,
                    displayName: name,
                    hasAdapterConfig: hasConfig
                )
            )
        }
        return results.sorted {
            $0.directoryName.localizedCaseInsensitiveCompare($1.directoryName) == .orderedAscending
        }
    }
}
