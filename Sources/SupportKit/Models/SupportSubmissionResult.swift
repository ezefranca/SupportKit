import Foundation

/// The nonthrowing app-facing result of a queue request.
public enum SupportSubmissionResult: Equatable, Sendable {
    /// A new report is durable in the local queue.
    case queued(reportID: UUID)
    /// Matching content is already pending locally.
    case duplicatePending(reportID: UUID)
    /// Matching content was recently accepted by the receiver.
    case duplicateAccepted(SupportDeliveryReceipt)
    /// The report could not be validated or durably stored.
    case rejected(SupportSubmissionFailure)
}
