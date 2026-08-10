import BAMModelCatalog
import Foundation

/// Whether an on-disk base model can drive real mlx-lm generate / LoRA.
enum LocalModelCapability: Equatable, Sendable {
    /// Toy fixture or dogfood stub — no real weight tensors.
    case stub(reason: String)
    /// Looks like a full install (no stub markers); real generate/train may work if mlx-lm is present.
    case realWeights

    var isStub: Bool {
        if case .stub = self { return true }
        return false
    }

    var shortLabel: String {
        switch self {
        case .stub: return "Stub / fixture"
        case .realWeights: return "Weights on disk"
        }
    }
}

enum LocalModelCapabilityProbe {
    /// Inspect a `models/base/<dir>` path for fixture / dogfood stub markers.
    static func probe(path: String?) -> LocalModelCapability {
        guard let path, !path.isEmpty else {
            return .stub(reason: "No model selected")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        let fm = FileManager.default

        if dir.lastPathComponent == FixtureModel.installDirectoryName {
            return .stub(reason: "Offline fixture (no real MLX weights)")
        }

        let weightsMissing = dir.appendingPathComponent("WEIGHTS_NOT_INCLUDED.txt", isDirectory: false)
        if fm.fileExists(atPath: weightsMissing.path) {
            return .stub(reason: "WEIGHTS_NOT_INCLUDED marker present")
        }

        if let meta = ModelInstallService.installMetadata(at: dir), meta.dogfoodStub {
            return .stub(reason: "Dogfood catalog stub (toy layout)")
        }

        // Tiny placeholder safetensors (< 8 KiB) ⇒ not real weights.
        let st = dir.appendingPathComponent("model.safetensors", isDirectory: false)
        if let size = try? st.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 8192 {
            return .stub(reason: "model.safetensors is a tiny placeholder")
        }

        return .realWeights
    }

    /// Resolve catalog sourceKey for a local install path when known.
    static func sourceKey(path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        if dir.lastPathComponent == FixtureModel.installDirectoryName {
            return FixtureModel.sourceKey
        }
        return ModelInstallService.installMetadata(at: dir)?.sourceKey
    }
}
