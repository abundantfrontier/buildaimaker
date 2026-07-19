import Foundation
import BAMCore

/// Microphone authorization state (maps to TCC).
public enum MicPermissionStatus: String, Sendable, Equatable, CaseIterable {
    case notDetermined
    case authorized
    case denied
    case restricted

    public var isUsable: Bool { self == .authorized }
}

/// Abstraction over macOS microphone TCC so unit tests stay CI-safe.
public protocol MicPermissionChecking: Sendable {
    func status() async -> MicPermissionStatus
    /// Prompt the user when status is `.notDetermined`. Returns resulting status.
    func requestAccess() async -> MicPermissionStatus
}

/// Always-authorized mic permission (unit tests / headless).
public struct FakeMicPermission: MicPermissionChecking, Sendable {
    public var current: MicPermissionStatus

    public init(current: MicPermissionStatus = .authorized) {
        self.current = current
    }

    public func status() async -> MicPermissionStatus { current }

    public func requestAccess() async -> MicPermissionStatus {
        // Mimic grant on request when not determined; keep denied/restricted sticky.
        if current == .notDetermined {
            return .authorized
        }
        return current
    }
}

/// User-facing copy + Settings deep link for TCC microphone denial.
public enum MicPermissionMessaging: Sendable {
    public static let deniedTitle = "Microphone access required"

    public static let deniedMessage =
        "Talk mode needs the microphone for push-to-talk. Enable Microphone access for BuildAIMaker in System Settings → Privacy & Security → Microphone, then try again."

    public static let restrictedMessage =
        "Microphone access is restricted on this Mac (parental controls or device management). Talk mode cannot capture audio."

    /// Opens Privacy → Microphone in System Settings when possible.
    public static var systemSettingsMicrophoneURL: URL {
        // macOS Ventura+ settings URL; falls back gracefully if scheme ignored.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            return url
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security")!
    }

    /// Build a `BAMError` for denied / restricted mic TCC.
    public static func error(for status: MicPermissionStatus) -> BAMError {
        switch status {
        case .denied:
            return BAMError(code: .tccMicDenied, message: deniedMessage)
        case .restricted:
            return BAMError(code: .tccMicDenied, message: restrictedMessage)
        case .notDetermined:
            return BAMError(
                code: .tccMicDenied,
                message: "Microphone permission has not been granted yet."
            )
        case .authorized:
            return BAMError(code: .tccMicDenied, message: "Unexpected mic permission error.")
        }
    }

    public static func userMessage(for status: MicPermissionStatus) -> String {
        switch status {
        case .denied: return deniedMessage
        case .restricted: return restrictedMessage
        case .notDetermined: return "Microphone permission is required for Talk mode."
        case .authorized: return ""
        }
    }
}
