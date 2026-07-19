import Foundation

/// What a training/infer job does (Runner Protocol / jobs table).
public enum JobModality: String, Codable, Sendable, CaseIterable, Equatable {
    case llm
    case voiceClone
    case voiceFinetune // Phase 2+; schema reserved
}

/// What a dataset contains (datasets table only).
public enum DatasetModality: String, Codable, Sendable, CaseIterable, Equatable {
    case text // chat JSONL, prompt-completion, etc.
    case audio // WAV/FLAC/M4A corpora or clone reference sets
}

/// Job lifecycle state machine (v1 — no pause).
public enum JobStatus: String, Codable, Sendable, CaseIterable, Equatable {
    case draft
    case queued
    case preparing
    case running
    case succeeded
    case failed
    case cancelled
    case interrupted
}

/// Backward-compat alias used in prose: `Modality` == `JobModality`.
public typealias Modality = JobModality

/// Mapping: dataset modality → eligible job modalities.
public enum ModalityMapping: Sendable {
    /// Job modalities that may consume a dataset of the given kind.
    public static func eligibleJobModalities(for dataset: DatasetModality) -> [JobModality] {
        switch dataset {
        case .text:
            return [.llm]
        case .audio:
            return [.voiceClone, .voiceFinetune]
        }
    }

    /// Whether `job` may legally consume a dataset of kind `dataset`.
    public static func isCompatible(dataset: DatasetModality, job: JobModality) -> Bool {
        eligibleJobModalities(for: dataset).contains(job)
    }
}
