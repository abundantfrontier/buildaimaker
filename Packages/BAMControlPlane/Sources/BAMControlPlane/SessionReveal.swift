import Foundation

/// Writes session chrome so the running UI can follow MCP/CLI work.
public enum SessionReveal: Sendable {
    /// Default: reveal unless the caller passes `reveal: false`.
    public static func shouldReveal(_ params: JSONValue) -> Bool {
        params["reveal"]?.boolValue ?? true
    }

    /// Merge route / selection / guide fields into the session snapshot.
    public static func apply(
        to state: inout StateSnapshot,
        route: String? = nil,
        characterId: String? = nil,
        datasetId: String? = nil,
        jobId: String? = nil,
        open: String? = nil,
        highlight: String? = nil,
        guideTitle: String? = nil,
        guideSteps: [String]? = nil,
        pendingUserMessage: String? = nil,
        chatUser: String? = nil,
        chatAssistant: String? = nil,
        wizardStep: String? = nil,
        speakReplies: Bool? = nil
    ) {
        if let route { state.route = route }
        if let characterId { state.selection["characterId"] = characterId }
        if let datasetId { state.selection["datasetId"] = datasetId }
        if let jobId { state.selection["jobId"] = jobId }
        if let open { state.selection["open"] = open }
        if let wizardStep { state.selection["wizardStep"] = wizardStep }

        let nonce = UUID().uuidString
        state.selection["sessionNonce"] = nonce

        if let highlight {
            state.ui["highlight"] = .string(highlight)
        }
        if let guideTitle {
            state.ui["guideTitle"] = .string(guideTitle)
        }
        if let guideSteps {
            state.ui["guideSteps"] = .array(guideSteps.map { .string($0) })
        }
        if let pendingUserMessage {
            state.ui["pendingUserMessage"] = .string(pendingUserMessage)
        }
        if let chatUser { state.ui["chatUser"] = .string(chatUser) }
        if let chatAssistant { state.ui["chatAssistant"] = .string(chatAssistant) }
        if let speakReplies { state.ui["speakReplies"] = .bool(speakReplies) }
        state.ui["nonce"] = .string(nonce)
    }

    /// Drop coach/highlight chrome (route change, dismiss, or a plain nav.go).
    public static func clearGuide(from state: inout StateSnapshot) {
        for key in [
            "guideTitle", "guideSteps", "highlight",
            "pendingUserMessage", "chatUser", "chatAssistant",
        ] {
            state.ui.removeValue(forKey: key)
        }
    }

    /// Apply optional session fields from an invoke params object (`nav.go`, `selection.set`).
    public static func mergeParams(_ params: JSONValue, into state: inout StateSnapshot) {
        apply(
            to: &state,
            route: params["route"]?.stringValue,
            characterId: params["characterId"]?.stringValue,
            datasetId: params["datasetId"]?.stringValue,
            jobId: params["jobId"]?.stringValue,
            open: params["open"]?.stringValue,
            highlight: params["highlight"]?.stringValue,
            guideTitle: params["guideTitle"]?.stringValue,
            guideSteps: stringArray(params["guideSteps"]),
            pendingUserMessage: params["pendingUserMessage"]?.stringValue,
            wizardStep: params["wizardStep"]?.stringValue
        )
    }

    public static func stringArray(_ value: JSONValue?) -> [String]? {
        guard case .array(let items) = value else { return nil }
        let mapped = items.compactMap(\.stringValue)
        return mapped.isEmpty && items.isEmpty ? [] : mapped
    }
}
