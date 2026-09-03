import Foundation

/// Copy and field definitions for the standard SwiftUI support form.
public struct SupportFormConfiguration: Sendable {
    private static let maximumAdditionalFieldCount = 24
    private static let maximumConfiguredDefaultBytes = 256 * 1024
    private static let maximumFieldLabelLength = 200
    private static let maximumMessageLength = 10000
    private static let maximumPickerOptionCount = 100
    private static let maximumSubjectLength = 120

    /// The heading shown above the support form.
    public let title: String
    /// Introductory copy explaining the form and its privacy behavior.
    public let introduction: String
    /// The visible and accessible label for the subject field.
    public let subjectLabel: String
    /// Placeholder text for the subject field.
    public let subjectPrompt: String
    /// The maximum accepted subject length in characters, capped at 120.
    public let subjectMaximumLength: Int
    /// The visible and accessible label for the message field.
    public let messageLabel: String
    /// Placeholder text for the message field.
    public let messagePrompt: String
    /// The maximum accepted message length in characters, capped at 10,000.
    public let messageMaximumLength: Int
    /// Validated app-specific fields rendered after the subject and message.
    public let additionalFields: [SupportFormField]
    /// The heading above app-specific fields.
    public let detailsSectionTitle: String
    /// The heading above diagnostic consent controls.
    public let privacySectionTitle: String
    /// The label for the diagnostic-consent toggle.
    public let diagnosticsOptInLabel: String
    /// Supporting copy explaining diagnostic consent and review.
    public let diagnosticsOptInHelp: String
    /// Whether a newly created form initially opts into diagnostics.
    public let diagnosticsInitiallyIncluded: Bool
    /// Whether the ready-made flow requires confirmation of the frozen payload.
    public let showsPayloadPreview: Bool
    /// The title of the payload-review screen.
    public let previewTitle: String
    /// The heading above the previewed title and message.
    public let previewReportSectionTitle: String
    /// The label for the final report title in the preview.
    public let previewSubjectLabel: String
    /// The heading above previewed additional-field responses.
    public let previewResponsesSectionTitle: String
    /// The heading above previewed diagnostics.
    public let previewDiagnosticsSectionTitle: String
    /// The annotation shown beside a potentially identifying diagnostic.
    public let potentiallyIdentifyingValueLabel: String
    /// The confirmation action title in the payload preview.
    public let previewConfirmationTitle: String
    /// The cancellation action title in the payload preview.
    public let previewCancellationTitle: String
    /// The primary form action title.
    public let submitButtonTitle: String
    /// The status message shown after durable local queueing.
    public let queuedMessage: String
    /// The status message shown after remote acceptance.
    public let deliveredMessage: String
    /// The action title for opening a trusted destination URL.
    public let viewDestinationTitle: String
    /// Localizable text announced before the queued report's identifier.
    public let reportIdentifierAccessibilityLabel: String
    /// A localizable formatter for validation and persistence failures.
    public let failureMessage: @Sendable (SupportSubmissionFailure) -> String

