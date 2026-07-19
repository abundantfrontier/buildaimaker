import Foundation

/// User-facing recovery guidance when L2 pin/lock/entry checks fail
/// (`BAM_RUNTIME_INTEGRITY`) or L1 helper trust rejects a launch.
///
/// Product rule: surface Settings → **Repair training runtime**; never fall
/// back to system Python.
public enum RuntimeRecovery: Sendable {
    /// Settings button / section label (stable for UI + diagnostics).
    public static let repairActionTitle = "Repair training runtime"

    /// Settings navigation hint shown next to integrity errors.
    public static let settingsPathHint = "Settings → Training runtime"

    /// Short CTA used in banners and train failure summaries.
    public static let shortCTA =
        "Open Settings → Training runtime → Repair training runtime."

    /// Full guidance for integrity failures (no system-Python escape hatch).
    public static let fullGuidance =
        """
        Training runtime integrity failed (\(BAMErrorCode.runtimeIntegrity.rawValue)). \
        Open Settings → Training runtime and choose “Repair training runtime”. \
        BuildAIMaker will reinstall the managed Python environment from pinned locks. \
        System Python is not used as a fallback.
        """

    /// True when `error` is (or wraps) `BAM_RUNTIME_INTEGRITY`.
    public static func isIntegrityFailure(_ error: Error) -> Bool {
        if let bam = error as? BAMError {
            return bam.code == .runtimeIntegrity
        }
        let text = error.localizedDescription
        return text.contains(BAMErrorCode.runtimeIntegrity.rawValue)
    }

    /// User-visible recovery copy for integrity failures; `nil` for other errors.
    public static func userMessage(for error: Error) -> String? {
        guard isIntegrityFailure(error) else { return nil }
        if let bam = error as? BAMError, let detail = bam.message, !detail.isEmpty {
            return "\(BAMErrorCode.runtimeIntegrity.rawValue): \(detail)\n\n\(shortCTA)"
        }
        return fullGuidance
    }

    /// Combine a raw status line with recovery CTA when appropriate.
    public static func augmentStatus(_ status: String, error: Error?) -> String {
        guard let error, isIntegrityFailure(error) else { return status }
        if status.contains(repairActionTitle) || status.contains("Repair") {
            return status
        }
        return status + " — " + shortCTA
    }
}
