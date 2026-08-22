import BAMCharacterStudio
import BAMControlPlane
import BAMCore
import BAMInference
import BAMJobs
import BAMModels
import BAMPersistence
import BAMRunnersMLX
import BAMRunnersVoice
import Foundation
import SwiftUI

/// App-owned control plane (UI + future MCP bridge share this instance).
@MainActor
final class ControlPlaneEnvironment: ObservableObject {
    let plane: ControlPlane
    /// Shared single-slot job queue for finetune.start / Jobs UI.
    let jobQueue: JobQueueController

    @Published private(set) var isReady = false
    @Published private(set) var lastOutcome: ActionOutcome?
    @Published private(set) var stateRevision: Int = 0
    @Published private(set) var bootstrapError: String?
    @Published private(set) var rpcStatus: String?
    /// MCP/CLI expensive or destructive actions waiting on a human.
    @Published private(set) var pendingConfirmations: [ConfirmationChallenge] = []
    /// Sidebar route last written by the control plane (`nav.go` / reveal).
    @Published private(set) var route: String = "home"
    @Published private(set) var selectionMap: [String: String] = [:]
    @Published private(set) var highlight: String?
    @Published private(set) var guide: GuidePresentation?
    @Published private(set) var sessionNonce: String = ""
    @Published private(set) var pendingUserMessage: String?
    @Published private(set) var incomingChatUser: String?
    @Published private(set) var incomingChatAssistant: String?
    /// MCP/session request to turn Speak replies on or off. Nil = leave as-is.
    @Published private(set) var pendingSpeakReplies: Bool?

    struct GuidePresentation: Equatable {
        var title: String
        var steps: [String]
    }

    private var rpcServer: AppRPCServer?

    init(plane: ControlPlane = ControlPlane()) {
        self.plane = plane
        // Best-effort default queue; bootstrap may replace if open fails.
        if let queue = try? AppJobQueueFactory.makeDefault() {
            self.jobQueue = queue
        } else {
            // Fallback in-memory fake queue so handlers still register.
            let db = try! LibraryDatabase.openInMemory()
            self.jobQueue = JobQueueController(
                store: JobStore(database: db),
                runner: FakeTrainingRunner(),
                libraryRoot: LibraryPaths.libraryRoot
            )
            self.bootstrapError = "Using in-memory job queue (library DB unavailable)."
        }
    }

    func bootstrap() async {
        guard !isReady else { return }
        await plane.installBuiltins()
        await registerDomainHandlers()

        var caps: [String: JSONValue] = [:]
        let apple = AppleFoundationModelSupport.probeStatus()
        caps["appleFoundation"] = .string(apple.rawValue)
        caps["appleFoundationUsable"] = .bool(apple.isUsable)

        let characterCount = (try? CharacterLibraryStore().list())?.count ?? 0

        await plane.bootstrapSession(
            route: "home",
            flags: [
                "controlPlane": true,
            ],
            capabilities: caps
        )
        let count = characterCount
        await plane.stateStore.apply { state in
            state.counts["characters"] = count
        }

        do {
            try await jobQueue.recoverStaleJobs()
        } catch {
            // Non-fatal
        }

        startAppRPC()
        watchSessionEvents()

        isReady = true
        await refreshSessionProjection()
        await refreshPendingConfirmations()
    }

    func dismissGuide() async {
        await plane.stateStore.apply { state in
            state.ui.removeValue(forKey: "guideTitle")
            state.ui.removeValue(forKey: "guideSteps")
            state.ui.removeValue(forKey: "highlight")
        }
        await refreshSessionProjection()
    }

    func allowPendingConfirmation(_ token: String) async {
        lastOutcome = await plane.allowConfirmation(token)
        await refreshPendingConfirmations()
        stateRevision = await plane.stateStore.revision
    }

    func denyPendingConfirmation(_ token: String) async {
        lastOutcome = await plane.denyConfirmation(token)
        await refreshPendingConfirmations()
        stateRevision = await plane.stateStore.revision
    }

    func refreshPendingConfirmations() async {
        pendingConfirmations = await plane.confirmationGate.listChallenges()
    }

