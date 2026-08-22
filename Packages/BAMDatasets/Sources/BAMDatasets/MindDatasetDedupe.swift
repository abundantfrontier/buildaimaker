import BAMCore
import BAMModels
import Foundation

/// Result of a mind-dataset dedupe pass.
public struct MindDedupeResult: Sendable, Equatable {
    public var examined: Int
    public var kept: [String]
    public var deleted: [String]
    public var dryRun: Bool
    public var reasons: [String: String]

    public init(
        examined: Int,
        kept: [String],
        deleted: [String],
        dryRun: Bool,
        reasons: [String: String] = [:]
    ) {
        self.examined = examined
        self.kept = kept
        self.deleted = deleted
        self.dryRun = dryRun
        self.reasons = reasons
    }
}

extension DatasetLibraryService {
    /// Remove orphan mind datasets that duplicate a kept id.
    ///
    /// **Keep rules (in order):**
    /// 1. Any dataset id listed in `referencedDatasetIds` (characters still point at it).
    /// 2. Within a name group (e.g. all “Robby mind”), keep the newest by `createdAt`.
    /// 3. Optionally collapse same content-hash within a name group onto the kept id.
    ///
    /// Only **copy-mode** datasets whose names end with `nameSuffix` (default `" mind"`) are candidates.
    /// Reference-mode and non-mind names are never deleted.
    public func dedupeMindDatasets(
        referencedDatasetIds: Set<String>,
        nameSuffix: String = " mind",
        dryRun: Bool = true
    ) throws -> MindDedupeResult {
        let all = try listDatasets()
        let candidates = all.filter { ds in
            ds.importMode == .copy
                && ds.name.hasSuffix(nameSuffix)
        }
        var keep = Set<String>()
        var reasons: [String: String] = [:]

        // Always keep referenced.
        for id in referencedDatasetIds {
            if candidates.contains(where: { $0.id == id }) {
                keep.insert(id)
                reasons[id] = "referenced_by_character"
            }
        }

        // Group by display name.
        var byName: [String: [DatasetRecord]] = [:]
        for ds in candidates {
            byName[ds.name, default: []].append(ds)
        }

        for (name, group) in byName {
            let sorted = group.sorted { $0.createdAt > $1.createdAt }
            // Prefer a referenced one in the group; else newest.
            if let preferred = sorted.first(where: { keep.contains($0.id) })
                ?? sorted.first
            {
                keep.insert(preferred.id)
                if reasons[preferred.id] == nil {
                    reasons[preferred.id] = "canonical_for_name:\(name)"
                }
                // Same content hash as preferred → drop others (even if newer — rare).
                let preferredHash = try? latestVersion(datasetId: preferred.id)?.contentHash
                for other in sorted where other.id != preferred.id {
                    if keep.contains(other.id) { continue }
                    if let ph = preferredHash,
                       let oh = try? latestVersion(datasetId: other.id)?.contentHash,
                       ph == oh
                    {
                        reasons[other.id] = "duplicate_hash_of:\(preferred.id)"
                    } else if !referencedDatasetIds.contains(other.id) {
                        reasons[other.id] = "orphan_name_group:\(name)_kept:\(preferred.id)"
                    } else {
                        keep.insert(other.id)
                        reasons[other.id] = "referenced_by_character"
                    }
                }
            }
        }

        let deleteIds = candidates.map(\.id).filter { !keep.contains($0) }
        if !dryRun {
            for id in deleteIds {
                try deleteDataset(id: id)
            }
        }

        return MindDedupeResult(
            examined: candidates.count,
            kept: Array(keep).sorted(),
            deleted: deleteIds.sorted(),
            dryRun: dryRun,
            reasons: reasons
        )
    }
}
