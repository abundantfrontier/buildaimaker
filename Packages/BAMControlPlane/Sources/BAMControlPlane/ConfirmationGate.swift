import CryptoKit
import Foundation

/// Whether an invoke must pause for a human (design: default profile).
public enum ConfirmationPolicy: Sendable {
    /// MCP/CLI expensive + destructive writes need the in-app banner.
    /// UI / test / system already have a human (or are harnesses).
    /// `minds.dedupe` is destructive only when `dryRun` is explicitly false.
    public static func requiresHumanConfirm(
        definition: ActionDefinition,
        params: JSONValue,
        source: ActionSource
    ) -> Bool {
        switch source {
        case .ui, .test, .system:
            return false
        case .mcp, .cli:
            switch definition.risk {
            case .destructive:
                if definition.id.rawValue == "minds.dedupe" {
                    return params["dryRun"]?.boolValue == false
                }
                return true
            case .expensive:
                return true
            case .read, .session, .write, .external:
                return false
            }
        }
    }

    public static func summary(
        for id: ActionID,
        params: JSONValue,
        risk: ActionRisk
    ) -> String {
        switch id.rawValue {
        case "finetune.start":
            let recipe = params["recipe"]?.stringValue ?? "mlx_lora"
            let cid = params["characterId"]?.stringValue ?? "unknown character"
            return "Start \(recipe) fine-tune for character \(cid)"
        case "minds.dedupe":
            return "Delete orphan duplicate mind datasets (not a dry-run)"
        case "character.delete":
            let name = params["name"]?.stringValue
                ?? params["characterId"]?.stringValue
                ?? "this character"
            return "Permanently remove \(name)"
        case "dataset.delete":
            return "Permanently remove dataset \(params["datasetId"]?.stringValue ?? "")"
        default:
            return "\(risk.rawValue) action \(id.rawValue) requires approval"
        }
    }

    public static func paramsDigest(_ params: JSONValue) -> String {
        let data = (try? params.jsonData()) ?? Data()
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

public enum ConfirmationGateError: Error, LocalizedError, Sendable {
    case tooManyPending

    public var errorDescription: String? {
        switch self {
        case .tooManyPending:
            return "Too many pending confirmations. Approve or deny one in the app first."
        }
    }
}

/// Server-side confirmation tokens (TTL 5 min, max 32 pending).
public actor ConfirmationGate {
    public struct Pending: Sendable {
        public var challenge: ConfirmationChallenge
        public var actionId: ActionID
        public var params: JSONValue
        public var context: ActionContext
        public var paramsDigest: String
    }

    public static let defaultTTL: TimeInterval = 300
    public static let maxPending = 32

    private var pending: [String: Pending] = [:]
    private let ttl: TimeInterval

    public init(ttl: TimeInterval = ConfirmationGate.defaultTTL) {
        self.ttl = ttl
    }

    public func issue(
        actionId: ActionID,
        params: JSONValue,
        context: ActionContext,
        risk: ActionRisk,
        summary: String
    ) throws -> ConfirmationChallenge {
        pruneExpired()
        if pending.count >= Self.maxPending {
            throw ConfirmationGateError.tooManyPending
        }
        let challenge = ConfirmationChallenge(
            token: "conf_\(UUID().uuidString)",
            actionId: actionId.rawValue,
            risk: risk,
            summary: summary,
            expiresAt: Date().addingTimeInterval(ttl),
            uiRequired: true
        )
        pending[challenge.token] = Pending(
            challenge: challenge,
            actionId: actionId,
            params: params,
            context: context,
            paramsDigest: ConfirmationPolicy.paramsDigest(params)
        )
        return challenge
    }

    public func pending(token: String) -> Pending? {
        pruneExpired()
        return pending[token]
    }

    public func listChallenges() -> [ConfirmationChallenge] {
        pruneExpired()
        return pending.values.map(\.challenge).sorted { $0.expiresAt < $1.expiresAt }
    }

    public var pendingCount: Int {
        pruneExpired()
        return pending.count
    }

    /// Consume a token if it matches action + params and is unexpired.
    public func consume(token: String, actionId: ActionID, params: JSONValue) -> Bool {
        pruneExpired()
        guard let item = pending[token] else { return false }
        let digest = ConfirmationPolicy.paramsDigest(params)
        guard item.actionId == actionId, item.paramsDigest == digest else { return false }
        pending.removeValue(forKey: token)
        return true
    }

    @discardableResult
    public func remove(token: String) -> Pending? {
        pending.removeValue(forKey: token)
    }

    private func pruneExpired() {
        let now = Date()
        pending = pending.filter { $0.value.challenge.expiresAt > now }
    }
}
