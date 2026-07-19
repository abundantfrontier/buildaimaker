import BAMCore
import BAMModels
import Foundation

/// Validation failures when creating or accepting a consent draft.
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
            return "Third-party consent requires secondary confirmation and a subject display name."
        case .emptyStatements:
            return "At least one consent statement is required."
        }
    }

    /// Maps to stable BAM error codes where applicable.
    public var bamError: BAMError {
        switch self {
        case .thirdPartySecondaryConfirmRequired, .missingSubjectDisplayName:
            return BAMError(code: .consentRequired, message: errorDescription)
        default:
            return BAMError(code: .schemaInvalid, message: errorDescription)
        }
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

        switch draft.subjectType {
        case .thirdParty:
            // Design: third_party requires non-empty subjectDisplayName + secondary checkbox.
            guard !name.isEmpty else {
                throw ConsentValidationError.missingSubjectDisplayName
            }
            guard draft.thirdPartySecondaryConfirmed else {
                throw ConsentValidationError.thirdPartySecondaryConfirmRequired
            }
        case .self_, .syntheticOrPublicDomain:
            // Display name still required for binding/display (self may default later in UI).
            guard !name.isEmpty else {
                throw ConsentValidationError.missingSubjectDisplayName
            }
        }
    }
}
