import Foundation

#if canImport(AVFoundation)
import AVFoundation
#endif

/// Production microphone TCC check via AVFoundation (macOS).
///
/// Falls back to `.denied` when AVFoundation is unavailable (should not happen
/// on the app target). Unit tests should inject `FakeMicPermission` instead.
public struct SystemMicPermission: MicPermissionChecking, Sendable {
    public init() {}

    public func status() async -> MicPermissionStatus {
        #if canImport(AVFoundation)
        map(AVCaptureDevice.authorizationStatus(for: .audio))
        #else
        .denied
        #endif
    }

    public func requestAccess() async -> MicPermissionStatus {
        #if canImport(AVFoundation)
        let current = AVCaptureDevice.authorizationStatus(for: .audio)
        if current == .authorized { return .authorized }
        if current == .denied || current == .restricted {
            return map(current)
        }
        let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                cont.resume(returning: ok)
            }
        }
        return granted ? .authorized : .denied
        #else
        return .denied
        #endif
    }

    #if canImport(AVFoundation)
    private func map(_ status: AVAuthorizationStatus) -> MicPermissionStatus {
        switch status {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }
    #endif
}
