import Foundation

/// The frozen, redacted user content and diagnostics that will be queued.
/// Protocol metadata such as IDs, timestamps, labels, and hashes is omitted.
public struct SupportPayloadPreview: Equatable, Sendable {
    /// The final report title.
    public let title: String
    /// The final free-form message.
    public let message: String
    /// Rendered additional-field responses.
    public let responses: [SupportFieldResponse]
    /// Opted-in diagnostics with sensitivity annotations.
    public let diagnostics: [SupportDiagnostic]

    init(submission: SupportSubmission) {
        title = submission.title
        message = submission.message
        responses = submission.responses
        diagnostics = submission.diagnostics
    }
}
