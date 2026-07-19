import Foundation

/// One timed stage inside a playground turn (design: BAMInference diagnostics).
public struct PlaygroundTraceStage: Sendable, Equatable, Codable {
    public var name: String
    public var startedAt: Date
    public var endedAt: Date?
    public var durationMs: Double?
    public var metadata: [String: String]

    public init(
        name: String,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        durationMs: Double? = nil,
        metadata: [String: String] = [:]
    ) {
        self.name = name
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationMs = durationMs
        self.metadata = metadata
    }
}

/// Job-less playground diagnostics payload written to `playground_trace.json`.
public struct PlaygroundTraceDocument: Sendable, Equatable, Codable {
    public var v: Int
    public var sessionId: String
    public var recordedAt: Date
    public var stages: [PlaygroundTraceStage]
    public var backendId: String?
    public var latencyMs: Double?
    public var isStub: Bool?
    public var baseModelPath: String?
    public var adapterPath: String?
    public var adapterEnabled: Bool?

    public init(
        v: Int = 1,
        sessionId: String = UUID().uuidString,
        recordedAt: Date = Date(),
        stages: [PlaygroundTraceStage] = [],
        backendId: String? = nil,
        latencyMs: Double? = nil,
        isStub: Bool? = nil,
        baseModelPath: String? = nil,
        adapterPath: String? = nil,
        adapterEnabled: Bool? = nil
    ) {
        self.v = v
        self.sessionId = sessionId
        self.recordedAt = recordedAt
        self.stages = stages
        self.backendId = backendId
        self.latencyMs = latencyMs
        self.isStub = isStub
        self.baseModelPath = baseModelPath
        self.adapterPath = adapterPath
        self.adapterEnabled = adapterEnabled
    }
}

/// Optional recorder for playground stage timestamps.
///
/// When `enabled` is false, all methods are no-ops (zero I/O). When enabled,
/// the latest turn is written atomically to `playground_trace.json` under the
/// configured diagnostics directory (default: library root `diagnostics/`).
public struct PlaygroundTraceRecorder: Sendable {
    public static let fileName = "playground_trace.json"
    public static let diagnosticsDirectoryName = "diagnostics"

    public var enabled: Bool
    public var outputDirectory: URL
    public var fileManager: FileManager

    public init(
        enabled: Bool = false,
        outputDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.enabled = enabled
        self.outputDirectory = outputDirectory
        self.fileManager = fileManager
    }

    /// Convenience: `libraryRoot/diagnostics/`, enabled by default when `enabled` is true.
    public static func underLibraryRoot(
        _ libraryRoot: URL,
        enabled: Bool = true,
        fileManager: FileManager = .default
    ) -> PlaygroundTraceRecorder {
        let dir = libraryRoot.appendingPathComponent(diagnosticsDirectoryName, isDirectory: true)
        return PlaygroundTraceRecorder(
            enabled: enabled,
            outputDirectory: dir,
            fileManager: fileManager
        )
    }

    public var traceFileURL: URL {
        outputDirectory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    /// Environment / UserDefaults helpers for the app shell.
    public static let defaultsEnabledKey = "bam.playgroundTrace.enabled"

    /// Reads enablement: env `BAM_PLAYGROUND_TRACE=0` forces off; `=1` forces on;
    /// otherwise uses UserDefaults (default **true** for dogfood when key absent).
    public static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> Bool {
        if let env = environment["BAM_PLAYGROUND_TRACE"] {
            let v = env.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if v == "0" || v == "false" || v == "off" { return false }
            if v == "1" || v == "true" || v == "on" { return true }
        }
        if defaults.object(forKey: defaultsEnabledKey) == nil {
            return true
        }
        return defaults.bool(forKey: defaultsEnabledKey)
    }

    /// Record a single playground turn with stage timestamps and write JSON.
    @discardableResult
    public func recordTurn(
        stages: [PlaygroundTraceStage],
        backendId: String? = nil,
        latencyMs: Double? = nil,
        isStub: Bool? = nil,
        baseModelPath: String? = nil,
        adapterPath: String? = nil,
        adapterEnabled: Bool? = nil,
        sessionId: String = UUID().uuidString
    ) throws -> URL? {
        guard enabled else { return nil }

        let doc = PlaygroundTraceDocument(
            sessionId: sessionId,
            recordedAt: Date(),
            stages: stages,
            backendId: backendId,
            latencyMs: latencyMs,
            isStub: isStub,
            baseModelPath: baseModelPath,
            adapterPath: adapterPath,
            adapterEnabled: adapterEnabled
        )
        return try write(doc)
    }

    /// Build stages for a simple complete-turn: format → complete → append.
    public static func stagesForCompletion(
        formatStarted: Date,
        completeStarted: Date,
        completeEnded: Date,
        totalEnded: Date
    ) -> [PlaygroundTraceStage] {
        let formatMs = completeStarted.timeIntervalSince(formatStarted) * 1000
        let completeMs = completeEnded.timeIntervalSince(completeStarted) * 1000
        let totalMs = totalEnded.timeIntervalSince(formatStarted) * 1000
        return [
            PlaygroundTraceStage(
                name: "format",
                startedAt: formatStarted,
                endedAt: completeStarted,
                durationMs: formatMs
            ),
            PlaygroundTraceStage(
                name: "complete",
                startedAt: completeStarted,
                endedAt: completeEnded,
                durationMs: completeMs
            ),
            PlaygroundTraceStage(
                name: "turn",
                startedAt: formatStarted,
                endedAt: totalEnded,
                durationMs: totalMs
            ),
        ]
    }

    @discardableResult
    public func write(_ document: PlaygroundTraceDocument) throws -> URL {
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        let url = traceFileURL
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Read the last written trace, if any.
    public func read() throws -> PlaygroundTraceDocument? {
        let url = traceFileURL
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PlaygroundTraceDocument.self, from: data)
    }
}
