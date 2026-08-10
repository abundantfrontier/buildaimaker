import Foundation

/// Best-effort size class parsed from a model id/name/tags (HF listings rarely ship param counts).
public struct ModelSizeHints: Equatable, Sendable {
    /// Parameter count in billions (e.g. 1.5, 7, 70).
    public var paramCountB: Double?
    /// Weight quant bits when known (4, 8, 16, …).
    public var quantBits: Int?
    /// Rough inference footprint (GB) for MLX generate on Apple Silicon.
    public var estimatedInferenceGB: Double?
    /// Rough LoRA train peak (GB) using a coarse heuristic (not full HardwareFitGate).
    public var estimatedTrainPeakGB: Double?

    public init(
        paramCountB: Double? = nil,
        quantBits: Int? = nil,
        estimatedInferenceGB: Double? = nil,
        estimatedTrainPeakGB: Double? = nil
    ) {
        self.paramCountB = paramCountB
        self.quantBits = quantBits
        self.estimatedInferenceGB = estimatedInferenceGB
        self.estimatedTrainPeakGB = estimatedTrainPeakGB
    }

    public var shortLabel: String {
        var parts: [String] = []
        if let p = paramCountB {
            if p >= 10 {
                parts.append(String(format: "%.0fB", p))
            } else if abs(p - p.rounded()) < 0.05 {
                parts.append(String(format: "%.0fB", p))
            } else {
                parts.append(String(format: "%gB", p))
            }
        }
        if let q = quantBits {
            parts.append("\(q)-bit")
        }
        return parts.isEmpty ? "size ?" : parts.joined(separator: " · ")
    }

    public var ramLabel: String {
        if let g = estimatedInferenceGB {
            return String(format: "~%.1f GB infer", g)
        }
        return "RAM ?"
    }
}

/// Parses HF-style model names and estimates memory for filter chips.
public enum ModelSizeEstimator: Sendable {
    /// Parse `sourceKey` / display name / tags for size class + RAM estimates.
    public static func estimate(
        sourceKey: String,
        name: String = "",
        tags: [String] = []
    ) -> ModelSizeHints {
        let blob = ([sourceKey, name] + tags).joined(separator: " ")
        let paramB = parseParamCountB(from: blob)
        let quant = parseQuantBits(from: blob) ?? 4 // MLX community defaults to 4-bit often
        var inference: Double?
        var train: Double?
        if let paramB {
            inference = estimateInferenceGB(paramCountB: paramB, quantBits: quant)
            train = estimateTrainPeakGB(paramCountB: paramB, quantBits: quant)
        }
        return ModelSizeHints(
            paramCountB: paramB,
            quantBits: paramB == nil ? parseQuantBits(from: blob) : quant,
            estimatedInferenceGB: inference,
            estimatedTrainPeakGB: train
        )
    }

    /// Inference ≈ weights bytes + KV/runtime overhead.
    ///
    /// `weightsGB = paramsB * (quantBits/8)`, then ×1.35 + 1.0 GB fixed overhead.
    public static func estimateInferenceGB(paramCountB: Double, quantBits: Int) -> Double {
        let bits = max(2, quantBits)
        let weights = paramCountB * (Double(bits) / 8.0)
        return max(0.2, weights * 1.35 + 1.0)
    }

    /// Coarse LoRA train peak: base weights + adapters/optim/activations fudge.
    public static func estimateTrainPeakGB(paramCountB: Double, quantBits: Int) -> Double {
        let infer = estimateInferenceGB(paramCountB: paramCountB, quantBits: quantBits)
        // Training is heavier; scale up with model size.
        let trainFudge = max(2.0, paramCountB * 0.35)
        return infer + trainFudge + 2.0
    }

    // MARK: - Parsing

