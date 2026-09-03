import Foundation

/// Aggregate outcomes from one bounded ``SupportClient/flush()`` call.
public struct SupportDeliveryReport: Equatable, Sendable {
    /// Reports durably accepted by the receiver.
    public var accepted: Int
    /// Reports persisted with a future retry date.
    public var retryScheduled: Int
    /// Reports retained for explicit operator or host attention.
    public var needsAttention: Int
    /// Ready reports still retained after the flush.
    public var remainingReady: Int

    /// Creates an aggregate delivery report.
    ///
    /// - Parameters:
    ///   - accepted: The number of reports accepted by the receiver.
    ///   - retryScheduled: The number of reports scheduled for another attempt.
    ///   - needsAttention: The number of reports retained for attention.
    ///   - remainingReady: The number of reports still in the automatic-delivery state.
    public init(
        accepted: Int = 0,
        retryScheduled: Int = 0,
        needsAttention: Int = 0,
        remainingReady: Int = 0,
    ) {
        self.accepted = accepted
        self.retryScheduled = retryScheduled
        self.needsAttention = needsAttention
        self.remainingReady = remainingReady
    }
}
