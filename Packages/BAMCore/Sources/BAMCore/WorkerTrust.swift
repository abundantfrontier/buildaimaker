import Foundation
import Security

/// L1 process-entry trust: only launch TeamID-signed `Helpers/bam-*-worker`.
///
/// Debug policy (explicit):
/// - Matching TeamID → allow
/// - Helper without TeamID (ad-hoc / unsigned local `swift build`) → allow
/// - Helper with a **foreign** TeamID → reject unless `BAM_ALLOW_FOREIGN_HELPER_TEAMID=1`
///
/// Never TeamID-check venv/CPython.
public enum WorkerTrust: Sendable {
    public enum Mode: Sendable, Equatable {
        /// Production: valid code signature + helper TeamID must match the running app TeamID.
        case release
        /// Debug: unsigned/ad-hoc helpers OK; foreign TeamID rejected (see type docs).
        case debug
    }

    /// Environment opt-in to allow a foreign-TeamID helper while debugging.
    public static let allowForeignHelperTeamIDEnvKey = "BAM_ALLOW_FOREIGN_HELPER_TEAMID"

    /// Result of inspecting a helper binary's code signature.
    public struct CodeIdentity: Sendable, Equatable {
        public var teamID: String?
        public var signingID: String?
        /// Whether `SecStaticCodeCheckValidity` succeeded for this binary.
        public var signatureValid: Bool

        public init(teamID: String?, signingID: String?, signatureValid: Bool) {
            self.teamID = teamID
            self.signingID = signingID
            self.signatureValid = signatureValid
        }

        /// True when a non-empty TeamID is present on the signature info.
        public var hasTeamID: Bool {
            guard let teamID, !teamID.isEmpty else { return false }
            return true
        }
    }

    /// Default policy: debug in `#if DEBUG`, else release.
    public static var defaultMode: Mode {
        #if DEBUG
        return .debug
        #else
        return .release
        #endif
    }

    // MARK: - Helper identity / path policy

    /// Basename must be `bam-*-worker` (e.g. `bam-llm-worker`).
    /// Rejects path separators / null bytes so `../bam-llm-worker` cannot sneak through.
    public static func isAllowedHelperBasename(_ name: String) -> Bool {
        guard !name.isEmpty,
              !name.contains("/"),
              !name.contains("\\"),
              !name.contains("\0")
        else { return false }
        // Require a non-empty middle segment: bam-<id>-worker
        guard name.hasPrefix("bam-"), name.hasSuffix("-worker") else { return false }
        let middle = name.dropFirst(4).dropLast(7) // strip "bam-" and "-worker"
        return !middle.isEmpty && !middle.contains("/")
    }

    /// `Contents/Helpers` under an app bundle URL.
    public static func helpersDirectory(inBundle bundleURL: URL) -> URL {
        bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
    }

    /// Resolve `Contents/Helpers/<name>` and jail it under the Helpers directory.
    public static func helperURL(named name: String, inBundle bundleURL: URL) throws -> URL {
        guard isAllowedHelperBasename(name) else {
            throw BAMError(
                code: .runtimeIntegrity,
                message: "helper name not allowed: \(name) (expected bam-*-worker)"
            )
        }
        let helpers = helpersDirectory(inBundle: bundleURL)
        let url = helpers.appendingPathComponent(name, isDirectory: false)
        try RuntimeIntegrity.assertPathUnderRoot(url, root: helpers, relativePath: name)
        return url
    }

    /// Whether `helperURL` is under `bundleURL/Contents/Helpers` after symlink resolution.
    public static func isUnderHelpersDirectory(helperURL: URL, bundleURL: URL) -> Bool {
        let helpers = helpersDirectory(inBundle: bundleURL)
        let rootReal = helpers.resolvingSymlinksInPath().standardizedFileURL
        let pathReal = helperURL.resolvingSymlinksInPath().standardizedFileURL
        return RuntimeIntegrity.isPath(pathReal, under: rootReal)
    }

    // MARK: - Launch verification

