import BAMCore
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Status of Apple’s on-device Foundation Model (system Language Model).
public enum AppleFoundationModelStatus: String, Sendable, Equatable, Codable {
    /// Framework present and `SystemLanguageModel` reports available.
    case available
    /// Framework present but model not ready (waitlist, download, AI off, region, …).
    case unavailable
    /// OS/SDK has no FoundationModels framework (CI / older macOS).
    case unsupported
    /// Probed too early / unknown shape on a beta.
    case unknown

    public var isUsable: Bool { self == .available }

    public var title: String {
        switch self {
        case .available: return "Apple on-device model ready"
        case .unavailable: return "Apple on-device model not ready"
        case .unsupported: return "Apple Foundation Models not on this OS"
        case .unknown: return "Apple model status unknown"
        }
    }

    public var detail: String {
        switch self {
        case .available:
            return "SystemLanguageModel is available. Playground can use it by default (no HF download)."
        case .unavailable:
            return "Enable Apple Intelligence & finish any model download. Siri AI (Beta) waitlist is separate from Writing Tools / FM API."
        case .unsupported:
            return "Needs a recent macOS with the FoundationModels framework (Apple Intelligence era)."
        case .unknown:
            return "Could not determine status on this beta."
        }
    }
}

/// Probe + optional generate via Apple Foundation Models (system on-device LLM).
///
/// Distinct from open MLX weights under `models/base`. Does not install Apple’s
/// model — the OS does when Apple Intelligence is enabled.
public enum AppleFoundationModelSupport: Sendable {
    public static let backendId = "apple-foundation"

    /// Whether this process can import the framework (compile-time + runtime).
    public static var frameworkPresent: Bool {
        #if canImport(FoundationModels)
        true
        #else
        false
        #endif
    }

    /// Best-effort availability probe (main-thread safe; cheap).
    public static func probeStatus() -> AppleFoundationModelStatus {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                return .available
            case .unavailable:
                return .unavailable
            @unknown default:
                return .unknown
            }
        }
        return .unsupported
        #else
        return .unsupported
        #endif
    }

    /// Human-readable reason when unavailable (beta-dependent).
    public static func unavailableReasonDescription() -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            if case .unavailable(let reason) = model.availability {
                return String(describing: reason)
            }
        }
        #endif
        return nil
    }
}

/// LLM backend that calls Apple’s on-device `SystemLanguageModel` via FoundationModels.
public struct AppleFoundationLLMBackend: LLMBackend, Sendable {
    public static let id = AppleFoundationModelSupport.backendId

    public var backendId: String { Self.id }

    public init() {}

    public static func makeIfAvailable() -> AppleFoundationLLMBackend? {
        AppleFoundationModelSupport.probeStatus() == .available
            ? AppleFoundationLLMBackend()
            : nil
    }

