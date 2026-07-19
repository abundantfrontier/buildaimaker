import XCTest
import BAMModels
@testable import BAMConsent

final class ConsentValidationTests: XCTestCase {
    func testSelfDraftValidWhenAllFieldsFilled() throws {
        var draft = ConsentDraft(
            subjectType: .self_,
            subjectDisplayName: "Test Subject",
            attestorUserLabel: "test-user",
            scope: .personalUse
        )
        draft.acceptedStatements = draft.acceptedStatements.map { _ in true }
        try ConsentValidator.validate(draft)
    }

    func testRejectsMissingAttestor() {
        var draft = ConsentDraft(
            subjectType: .self_,
            subjectDisplayName: "Name",
            attestorUserLabel: "  "
        )
        draft.acceptedStatements = draft.acceptedStatements.map { _ in true }
        XCTAssertThrowsError(try ConsentValidator.validate(draft)) { error in
            XCTAssertEqual(error as? ConsentValidationError, .missingAttestorUserLabel)
        }
    }

    func testRejectsIncompleteStatements() {
        let draft = ConsentDraft(
            subjectType: .self_,
            subjectDisplayName: "Name",
            attestorUserLabel: "user"
        )
        // Leave checkboxes false.
        XCTAssertThrowsError(try ConsentValidator.validate(draft)) { error in
            XCTAssertEqual(error as? ConsentValidationError, .statementsIncomplete)
        }
    }

    func testThirdPartyRequiresDisplayName() {
        var draft = ConsentDraft(
            subjectType: .thirdParty,
            subjectDisplayName: "",
            attestorUserLabel: "user",
            thirdPartySecondaryConfirmed: true
        )
        draft.acceptedStatements = draft.acceptedStatements.map { _ in true }
        XCTAssertThrowsError(try ConsentValidator.validate(draft)) { error in
            XCTAssertEqual(error as? ConsentValidationError, .missingSubjectDisplayName)
        }
    }

    func testThirdPartyRequiresSecondaryConfirm() {
        var draft = ConsentDraft(
            subjectType: .thirdParty,
            subjectDisplayName: "Alice",
            attestorUserLabel: "user",
            thirdPartySecondaryConfirmed: false
        )
        draft.acceptedStatements = draft.acceptedStatements.map { _ in true }
        XCTAssertThrowsError(try ConsentValidator.validate(draft)) { error in
            XCTAssertEqual(error as? ConsentValidationError, .thirdPartySecondaryConfirmRequired)
        }
    }

    func testThirdPartyValidWithNameAndSecondary() throws {
        var draft = ConsentDraft(
            subjectType: .thirdParty,
            subjectDisplayName: "Alice",
            attestorUserLabel: "user",
            thirdPartySecondaryConfirmed: true
        )
        draft.acceptedStatements = draft.acceptedStatements.map { _ in true }
        try ConsentValidator.validate(draft)
    }

    func testSelfDoesNotRequireSecondaryConfirm() throws {
        var draft = ConsentDraft(
            subjectType: .self_,
            subjectDisplayName: "Me",
            attestorUserLabel: "user",
            thirdPartySecondaryConfirmed: false
        )
        draft.acceptedStatements = draft.acceptedStatements.map { _ in true }
        try ConsentValidator.validate(draft)
    }

    func testDefaultStatementTextsMatchGoldenFixture() {
        XCTAssertEqual(ConsentStatements.defaults, DomainFixtures.goldenConsentRecord.statements)
    }
}
