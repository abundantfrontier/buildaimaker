import CryptoKit
import Foundation

/// L2 integrity: verify `runtime-pins.json` against on-disk lockfile + entry modules
/// and (when present) that the interpreter path stays under the managed env root.
///
/// Fail closed with `BAMErrorCode.runtimeIntegrity` (`BAM_RUNTIME_INTEGRITY`).
public enum RuntimeIntegrity: Sendable {
    public struct VerificationOptions: Sendable {
        /// When true, require the managed interpreter file to exist.
        public var requireInterpreterPresent: Bool
        /// Managed env root used for interpreter path allowlisting.
        public var managedEnvRoot: URL?

        public init(
            requireInterpreterPresent: Bool = false,
            managedEnvRoot: URL? = nil
        ) {
            self.requireInterpreterPresent = requireInterpreterPresent
            self.managedEnvRoot = managedEnvRoot
        }

        public static let pinsOnly = VerificationOptions(
            requireInterpreterPresent: false,
            managedEnvRoot: nil
        )
    }

    /// SHA-256 lowercase hex of raw bytes.
    public static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 lowercase hex of a file's contents.
    public static func sha256Hex(ofFile url: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw BAMError(
                code: .runtimeIntegrity,
                message: "unable to read file for hashing: \(url.path)"
            )
        }
        return sha256Hex(of: data)
    }

    /// Normalize hash strings: strip optional `sha256:` prefix, lowercase.
    public static func normalizeHash(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("sha256:") {
            s = String(s.dropFirst("sha256:".count))
        }
        return s
    }

    /// Verify pins against files under `pinsRoot`. Throws `BAMError` with
    /// `.runtimeIntegrity` on any mismatch or path escape.
    public static func verify(
        pins: RuntimePins,
        pinsRoot: URL,
        options: VerificationOptions = .pinsOnly,
        fileManager: FileManager = .default
    ) throws {
        let root = pinsRoot.standardizedFileURL

        // 1) Lockfile hash
        let lockURL = try resolvedFile(relativePath: pins.lockfile.relativePath, under: root)
        let lockHash = try sha256Hex(ofFile: lockURL)
        let expectedLock = normalizeHash(pins.lockfile.sha256)
        guard lockHash == expectedLock else {
            throw BAMError(
                code: .runtimeIntegrity,
                message: "lockfile hash mismatch for \(pins.lockfile.relativePath) (expected \(expectedLock), got \(lockHash))"
            )
        }

        // 2) Entry module hashes
        for entry in pins.entries {
            let entryURL = try resolvedFile(relativePath: entry.relativePath, under: root)
            let actual = try sha256Hex(ofFile: entryURL)
            let expected = normalizeHash(entry.sha256)
            guard actual == expected else {
                throw BAMError(
                    code: .runtimeIntegrity,
                    message: "entry hash mismatch for \(entry.id) (\(entry.relativePath)) (expected \(expected), got \(actual))"
                )
            }
        }

        // 3) Interpreter under managed env (path allowlist; optional existence)
        if let envRoot = options.managedEnvRoot {
            try verifyInterpreterPath(
                relativePath: pins.interpreterRelativePath,
                managedEnvRoot: envRoot,
                requirePresent: options.requireInterpreterPresent,
                fileManager: fileManager
            )
        } else if options.requireInterpreterPresent {
            throw BAMError(
                code: .runtimeIntegrity,
                message: "managed env root required when interpreter presence is required"
            )
        }
    }

    /// Load pins from `pinsRoot/runtime-pins.json` and verify.
    @discardableResult
    public static func verifyPinsRoot(
        _ pinsRoot: URL,
        options: VerificationOptions = .pinsOnly,
        fileManager: FileManager = .default
    ) throws -> RuntimePins {
        let pinsURL = RuntimePaths.pinsFile(in: pinsRoot)
        let pins: RuntimePins
        do {
            pins = try RuntimePins.load(from: pinsURL)
        } catch let error as BAMError {
            throw error
        } catch {
            throw BAMError(
                code: .runtimeIntegrity,
                message: "failed to load runtime-pins.json at \(pinsURL.path)"
            )
        }
        try verify(pins: pins, pinsRoot: pinsRoot, options: options, fileManager: fileManager)
        return pins
    }

    // MARK: - Path helpers

    /// Resolve `relativePath` under `root`, rejecting `..` / absolute escapes.
    public static func resolvedFile(relativePath: String, under root: URL) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BAMError(code: .runtimeIntegrity, message: "empty relative path in pins")
        }
        guard !trimmed.hasPrefix("/"), !trimmed.contains("\0") else {
            throw BAMError(
                code: .runtimeIntegrity,
                message: "absolute or invalid path in pins: \(trimmed)"
            )
        }

        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty else {
            throw BAMError(code: .runtimeIntegrity, message: "empty relative path in pins")
        }
        for part in components {
            if part.isEmpty || part == ".." {
                throw BAMError(
                    code: .runtimeIntegrity,
                    message: "path escape in pins: \(trimmed)"
                )
            }
        }

        var url = root.standardizedFileURL
        for part in components where part != "." {
            url = url.appendingPathComponent(part, isDirectory: false)
        }
        let standardized = url.standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        let filePath = standardized.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) || filePath == rootPath else {
            throw BAMError(
                code: .runtimeIntegrity,
                message: "resolved path escaped pins root: \(trimmed)"
            )
        }
        return standardized
    }

    public static func verifyInterpreterPath(
        relativePath: String,
        managedEnvRoot: URL,
        requirePresent: Bool,
        fileManager: FileManager = .default
    ) throws {
        let envRoot = managedEnvRoot.standardizedFileURL
        let interpreter = try resolvedFile(relativePath: relativePath, under: envRoot)

        if requirePresent {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: interpreter.path, isDirectory: &isDir),
                  !isDir.boolValue
            else {
                throw BAMError(
                    code: .runtimeIntegrity,
                    message: "managed interpreter missing: \(interpreter.path)"
                )
            }
        }
    }
}