    public func complete(_ request: LLMCompletionRequest) async throws -> LLMCompletionResult {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let status = AppleFoundationModelSupport.probeStatus()
            guard status == .available else {
                throw BAMError(
                    code: .capabilityUnsupported,
                    message: "Apple Foundation Model not available (\(status.rawValue)). Enable Apple Intelligence / finish model download."
                )
            }

            let start = Date()
            let prompt = Self.formatPrompt(messages: request.messages)
            let adapterPath = request.effectiveAdapterPath
            let (session, detail, isStubAdapter) = try await Self.makeSession(adapterPath: adapterPath)
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw BAMError(
                    code: .capabilityUnsupported,
                    message: "Apple Foundation Model returned empty text."
                )
            }
            let elapsed = Date().timeIntervalSince(start) * 1000
            return LLMCompletionResult(
                assistantMessage: .assistant(text),
                backendId: backendId,
                latencyMs: elapsed,
                isStub: isStubAdapter,
                detail: detail
            )
        }
        #endif
        throw BAMError(
            code: .capabilityUnsupported,
            message: "Apple Foundation Models framework not available in this build/OS."
        )
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func makeSession(
        adapterPath: String?
    ) async throws -> (LanguageModelSession, String, Bool) {
        let base = SystemLanguageModel.default

        guard let adapterPath, !adapterPath.isEmpty else {
            return (LanguageModelSession(model: base), "SystemLanguageModel.default", false)
        }

        let packageURL = resolvePackageURL(from: adapterPath)
        let signatureNote = Self.signatureNote(forPackage: packageURL)

        // Stub packages from FoundationAdapterService.publishStub are not loadable.
        if isStubPackage(at: packageURL) {
            let detail = "SystemLanguageModel.default + stub adapter (not applied): \(packageURL.lastPathComponent)"
                + (signatureNote.map { " · \($0)" } ?? "")
            return (LanguageModelSession(model: base), detail, true)
        }

        do {
            let specialized = try await loadAdapterModel(packageURL: packageURL)
            let detail = "SystemLanguageModel + adapter \(packageURL.lastPathComponent)"
                + (signatureNote.map { " · \($0)" } ?? "")
            return (LanguageModelSession(model: specialized), detail, false)
        } catch {
            let sigHint = signatureNote.map { " \($0)" } ?? ""
            throw BAMError(
                code: .capabilityUnsupported,
                message: """
                Could not load Foundation adapter at \(packageURL.path): \(error.localizedDescription).\
                \(sigHint) \
                Ensure the package matches this OS system model revision, \
                or train/export via Apple’s Adapter Training Toolkit and re-import.
                """
            )
        }
    }

    /// Soft signature check against foundation_adapter.json next to the package.
    private static func signatureNote(forPackage packageURL: URL) -> String? {
        let meta = packageURL.deletingLastPathComponent()
            .appendingPathComponent("foundation_adapter.json")
        guard let data = try? Data(contentsOf: meta),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stored = obj["baseModelSignature"] as? String,
              !stored.isEmpty
        else { return nil }
        let current = Self.hostSignature()
        let storedKey = Self.compatKey(stored)
        let currentKey = Self.compatKey(current)
        if storedKey == currentKey { return "signature ok (\(stored))" }
        return "SIGNATURE MISMATCH: adapter=\(stored) host=\(current) — retrain recommended"
    }

    private static func hostSignature() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return String(format: "macos-%d.%d.%d", v.majorVersion, v.minorVersion, v.patchVersion)
    }

    private static func compatKey(_ signature: String) -> String {
        let parts = signature.split(separator: ".")
        if parts.count >= 2 { return parts.prefix(2).joined(separator: ".") }
        return signature
    }

    @available(macOS 26.0, *)
    private static func loadAdapterModel(packageURL: URL) async throws -> SystemLanguageModel {
        // Foundation Models: Adapter(fileURL:) → optional compile → SystemLanguageModel(adapter:).
        let adapter = try SystemLanguageModel.Adapter(fileURL: packageURL)
        do {
            try await adapter.compile()
        } catch {
            // Already compiled or compile not required — continue.
        }
        return SystemLanguageModel(adapter: adapter)
    }

    private static func resolvePackageURL(from adapterPath: String) -> URL {
        let url = URL(fileURLWithPath: adapterPath)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            let preferred = url.appendingPathComponent("adapter.fmadapter")
            if FileManager.default.fileExists(atPath: preferred.path) {
                return preferred
            }
            if let found = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil
            ).first(where: { $0.pathExtension.lowercased() == "fmadapter" }) {
                return found
            }
        }
        return url
    }

    private static func isStubPackage(at url: URL) -> Bool {
        // Directory metadata or package file body.
        let meta = url.deletingLastPathComponent().appendingPathComponent("foundation_adapter.json")
        if let data = try? Data(contentsOf: meta),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let fake = obj["fake"] as? Bool,
           fake
        {
            return true
        }
        if let body = try? String(contentsOf: url, encoding: .utf8),
           body.contains("BAM_FOUNDATION_ADAPTER_STUB")
        {
            return true
        }
        return false
    }
    #endif

    /// Flatten chat messages into a single prompt the system model can handle.
    static func formatPrompt(messages: [InferenceChatMessage]) -> String {
        var systemBits: [String] = []
        var turns: [String] = []
        for m in messages {
            let content = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            switch m.role.lowercased() {
            case "system":
                systemBits.append(content)
            case "user":
                turns.append("User: \(content)")
            case "assistant":
                turns.append("Assistant: \(content)")
            default:
                turns.append("\(m.role): \(content)")
            }
        }
        var parts: [String] = []
        if !systemBits.isEmpty {
            parts.append("Instructions:\n" + systemBits.joined(separator: "\n"))
        }
        if !turns.isEmpty {
            parts.append(turns.joined(separator: "\n"))
        }
        parts.append("Assistant:")
        return parts.joined(separator: "\n\n")
    }
}
