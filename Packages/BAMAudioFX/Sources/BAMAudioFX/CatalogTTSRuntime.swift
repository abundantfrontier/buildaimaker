import Foundation

/// Local Kokoro catalog: many distinct speakers, system TTS fallback if missing.
///
/// Warm sidecar (`catalog_tts.py serve`). Logs on stderr; one JSON object per line
/// on stdout. Never call from the main thread's first layout — `ensureReady` is
/// async and first-run install can take minutes.
public enum CatalogTTSRuntime {
    public static let engineId = "kokoro-catalog-v1"

    public enum Status: Equatable, Sendable {
        case missing
        case installing(String)
        case ready
        case failed(String)
    }

    private static let statusLock = NSLock()
    private static var storedStatus: Status = .missing
    private static var lastErrorMessage: String?
    private static var lastEngineName: String = "unknown"

    /// Probe files + venv only (no process spawn). Safe on any thread.
    public static func isReady(fileManager: FileManager = .default) -> Bool {
        materializeScript(fileManager: fileManager)
        guard fileManager.isExecutableFile(atPath: pythonURL.path) else { return false }
        guard let script = scriptURL, fileManager.fileExists(atPath: script.path) else { return false }
        let model = modelDirectory.appendingPathComponent("kokoro-v1.0.onnx")
        let voices = modelDirectory.appendingPathComponent("voices-v1.0.bin")
        guard let modelSize = (try? fileManager.attributesOfItem(atPath: model.path)[.size] as? NSNumber)?.int64Value,
              modelSize > 1_000_000
        else { return false }
        return fileManager.fileExists(atPath: voices.path)
    }

    /// Why the catalog is or isn't usable — shown in the Voice step.
    public static func readinessNote() -> String {
        let fm = FileManager.default
        materializeScript(fileManager: fm)
        if !fm.isExecutableFile(atPath: pythonURL.path) {
            return "Kokoro venv missing (\(pythonURL.path))"
        }
        if scriptURL == nil {
            return "catalog_tts.py not found (cwd \(fm.currentDirectoryPath))"
        }
        let model = modelDirectory.appendingPathComponent("kokoro-v1.0.onnx")
        let size = (try? fm.attributesOfItem(atPath: model.path)[.size] as? NSNumber)?.int64Value ?? 0
        if size < 1_000_000 {
            return "Kokoro model not downloaded yet"
        }
        if !fm.fileExists(atPath: modelDirectory.appendingPathComponent("voices-v1.0.bin").path) {
            return "Kokoro voices.bin missing"
        }
        if let lastErrorMessage, !lastErrorMessage.isEmpty {
            return "Kokoro ready, last error: \(lastErrorMessage)"
        }
        return "Kokoro ready"
    }

    public static func lastError() -> String? {
        statusLock.lock(); defer { statusLock.unlock() }
        return lastErrorMessage
    }

    public static func lastEngine() -> String {
        statusLock.lock(); defer { statusLock.unlock() }
        return lastEngineName
    }

    public static func recordAttempt(engine: String, error: String?) {
        statusLock.lock()
        lastEngineName = engine
        lastErrorMessage = error
        statusLock.unlock()
        writeDiagnostic(engine: engine, error: error)
    }

    public static var modelDirectory: URL {
        if let raw = ProcessInfo.processInfo.environment["BAM_KOKORO_DIR"], !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return libraryRoot
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("tts", isDirectory: true)
            .appendingPathComponent("kokoro", isDirectory: true)
    }

    public static var envDirectory: URL {
        libraryRoot
            .appendingPathComponent("envs", isDirectory: true)
            .appendingPathComponent("python", isDirectory: true)
            .appendingPathComponent("tts-catalog", isDirectory: true)
    }

    public static var pythonURL: URL {
        if let raw = ProcessInfo.processInfo.environment["BAM_CATALOG_TTS_PYTHON"], !raw.isEmpty {
            return URL(fileURLWithPath: raw)
        }
        return envDirectory.appendingPathComponent("bin/python", isDirectory: false)
    }

