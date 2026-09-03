import Foundation

/// Retry, deduplication, and queue limits for delivery.
public struct DeliveryConfiguration: Sendable {
    private static let maximumAllowedBatchSize = 100
    private static let maximumAllowedHistoryInterval: TimeInterval = 365 * 24 * 60 * 60
    private static let maximumAllowedRetryDelay: TimeInterval = 7 * 24 * 60 * 60
    private static let maximumAllowedStoredSubmissions = 1000
    private static let maximumAllowedSubmissionBytes = 256 * 1024

    /// Whether submitting a report starts the in-process delivery worker automatically.
    public let automaticallyDelivers: Bool
    /// How far back pending reports and receipts participate in content deduplication, capped at one year.
    public let duplicateSuppressionInterval: TimeInterval
    /// The minimum delay before the first client-directed retry, capped at seven days.
    public let initialRetryDelay: TimeInterval
    /// The upper bound for exponential and server-directed retry delays, capped at seven days.
    public let maximumRetryDelay: TimeInterval
    /// The maximum number of reports retained in the queue, clamped to 1 through 1,000.
    public let maximumStoredSubmissions: Int
    /// The maximum reports attempted by one flush, clamped to 1 through 100.
    public let deliveryBatchSize: Int
    /// How long accepted receipts remain available for deduplication, capped at one year.
    public let receiptRetentionInterval: TimeInterval
    /// The largest encoded submission SupportKit will persist and attempt to deliver.
    public let maximumSubmissionBytes: Int
    /// How long another delivery worker must wait before reclaiming an abandoned report.
    public let deliveryLeaseDuration: TimeInterval

    /// Creates normalized queue and retry limits.
    ///
    /// Non-finite durations use their documented defaults. Durations and counts are clamped to safe ranges, and
    /// receipt retention is never shorter than duplicate suppression.
    ///
    /// - Parameters:
    ///   - automaticallyDelivers: Whether queueing starts the in-process worker.
    ///   - duplicateSuppressionInterval: The recent-content deduplication window, in seconds.
    ///   - initialRetryDelay: The minimum retry delay, in seconds.
    ///   - maximumRetryDelay: The maximum retry delay, in seconds.
    ///   - maximumStoredSubmissions: The queue's report capacity.
    ///   - deliveryBatchSize: The maximum attempts in one flush.
    ///   - receiptRetentionInterval: The accepted-receipt retention period, in seconds.
    ///   - maximumSubmissionBytes: The maximum encoded report size.
    ///   - deliveryLeaseDuration: The ownership lease for an in-flight delivery, in seconds.
    public init(
        automaticallyDelivers: Bool = true,
        duplicateSuppressionInterval: TimeInterval = 24 * 60 * 60,
        initialRetryDelay: TimeInterval = 5,
        maximumRetryDelay: TimeInterval = 6 * 60 * 60,
        maximumStoredSubmissions: Int = 100,
        deliveryBatchSize: Int = 10,
        receiptRetentionInterval: TimeInterval = 30 * 24 * 60 * 60,
        maximumSubmissionBytes: Int = 256 * 1024,
        deliveryLeaseDuration: TimeInterval = 5 * 60,
    ) {
        let safeDuplicateInterval = Self.finite(duplicateSuppressionInterval, fallback: 24 * 60 * 60)
        let safeInitialDelay = Self.finite(initialRetryDelay, fallback: 5)
        let safeMaximumDelay = Self.finite(maximumRetryDelay, fallback: 6 * 60 * 60)
        let safeReceiptInterval = Self.finite(receiptRetentionInterval, fallback: 30 * 24 * 60 * 60)
        let safeLeaseDuration = Self.finite(deliveryLeaseDuration, fallback: 5 * 60)

        self.automaticallyDelivers = automaticallyDelivers
        self.duplicateSuppressionInterval = min(max(0, safeDuplicateInterval), Self.maximumAllowedHistoryInterval)
        self.initialRetryDelay = min(max(1, safeInitialDelay), Self.maximumAllowedRetryDelay)
        self.maximumRetryDelay = min(
            max(self.initialRetryDelay, safeMaximumDelay),
            Self.maximumAllowedRetryDelay,
        )
        self.maximumStoredSubmissions = min(max(1, maximumStoredSubmissions), Self.maximumAllowedStoredSubmissions)
        self.deliveryBatchSize = min(max(1, deliveryBatchSize), Self.maximumAllowedBatchSize)
        self.receiptRetentionInterval = min(
            max(self.duplicateSuppressionInterval, safeReceiptInterval),
            Self.maximumAllowedHistoryInterval,
        )
        self.maximumSubmissionBytes = min(max(1024, maximumSubmissionBytes), Self.maximumAllowedSubmissionBytes)
        self.deliveryLeaseDuration = min(max(60, safeLeaseDuration), 24 * 60 * 60)
    }

    private static func finite(_ value: TimeInterval, fallback: TimeInterval) -> TimeInterval {
        value.isFinite ? value : fallback
    }
}
