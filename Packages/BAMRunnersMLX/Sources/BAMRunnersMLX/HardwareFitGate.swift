import BAMCore
import BAMModels
import Foundation

/// Hardware Fit estimator v0 + K16 global gate.
///
/// Table-driven heuristic for LLM LoRA peak unified memory (approximate — not a profiled run).
/// Global policy (K16): refuse train features when `availableUnifiedGB < 16`.
public enum HardwareFitGate: Sendable {
    /// Default OS reserve used when estimating peak memory (documented for UI copy).
    public static let defaultOSReserveGB: Double = 6

    /// Soft-warning band: required headroom within this fraction of available memory.
    public static let warningBandFraction: Double = 0.15

    /// Minimum trainable LoRA footprint (GB) after clamping the coarse formula.
    public static let minLoraGB: Double = 0.05

    /// Fixed fudge added to every peak estimate (GB) for runtime overhead.
    public static let fixedOverheadGB: Double = 1.5

    /// UI copy for the Approximate label.
    public static let approximateLabel =
        "Approximate — based on model size class, not a profiled run."

    // MARK: - Fit status

    /// Outcome of a hardware fit evaluation.
    public enum FitStatus: String, Sendable, Equatable, Codable {
        /// Comfortable headroom.
        case ok
        /// Within 15% of the memory limit; allow with warning / advanced override.
        case warning
        /// Must not start (K16 fail and/or peak + OS reserve exceeds available).
        case refuse
    }

    /// Inputs for the LLM LoRA peak-memory heuristic.
    public struct EstimateInput: Sendable, Equatable {
        public var paramCountB: Double
        public var quantBits: Int
        public var loraRank: Int
        public var maxSeqLen: Int
        public var batchSize: Int
        public var gradAccum: Int
        public var osReserveGB: Double
        public var availableUnifiedGB: Double

        public init(
            paramCountB: Double,
            quantBits: Int,
            loraRank: Int = 16,
            maxSeqLen: Int = 2048,
            batchSize: Int = 1,
            gradAccum: Int = 4,
            osReserveGB: Double = HardwareFitGate.defaultOSReserveGB,
            availableUnifiedGB: Double
        ) {
            self.paramCountB = paramCountB
            self.quantBits = quantBits
            self.loraRank = loraRank
            self.maxSeqLen = maxSeqLen
            self.batchSize = batchSize
            self.gradAccum = gradAccum
            self.osReserveGB = osReserveGB
            self.availableUnifiedGB = availableUnifiedGB
        }

        /// Builds inputs from LLM hyperparameters + model size class.
        public init(
            paramCountB: Double,
            quantBits: Int,
            hyperparameters: LLMHyperparameters,
            osReserveGB: Double = HardwareFitGate.defaultOSReserveGB,
            availableUnifiedGB: Double
        ) {
            self.init(
                paramCountB: paramCountB,
                quantBits: quantBits,
                loraRank: hyperparameters.loraRank,
                maxSeqLen: hyperparameters.maxSeqLen,
                batchSize: hyperparameters.batchSize,
                gradAccum: hyperparameters.gradAccum,
                osReserveGB: osReserveGB,
                availableUnifiedGB: availableUnifiedGB
            )
        }
    }

    /// Result of the peak-memory estimate and fit decision.
    public struct Estimate: Sendable, Equatable {
        public var peakGB: Double
        public var osReserveGB: Double
        /// `peakGB + osReserveGB` — total claimed against available unified memory.
        public var requiredGB: Double
        public var availableUnifiedGB: Double
        public var headroomGB: Double
        public var status: FitStatus
        public var message: String?
        public var suggestions: [String]
        /// Decomposition retained for tests / advanced UI.
        public var baseGB: Double
        public var loraGB: Double
        public var optimGB: Double
        public var activGB: Double

        public init(
            peakGB: Double,
            osReserveGB: Double,
            requiredGB: Double,
            availableUnifiedGB: Double,
            headroomGB: Double,
            status: FitStatus,
            message: String? = nil,
            suggestions: [String] = [],
            baseGB: Double,
            loraGB: Double,
            optimGB: Double,
            activGB: Double
        ) {
            self.peakGB = peakGB
            self.osReserveGB = osReserveGB
            self.requiredGB = requiredGB
            self.availableUnifiedGB = availableUnifiedGB
            self.headroomGB = headroomGB
            self.status = status
            self.message = message
            self.suggestions = suggestions
            self.baseGB = baseGB
            self.loraGB = loraGB
            self.optimGB = optimGB
            self.activGB = activGB
        }

