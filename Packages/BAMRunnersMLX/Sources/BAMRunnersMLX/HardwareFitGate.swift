import BAMCore
import Foundation

/// Preflight hardware gate (stub for PR-LLM-Materialize; full estimator is PR-HW-Fit).
///
/// Global policy (K16): refuse train features when `availableUnifiedGB < 16`.
public enum HardwareFitGate: Sendable {
    /// Default OS reserve used when estimating peak memory later (documented for UI copy).
    public static let defaultOSReserveGB: Int = 6

    /// Result of a preflight memory gate check.
    public struct Result: Sendable, Equatable {
        public var allowed: Bool
        public var availableUnifiedGB: Int
        public var minimumRequiredGB: Int
        public var message: String?

        public init(
            allowed: Bool,
            availableUnifiedGB: Int,
            minimumRequiredGB: Int = AppIdentity.minimumUnifiedMemoryGB,
            message: String? = nil
        ) {
            self.allowed = allowed
            self.availableUnifiedGB = availableUnifiedGB
            self.minimumRequiredGB = minimumRequiredGB
            self.message = message
        }
    }

    /// Checks the K16 minimum unified memory gate.
    ///
    /// - Parameter availableUnifiedGB: Injectable for tests; defaults to a best-effort probe.
    public static func check(
        availableUnifiedGB: Int? = nil,
        minimumRequiredGB: Int = AppIdentity.minimumUnifiedMemoryGB
    ) -> Result {
        let available = availableUnifiedGB ?? probeAvailableUnifiedGB()
        if available < minimumRequiredGB {
            return Result(
                allowed: false,
                availableUnifiedGB: available,
                minimumRequiredGB: minimumRequiredGB,
                message:
                    "Requires at least \(minimumRequiredGB) GB unified memory (detected ~\(available) GB). "
                    + "LLM LoRA and voice train features are not supported on this machine."
            )
        }
        return Result(
            allowed: true,
            availableUnifiedGB: available,
            minimumRequiredGB: minimumRequiredGB,
            message: nil
        )
    }

    /// Throws `BAM_PREFLIGHT_MEMORY` when the machine is below the minimum.
    public static func refuseIfUnsupported(
        availableUnifiedGB: Int? = nil,
        minimumRequiredGB: Int = AppIdentity.minimumUnifiedMemoryGB
    ) throws {
        let result = check(
            availableUnifiedGB: availableUnifiedGB,
            minimumRequiredGB: minimumRequiredGB
        )
        guard result.allowed else {
            throw BAMError(code: .preflightMemory, message: result.message)
        }
    }

    /// Best-effort unified memory probe (physical memory in GB, floored).
    ///
    /// Not a Metal free-memory sample — good enough for the K16 refuse stub.
    public static func probeAvailableUnifiedGB() -> Int {
        let bytes = ProcessInfo.processInfo.physicalMemory
        let gb = Double(bytes) / (1024.0 * 1024.0 * 1024.0)
        return max(0, Int(gb.rounded(.down)))
    }
}
