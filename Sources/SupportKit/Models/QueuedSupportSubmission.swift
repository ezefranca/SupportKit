import Foundation

/// A frozen report plus the durable state required for coordinated delivery.
public struct QueuedSupportSubmission: Codable, Equatable, Identifiable, Sendable {
    /// Whether automatic delivery may claim the report.
    public enum State: String, Codable, Sendable {
        /// The report is eligible when its retry date and lease allow delivery.
        case ready
        /// Automatic retry is paused until the host or user resubmits the report.
        case needsAttention
    }

    /// The stable report and idempotency identifier.
    public var id: UUID {
        submission.id
    }

    /// The complete scope-and-UUID identity used for durable state transitions.
    public var recordID: SupportQueueRecordID {
        .init(queueScope: queueScope, reportID: id)
    }

    /// The exact immutable payload represented by this queue record.
    public let submission: SupportSubmission
    /// The configuration scope that owns this record and every state transition applied to it.
    public let queueScope: SupportQueueScope
    /// The number of failed delivery attempts already persisted.
    public var attemptCount: Int
    /// The earliest date when a ready report may be attempted again.
    public var nextAttemptAt: Date
    /// A bounded, user-safe description of the most recent failure.
    public var lastFailure: String?
    /// Whether automatic delivery may retry the report.
    public var state: State
    /// The durable token of the worker currently delivering this report.
    public var leaseID: UUID?
    /// The point after which another worker may reclaim an abandoned lease.
    public var leaseExpiresAt: Date?

    /// Creates durable delivery state for a frozen report.
    ///
    /// - Parameters:
    ///   - submission: The exact immutable report payload.
    ///   - queueScope: The stable configuration scope that owns the report.
    ///   - attemptCount: The number of failed attempts, normalized to zero or greater.
    ///   - nextAttemptAt: The earliest next attempt, defaulting to the report creation date.
    ///   - lastFailure: A user-safe description of the latest failure.
    ///   - state: Whether automatic delivery may claim the report.
    ///   - leaseID: The current delivery worker's durable ownership token.
    ///   - leaseExpiresAt: The point after which another worker may reclaim the report.
    public init(
        submission: SupportSubmission,
        queueScope: SupportQueueScope,
        attemptCount: Int = 0,
        nextAttemptAt: Date? = nil,
        lastFailure: String? = nil,
        state: State = .ready,
        leaseID: UUID? = nil,
        leaseExpiresAt: Date? = nil,
    ) {
        self.submission = submission
        self.queueScope = queueScope
        self.attemptCount = max(0, attemptCount)
        self.nextAttemptAt = nextAttemptAt ?? submission.createdAt
        self.lastFailure = lastFailure
        self.state = state
        self.leaseID = leaseID
        self.leaseExpiresAt = leaseExpiresAt
    }
}