        public var allowed: Bool { status != .refuse }
    }

    /// Result of the K16 minimum unified memory gate (legacy / simple preflight).
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

    // MARK: - Peak estimate (table heuristic)

    /// Computes peak unified memory (GB) for an LLM LoRA train config.
    ///
    /// ```
    /// baseBytes  ≈ paramCountB * 1e9 * (quantBits/8)
    /// loraBytes  ≈ paramCountB * 1e9 * (loraRank / 16) * 0.02  // clamp ≥ 0.05 GB
    /// optimBytes ≈ loraBytes * 2
    /// activFudge ≈ (maxSeqLen/2048) * batchSize * gradAccum * 0.5 * paramCountB
    /// peakGB     ≈ (base+lora+optim)/1e9 + activFudge + 1.5
    /// ```
    public static func estimatePeakGB(
        paramCountB: Double,
        quantBits: Int,
        loraRank: Int,
        maxSeqLen: Int,
        batchSize: Int,
        gradAccum: Int
    ) -> (
        peakGB: Double,
        baseGB: Double,
        loraGB: Double,
        optimGB: Double,
        activGB: Double
    ) {
        let params = max(0, paramCountB)
        let bits = max(1, quantBits)
        let rank = max(0, loraRank)
        let seq = max(1, maxSeqLen)
        let batch = max(1, batchSize)
        let accum = max(1, gradAccum)

        let baseBytes = params * 1e9 * (Double(bits) / 8.0)
        let loraBytesRaw = params * 1e9 * (Double(rank) / 16.0) * 0.02
        let loraBytes = max(minLoraGB * 1e9, loraBytesRaw)
        let optimBytes = loraBytes * 2.0
        let activGB = (Double(seq) / 2048.0) * Double(batch) * Double(accum) * 0.5 * params

        let baseGB = baseBytes / 1e9
        let loraGB = loraBytes / 1e9
        let optimGB = optimBytes / 1e9
        let peakGB = baseGB + loraGB + optimGB + activGB + fixedOverheadGB

        return (peakGB, baseGB, loraGB, optimGB, activGB)
    }