    /// Whether the UI/supervisor may spawn `helperURL`.
    ///
    /// - Parameters:
    ///   - helperURL: Path to the helper binary.
    ///   - mode: Release vs debug policy.
    ///   - expectedBundleURL: When set, helper must live under `Contents/Helpers` of this bundle.
    ///   - requireHelpersDirectory: When true (default if `expectedBundleURL` set), enforce Helpers jail.
    ///   - environment: Used for foreign-TeamID opt-in in debug.
    public static func verifyHelperLaunch(
        helperURL: URL,
        mode: Mode = defaultMode,
        expectedBundleURL: URL? = nil,
        requireHelpersDirectory: Bool? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws {
        let basename = helperURL.lastPathComponent
        guard isAllowedHelperBasename(basename) else {
            throw BAMError(
                code: .runtimeIntegrity,
                message: "helper name not allowed: \(basename) (expected bam-*-worker)"
            )
        }

        let enforceHelpers = requireHelpersDirectory ?? (expectedBundleURL != nil)
        if enforceHelpers {
            guard let bundleURL = expectedBundleURL else {
                throw BAMError(
                    code: .runtimeIntegrity,
                    message: "bundle URL required to enforce Contents/Helpers jail"
                )
            }
            guard isUnderHelpersDirectory(helperURL: helperURL, bundleURL: bundleURL) else {
                throw BAMError(
                    code: .runtimeIntegrity,
                    message: "helper not under Contents/Helpers: \(helperURL.path)"
                )
            }
        }

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: helperURL.path, isDirectory: &isDir),
              !isDir.boolValue
        else {
            throw BAMError(
                code: .runtimeIntegrity,
                message: "helper binary missing: \(helperURL.path)"
            )
        }

        let helperIdentity = try codeIdentity(of: helperURL, mode: mode)
        let selfIdentity = try codeIdentityOfCurrentProcess(mode: mode)

        switch mode {
        case .release:
            guard helperIdentity.signatureValid else {
                throw BAMError(
                    code: .runtimeIntegrity,
                    message: "helper has invalid or missing code signature (release policy)"
                )
            }
            guard let helperTeam = nonEmptyTeam(helperIdentity.teamID) else {
                throw BAMError(
                    code: .runtimeIntegrity,
                    message: "helper missing TeamID (release policy)"
                )
            }
            guard let selfTeam = nonEmptyTeam(selfIdentity.teamID) else {
                throw BAMError(
                    code: .runtimeIntegrity,
                    message: "app process missing TeamID (release policy)"
                )
            }
            guard helperTeam == selfTeam else {
                throw BAMError(
                    code: .runtimeIntegrity,
                    message: "helper TeamID \(helperTeam) does not match app TeamID \(selfTeam)"
                )
            }
        case .debug:
            try applyDebugPolicy(
                helper: helperIdentity,
                selfIdentity: selfIdentity,
                environment: environment
            )
        }
    }

    // MARK: - SecCode helpers

    /// Inspect a helper binary. In `.release`, creation or validity failure throws.
    /// In `.debug`, unsigned / invalid local products become identities with
    /// `signatureValid == false` and no TeamID.
    public static func codeIdentity(of fileURL: URL, mode: Mode = defaultMode) throws -> CodeIdentity {
        var staticCode: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(fileURL as CFURL, [], &staticCode)
        guard status == errSecSuccess, let staticCode else {
            if mode == .release {
                throw BAMError(
                    code: .runtimeIntegrity,
                    message: "helper has invalid or missing code signature (cannot create SecStaticCode)"
                )
            }
            // Unsigned / unreadable local binary — debug only.
            return CodeIdentity(teamID: nil, signingID: nil, signatureValid: false)
        }

        let validity = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSBasicValidateOnly),
            nil
        )
        let signatureValid = (validity == errSecSuccess)
        if !signatureValid, mode == .release {
            throw BAMError(
                code: .runtimeIntegrity,
                message: "helper has invalid or missing code signature (SecStaticCodeCheckValidity failed)"
            )
        }

        return identity(from: staticCode, signatureValid: signatureValid)
    }

    public static func codeIdentityOfCurrentProcess(mode: Mode = defaultMode) throws -> CodeIdentity {
        var code: SecCode?
        let status = SecCodeCopySelf([], &code)
        guard status == errSecSuccess, let code else {
            return CodeIdentity(teamID: nil, signingID: nil, signatureValid: false)
        }
        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(code, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            return CodeIdentity(teamID: nil, signingID: nil, signatureValid: false)
        }

        let validity = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSBasicValidateOnly),
            nil
        )
        // Process self: do not throw on invalid in debug; release callers still
        // require a TeamID on self when verifying helpers.
        _ = mode
        return identity(from: staticCode, signatureValid: validity == errSecSuccess)
    }

    // MARK: - Private

    private static func applyDebugPolicy(
        helper: CodeIdentity,
        selfIdentity: CodeIdentity,
        environment: [String: String]
    ) throws {
        let allowForeign = environment[allowForeignHelperTeamIDEnvKey] == "1"

        if let helperTeam = nonEmptyTeam(helper.teamID) {
            if let selfTeam = nonEmptyTeam(selfIdentity.teamID), helperTeam == selfTeam {
                return
            }
            // Foreign TeamID (or signed helper while app is unsigned).
            if allowForeign { return }
            throw BAMError(
                code: .runtimeIntegrity,
                message: "helper TeamID \(helperTeam) is foreign in debug mode (set \(allowForeignHelperTeamIDEnvKey)=1 to override)"
            )
        }

        // Helper has no TeamID → ad-hoc / unsigned; allowed in debug for local swift build.
        return
    }

    private static func identity(from staticCode: SecStaticCode, signatureValid: Bool) -> CodeIdentity {
        var infoCF: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &infoCF
        )
        guard infoStatus == errSecSuccess, let info = infoCF as? [String: Any] else {
            return CodeIdentity(teamID: nil, signingID: nil, signatureValid: signatureValid)
        }

        let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
        let signingID = info[kSecCodeInfoIdentifier as String] as? String
        return CodeIdentity(teamID: teamID, signingID: signingID, signatureValid: signatureValid)
    }

    private static func nonEmptyTeam(_ team: String?) -> String? {
        guard let team, !team.isEmpty else { return nil }
        return team
    }
}
