import Foundation

/// The result of validation, redaction, and optional diagnostic collection.
public enum SupportPreparationResult: Sendable {
    /// A frozen report is ready for preview or queueing.
    case ready(PreparedSupportSubmission)
    /// The draft could not be prepared safely.
    case rejected(SupportSubmissionFailure)
}