    /// Full fit evaluation: peak estimate + OS reserve vs available, plus K16.
    public static func estimate(_ input: EstimateInput) -> Estimate {
        let parts = estimatePeakGB(
            paramCountB: input.paramCountB,
            quantBits: input.quantBits,
            loraRank: input.loraRank,
            maxSeqLen: input.maxSeqLen,
            batchSize: input.batchSize,
            gradAccum: input.gradAccum
        )

        let peak = parts.peakGB
        let reserve = max(0, input.osReserveGB)
        let required = peak + reserve
        let available = max(0, input.availableUnifiedGB)
        let headroom = available - required
        let minimum = Double(AppIdentity.minimumUnifiedMemoryGB)

        // K16: hard refuse below minimum unified memory.
        if available < minimum {
            return Estimate(
                peakGB: peak,
                osReserveGB: reserve,
                requiredGB: required,
                availableUnifiedGB: available,
                headroomGB: headroom,
                status: .refuse,
                message:
                    "Requires at least \(AppIdentity.minimumUnifiedMemoryGB) GB unified memory "
                    + "(detected ~\(formatGB(available)) GB). "
                    + "LLM LoRA and voice train features are not supported on this machine.",
                suggestions: [],
                baseGB: parts.baseGB,
                loraGB: parts.loraGB,
                optimGB: parts.optimGB,
                activGB: parts.activGB
            )
        }

        // Peak + OS reserve exceeds available → refuse with suggestions.
        if required > available {
            let suggestions = makeSuggestions(input: input)
            return Estimate(
                peakGB: peak,
                osReserveGB: reserve,
                requiredGB: required,
                availableUnifiedGB: available,
                headroomGB: headroom,
                status: .refuse,
                message:
                    "Estimated peak ~\(formatGB(peak)) GB + \(formatGB(reserve)) GB OS reserve "
                    + "(\(formatGB(required)) GB) exceeds ~\(formatGB(available)) GB available. "
                    + "Lower rank, sequence length, or batch size — or use a smaller base model.",
                suggestions: suggestions,
                baseGB: parts.baseGB,
                loraGB: parts.loraGB,
                optimGB: parts.optimGB,
                activGB: parts.activGB
            )
        }

        // Within 15% of limit → soft warning (still allowed).
        let warningThreshold = available * (1.0 - warningBandFraction)
        if required >= warningThreshold {
            return Estimate(
                peakGB: peak,
                osReserveGB: reserve,
                requiredGB: required,
                availableUnifiedGB: available,
                headroomGB: headroom,
                status: .warning,
                message:
                    "Tight fit: estimated need ~\(formatGB(required)) GB of ~\(formatGB(available)) GB "
                    + "(within \(Int(warningBandFraction * 100))% of limit). "
                    + "Close other apps or lower rank/seq if training becomes unstable.",
                suggestions: makeSuggestions(input: input),
                baseGB: parts.baseGB,
                loraGB: parts.loraGB,
                optimGB: parts.optimGB,
                activGB: parts.activGB
            )
        }

        return Estimate(
            peakGB: peak,
            osReserveGB: reserve,
            requiredGB: required,
            availableUnifiedGB: available,
            headroomGB: headroom,
            status: .ok,
            message:
                "Hardware fit OK: peak ~\(formatGB(peak)) GB + \(formatGB(reserve)) GB OS reserve "
                + "(\(formatGB(required)) GB of ~\(formatGB(available)) GB).",
            suggestions: [],
            baseGB: parts.baseGB,
            loraGB: parts.loraGB,
            optimGB: parts.optimGB,
            activGB: parts.activGB
        )
    }

    /// Throws `BAM_PREFLIGHT_MEMORY` when estimate status is `.refuse`.
    public static func refuseIfUnfit(_ input: EstimateInput) throws {
        let est = estimate(input)
        guard est.allowed else {
            var detail = est.message ?? "Hardware fit refused"
            if !est.suggestions.isEmpty {
                detail += " Suggestions: " + est.suggestions.joined(separator: "; ") + "."
            }
            throw BAMError(code: .preflightMemory, message: detail)
        }
    }

    // MARK: - K16 simple gate (kept for dry-run / voice preflight)

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

    /// Throws `BAM_PREFLIGHT_MEMORY` when the machine is below the K16 minimum.
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
    /// Not a Metal free-memory sample — good enough for K16 + table heuristic.
    public static func probeAvailableUnifiedGB() -> Int {
        let bytes = ProcessInfo.processInfo.physicalMemory
        let gb = Double(bytes) / (1024.0 * 1024.0 * 1024.0)
        return max(0, Int(gb.rounded(.down)))
    }

    // MARK: - Suggestions

    /// Actionable knobs when refuse or tight warning.
    public static func makeSuggestions(input: EstimateInput) -> [String] {
        var out: [String] = []
        if input.loraRank > 8 {
            out.append("lower LoRA rank (\(input.loraRank)→8)")
        } else if input.loraRank > 4 {
            out.append("lower LoRA rank (\(input.loraRank)→4)")
        }
        if input.maxSeqLen > 1024 {
            out.append("lower max seq (\(input.maxSeqLen)→1024)")
        } else if input.maxSeqLen > 512 {
            out.append("lower max seq (\(input.maxSeqLen)→512)")
        }
        if input.batchSize > 1 {
            out.append("set batch size to 1")
        }
        if input.gradAccum > 1 {
            out.append("reduce grad accum (\(input.gradAccum)→1)")
        }
        if input.paramCountB > 1.5 {
            out.append("use a smaller base model (≤1.5B)")
        } else if input.paramCountB > 0.5 {
            out.append("use a smaller base model (≤0.5B)")
        }
        if out.isEmpty {
            out.append("close other apps to free unified memory")
        }
        return out
    }

    // MARK: - Formatting

    public static func formatGB(_ value: Double) -> String {
        if value < 10 {
            return String(format: "%.2f", value)
        }
        return String(format: "%.1f", value)
    }
}
