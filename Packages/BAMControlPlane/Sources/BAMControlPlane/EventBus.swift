import Foundation

public enum BusEventKind: String, Codable, Sendable {
    case actionInvoked = "action.invoked"
    case actionCompleted = "action.completed"
    case actionFailed = "action.failed"
    case stateChanged = "state.changed"
    case jobProgress = "job.progress"
    case jobCompleted = "job.completed"
    case confirmRequired = "confirm.required"
    case confirmResolved = "confirm.resolved"
}

public struct BusEvent: Sendable, Equatable {
    public var kind: BusEventKind
    public var correlationId: String?
    public var actionId: String?
    public var payload: JSONValue?
    public var at: Date

    public init(
        kind: BusEventKind,
        correlationId: String? = nil,
        actionId: String? = nil,
        payload: JSONValue? = nil,
        at: Date = Date()
    ) {
        self.kind = kind
        self.correlationId = correlationId
        self.actionId = actionId
        self.payload = payload
        self.at = at
    }
}

public protocol EventBusProtocol: Sendable {
    func publish(_ event: BusEvent)
    func subscribe() -> AsyncStream<BusEvent>
}

/// Simple fan-out event bus (in-process UI + tests).
public final class EventBus: EventBusProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<BusEvent>.Continuation] = [:]

    public init() {}

    public func publish(_ event: BusEvent) {
        lock.lock()
        let conts = Array(continuations.values)
        lock.unlock()
        for c in conts {
            c.yield(event)
        }
    }

    public func subscribe() -> AsyncStream<BusEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }
}
