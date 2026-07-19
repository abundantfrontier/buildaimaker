import Foundation
import Security

/// L1 process-entry trust: only launch TeamID-signed `Helpers/bam-*-worker`.
///
/// In debug / development, ad-hoc or development-signed helpers matching the
/// current process signing identity are allowed. Never TeamID-check venv/CPython.
public enum WorkerTrust: Sendable {
    public enum Mode: Sendable, Equatable {
        /// Production: helper TeamID must match the running app TeamID.
        case release
        /// Debug: allow ad-hoc / development signatures when TeamID matches or both unsigned-dev.
        case debug
    }

    /// Result of inspecting a helper binary's code signature.
    public struct CodeIdentity: Sendable, Equatable {
        public var teamID: String?
        public var signingID: String?
        public var isAdHoc: Bool

        public init(teamID: String?, signingID: String?, isAdHoc: Bool) {
            self.teamID = teamID
            self.signingID = signingID
            self.isAdHoc = isAdHoc
        }
    }

    /// Whether the UI/supervisor may spawn `helperURL`.
    ///
    /// Fail closed with `BAM_RUNTIME_INTEGRITY` when the helper is missing or
    /// signature policy is violated.
    public static func verifyHelperLaunch(
        helperURL: URL,
        mode: Mode = defaultMode,
        fileManager: FileManager = .default
    ) throws {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: helperURL.path, isDirectory: &isDir),
              !isDir.boolValue
        else {
            throw BAMError(
                code: .runtimeIntegrity,
                message: "helper binary missing: \(helperURL.path)"
            )
        }

        let helperIdentity = try codeIdentity(of: helperURL)
        let selfIdentity = try codeIdentityOfCurrentProcess()

        switch mode {
        case .release:
            guard let helperTeam = helperIdentity.teamID, !helperTeam.isEmpty else {
                throw BAMError(
                    code: .runtimeIntegrity,
                    message: "helper missing TeamID (release policy)"
                )
            }
            guard let selfTeam = selfIdentity.teamID, !selfTeam.isEmpty else {
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
            // Allow: matching TeamID, or both ad-hoc / unsigned-dev (local swift run).
            if let helperTeam = helperIdentity.teamID, let selfTeam = selfIdentity.teamID,
               !helperTeam.isEmpty, !selfTeam.isEmpty
            {
                guard helperTeam == selfTeam else {
                    throw BAMError(
                        code: .runtimeIntegrity,
                        message: "helper TeamID \(helperTeam) does not match app TeamID \(selfTeam)"
                    )
                }
                return
            }
            // Dev-signed / ad-hoc path: accept if helper is ad-hoc or self is ad-hoc/dev.
            if helperIdentity.isAdHoc || selfIdentity.isAdHoc
                || helperIdentity.teamID == nil || selfIdentity.teamID == nil
            {
                return
            }
            throw BAMError(
                code: .runtimeIntegrity,
                message: "helper signature not acceptable in debug mode"
            )
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

    // MARK: - SecCode helpers

    public static func codeIdentity(of fileURL: URL) throws -> CodeIdentity {
        var staticCode: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(fileURL as CFURL, [], &staticCode)
        guard status == errSecSuccess, let staticCode else {
            // Unreadable / unsigned binary — treat as ad-hoc for debug policy decisions.
            if status == errSecCSUnsigned || status == CSSMERR_TP_NOT_TRUSTED {
                return CodeIdentity(teamID: nil, signingID: nil, isAdHoc: true)
            }
            // Common for local `swift build` products without codesign.
            return CodeIdentity(teamID: nil, signingID: nil, isAdHoc: true)
        }

        return try identity(from: staticCode)
    }

    public static func codeIdentityOfCurrentProcess() throws -> CodeIdentity {
        var code: SecCode?
        let status = SecCodeCopySelf([], &code)
        guard status == errSecSuccess, let code else {
            return CodeIdentity(teamID: nil, signingID: nil, isAdHoc: true)
        }
        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(code, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            return CodeIdentity(teamID: nil, signingID: nil, isAdHoc: true)
        }
        return try identity(from: staticCode)
    }

    private static func identity(from staticCode: SecStaticCode) throws -> CodeIdentity {
        var infoCF: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &infoCF
        )
        guard infoStatus == errSecSuccess, let info = infoCF as? [String: Any] else {
            return CodeIdentity(teamID: nil, signingID: nil, isAdHoc: true)
        }

        let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
        let signingID = info[kSecCodeInfoIdentifier as String] as? String
        let flags = info[kSecCodeInfoFlags as String] as? UInt32 ?? 0
        // Ad-hoc if no team and flags indicate host / no certificate chain.
        let isAdHoc = teamID == nil || teamID?.isEmpty == true
        _ = flags
        return CodeIdentity(teamID: teamID, signingID: signingID, isAdHoc: isAdHoc)
    }
}

// CSSM error fallback when Security constants differ across SDKs.
private let CSSMERR_TP_NOT_TRUSTED: OSStatus = -2147409654