    /// Launch venv Python without losing site-packages (Swift `Process` resolves the symlink).
    public static func makePythonProcess(arguments: [String]) -> Process {
        let proc = Process()
        let site = envDirectory
            .appendingPathComponent("lib/python3.13/site-packages", isDirectory: true)
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["ORT_LOG_SEVERITY_LEVEL"] = "3"
        env["BAM_KOKORO_DIR"] = modelDirectory.path
        env["VIRTUAL_ENV"] = envDirectory.path
        let existing = env["PYTHONPATH"] ?? ""
        env["PYTHONPATH"] = existing.isEmpty ? site.path : "\(site.path):\(existing)"
        // Prefer /bin/bash so argv[0] stays the venv launcher.
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        let quotedPy = "'\(pythonURL.path)'"
        let quotedArgs = arguments.map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: " ")
        proc.arguments = ["-lc", "\(quotedPy) \(quotedArgs)"]
        proc.environment = env
        return proc
    }

    public static var installedScriptURL: URL {
        modelDirectory.appendingPathComponent("catalog_tts.py")
    }

    public static var scriptURL: URL? {
        if let raw = ProcessInfo.processInfo.environment["BAM_CATALOG_TTS_SCRIPT"], !raw.isEmpty {
            return URL(fileURLWithPath: raw)
        }
        let installed = installedScriptURL
        if FileManager.default.fileExists(atPath: installed.path) {
            return installed
        }
        return resolveScriptOnDisk()
    }

    public static var libraryRoot: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport.appendingPathComponent("BuildAIMaker", isDirectory: true)
    }

    private struct PreparedSpeech {
        var text: String
        var speed: Double
        var params: CreatureFXParams
    }

    private static func prepareCatalogSpeech(text: String, voiceId: String, speed: Double) -> PreparedSpeech {
        let preset = CreatureVoicePreset.fromCatalogVoiceId(voiceId) ?? .sultry
        let params = CreatureFXParams.fromPreset(preset)
        // Caller already mapped the How-fast slider (catalogActingDeliverySpeed).
        // Do not rebuild speed from a factory preset — that made the slider a no-op.
        let kokoroSpeed = min(1.32, max(0.58, speed))
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !CreatureVoicePreset.looksLikeLoreDump(trimmed) {
            return PreparedSpeech(text: trimmed, speed: kokoroSpeed, params: params)
        }
        let name = CreatureVoicePreset.inferCharacterName(from: trimmed)
        return PreparedSpeech(
            text: preset.spokenPreviewLine(characterName: name),
            speed: kokoroSpeed,
            params: params
        )
    }

    /// Speak with the catalog. Serve first; one-shot if the sidecar fails.
    public static func synthesize(
        text: String,
        voiceId: String,
        speed: Double,
        lang: String
    ) async throws -> SystemSpeechSynthesizer.SpeechAudio {
        materializeScript()
        let prepared = Self.prepareCatalogSpeech(text: text, voiceId: voiceId, speed: speed)
        // One-shot is the proven path. The warm sidecar can fail silently in-app.
        let audio = try await CatalogTTSSession.shared.synthesizeOneShot(
            text: prepared.text,
            voiceId: voiceId,
            speed: prepared.speed,
            lang: lang
        )
        recordAttempt(engine: "kokoro-catalog-v1", error: nil)
        return audio
    }

    /// Best-effort one-time install. Safe to call repeatedly.
    public static func ensureReady() async {
        materializeScript()
        await CatalogTTSInstaller.shared.ensureReady()
    }

    public static func currentStatus() -> Status {
        statusLock.lock()
        let stored = storedStatus
        statusLock.unlock()
        switch stored {
        case .installing, .failed:
            return stored
        case .ready, .missing:
            return isReady() ? .ready : .missing
        }
    }

    static func setStatus(_ status: Status) {
        statusLock.lock()
        storedStatus = status
        statusLock.unlock()
    }

    static func materializeScript(fileManager: FileManager = .default) {
        let dest = installedScriptURL
        if fileManager.fileExists(atPath: dest.path) { return }
        guard let src = resolveScriptOnDisk(), src.standardizedFileURL != dest.standardizedFileURL else { return }
        try? fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.copyItem(at: src, to: dest)
    }

    private static func writeDiagnostic(engine: String, error: String?) {
        let dir = libraryRoot.appendingPathComponent("diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("last-voice.json")
        let payload: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "engine": engine,
            "error": error ?? "",
            "ready": isReady(),
            "readinessNote": readinessNote(),
            "python": pythonURL.path,
            "script": scriptURL?.path ?? "",
            "modelDir": modelDirectory.path,
            "cwd": FileManager.default.currentDirectoryPath,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
        UserDefaults.standard.set(engine, forKey: "bam.lastVoiceEngine")
        UserDefaults.standard.set(error ?? "", forKey: "bam.lastVoiceError")
    }

    private static func resolveScriptOnDisk() -> URL? {
        let fm = FileManager.default
        let seeds = [
            URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent(),
        ]
        for seed in seeds {
            var dir = seed
            for _ in 0..<12 {
                let candidate = dir
                    .appendingPathComponent("Workers/python/catalog_tts.py", isDirectory: false)
                if fm.fileExists(atPath: candidate.path) {
                    return candidate.standardizedFileURL
                }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }
        return nil
    }
}

// MARK: - Warm sidecar

actor CatalogTTSSession {
    static let shared = CatalogTTSSession()

    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var lastError: String?

    func synthesize(
        text: String,
        voiceId: String,
        speed: Double,
        lang: String
    ) async throws -> SystemSpeechSynthesizer.SpeechAudio {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CreatureFXError.emptySpeechText }
        guard CatalogTTSRuntime.isReady() else {
            throw CreatureFXError.catalogUnavailable
        }

        try ensureServer()

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-kokoro-\(UUID().uuidString).wav")
        let req: [String: Any] = [
            "cmd": "speak",
            "text": trimmed,
            "voice": voiceId,
            "speed": speed,
            "lang": lang,
            "out": out.path,
        ]
        let data = try JSONSerialization.data(withJSONObject: req)
        guard var line = String(data: data, encoding: .utf8) else {
            throw CreatureFXError.catalogUnavailable
        }
        line += "\n"
        guard let stdin else { throw CreatureFXError.catalogUnavailable }
        try writeAndRead(line: line, stdin: stdin)
        let reply = try readReply()
        if reply["ok"] as? Bool != true {
            let err = reply["error"] as? String ?? "catalog speak failed"
            lastError = err
            throw CreatureFXError.ttsProducedNoAudio
        }
        let path = reply["path"] as? String ?? out.path
        let url = URL(fileURLWithPath: path)
        defer { try? FileManager.default.removeItem(at: url) }
        return try SystemSpeechSynthesizer.loadAudioFile(url: url)
    }

    func synthesizeOneShot(
        text: String,
        voiceId: String,
        speed: Double,
        lang: String
    ) async throws -> SystemSpeechSynthesizer.SpeechAudio {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CreatureFXError.emptySpeechText }
        guard let script = CatalogTTSRuntime.scriptURL else {
            throw CreatureFXError.catalogUnavailable
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-kokoro-once-\(UUID().uuidString).wav")
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let proc = CatalogTTSRuntime.makePythonProcess(arguments: [
                        "-u", script.path, "speak",
                        "--model-dir", CatalogTTSRuntime.modelDirectory.path,
                        "--text", trimmed,
                        "--voice", voiceId,
                        "--speed", String(speed),
                        "--lang", lang,
                        "--out", out.path,
                    ])
                    proc.standardOutput = FileHandle.nullDevice
                    proc.standardError = FileHandle.nullDevice
                    try proc.run()
                    proc.waitUntilExit()
                    if proc.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) {
                        cont.resume()
                    } else {
                        cont.resume(throwing: CreatureFXError.catalogUnavailable)
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        defer { try? FileManager.default.removeItem(at: out) }
        return try SystemSpeechSynthesizer.loadAudioFile(url: out)
    }

    private func ensureServer() throws {
        if let process, process.isRunning { return }
        teardown()
        guard let script = CatalogTTSRuntime.scriptURL else {
            throw CreatureFXError.catalogUnavailable
        }
        let proc = CatalogTTSRuntime.makePythonProcess(arguments: [
            "-u", script.path, "serve", "--model-dir", CatalogTTSRuntime.modelDirectory.path,
        ])

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        process = proc
        stdin = inPipe.fileHandleForWriting
        stdout = outPipe.fileHandleForReading
        // Drain stderr so the pipe cannot fill and stall.
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        let hello = try readReply()
        if hello["ok"] as? Bool != true {
            teardown()
            throw CreatureFXError.catalogUnavailable
        }
    }

    private func writeAndRead(line: String, stdin: FileHandle) throws {
        guard let data = line.data(using: .utf8) else {
            throw CreatureFXError.catalogUnavailable
        }
        try stdin.write(contentsOf: data)
    }

    private func readReply() throws -> [String: Any] {
        guard let stdout else { throw CreatureFXError.catalogUnavailable }
        var buffer = Data()
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if let process, !process.isRunning {
                throw CreatureFXError.catalogUnavailable
            }
            let chunk = stdout.availableData
            if !chunk.isEmpty {
                buffer.append(chunk)
                if let s = String(data: buffer, encoding: .utf8),
                   let nl = s.firstIndex(of: "\n") {
                    let line = String(s[..<nl])
                    if let data = line.data(using: .utf8),
                       let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        return obj
                    }
                    throw CreatureFXError.catalogUnavailable
                }
            } else {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        throw CreatureFXError.catalogUnavailable
    }

    private func teardown() {
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        stdin = nil
        stdout = nil
    }
}