    private func watchSessionEvents() {
        Task { [weak self] in
            guard let self else { return }
            let stream = self.plane.eventBus.subscribe()
            for await ev in stream {
                switch ev.kind {
                case .confirmRequired, .confirmResolved:
                    await self.refreshPendingConfirmations()
                    await self.refreshSessionProjection()
                case .stateChanged, .actionCompleted:
                    await self.refreshSessionProjection()
                default:
                    break
                }
            }
        }
    }

    func refreshSessionProjection() async {
        let snap = await plane.stateStore.snapshot()
        stateRevision = snap.revision
        route = snap.route ?? "home"
        selectionMap = snap.selection
        sessionNonce = snap.selection["sessionNonce"]
            ?? snap.ui["nonce"]?.stringValue
            ?? ""
        highlight = snap.ui["highlight"]?.stringValue
        pendingUserMessage = snap.ui["pendingUserMessage"]?.stringValue
        incomingChatUser = snap.ui["chatUser"]?.stringValue
        incomingChatAssistant = snap.ui["chatAssistant"]?.stringValue
        pendingSpeakReplies = snap.ui["speakReplies"]?.boolValue
        if let title = snap.ui["guideTitle"]?.stringValue, !title.isEmpty {
            let steps = SessionReveal.stringArray(snap.ui["guideSteps"]) ?? []
            guide = GuidePresentation(title: title, steps: steps)
        } else {
            guide = nil
        }
    }

    private func startAppRPC() {
        let server = AppRPCServer(
            plane: plane,
            socketPath: LibraryPaths.mcpSocket,
            tokenPath: LibraryPaths.mcpToken,
            pidPath: LibraryPaths.mcpPidLock
        )
        do {
            try server.start()
            rpcServer = server
            rpcStatus = "MCP socket: \(LibraryPaths.mcpSocket.path)"
        } catch {
            rpcStatus = "MCP socket failed: \(error.localizedDescription)"
        }
    }

    private func registerDomainHandlers() async {
        await plane.registry.register(CharacterListHandler())
        await plane.registry.register(CharacterCreateHandler(stateStore: plane.stateStore))
        await plane.registry.register(CharacterGetHandler())
        await plane.registry.register(CharacterUpdateHandler(stateStore: plane.stateStore))
        await plane.registry.register(CharacterDeleteHandler(stateStore: plane.stateStore))
        await plane.registry.register(CharacterOpenHandler(stateStore: plane.stateStore))
        await plane.registry.register(CharacterImportMindHandler(stateStore: plane.stateStore))
        await plane.registry.register(ExamplesProposeHandler(stateStore: plane.stateStore))
        await plane.registry.register(DatasetListHandler())
        await plane.registry.register(DatasetGetHandler())
        await plane.registry.register(DatasetImportHandler(stateStore: plane.stateStore))
        await plane.registry.register(DatasetDeleteHandler(stateStore: plane.stateStore))
        await plane.registry.register(ModelListHandler())
        await plane.registry.register(ChatSendHandler(stateStore: plane.stateStore))
        await plane.registry.register(PlaygroundSetHandler(stateStore: plane.stateStore))
        await plane.registry.register(PersonaListHandler())
        await plane.registry.register(VoiceListHandler())
        await plane.registry.register(UIGuideHandler(stateStore: plane.stateStore))
        await plane.registry.register(MindsDedupeHandler(stateStore: plane.stateStore))
        await plane.registry.register(
            FinetuneStartHandler(jobQueue: jobQueue, stateStore: plane.stateStore)
        )
        await plane.registry.register(JobGetHandler(jobQueue: jobQueue))
        await plane.registry.register(JobListHandler(jobQueue: jobQueue))
        await plane.registry.register(JobCancelHandler(jobQueue: jobQueue))
    }

    @discardableResult
    func invoke(
        _ id: ActionID,
        params: JSONValue = .object([:]),
        source: ActionSource = .ui
    ) async -> ActionOutcome {
        let outcome = await plane.invoke(
            id,
            params: params,
            context: ActionContext(source: source)
        )
        lastOutcome = outcome
        await refreshSessionProjection()
        return outcome
    }

}
