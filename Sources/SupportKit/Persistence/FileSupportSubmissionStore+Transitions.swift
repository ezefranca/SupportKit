import Foundation

public extension FileSupportSubmissionStore {
    func markAccepted(
        recordID: SupportQueueRecordID,
        receipt: SupportDeliveryReceipt,
        fingerprint: String,
        recordedAt: Date,
    ) async throws {
        guard SupportQueueScope.isValid(recordID.queueScope.identifier) else {
            throw SupportStoreError.cannotPersist
        }
        let key = try await encryptionKey()
        try withExclusiveLock {
            try markAccepted(
                recordID: recordID,
                receipt: receipt,
                fingerprint: fingerprint,
                recordedAt: recordedAt,
                using: key,
            )
        }
    }

    func markAccepted(
        recordID: SupportQueueRecordID,
        receipt: SupportDeliveryReceipt,
        fingerprint: String,
        leaseID _: UUID,
        recordedAt: Date,
    ) async throws {
        guard SupportQueueScope.isValid(recordID.queueScope.identifier) else {
            throw SupportStoreError.cannotPersist
        }
        // A valid remote acceptance is authoritative even if a local lease
        // expired while the response was in flight.
        try await markAccepted(
            recordID: recordID,
            receipt: receipt,
            fingerprint: fingerprint,
            recordedAt: recordedAt,
        )
    }

    func markRetry(
        recordID: SupportQueueRecordID,
        attemptCount: Int,
        nextAttemptAt: Date,
        failure: String,
    ) async throws {
        guard SupportQueueScope.isValid(recordID.queueScope.identifier) else {
            throw SupportStoreError.cannotPersist
        }
        let key = try await encryptionKey()
        try withExclusiveLock {
            guard var item = loadPendingItem(
                id: recordID.reportID,
                in: recordID.queueScope,
                using: key,
            ) else { return }
            applyRetry(
                to: &item,
                attemptCount: attemptCount,
                nextAttemptAt: nextAttemptAt,
                failure: failure,
            )
            try write(
                item,
                to: pendingURL(for: recordID.reportID, in: recordID.queueScope),
                using: key,
            )
        }
    }

    func markRetry(
        recordID: SupportQueueRecordID,
        leaseID: UUID,
        attemptCount: Int,
        nextAttemptAt: Date,
        failure: String,
    ) async throws {
        guard SupportQueueScope.isValid(recordID.queueScope.identifier) else {
            throw SupportStoreError.cannotPersist
        }
        let key = try await encryptionKey()
        try withExclusiveLock {
            guard var item = loadPendingItem(
                id: recordID.reportID,
                in: recordID.queueScope,
                using: key,
            ), item.leaseID == leaseID else {
                throw SupportStoreError.leaseLost
            }
            applyRetry(
                to: &item,
                attemptCount: attemptCount,
                nextAttemptAt: nextAttemptAt,
                failure: failure,
            )
            try write(
                item,
                to: pendingURL(for: recordID.reportID, in: recordID.queueScope),
                using: key,
            )
        }
    }

    func markNeedsAttention(recordID: SupportQueueRecordID, failure: String) async throws {
        guard SupportQueueScope.isValid(recordID.queueScope.identifier) else {
            throw SupportStoreError.cannotPersist
        }
        let key = try await encryptionKey()
        try withExclusiveLock {
            guard var item = loadPendingItem(
                id: recordID.reportID,
                in: recordID.queueScope,
                using: key,
            ) else { return }
            applyNeedsAttention(to: &item, failure: failure)
            try write(
                item,
                to: pendingURL(for: recordID.reportID, in: recordID.queueScope),
                using: key,
            )
        }
    }

    func markNeedsAttention(
        recordID: SupportQueueRecordID,
        leaseID: UUID,
        failure: String,
    ) async throws {
        guard SupportQueueScope.isValid(recordID.queueScope.identifier) else {
            throw SupportStoreError.cannotPersist
        }
        let key = try await encryptionKey()
        try withExclusiveLock {
            guard var item = loadPendingItem(
                id: recordID.reportID,
                in: recordID.queueScope,
                using: key,
            ), item.leaseID == leaseID else {
                throw SupportStoreError.leaseLost
            }
            applyNeedsAttention(to: &item, failure: failure)
            try write(
                item,
                to: pendingURL(for: recordID.reportID, in: recordID.queueScope),
                using: key,
            )
        }
    }

    func releaseLease(recordID: SupportQueueRecordID, leaseID: UUID) async {
        guard SupportQueueScope.isValid(recordID.queueScope.identifier) else { return }
        guard let key = try? await encryptionKey() else { return }
        try? withExclusiveLock {
            guard var item = loadPendingItem(
                id: recordID.reportID,
                in: recordID.queueScope,
                using: key,
            ), item.leaseID == leaseID else { return }
            item.leaseID = nil
            item.leaseExpiresAt = nil
            try write(
                item,
                to: pendingURL(for: recordID.reportID, in: recordID.queueScope),
                using: key,
            )
        }
    }

    func readyCount(in scope: SupportQueueScope) async -> Int {
        guard SupportQueueScope.isValid(scope.identifier), let key = try? await encryptionKey() else { return 0 }
        return (try? withExclusiveLock {
            removeAcceptedPending(from: loadPendingItems(using: key), using: key)
                .count { $0.queueScope == scope && $0.state == .ready }
        }) ?? 0
    }

    func pendingCount(in scope: SupportQueueScope) async -> Int {
        guard SupportQueueScope.isValid(scope.identifier), let key = try? await encryptionKey() else { return 0 }
        return (try? withExclusiveLock {
            removeAcceptedPending(from: loadPendingItems(using: key), using: key)
                .count { $0.queueScope == scope }
        }) ?? 0
    }

    func pruneReceipts(in scope: SupportQueueScope, olderThan date: Date) async {
        guard SupportQueueScope.isValid(scope.identifier), let key = try? await encryptionKey() else { return }
        try? withExclusiveLock {
            for stored in loadStoredReceipts(using: key)
                where stored.queueScope == scope && stored.recordedAt < date {
                removeIfPresent(receiptURL(for: stored.receipt.reportID, in: scope))
            }
        }
    }
}
