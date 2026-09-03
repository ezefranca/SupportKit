import Foundation

/// A frozen, redacted report. Retrying this value never recollects diagnostics
/// or changes the payload hash.
public struct PreparedSupportSubmission: Identifiable, Sendable {
    /// The stable report identifier and idempotency identity.
    public var id: UUID {
        submission.id
    }

    /// User content and diagnostics suitable for confirmation UI.
    public var preview: SupportPayloadPreview {
        .init(submission: submission)
    }

    let submission: SupportSubmission
    let ownerID: UUID
}
