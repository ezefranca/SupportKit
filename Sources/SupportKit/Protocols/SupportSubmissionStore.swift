import Foundation

/// Durable storage that atomically deduplicates and leases support reports.
///
/// Every record belongs to a ``SupportQueueScope``. Implementations must include that scope in all indexes, duplicate
/// checks, counts, claims, and identifier-based mutations. This permits multiple clients to share a store without one
/// client observing or delivering another client's records.
///
/// Implementations must serialize operations that inspect and mutate queue state. In particular,
/// ``enqueueIfAbsent(_:duplicateSince:capacity:)`` must combine duplicate lookup, attention-item requeueing, capacity
/// enforcement, and insertion in one transaction. Lease-aware mutations must reject a mismatched lease with
/// ``SupportStoreError/leaseLost``.
public protocol SupportSubmissionStore: Sendable {
    /// Persists or replaces a report while enforcing queue capacity.
    ///
    /// - Parameters:
    ///   - item: The complete frozen report and its delivery state.
    ///   - capacity: The maximum number of pending records in `item.queueScope`.
    /// - Throws: ``SupportStoreError/queueFull`` when a distinct item exceeds capacity, or a persistence error.
    func enqueue(_ item: QueuedSupportSubmission, capacity: Int) async throws

    /// Atomically resolves accepted and pending duplicates, or enqueues a new report.
    ///
    /// Every matching pending report participates regardless of age, so an offline report can never be duplicated.
    /// A matching ready report returns ``SupportStoreEnqueueResult/duplicatePending(reportID:)``. A matching
    /// needs-attention report is reset to ready under its original report and idempotency key, then returns
    /// ``SupportStoreEnqueueResult/enqueued(reportID:)``. A recent receipt returns
    /// ``SupportStoreEnqueueResult/duplicateAccepted(_:)``.
    ///
    /// - Parameters:
    ///   - item: The newly prepared report.
    ///   - date: The inclusive lower bound for accepted-receipt duplicate candidates.
    ///   - capacity: The maximum number of pending records.
    /// - Returns: The atomic enqueue or duplicate outcome.
    func enqueueIfAbsent(
        _ item: QueuedSupportSubmission,
        duplicateSince date: Date,
        capacity: Int,
    ) async throws -> SupportStoreEnqueueResult

    /// Returns, without claiming, the due ready reports in deterministic delivery order.
    ///
    /// - Parameters:
    ///   - date: The inclusive latest retry date to return.
    ///   - limit: The maximum number of reports to return.
    ///   - scope: The only configuration scope whose records may be returned.
    /// - Returns: Unleased ready reports in `scope` whose next-attempt date is no later than `date`.
    func dueSubmissions(
        in scope: SupportQueueScope,
        before date: Date,
        limit: Int,
    ) async -> [QueuedSupportSubmission]

    /// Atomically leases due reports so cooperating workers cannot send them concurrently.
    ///
    /// Implementations must persist the lease before returning. Reports with unexpired leases must be excluded, while
    /// expired leases may be replaced by the new lease.
    ///
    /// - Parameters:
    ///   - scope: The only configuration scope whose records may be claimed.
    ///   - date: The reference date used to select due reports and evaluate existing leases.
    ///   - limit: The maximum number of reports to claim.
    ///   - leaseID: The unique ownership token for this delivery worker.
    ///   - leaseExpiresAt: The point after which another worker may reclaim the reports.
    /// - Returns: The claimed reports including their persisted lease metadata.
    func claimDueSubmissions(
        in scope: SupportQueueScope,
        before date: Date,
        limit: Int,
        leaseID: UUID,
        leaseExpiresAt: Date,
    ) async throws -> [QueuedSupportSubmission]

    /// Returns the earliest date when a ready report in `scope` can next be claimed.
    func nextReadyDate(in scope: SupportQueueScope) async -> Date?

    /// Returns the next date at which a report can be claimed, including lease expiry.
    ///
    /// - Parameters:
    ///   - scope: The only configuration scope to inspect.
    ///   - date: The reference date used to evaluate current leases.
    /// - Returns: The earliest retry or active-lease expiry date, or `nil` when no report is ready.
    func nextReadyDate(in scope: SupportQueueScope, relativeTo date: Date) async -> Date?

    /// Returns the newest pending report with a matching fingerprint regardless of age.
    ///
    /// - Parameters:
    ///   - scope: The only configuration scope to inspect.
    ///   - fingerprint: The canonical content fingerprint to match.
    ///   - date: Retained for source compatibility; pending matches are never age-limited.
    /// - Returns: The newest matching pending report, including one that needs attention.
    func pendingSubmission(
        in scope: SupportQueueScope,
        withFingerprint fingerprint: String,
        since date: Date,
    ) async -> QueuedSupportSubmission?

