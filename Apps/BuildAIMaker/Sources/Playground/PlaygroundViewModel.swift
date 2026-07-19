import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
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

    private let libraryRoot: URL
    private let featureFlags: FeatureFlags
    private let backend: any LLMBackend
    private let baseScanner: LocalModelScanner
    private let metricsStore: MVPMetricsStore
    private var traceRecorder: PlaygroundTraceRecorder

    init(
        libraryRoot: URL = LibraryPaths.libraryRoot,
        featureFlags: FeatureFlags = .default,
        backend: (any LLMBackend)? = nil,
        metricsStore: MVPMetricsStore = .shared
    ) {
        self.libraryRoot = libraryRoot
        self.featureFlags = featureFlags
        self.playgroundEnabled = featureFlags.playground
        self.backend = backend ?? LLMBackendFactory.makeDefault(forceEcho: false)
        self.backendId = self.backend.backendId
        self.baseScanner = LocalModelScanner(
            modelsBaseURL: libraryRoot.appendingPathComponent("models/base", isDirectory: true)
        )
        self.metricsStore = metricsStore
        self.traceRecorder = PlaygroundTraceRecorder.underLibraryRoot(
            libraryRoot,
            enabled: PlaygroundTraceRecorder.isEnabled()
        )
    }

    func bootstrap() {
        reload()
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
                selectedBasePath = baseModels.first?.localPath
            }
            if let path = selectedAdapterPath,
               !adapters.contains(where: { $0.localPath == path })
            {
                selectedAdapterPath = nil
            }
            if baseModels.isEmpty {
                statusMessage = "Install a base model (Models → Install fixture model) to chat."
            } else if backend.backendId == EchoLLMBackend.id {
                statusMessage = "Using echo backend (CI-safe). Install mlx-lm for real generate."
            } else {
                statusMessage = "Backend: \(backend.backendId)"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var canSend: Bool {
        playgroundEnabled
            && !isGenerating
            && selectedBasePath != nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canExport: Bool {
        !messages.isEmpty && messages.contains(where: { $0.role == "user" })
    }

    func send() {
        guard canSend, let base = selectedBasePath else { return }
        let text = draft
        draft = ""
        isGenerating = true
        errorMessage = nil
        exportMessage = nil
        // Re-read enablement each send (Settings toggle / env).
        traceRecorder.enabled = PlaygroundTraceRecorder.isEnabled()

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
                let result = try await session.send(userText: text, backend: backend)
                let completeEnded = Date()
                messages = session.messages
                lastLatencyMs = result.latencyMs
                lastWasStub = result.isStub
                backendId = result.backendId
                statusMessage = result.isStub
                    ? "Echo reply (\(Int(result.latencyMs)) ms) — adapter \(adapterEnabled && selectedAdapterPath != nil ? "on" : "off")"
                    : "Reply via \(result.backendId) (\(Int(result.latencyMs)) ms)"

                // M3: playground produced a coherent reply (subjective quality not scored).
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
        // Prefer .jsonl extension even if panel used .json UTI.
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
