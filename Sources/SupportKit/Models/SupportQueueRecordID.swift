import Foundation

/// The complete identity of one durable queue record.
///
/// A report UUID is unique only inside its ``queueScope``. Stores use both
/// values for every identifier-based state transition.
public struct SupportQueueRecordID: Codable, Equatable, Hashable, Sendable {
    /// The configuration scope that owns the record.
    public let queueScope: SupportQueueScope
    /// The report UUID inside that scope.
    public let reportID: UUID

    /// Creates a complete scoped queue-record identifier.
    public init(queueScope: SupportQueueScope, reportID: UUID) {
        self.queueScope = queueScope
        self.reportID = reportID
    }
}