    /// Creates all fields, copy, accessibility text, and preview behavior for a support form.
    ///
    /// Length limits are clamped to the built-in receiver contract. Call ``validate()`` directly to validate an
    /// independent form value; ``SupportConfiguration`` validates it automatically.
    ///
    /// - Parameters:
    ///   - title: The form heading.
    ///   - introduction: Introductory privacy and usage copy.
    ///   - subjectLabel: The visible and accessible subject label.
    ///   - subjectPrompt: Placeholder text for the subject field.
    ///   - subjectMaximumLength: The maximum subject length in characters.
    ///   - messageLabel: The visible and accessible message label.
    ///   - messagePrompt: Placeholder text for the message field.
    ///   - messageMaximumLength: The maximum message length in characters.
    ///   - additionalFields: App-specific fields shown after the core fields.
    ///   - detailsSectionTitle: The app-specific field section heading.
    ///   - privacySectionTitle: The diagnostic-consent section heading.
    ///   - diagnosticsOptInLabel: The diagnostic-consent toggle label.
    ///   - diagnosticsOptInHelp: Supporting consent and preview copy.
    ///   - diagnosticsInitiallyIncluded: Whether diagnostics initially appear opted in.
    ///   - showsPayloadPreview: Whether confirmation of the frozen payload is required.
    ///   - previewTitle: The payload-review screen title.
    ///   - previewReportSectionTitle: The preview's core report section heading.
    ///   - previewSubjectLabel: The preview's final-title label.
    ///   - previewResponsesSectionTitle: The preview's additional-response heading.
    ///   - previewDiagnosticsSectionTitle: The preview's diagnostic heading.
    ///   - potentiallyIdentifyingValueLabel: The potentially identifying value annotation.
    ///   - previewConfirmationTitle: The preview confirmation action title.
    ///   - previewCancellationTitle: The preview cancellation action title.
    ///   - submitButtonTitle: The primary form action title.
    ///   - queuedMessage: The durable local queue status message.
    ///   - deliveredMessage: The remote acceptance status message.
    ///   - viewDestinationTitle: The action title for opening a trusted destination URL.
    ///   - reportIdentifierAccessibilityLabel: Localizable text announced before a report identifier.
    ///   - failureMessage: A localizable, sendable formatter for app-facing submission failures.
    public init(
        title: String = "Contact Support",
        introduction: String = "Tell us what happened. We’ll include only the technical details you approve below.",
        subjectLabel: String = "Subject",
        subjectPrompt: String = "A short summary",
        subjectMaximumLength: Int = 120,
        messageLabel: String = "Message",
        messagePrompt: String = "What were you doing, and what did you expect?",
        messageMaximumLength: Int = 10000,
        additionalFields: [SupportFormField] = SupportFormConfiguration.defaultFields,
        detailsSectionTitle: String = "Details",
        privacySectionTitle: String = "Privacy",
        diagnosticsOptInLabel: String = "Include technical diagnostics",
        diagnosticsOptInHelp: String = "You’ll review the exact diagnostics before the report is saved.",
        diagnosticsInitiallyIncluded: Bool = false,
        showsPayloadPreview: Bool = true,
        previewTitle: String = "Review Report",
        previewReportSectionTitle: String = "Report",
        previewSubjectLabel: String = "Title",
        previewResponsesSectionTitle: String = "Your details",
        previewDiagnosticsSectionTitle: String = "Technical diagnostics",
        potentiallyIdentifyingValueLabel: String = "May identify your environment",
        previewConfirmationTitle: String = "Confirm & Send",
        previewCancellationTitle: String = "Keep Editing",
        submitButtonTitle: String = "Send to Support",
        queuedMessage: String = "Saved. We’ll send this report when a connection is available.",
        deliveredMessage: String = "Your report was sent. Thank you.",
        viewDestinationTitle: String = "View destination",
        reportIdentifierAccessibilityLabel: String = "Report identifier",
        failureMessage: @escaping @Sendable (SupportSubmissionFailure) -> String = { $0.localizedDescription },
    ) {
        self.title = title
        self.introduction = introduction
        self.subjectLabel = subjectLabel
        self.subjectPrompt = subjectPrompt
        self.subjectMaximumLength = min(max(1, subjectMaximumLength), Self.maximumSubjectLength)
        self.messageLabel = messageLabel
        self.messagePrompt = messagePrompt
        self.messageMaximumLength = min(max(1, messageMaximumLength), Self.maximumMessageLength)
        self.additionalFields = additionalFields
        self.detailsSectionTitle = detailsSectionTitle
        self.privacySectionTitle = privacySectionTitle
        self.diagnosticsOptInLabel = diagnosticsOptInLabel
        self.diagnosticsOptInHelp = diagnosticsOptInHelp
        self.diagnosticsInitiallyIncluded = diagnosticsInitiallyIncluded
        self.showsPayloadPreview = showsPayloadPreview
        self.previewTitle = previewTitle
        self.previewReportSectionTitle = previewReportSectionTitle
        self.previewSubjectLabel = previewSubjectLabel
        self.previewResponsesSectionTitle = previewResponsesSectionTitle
        self.previewDiagnosticsSectionTitle = previewDiagnosticsSectionTitle
        self.potentiallyIdentifyingValueLabel = potentiallyIdentifyingValueLabel
        self.previewConfirmationTitle = previewConfirmationTitle
        self.previewCancellationTitle = previewCancellationTitle
        self.submitButtonTitle = submitButtonTitle
        self.queuedMessage = queuedMessage
        self.deliveredMessage = deliveredMessage
        self.viewDestinationTitle = viewDestinationTitle
        self.reportIdentifierAccessibilityLabel = reportIdentifierAccessibilityLabel
        self.failureMessage = failureMessage
    }

