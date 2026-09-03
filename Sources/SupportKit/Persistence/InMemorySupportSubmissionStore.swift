import Foundation

/// A deterministic store useful for previews, tests, and ephemeral tools.
public actor InMemorySupportSubmissionStore: SupportSubmissionStore {
    private var pending: [SupportQueueRecordID: QueuedSupportSubmission] = [:]
    private var receipts: [SupportQueueRecordID: StoredSupportReceipt] = [:]

    /// Creates an empty process-local queue.
    public init() {}

    public func enqueue(_ item: QueuedSupportSubmission, capacity: Int) throws {
        let key = item.recordID
        let scopedCount = pending.values.count { $0.queueScope == item.queueScope }
        guard scopedCount < capacity || pending[key] != nil else { throw SupportStoreError.queueFull }
        pending[key] = item
    }

    public func enqueueIfAbsent(
        _ item: QueuedSupportSubmission,
        duplicateSince date: Date,
        capacity: Int,
    ) async throws -> SupportStoreEnqueueResult {
        if let receipt = acceptedReceipt(
            in: item.queueScope,
            withFingerprint: item.submission.contentFingerprint,
            since: date,
        ) {
            return .duplicateAccepted(receipt)
        }
        if var duplicate = pendingSubmission(
            in: item.queueScope,
            withFingerprint: item.submission.contentFingerprint,
            since: .distantPast,
        ) {
            if duplicate.state == .needsAttention {
                duplicate.attemptCount = 0
                duplicate.nextAttemptAt = item.submission.createdAt
                duplicate.lastFailure = nil
                duplicate.state = .ready
                duplicate.leaseID = nil
                duplicate.leaseExpiresAt = nil
                pending[duplicate.recordID] = duplicate
                return .enqueued(reportID: duplicate.id)
            }
            return .duplicatePending(reportID: duplicate.id)
        }

        try enqueue(item, capacity: capacity)
        return .enqueued(reportID: item.id)
    }

    public func dueSubmissions(
        in scope: SupportQueueScope,
        before date: Date,
        limit: Int,
    ) -> [QueuedSupportSubmission] {
        guard limit > 0 else { return [] }
        return Array(
            pending.values
                .filter {
                    $0.queueScope == scope
                        && $0.state == .ready
                        && $0.nextAttemptAt <= date
                        && !Self.hasActiveLease($0, at: date)
                        && receipts[SupportQueueRecordID(queueScope: scope, reportID: $0.id)] == nil
                }
                .sorted(by: Self.deliveryOrder)
                .prefix(limit),
        )
    }

    public func claimDueSubmissions(
        in scope: SupportQueueScope,
        before date: Date,
        limit: Int,
        leaseID: UUID,
        leaseExpiresAt: Date,
    ) async throws -> [QueuedSupportSubmission] {
        guard limit > 0, leaseExpiresAt > date else { return [] }

        let keys = dueSubmissions(in: scope, before: date, limit: limit).map {
            SupportQueueRecordID(queueScope: scope, reportID: $0.id)
        }
        return keys.compactMap { key in
            guard var item = pending[key] else { return nil }
            item.leaseID = leaseID
            item.leaseExpiresAt = leaseExpiresAt
            pending[key] = item
            return item
        }
    }

    public func nextReadyDate(in scope: SupportQueueScope) async -> Date? {
        await nextReadyDate(in: scope, relativeTo: .now)
    }

    public func nextReadyDate(in scope: SupportQueueScope, relativeTo date: Date) async -> Date? {
        pending.values
            .filter {
                $0.queueScope == scope
                    && $0.state == .ready
                    && receipts[SupportQueueRecordID(queueScope: scope, reportID: $0.id)] == nil
            }
            .map { item in
                if Self.hasActiveLease(item, at: date), let leaseExpiresAt = item.leaseExpiresAt {
                    return max(item.nextAttemptAt, leaseExpiresAt)
                }
                return item.nextAttemptAt
            }
            .min()
    }

    public func pendingSubmission(
        in scope: SupportQueueScope,
        withFingerprint fingerprint: String,
        since _: Date,
    ) -> QueuedSupportSubmission? {
        pending.values
            .filter { $0.queueScope == scope && $0.submission.contentFingerprint == fingerprint }
            .max(by: Self.pendingRecencyOrder)
    }

    public func acceptedReceipt(
        in scope: SupportQueueScope,
        withFingerprint fingerprint: String,
        since date: Date,
    ) -> SupportDeliveryReceipt? {
        receipts.values
            .filter {
                $0.queueScope == scope
                    && $0.contentFingerprint == fingerprint
                    && $0.recordedAt >= date
            }
            .max(by: Self.receiptRecencyOrder)?
            .receipt
    }

    public func markAccepted(
        recordID: SupportQueueRecordID,
        receipt: SupportDeliveryReceipt,
        fingerprint: String,
        recordedAt: Date,
    ) throws {
        guard receipt.reportID == recordID.reportID else { throw SupportStoreError.cannotPersist }
        receipts[recordID] = .init(
            queueScope: recordID.queueScope,
            receipt: receipt,
            contentFingerprint: fingerprint,
            recordedAt: recordedAt,
        )
        pending[recordID] = nil
    }

    public func markAccepted(
        recordID: SupportQueueRecordID,
        receipt: SupportDeliveryReceipt,
        fingerprint: String,
        leaseID _: UUID,
        recordedAt: Date,
    ) async throws {
        try markAccepted(
            recordID: recordID,
            receipt: receipt,
            fingerprint: fingerprint,
            recordedAt: recordedAt,
        )
    }

    public func markRetry(
        recordID: SupportQueueRecordID,
        attemptCount: Int,
        nextAttemptAt: Date,
        failure: String,
    ) {
        guard var item = pending[recordID] else { return }
        item.attemptCount = max(0, attemptCount)
        item.nextAttemptAt = nextAttemptAt
        item.lastFailure = SupportTextSafety.boundedFailureReason(failure)
        item.state = .ready
        item.leaseID = nil
        item.leaseExpiresAt = nil
        pending[recordID] = item
    }

    public func markRetry(
        recordID: SupportQueueRecordID,
        leaseID: UUID,
        attemptCount: Int,
        nextAttemptAt: Date,
        failure: String,
    ) async throws {
        guard pending[recordID]?.leaseID == leaseID else { throw SupportStoreError.leaseLost }
        markRetry(
            recordID: recordID,
            attemptCount: attemptCount,
            nextAttemptAt: nextAttemptAt,
            failure: failure,
        )
    }

    public func markNeedsAttention(recordID: SupportQueueRecordID, failure: String) {
        guard var item = pending[recordID] else { return }
        item.lastFailure = SupportTextSafety.boundedFailureReason(failure)
        item.state = .needsAttention
        item.leaseID = nil
        item.leaseExpiresAt = nil
        pending[recordID] = item
    }

    public func markNeedsAttention(
        recordID: SupportQueueRecordID,
        leaseID: UUID,
        failure: String,
    ) async throws {
        guard pending[recordID]?.leaseID == leaseID else { throw SupportStoreError.leaseLost }
        markNeedsAttention(recordID: recordID, failure: failure)
    }

    public func releaseLease(recordID: SupportQueueRecordID, leaseID: UUID) async {
        guard var item = pending[recordID], item.leaseID == leaseID else { return }
        item.leaseID = nil
        item.leaseExpiresAt = nil
        pending[recordID] = item
    }

    public func readyCount(in scope: SupportQueueScope) -> Int {
        pending.values.count { $0.queueScope == scope && $0.state == .ready }
    }

    public func pendingCount(in scope: SupportQueueScope) async -> Int {
        pending.count { key, item in
            item.queueScope == scope && receipts[key] == nil
        }
    }

    public func pruneReceipts(in scope: SupportQueueScope, olderThan date: Date) {
        receipts = receipts.filter { key, value in
            key.queueScope != scope || value.recordedAt >= date
        }
    }

    private static func hasActiveLease(_ item: QueuedSupportSubmission, at date: Date) -> Bool {
        item.leaseID != nil && item.leaseExpiresAt.map { $0 > date } == true
    }

    private static func deliveryOrder(_ lhs: QueuedSupportSubmission, _ rhs: QueuedSupportSubmission) -> Bool {
        if lhs.nextAttemptAt == rhs.nextAttemptAt {
            if lhs.submission.createdAt == rhs.submission.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.submission.createdAt < rhs.submission.createdAt
        }
        return lhs.nextAttemptAt < rhs.nextAttemptAt
    }

    private static func pendingRecencyOrder(
        _ lhs: QueuedSupportSubmission,
        _ rhs: QueuedSupportSubmission,
    ) -> Bool {
        if lhs.submission.createdAt == rhs.submission.createdAt {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.submission.createdAt < rhs.submission.createdAt
    }

    private static func receiptRecencyOrder(_ lhs: StoredSupportReceipt, _ rhs: StoredSupportReceipt) -> Bool {
        if lhs.recordedAt == rhs.recordedAt {
            return lhs.receipt.reportID.uuidString < rhs.receipt.reportID.uuidString
        }
        return lhs.recordedAt < rhs.recordedAt
    }
}
