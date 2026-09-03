import Foundation

/// A bounded lifecycle event emitted by ``SupportClient/events()``.
public enum SupportDeliveryEvent: Equatable, Sendable {
    /// A report was written to durable local storage.
    case queued(reportID: UUID)
    /// The receiver durably accepted a report.
    case accepted(SupportDeliveryReceipt)
    /// A transient failure persisted a future delivery attempt.
    case retryScheduled(reportID: UUID, attempt: Int, nextAttemptAt: Date)
    /// Automatic retry stopped because operator or host action is needed.
    case needsAttention(reportID: UUID, reason: String)
}
