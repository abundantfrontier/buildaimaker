import Foundation

/// Heartbeat payload written to `heartbeat.json` and tracked in memory.
public struct HeartbeatState: Codable, Sendable, Equatable {
    public var pid: Int32
    public var ts: String
    public var rssBytes: Int64?
    public var gpuUtil: Double?
    public var cpuUtil: Double?

    public init(
        pid: Int32,
        ts: String,
        rssBytes: Int64? = nil,
        gpuUtil: Double? = nil,
        cpuUtil: Double? = nil
    ) {
        self.pid = pid
        self.ts = ts
        self.rssBytes = rssBytes
        self.gpuUtil = gpuUtil
        self.cpuUtil = cpuUtil
    }
}

/// In-memory + optional on-disk heartbeat for hang / crash detection.
///
/// Design: worker emits heartbeat ≥ every 5 s; supervisor timeout 20 s → hung /
/// stale on relaunch → `interrupted`.
public final class HeartbeatMonitor: @unchecked Sendable {
    /// Default supervisor timeout (seconds) matching Runner Protocol v1.
    public static let defaultTimeoutSeconds: TimeInterval = 20

    private let lock = NSLock()
    private var last: HeartbeatState?
    private var lastWallClock: Date?
    private let fileURL: URL?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        self.encoder = e
        self.decoder = JSONDecoder()
    }

    public var lastHeartbeat: HeartbeatState? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    /// Records a heartbeat and optionally mirrors it to `heartbeat.json`.
    ///
    /// In-memory state is always updated. File I/O is **best-effort**: failures
    /// are ignored so a disk error cannot fail a healthy training run.
    public func touch(
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        rssBytes: Int64? = nil,
        gpuUtil: Double? = nil,
        cpuUtil: Double? = nil,
        ts: String = JobTimestamps.now(),
        at date: Date = Date()
    ) {
        let state = HeartbeatState(
            pid: pid,
            ts: ts,
            rssBytes: rssBytes,
            gpuUtil: gpuUtil,
            cpuUtil: cpuUtil
        )
        lock.lock()
        last = state
        lastWallClock = date
        lock.unlock()

        if let fileURL {
            do {
                let parent = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                let data = try encoder.encode(state)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                // Best-effort mirror only; hang detection uses in-memory clock.
            }
        }
    }

    /// True when the last heartbeat is older than `timeout`.
    ///
    /// Returns `false` when no heartbeat has been recorded yet (grace until first
    /// touch) so a freshly started run is not immediately treated as hung.
    /// Use `requireTouch: true` for crash-recovery paths that expect a prior beat.
    public func isStale(
        timeout: TimeInterval = HeartbeatMonitor.defaultTimeoutSeconds,
        now: Date = Date(),
        requireTouch: Bool = false
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let lastWallClock else { return requireTouch }
        return now.timeIntervalSince(lastWallClock) > timeout
    }

    /// Age of last heartbeat in seconds, or `nil` if never touched.
    public func age(now: Date = Date()) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard let lastWallClock else { return nil }
        return now.timeIntervalSince(lastWallClock)
    }

    public func reset() {
        lock.lock()
        last = nil
        lastWallClock = nil
        lock.unlock()
    }

    /// Loads heartbeat from disk (crash recovery / relaunch).
    public static func readFile(at url: URL) throws -> HeartbeatState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(HeartbeatState.self, from: data)
    }

    /// True when on-disk heartbeat mtime (or embedded `ts`) is older than `timeout`.
    public static func isFileStale(
        at url: URL,
        timeout: TimeInterval = HeartbeatMonitor.defaultTimeoutSeconds,
        now: Date = Date()
    ) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return true
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        if let mod = attrs[.modificationDate] as? Date {
            return now.timeIntervalSince(mod) > timeout
        }
        // Fall back to embedded ISO timestamp when mtime unavailable.
        if let state = try readFile(at: url),
           let parsed = JobTimestamps.parse(state.ts)
        {
            return now.timeIntervalSince(parsed) > timeout
        }
        return true
    }
}

/// ISO-8601 timestamps for job rows and heartbeats.
public enum JobTimestamps: Sendable {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        // Fractional seconds keep FIFO stable when jobs are enqueued in the same wall second.
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let fallbackFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func now(_ date: Date = Date()) -> String {
        formatter.string(from: date)
    }

    public static func parse(_ raw: String) -> Date? {
        formatter.date(from: raw) ?? fallbackFormatter.date(from: raw)
    }
}
