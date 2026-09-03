import Foundation
import SupportKit

actor GatedUISubmissionStore: SupportSubmissionStore {
    private let backing = InMemorySupportSubmissionStore()
    private var enqueueContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasStarted = false
    private var isReleased = false

    func enqueue(_ item: QueuedSupportSubmission, capacity: Int) async throws {
        await waitForRelease()
        try await backing.enqueue(item, capacity: capacity)
    }

    func enqueueIfAbsent(
        _ item: QueuedSupportSubmission,
        duplicateSince date: Date,
        capacity: Int,
    ) async throws -> SupportStoreEnqueueResult {
        await waitForRelease()
        return try await backing.enqueueIfAbsent(
            item,
            duplicateSince: date,
            capacity: capacity,
        )
    }

    func waitUntilEnqueueStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseEnqueue() {
        isReleased = true
        enqueueContinuation?.resume()
        enqueueContinuation = nil
    }

    func dueSubmissions(
        in scope: SupportQueueScope,
        before date: Date,
        limit: Int,
    ) async -> [QueuedSupportSubmission] {
        await backing.dueSubmissions(in: scope, before: date, limit: limit)
    }

    func claimDueSubmissions(
        in scope: SupportQueueScope,
        before date: Date,
        limit: Int,
        leaseID: UUID,
        leaseExpiresAt: Date,
    ) async throws -> [QueuedSupportSubmission] {
        try await backing.claimDueSubmissions(
            in: scope,
            before: date,
            limit: limit,
            leaseID: leaseID,
            leaseExpiresAt: leaseExpiresAt,
        )
    }

    func nextReadyDate(in scope: SupportQueueScope) async -> Date? {
        await backing.nextReadyDate(in: scope)
    }

    func nextReadyDate(in scope: SupportQueueScope, relativeTo date: Date) async -> Date? {
        await backing.nextReadyDate(in: scope, relativeTo: date)
    }

    func pendingSubmission(
        in scope: SupportQueueScope,
        withFingerprint fingerprint: String,
        since date: Date,
    ) async -> QueuedSupportSubmission? {
        await backing.pendingSubmission(in: scope, withFingerprint: fingerprint, since: date)
    }

    func acceptedReceipt(
        in scope: SupportQueueScope,
        withFingerprint fingerprint: String,
        since date: Date,
    ) async -> SupportDeliveryReceipt? {
        await backing.acceptedReceipt(in: scope, withFingerprint: fingerprint, since: date)
    }

    func markAccepted(
        recordID: SupportQueueRecordID,
        receipt: SupportDeliveryReceipt,
        fingerprint: String,
        recordedAt: Date,
    ) async throws {
        try await backing.markAccepted(
            recordID: recordID,
            receipt: receipt,
            fingerprint: fingerprint,
            recordedAt: recordedAt,
        )
    }

    func markAccepted(
        recordID: SupportQueueRecordID,
        receipt: SupportDeliveryReceipt,
        fingerprint: String,
        leaseID: UUID,
        recordedAt: Date,
    ) async throws {
        try await backing.markAccepted(
            recordID: recordID,
            receipt: receipt,
            fingerprint: fingerprint,
            leaseID: leaseID,
            recordedAt: recordedAt,
        )
    }

    func markRetry(
        recordID: SupportQueueRecordID,
        attemptCount: Int,
        nextAttemptAt: Date,
        failure: String,
    ) async throws {
        await backing.markRetry(
            recordID: recordID,
            attemptCount: attemptCount,
            nextAttemptAt: nextAttemptAt,
            failure: failure,
        )
    }

    func markRetry(
        recordID: SupportQueueRecordID,
        leaseID: UUID,
        attemptCount: Int,
        nextAttemptAt: Date,
        failure: String,
    ) async throws {
        try await backing.markRetry(
            recordID: recordID,
            leaseID: leaseID,
            attemptCount: attemptCount,
            nextAttemptAt: nextAttemptAt,
            failure: failure,
        )
    }

    func markNeedsAttention(recordID: SupportQueueRecordID, failure: String) async throws {
        await backing.markNeedsAttention(recordID: recordID, failure: failure)
    }

    func markNeedsAttention(
        recordID: SupportQueueRecordID,
        leaseID: UUID,
        failure: String,
    ) async throws {
        try await backing.markNeedsAttention(
            recordID: recordID,
            leaseID: leaseID,
            failure: failure,
        )
    }

    func releaseLease(recordID: SupportQueueRecordID, leaseID: UUID) async {
        await backing.releaseLease(recordID: recordID, leaseID: leaseID)
    }

    func pendingCount(in scope: SupportQueueScope) async -> Int {
        await backing.pendingCount(in: scope)
    }

    func readyCount(in scope: SupportQueueScope) async -> Int {
        await backing.readyCount(in: scope)
    }

    func pruneReceipts(in scope: SupportQueueScope, olderThan date: Date) async {
        await backing.pruneReceipts(in: scope, olderThan: date)
    }

    private func waitForRelease() async {
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        if !isReleased {
            await withCheckedContinuation { continuation in
                enqueueContinuation = continuation
            }
        }
    }
}