    /// The standard required topic picker used when no app-specific fields are supplied.
    public static let defaultFields: [SupportFormField] = [
        SupportFormField(
            id: "category",
            label: "Topic",
            kind: .picker(options: [
                .init(id: "problem", label: "Something isn’t working"),
                .init(id: "question", label: "I have a question"),
                .init(id: "idea", label: "I have an idea"),
            ]),
            isRequired: true,
            maximumLength: 80,
            defaultValue: "problem",
        ),
    ]

    /// Validates field identifiers, picker options, defaults, and length constraints.
    ///
    /// - Throws: ``SupportConfigurationError`` describing the first invalid field definition.
    public func validate() throws {
        try validateStaticCopy()
        guard additionalFields.count <= Self.maximumAdditionalFieldCount else {
            throw SupportConfigurationError.tooManyFormFields(maximum: Self.maximumAdditionalFieldCount)
        }
        let reserved = Set(["subject", "message", "diagnostics"])
        var identifiers = Set<String>()

        for field in additionalFields {
            guard SupportIdentifierValidator.isValid(field.id) else {
                throw SupportConfigurationError.invalidFieldIdentifier(field.id)
            }
            guard !reserved.contains(field.id) else {
                throw SupportConfigurationError.reservedFieldIdentifier(field.id)
            }
            guard identifiers.insert(field.id).inserted else {
                throw SupportConfigurationError.duplicateFieldIdentifier(field.id)
            }
            try Self.validateDefinition(of: field)
        }
    }

    private static func validateDefinition(of field: SupportFormField) throws {
        guard isValidRenderedLabel(field.label) else {
            throw SupportConfigurationError.invalidFieldLabel(field.id)
        }
        guard field.prompt.map(isSafeStaticCopy) != false,
              field.help.map(isSafeStaticCopy) != false
        else {
            throw SupportConfigurationError.invalidFieldSupportingText(field.id)
        }
        if let maximumLength = field.maximumLength, maximumLength < 0 {
            throw SupportConfigurationError.invalidFieldMaximumLength(field.id)
        }
        guard field.defaultValue.utf8.count <= maximumConfiguredDefaultBytes,
              SupportTextSafety.isWireSafe(field.defaultValue),
              field.maximumLength.map({ field.defaultValue.count <= $0 }) != false
        else {
            throw SupportConfigurationError.invalidFieldDefaultValue(field.id)
        }
        if case .toggle = field.kind,
           !["", "true", "false"].contains(field.defaultValue) {
            throw SupportConfigurationError.invalidFieldDefaultValue(field.id)
        }
        if case .toggle = field.kind {
            guard isValidRenderedLabel(field.toggleTrueLabel),
                  isValidRenderedLabel(field.toggleFalseLabel)
            else {
                throw SupportConfigurationError.invalidFieldLabel(field.id)
            }
        }
        try validatePicker(field)
    }

    private static func validatePicker(_ field: SupportFormField) throws {
        guard case let .picker(options) = field.kind else { return }
        guard !options.isEmpty else {
            throw SupportConfigurationError.emptyPickerOptions(field.id)
        }
        guard options.count <= Self.maximumPickerOptionCount else {
            throw SupportConfigurationError.tooManyPickerOptions(
                field: field.id,
                maximum: Self.maximumPickerOptionCount,
            )
        }

        var optionIdentifiers = Set<String>()
        for option in options {
            guard SupportIdentifierValidator.isValid(option.id) else {
                throw SupportConfigurationError.invalidPickerOptionIdentifier(
                    field: field.id,
                    option: option.id,
                )
            }
            guard Self.isValidRenderedLabel(option.label) else {
                throw SupportConfigurationError.invalidPickerOptionLabel(
                    field: field.id,
                    option: option.id,
                )
            }
            guard optionIdentifiers.insert(option.id).inserted else {
                throw SupportConfigurationError.duplicatePickerOptionIdentifier(
                    field: field.id,
                    option: option.id,
                )
            }
        }
        guard field.defaultValue.isEmpty || optionIdentifiers.contains(field.defaultValue) else {
            throw SupportConfigurationError.invalidPickerDefaultValue(
                field: field.id,
                value: field.defaultValue,
            )
        }
    }

    private static func isValidRenderedLabel(_ label: String) -> Bool {
        guard label.utf8.count <= 16 * 1024 else { return false }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed == label
            && label.count <= maximumFieldLabelLength
            && SupportTextSafety.isWireSafe(label)
    }
}
