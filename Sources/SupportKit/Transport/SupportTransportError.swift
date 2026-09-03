import Foundation

/// A classified receiver failure that controls SupportKit's retry behavior.
public enum SupportTransportError: Error, Equatable, LocalizedError, Sendable {
    /// A transient failure that can be retried, optionally after a receiver-specified delay.
    case retryable(code: Int?, retryAfter: TimeInterval?, reason: String)
    /// A terminal failure that requires user or host-app attention.
    case permanent(code: Int?, reason: String)
    /// The receiver response did not satisfy the transport contract.
    case invalidResponse
    /// The encoded request exceeded the transport's payload limit.
    case payloadTooLarge

    /// A bounded explanation suitable for diagnostics and default status copy.
    public var errorDescription: String? {
        switch self {
        case let .retryable(_, _, reason), let .permanent(_, reason): reason
        case .invalidResponse: "The support receiver returned an invalid response."
        case .payloadTooLarge: "The support report is too large for the receiver."
        }
    }

    var safeReason: String {
        String((errorDescription ?? "Delivery failed.").prefix(500))
    }
}
