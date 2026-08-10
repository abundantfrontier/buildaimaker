import Foundation

/// Local-only MVP success metric event counters (Phase 1 M1–M5).
///
/// These are **not** cloud telemetry. Counts live in `UserDefaults` so dogfood
/// can confirm funnel events without a network path. Opt-in remote telemetry
/// remains gated by `ff.telemetryOptIn` and is out of scope here.
///
/// | Metric | Event |
/// |--------|--------|
/// | M1 | `trainCompleted` — LoRA fine-tune finished successfully in-app |
/// | M2 | `jobCancelled` — cancel requested on a running/queued job |
/// | M3 | `playgroundReply` — playground produced an assistant reply |
/// | M4 | `datasetImportOK` / `datasetImportRejected` — import validate path |
/// | M5 | `networkCallTrainPlay` — network during train/play (should stay 0) |
public enum MVPMetricEvent: String, CaseIterable, Sendable, Codable, Identifiable {
    case trainCompleted = "m1.trainCompleted"
    case jobCancelled = "m2.jobCancelled"
    case playgroundReply = "m3.playgroundReply"
    case datasetImportOK = "m4.datasetImportOK"
    case datasetImportRejected = "m4.datasetImportRejected"
    case networkCallTrainPlay = "m5.networkCallTrainPlay"

    public var id: String { rawValue }

    /// Human-readable MVP metric label (M1…M5).
    public var metricId: String {
        switch self {
        case .trainCompleted: return "M1"
        case .jobCancelled: return "M2"
        case .playgroundReply: return "M3"
        case .datasetImportOK, .datasetImportRejected: return "M4"
        case .networkCallTrainPlay: return "M5"
        }
    }

    public var displayName: String {
        switch self {
        case .trainCompleted: return "LoRA train completed"
        case .jobCancelled: return "Job cancel requested"
        case .playgroundReply: return "Playground reply"
        case .datasetImportOK: return "Dataset import accepted"
        case .datasetImportRejected: return "Dataset import rejected"
        case .networkCallTrainPlay: return "Network during train/play"
        }
    }

    /// UserDefaults key for this counter.
    public var defaultsKey: String {
        "bam.metrics.\(rawValue)"
    }
}

/// Snapshot of all M1–M5 counters.
public struct MVPMetricsSnapshot: Sendable, Equatable {
    public var counts: [MVPMetricEvent: Int]

    public init(counts: [MVPMetricEvent: Int] = [:]) {
        self.counts = counts
    }

    public func count(for event: MVPMetricEvent) -> Int {
        counts[event] ?? 0
    }

    /// M5 pass criterion: zero network calls during train/play.
    public var m5NetworkCallsDuringTrainPlay: Int {
        count(for: .networkCallTrainPlay)
    }

    public var m5Passes: Bool {
        m5NetworkCallsDuringTrainPlay == 0
    }
}

/// Lightweight local metrics counters backed by `UserDefaults`.
///
/// `@unchecked Sendable`: `UserDefaults` is thread-safe for simple key I/O
/// but not formally Sendable in the SDK.
public struct MVPMetricsStore: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Shared process-wide store (standard UserDefaults).
    public static let shared = MVPMetricsStore()

    public func count(for event: MVPMetricEvent) -> Int {
        defaults.integer(forKey: event.defaultsKey)
    }

    @discardableResult
    public func increment(_ event: MVPMetricEvent, by delta: Int = 1) -> Int {
        let next = max(0, count(for: event) + delta)
        defaults.set(next, forKey: event.defaultsKey)
        return next
    }

    public func setCount(_ value: Int, for event: MVPMetricEvent) {
        defaults.set(max(0, value), forKey: event.defaultsKey)
    }

    public func snapshot() -> MVPMetricsSnapshot {
        var counts: [MVPMetricEvent: Int] = [:]
        for event in MVPMetricEvent.allCases {
            counts[event] = count(for: event)
        }
        return MVPMetricsSnapshot(counts: counts)
    }

    public func resetAll() {
        for event in MVPMetricEvent.allCases {
            defaults.removeObject(forKey: event.defaultsKey)
        }
    }
}
