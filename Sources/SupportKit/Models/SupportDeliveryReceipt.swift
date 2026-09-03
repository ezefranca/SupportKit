import Foundation

/// Proof that a receiver durably owns a report.
public struct SupportDeliveryReceipt: Codable, Equatable, Sendable {
    /// The receiver's known delivery state when it returns the receipt.
    public enum Status: String, Codable, Sendable {
        /// The receiver durably accepted the report and now owns delivery.
        case accepted
        /// The receiver has already delivered the report to its destination.
        case delivered
        /// The receiver had already accepted the same idempotency key and payload.
        case duplicate
    }

    /// The accepted report identifier.
    public let reportID: UUID
    /// The receiver's known delivery state.
    public let status: Status
    /// When the receiver first accepted ownership.
    public let acceptedAt: Date
    /// A destination URL when delivery is already known.
    public let destinationURL: URL?
    /// A receiver-defined destination reference, such as a ticket key.
    public let destinationReference: String?

    /// Creates a durable receiver receipt.
    ///
    /// - Parameters:
    ///   - reportID: The report identifier accepted by the receiver.
    ///   - status: The receiver's current delivery state.
    ///   - acceptedAt: When the receiver first accepted the report.
    ///   - destinationURL: A trusted destination URL, when known.
    ///   - destinationReference: A provider-neutral ticket or report reference, when known.
    public init(
        reportID: UUID,
        status: Status,
        acceptedAt: Date,
        destinationURL: URL? = nil,
        destinationReference: String? = nil,
    ) {
        self.reportID = reportID
        self.status = status
        self.acceptedAt = acceptedAt
        self.destinationURL = destinationURL
        self.destinationReference = destinationReference
    }
}
