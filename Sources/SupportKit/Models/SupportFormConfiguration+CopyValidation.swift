import Foundation

extension SupportFormConfiguration {
    func validateStaticCopy() throws {
        let values: [(name: String, value: String)] = [
            ("title", title),
            ("introduction", introduction),
            ("subjectLabel", subjectLabel),
            ("subjectPrompt", subjectPrompt),
            ("messageLabel", messageLabel),
            ("messagePrompt", messagePrompt),
            ("detailsSectionTitle", detailsSectionTitle),
            ("privacySectionTitle", privacySectionTitle),
            ("diagnosticsOptInLabel", diagnosticsOptInLabel),
            ("diagnosticsOptInHelp", diagnosticsOptInHelp),
            ("previewTitle", previewTitle),
            ("previewReportSectionTitle", previewReportSectionTitle),
            ("previewSubjectLabel", previewSubjectLabel),
            ("previewResponsesSectionTitle", previewResponsesSectionTitle),
            ("previewDiagnosticsSectionTitle", previewDiagnosticsSectionTitle),
            ("potentiallyIdentifyingValueLabel", potentiallyIdentifyingValueLabel),
            ("previewConfirmationTitle", previewConfirmationTitle),
            ("previewCancellationTitle", previewCancellationTitle),
            ("submitButtonTitle", submitButtonTitle),
            ("queuedMessage", queuedMessage),
            ("deliveredMessage", deliveredMessage),
            ("viewDestinationTitle", viewDestinationTitle),
            ("reportIdentifierAccessibilityLabel", reportIdentifierAccessibilityLabel),
        ]
        for value in values where !Self.isSafeStaticCopy(value.value) {
            throw SupportConfigurationError.invalidFormCopy(value.name)
        }
    }

    static func isSafeStaticCopy(_ value: String) -> Bool {
        value.utf8.count <= 16 * 1024
            && value.count <= 4000
            && SupportTextSafety.isWireSafe(value)
    }
}