// MARK: - Installer

actor CatalogTTSInstaller {
    static let shared = CatalogTTSInstaller()

    private var installTask: Task<Void, Never>?

    func ensureReady() async {
        if CatalogTTSRuntime.isReady() {
            CatalogTTSRuntime.setStatus(.ready)
            return
        }
        if let installTask {
            await installTask.value
            return
        }
        let task = Task { await self.runInstall() }
        installTask = task
        await task.value
        installTask = nil
    }

    private func runInstall() async {
        if CatalogTTSRuntime.isReady() {
            CatalogTTSRuntime.setStatus(.ready)
            return
        }
        CatalogTTSRuntime.setStatus(.installing("Creating character-voice runtime…"))
        let env = CatalogTTSRuntime.envDirectory
        let models = CatalogTTSRuntime.modelDirectory
        let py = URL(fileURLWithPath: "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3")
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: env.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createDirectory(at: models, withIntermediateDirectories: true)
            if !fm.isExecutableFile(atPath: env.appendingPathComponent("bin/python").path) {
                try await run(executable: py, arguments: ["-m", "venv", env.path])
            }
            let pipPython = env.appendingPathComponent("bin/python")
            CatalogTTSRuntime.setStatus(.installing("Installing Kokoro…"))
            try await run(
                executable: pipPython,
                arguments: ["-m", "pip", "install", "-U", "pip"]
            )
            try await run(
                executable: pipPython,
                arguments: ["-m", "pip", "install", "-U", "kokoro-onnx", "soundfile"]
            )
            CatalogTTSRuntime.setStatus(.installing("Downloading speakers (~350 MB, once)…"))
            try await download(
                url: URL(string: "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx")!,
                to: models.appendingPathComponent("kokoro-v1.0.onnx")
            )
            try await download(
                url: URL(string: "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin")!,
                to: models.appendingPathComponent("voices-v1.0.bin")
            )
            if CatalogTTSRuntime.isReady() {
                CatalogTTSRuntime.setStatus(.ready)
            } else {
                CatalogTTSRuntime.setStatus(.failed("Catalog files installed but not usable."))
            }
        } catch {
            CatalogTTSRuntime.setStatus(.failed(error.localizedDescription))
        }
    }

    private func run(executable: URL, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let proc = Process()
                    proc.executableURL = executable
                    proc.arguments = arguments
                    proc.standardOutput = FileHandle.nullDevice
                    proc.standardError = FileHandle.nullDevice
                    try proc.run()
                    proc.waitUntilExit()
                    if proc.terminationStatus == 0 {
                        cont.resume()
                    } else {
                        cont.resume(throwing: CreatureFXError.catalogUnavailable)
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func download(url: URL, to dest: URL) async throws {
        if FileManager.default.fileExists(atPath: dest.path) {
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? 0
            if size > 100_000 { return }
        }
        let (tmp, _) = try await URLSession.shared.download(from: url)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: tmp, to: dest)
    }
}


