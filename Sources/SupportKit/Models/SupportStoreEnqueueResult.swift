import Foundation

/// The atomic result of attempting to add a report to a submission store.
public enum SupportStoreEnqueueResult: Equatable, Sendable {
    /// The store durably queued the report under the returned stable identifier.
    case enqueued(reportID: UUID)
    /// An equivalent report is already pending under the returned identifier.
    case duplicatePending(reportID: UUID)
    /// An equivalent report was recently accepted by the receiver.
    case duplicateAccepted(SupportDeliveryReceipt)
}