    /// Returns the newest accepted receipt with a matching fingerprint inside a suppression window.
    ///
    /// - Parameters:
    ///   - scope: The only configuration scope to inspect.
    ///   - fingerprint: The canonical content fingerprint to match.
    ///   - date: The inclusive earliest acceptance date.
    /// - Returns: The newest matching durable receipt.
    func acceptedReceipt(
        in scope: SupportQueueScope,
        withFingerprint fingerprint: String,
        since date: Date,
    ) async -> SupportDeliveryReceipt?

    /// Atomically stores an acceptance receipt before removing its pending report.
    ///
    /// - Parameters:
    ///   - recordID: The complete scope-and-UUID identity of the pending report.
    ///   - receipt: An authoritative receiver receipt for `recordID.reportID`.
    ///   - fingerprint: The report fingerprint retained for accepted deduplication.
    ///   - recordedAt: The trusted local time used for receipt retention and duplicate-window evaluation.
    /// - Throws: A persistence error when the transition cannot be committed.
    func markAccepted(
        recordID: SupportQueueRecordID,
        receipt: SupportDeliveryReceipt,
        fingerprint: String,
        recordedAt: Date,
    ) async throws

    /// Stores an authoritative acceptance and removes its pending report after a leased delivery attempt.
    ///
    /// A valid remote acceptance remains authoritative if the local lease expired while its response was in flight.
    ///
    /// - Parameters:
    ///   - recordID: The complete scope-and-UUID identity of the pending report.
    ///   - receipt: An authoritative receiver receipt for `recordID.reportID`.
    ///   - fingerprint: The report fingerprint retained for accepted deduplication.
    ///   - leaseID: The delivery worker's ownership token.
    ///   - recordedAt: The trusted local time used for receipt retention and duplicate-window evaluation.
    /// - Throws: A persistence error when the transition cannot be committed.
    func markAccepted(
        recordID: SupportQueueRecordID,
        receipt: SupportDeliveryReceipt,
        fingerprint: String,
        leaseID: UUID,
        recordedAt: Date,
    ) async throws

    /// Persists retry state for an unleased report.
    ///
    /// - Parameters:
    ///   - recordID: The complete scope-and-UUID identity of the pending report.
    ///   - attemptCount: The total failed attempt count to persist.
    ///   - nextAttemptAt: The earliest next delivery date.
    ///   - failure: A bounded, user-safe failure reason.
    /// - Throws: A persistence error when the transition cannot be committed.
    func markRetry(
        recordID: SupportQueueRecordID,
        attemptCount: Int,
        nextAttemptAt: Date,
        failure: String,
    ) async throws

    /// Persists retry state only when `leaseID` owns the report, then clears its lease.
    ///
    /// - Parameters:
    ///   - recordID: The complete scope-and-UUID identity of the pending report.
    ///   - leaseID: The delivery worker's ownership token.
    ///   - attemptCount: The total failed attempt count to persist.
    ///   - nextAttemptAt: The earliest next delivery date.
    ///   - failure: A bounded, user-safe failure reason.
    /// - Throws: ``SupportStoreError/leaseLost`` for a mismatched lease, or a persistence error.
    func markRetry(
        recordID: SupportQueueRecordID,
        leaseID: UUID,
        attemptCount: Int,
        nextAttemptAt: Date,
        failure: String,
    ) async throws

    /// Retains an unleased report for operator or host-app attention.
    ///
    /// - Parameters:
    ///   - recordID: The complete scope-and-UUID identity of the pending report.
    ///   - failure: A bounded, user-safe failure reason.
    /// - Throws: A persistence error when the transition cannot be committed.
    func markNeedsAttention(recordID: SupportQueueRecordID, failure: String) async throws

    /// Retains a report for attention only when `leaseID` owns it, then clears its lease.
    ///
    /// - Parameters:
    ///   - recordID: The complete scope-and-UUID identity of the pending report.
    ///   - leaseID: The delivery worker's ownership token.
    ///   - failure: A bounded, user-safe failure reason.
    /// - Throws: ``SupportStoreError/leaseLost`` for a mismatched lease, or a persistence error.
    func markNeedsAttention(
        recordID: SupportQueueRecordID,
        leaseID: UUID,
        failure: String,
    ) async throws

    /// Clears a report's lease when `leaseID` is its current owner.
    ///
    /// - Parameters:
    ///   - recordID: The complete scope-and-UUID identity of the pending report.
    ///   - leaseID: The ownership token to release.
    func releaseLease(recordID: SupportQueueRecordID, leaseID: UUID) async

    /// All durably pending reports in `scope`, including reports requiring attention.
    func pendingCount(in scope: SupportQueueScope) async -> Int

    /// Reports in `scope` currently eligible for delivery or retry.
    func readyCount(in scope: SupportQueueScope) async -> Int

    /// Removes accepted receipts in `scope` older than `date`.
    ///
    /// - Parameters:
    ///   - scope: The only configuration scope whose receipts may be removed.
    ///   - date: The exclusive retention cutoff.
    func pruneReceipts(in scope: SupportQueueScope, olderThan date: Date) async
}
