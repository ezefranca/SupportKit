import Foundation

/// Presentation state for the standard support workflow.
public enum SupportFormPhase: Equatable {
    /// The user can edit the form.
    case editing
    /// The client is validating, collecting, and redacting content.
    case preparing
    /// A frozen report is awaiting confirmation.
    case reviewing
    /// The confirmed report is being written to the durable queue.
    case submitting
    /// The report is durable locally and may be delivered later.
    case queued(reportID: UUID)
    /// The receiver durably owns the report.
    case accepted(reportID: UUID, destinationURL: URL?)
    /// Preparation or queueing could not safely complete.
    case failed(message: String)
}
