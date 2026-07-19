import BAMCore
import BAMModels
import Foundation

/// Validation failures when creating or accepting a consent draft / record policy.
public enum ConsentValidationError: Error, Equatable, Sendable {
    case missingSubjectDisplayName
    case missingAttestorUserLabel
    case statementsIncomplete
    case thirdPartySecondaryConfirmRequired
    case emptyStatements
}

extension ConsentValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingSubjectDisplayName:
            return "Subject display name is required."
        case .missingAttestorUserLabel:
            return "Attestor label is required."
        case .statementsIncomplete:
            return "All consent statements must be accepted."
        case .thirdPartySecondaryConfirmRequired:
            // Name is already validated when this fires; do not imply name is missing.
            return "Third-party consent requires secondary confirmation."
        case .emptyStatements:
            return "At least one consent statement is required."
        }
    }

    /// Maps draft/acceptance failures that block cloning to `BAM_CONSENT_REQUIRED`.
    /// Structural malformation is still represented as `.emptyStatements` under the same
    /// product code (missing/invalid consent); encode/decode failures use `BAM_SCHEMA_INVALID`
    /// at the store layer instead.
    public var bamError: BAMError {
        BAMError(code: .consentRequired, message: errorDescription)
    }
}

/// Mutable form state for creating a `ConsentRecord`.
public struct ConsentDraft: Equatable, Sendable {
    public var subjectType: ConsentSubjectType
    public var subjectDisplayName: String
    public var attestorUserLabel: String
    public var scope: ConsentScope
    /// Parallel to `ConsentStatements.defaults` (or custom list); true = accepted.
    public var acceptedStatements: [Bool]
    /// Statement texts corresponding to `acceptedStatements` (order is semantic).
    public var statementTexts: [String]
    /// UI-only gate for `third_party` (not stored on ConsentRecord).
    public var thirdPartySecondaryConfirmed: Bool
    public var jurisdictionNote: String

    public init(
        subjectType: ConsentSubjectType = .self_,
        subjectDisplayName: String = "",
        attestorUserLabel: String = "",
        scope: ConsentScope = .personalUse,
        statementTexts: [String] = ConsentStatements.defaults,
        acceptedStatements: [Bool]? = nil,
        thirdPartySecondaryConfirmed: Bool = false,
        jurisdictionNote: String = ""
    ) {
        self.subjectType = subjectType
        self.subjectDisplayName = subjectDisplayName
        self.attestorUserLabel = attestorUserLabel
        self.scope = scope
        self.statementTexts = statementTexts
        if let acceptedStatements, acceptedStatements.count == statementTexts.count {
            self.acceptedStatements = acceptedStatements
        } else {
            self.acceptedStatements = Array(repeating: false, count: statementTexts.count)
        }
        self.thirdPartySecondaryConfirmed = thirdPartySecondaryConfirmed
        self.jurisdictionNote = jurisdictionNote
    }

    /// Statements accepted by the user, in order.
    public var selectedStatements: [String] {
        zip(statementTexts, acceptedStatements).compactMap { text, ok in ok ? text : nil }
    }

    public var allStatementsAccepted: Bool {
        !acceptedStatements.isEmpty && acceptedStatements.allSatisfy { $0 }
    }
}

/// Validates a consent draft before hashing / persistence.
public enum ConsentValidator: Sendable {
    /// Validates `draft` for create. Throws `ConsentValidationError` on failure.
    public static func validate(_ draft: ConsentDraft) throws {
        let attestor = draft.attestorUserLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !attestor.isEmpty else {
            throw ConsentValidationError.missingAttestorUserLabel
        }

        guard !draft.statementTexts.isEmpty else {
            throw ConsentValidationError.emptyStatements
        }
        guard draft.allStatementsAccepted else {
            throw ConsentValidationError.statementsIncomplete
        }

        let name = draft.subjectDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw ConsentValidationError.missingSubjectDisplayName
        }

        if draft.subjectType == .thirdParty {
            // Design: third_party also requires explicit secondary checkbox (UI-only field).
            guard draft.thirdPartySecondaryConfirmed else {
                throw ConsentValidationError.thirdPartySecondaryConfirmRequired
            }
        }
    }

    /// Record-level policy for persist/import paths (secondary confirm is UI-only and not stored).
    ///
    /// Enforces non-empty `subjectDisplayName` and `attestorUserLabel`, and non-empty `statements`,
    /// for all subject types including `third_party`.
    public static func validateRecordPolicy(_ record: ConsentRecord) throws {
        let name = record.subjectDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw ConsentValidationError.missingSubjectDisplayName
        }
        let attestor = record.attestorUserLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !attestor.isEmpty else {
            throw ConsentValidationError.missingAttestorUserLabel
        }
        guard !record.statements.isEmpty else {
            throw ConsentValidationError.emptyStatements
        }
    }
}
