import Foundation

/// A receiver that atomically and idempotently accepts frozen reports.
public protocol SupportTransport: Sendable {
    /// Durably accepts a report. A successful return means the receiver owns
    /// eventual delivery and can safely deduplicate the idempotency key.
    ///
    /// - Parameter submission: The frozen, already-redacted payload.
    /// - Returns: A durable receipt whose report identifier matches `submission`.
    /// - Throws: ``SupportTransportError`` or a cancellation error when ownership is not confirmed.
    func submit(_ submission: SupportSubmission) async throws -> SupportDeliveryReceipt
}