    /// Matches `0.5B`, `1.5B`, `7B`, `70B`, `3b`, optional dash/underscore before B.
    public static func parseParamCountB(from text: String) -> Double? {
        // Prefer explicit patterns near model family tokens.
        let patterns = [
            #"(?i)(?:^|[^0-9])(\d+(?:\.\d+)?)\s*[Bb](?:$|[^a-zA-Z])"#,
            #"(?i)[-_](\d+(?:\.\d+)?)[Bb](?:[-_]|$)"#,
        ]
        var candidates: [Double] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                guard let match, match.numberOfRanges >= 2,
                      let r = Range(match.range(at: 1), in: text),
                      let v = Double(text[r]), v > 0, v <= 1000
                else { return }
                candidates.append(v)
            }
        }
        // Prefer the largest plausible LLM size in the string (avoid matching "3" from "2512").
        // Also drop tiny integers that look like dates/versions when a larger B exists.
        if candidates.isEmpty { return nil }
        // Filter out year-like and version noise: keep values that look like model sizes.
        let filtered = candidates.filter { $0 <= 400 }
        return filtered.max()
    }

    public static func parseQuantBits(from text: String) -> Int? {
        let lower = text.lowercased()
        let ordered: [(String, Int)] = [
            ("mxfp4", 4),
            ("fp4", 4),
            ("4bit", 4),
            ("4-bit", 4),
            ("5bit", 5),
            ("5-bit", 5),
            ("6bit", 6),
            ("6-bit", 6),
            ("8bit", 8),
            ("8-bit", 8),
            ("3bit", 3),
            ("3-bit", 3),
            ("2bit", 2),
            ("2-bit", 2),
            ("bf16", 16),
            ("fp16", 16),
            ("f16", 16),
            ("16bit", 16),
            ("q8", 8),
            ("q6", 6),
            ("q5", 5),
            ("q4", 4),
            ("q3", 3),
        ]
        for (token, bits) in ordered {
            if lower.contains(token) { return bits }
        }
        return nil
    }
}

/// User-facing memory filter for the model browser.
public enum ModelMemoryFilter: String, CaseIterable, Identifiable, Sendable {
    /// Estimated inference fits in available unified memory (minus reserve).
    case fitsThisMac
    /// Comfortable headroom (~≤50% of available after reserve).
    case fitsComfortably
    case upTo1B
    case upTo3B
    case upTo7B
    case upTo14B
    case showAll

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fitsThisMac: return "Fits this Mac"
        case .fitsComfortably: return "Comfortable"
        case .upTo1B: return "≤ 1B"
        case .upTo3B: return "≤ 3B"
        case .upTo7B: return "≤ 7B"
        case .upTo14B: return "≤ 14B"
        case .showAll: return "All sizes"
        }
    }

    public var help: String {
        switch self {
        case .fitsThisMac:
            return "Hide models whose estimated inference RAM exceeds this Mac’s unified memory."
        case .fitsComfortably:
            return "Prefer models using roughly half of available memory or less."
        case .upTo1B: return "Parameter count ≤ 1B"
        case .upTo3B: return "Parameter count ≤ 3B"
        case .upTo7B: return "Parameter count ≤ 7B"
        case .upTo14B: return "Parameter count ≤ 14B"
        case .showAll: return "No size filter"
        }
    }

    /// Suggested default filter from probed unified memory (GB).
    public static func recommended(forAvailableGB availableGB: Int) -> ModelMemoryFilter {
        switch availableGB {
        case ..<12: return .upTo1B
        case 12..<20: return .upTo3B
        case 20..<36: return .fitsThisMac
        case 36..<64: return .fitsThisMac
        default: return .fitsThisMac
        }
    }

    /// Whether a listing passes this filter given Mac memory.
    public func allows(
        hints: ModelSizeHints,
        availableUnifiedGB: Int,
        osReserveGB: Double = 4
    ) -> Bool {
        let available = Double(max(0, availableUnifiedGB))
        let usable = max(0, available - osReserveGB)

        switch self {
        case .showAll:
            return true
        case .upTo1B:
            return paramAtMost(hints, 1.0)
        case .upTo3B:
            return paramAtMost(hints, 3.0)
        case .upTo7B:
            return paramAtMost(hints, 7.0)
        case .upTo14B:
            return paramAtMost(hints, 14.0)
        case .fitsThisMac:
            // Unknown size: keep (user can still install; badge shows "?")
            guard let need = hints.estimatedInferenceGB else { return true }
            return need <= usable
        case .fitsComfortably:
            guard let need = hints.estimatedInferenceGB else { return true }
            return need <= usable * 0.5
        }
    }

    private func paramAtMost(_ hints: ModelSizeHints, _ maxB: Double) -> Bool {
        guard let p = hints.paramCountB else { return true }
        return p <= maxB + 0.05
    }
}

public extension ModelRemoteListing {
    /// Parsed size / RAM hints for this listing.
    var sizeHints: ModelSizeHints {
        ModelSizeEstimator.estimate(sourceKey: sourceKey, name: name, tags: tags)
    }
}
