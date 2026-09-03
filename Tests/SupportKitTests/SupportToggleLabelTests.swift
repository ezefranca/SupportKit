import Foundation
@testable import SupportKit
import Testing

@Suite("Localized toggle report values")
struct SupportToggleLabelTests {
    @Test
    func `toggle fields render their configured true and false labels`() throws {
        // Arrange
        let form = SupportFormConfiguration(additionalFields: [
            .init(
                id: "enabled",
                label: "Enabled",
                kind: .toggle,
                toggleTrueLabel: "Oui",
                toggleFalseLabel: "Non",
            ),
            .init(
                id: "disabled",
                label: "Disabled",
                kind: .toggle,
                toggleTrueLabel: "Oui",
                toggleFalseLabel: "Non",
            ),
        ])
        let configuration = try SupportKitTestFixture.configuration(form: form)
        let sut = SupportSubmissionPreparer(configuration: configuration, redactor: .init())
        let draft = SupportDraft(
            subject: "Sujet",
            message: "Détails",
            responses: ["enabled": "true", "disabled": "false"],
        )

        // Act
        let result = sut.prepare(
            draft: draft,
            id: SupportKitTestFixture.reportID,
            now: SupportKitTestFixture.date,
            diagnostics: [],
        )
        let submission = try #require(result.preparedSubmission)

        // Assert
        #expect(submission.responses.map(\.value) == ["Oui", "Non"])
    }
}

private extension Result where Success == SupportSubmission, Failure == SupportSubmissionFailure {
    var preparedSubmission: SupportSubmission? {
        guard case let .success(submission) = self else { return nil }
        return submission
    }
}
