@testable import SupportKit
import Testing

@Suite("Submission validation")
struct SupportSubmissionValidationTests {
    struct ValidationCase: Sendable, CustomTestStringConvertible {
        let name: String
        let form: SupportFormConfiguration
        let draft: SupportDraft
        let expectedFailure: SupportSubmissionFailure

        var testDescription: String {
            name
        }
    }

    static let validationCases: [ValidationCase] = [
        .init(
            name: "blank subject",
            form: .init(additionalFields: []),
            draft: .init(subject: " \n ", message: "Details"),
            expectedFailure: .emptySubject,
        ),
        .init(
            name: "blank message",
            form: .init(additionalFields: []),
            draft: .init(subject: "Subject", message: " \t "),
            expectedFailure: .emptyMessage,
        ),
        .init(
            name: "subject over its limit",
            form: .init(subjectMaximumLength: 3, additionalFields: []),
            draft: .init(subject: "Four", message: "Details"),
            expectedFailure: .subjectTooLong(maximum: 3),
        ),
        .init(
            name: "message over its limit",
            form: .init(messageMaximumLength: 3, additionalFields: []),
            draft: .init(subject: "Subject", message: "Four"),
            expectedFailure: .messageTooLong(maximum: 3),
        ),
        .init(
            name: "missing required text field",
            form: .init(additionalFields: [
                .init(id: "account", label: "Account", isRequired: true),
            ]),
            draft: .init(subject: "Subject", message: "Details"),
            expectedFailure: .requiredField("Account"),
        ),
        .init(
            name: "required consent toggle is off",
            form: .init(additionalFields: [
                .init(id: "consent", label: "Consent", kind: .toggle, isRequired: true),
            ]),
            draft: .init(
                subject: "Subject",
                message: "Details",
                responses: ["consent": "false"],
            ),
            expectedFailure: .requiredField("Consent"),
        ),
        .init(
            name: "additional value over its limit",
            form: .init(additionalFields: [
                .init(id: "account", label: "Account", maximumLength: 3),
            ]),
            draft: .init(
                subject: "Subject",
                message: "Details",
                responses: ["account": "Four"],
            ),
            expectedFailure: .fieldTooLong(label: "Account", maximum: 3),
        ),
        .init(
            name: "malformed email",
            form: .init(additionalFields: [
                .init(id: "email", label: "Reply address", kind: .email),
            ]),
            draft: .init(
                subject: "Subject",
                message: "Details",
                responses: ["email": "not-an-email"],
            ),
            expectedFailure: .invalidEmail("Reply address"),
        ),
        .init(
            name: "unknown picker option",
            form: .init(additionalFields: [
                .init(
                    id: "topic",
                    label: "Topic",
                    kind: .picker(options: [.init(id: "bug", label: "Bug")]),
                    defaultValue: "bug",
                ),
            ]),
            draft: .init(
                subject: "Subject",
                message: "Details",
                responses: ["topic": "billing"],
            ),
            expectedFailure: .invalidSelection("Topic"),
        ),
    ]

    @Test(arguments: validationCases)
    func `invalid drafts are rejected with a precise failure`(testCase: ValidationCase) throws {
        // Arrange
        let configuration = try SupportKitTestFixture.configuration(form: testCase.form)
        let sut = SupportSubmissionPreparer(configuration: configuration, redactor: .init())

        // Act
        let result = sut.prepare(
            draft: testCase.draft,
            id: SupportKitTestFixture.reportID,
            now: SupportKitTestFixture.date,
            diagnostics: [],
        )

        // Assert
        #expect(result == .failure(testCase.expectedFailure))
    }
}
