import Foundation
@testable import SupportKit

extension SupportSubmissionStore {
    func dueSubmissions(before date: Date, limit: Int) async -> [QueuedSupportSubmission] {
        await dueSubmissions(in: SupportKitTestFixture.queueScope, before: date, limit: limit)
    }

    func claimDueSubmissions(
        before date: Date,
        limit: Int,
        leaseID: UUID,
        leaseExpiresAt: Date,
    ) async throws -> [QueuedSupportSubmission] {
        try await claimDueSubmissions(
            in: SupportKitTestFixture.queueScope,
            before: date,
            limit: limit,
            leaseID: leaseID,
            leaseExpiresAt: leaseExpiresAt,
        )
    }

    func nextReadyDate() async -> Date? {
        await nextReadyDate(in: SupportKitTestFixture.queueScope)
    }

    func nextReadyDate(relativeTo date: Date) async -> Date? {
        await nextReadyDate(in: SupportKitTestFixture.queueScope, relativeTo: date)
    }

    func pendingSubmission(
        withFingerprint fingerprint: String,
        since date: Date,
    ) async -> QueuedSupportSubmission? {
        await pendingSubmission(
            in: SupportKitTestFixture.queueScope,
            withFingerprint: fingerprint,
            since: date,
        )
    }

    func acceptedReceipt(
        withFingerprint fingerprint: String,
        since date: Date,
    ) async -> SupportDeliveryReceipt? {
        await acceptedReceipt(
            in: SupportKitTestFixture.queueScope,
            withFingerprint: fingerprint,
            since: date,
        )
    }

    func markAccepted(
        id: UUID,
        receipt: SupportDeliveryReceipt,
        fingerprint: String,
        recordedAt: Date,
    ) async throws {
        try await markAccepted(
            recordID: .init(queueScope: SupportKitTestFixture.queueScope, reportID: id),
            receipt: receipt,
            fingerprint: fingerprint,
            recordedAt: recordedAt,
        )
    }

    func markAccepted(
        id: UUID,
        receipt: SupportDeliveryReceipt,
        fingerprint: String,
        leaseID: UUID,
        recordedAt: Date,
    ) async throws {
        try await markAccepted(
            recordID: .init(queueScope: SupportKitTestFixture.queueScope, reportID: id),
            receipt: receipt,
            fingerprint: fingerprint,
            leaseID: leaseID,
            recordedAt: recordedAt,
        )
    }

    func markRetry(
        id: UUID,
        attemptCount: Int,
        nextAttemptAt: Date,
        failure: String,
    ) async throws {
        try await markRetry(
            recordID: .init(queueScope: SupportKitTestFixture.queueScope, reportID: id),
            attemptCount: attemptCount,
            nextAttemptAt: nextAttemptAt,
            failure: failure,
        )
    }

    func markRetry(
        id: UUID,
        leaseID: UUID,
        attemptCount: Int,
        nextAttemptAt: Date,
        failure: String,
    ) async throws {
        try await markRetry(
            recordID: .init(queueScope: SupportKitTestFixture.queueScope, reportID: id),
            leaseID: leaseID,
            attemptCount: attemptCount,
            nextAttemptAt: nextAttemptAt,
            failure: failure,
        )
    }

    func markNeedsAttention(id: UUID, failure: String) async throws {
        try await markNeedsAttention(
            recordID: .init(queueScope: SupportKitTestFixture.queueScope, reportID: id),
            failure: failure,
        )
    }

    func markNeedsAttention(id: UUID, leaseID: UUID, failure: String) async throws {
        try await markNeedsAttention(
            recordID: .init(queueScope: SupportKitTestFixture.queueScope, reportID: id),
            leaseID: leaseID,
            failure: failure,
        )
    }

    func releaseLease(id: UUID, leaseID: UUID) async {
        await releaseLease(
            recordID: .init(queueScope: SupportKitTestFixture.queueScope, reportID: id),
            leaseID: leaseID,
        )
    }

    func pendingCount() async -> Int {
        await pendingCount(in: SupportKitTestFixture.queueScope)
    }

    func readyCount() async -> Int {
        await readyCount(in: SupportKitTestFixture.queueScope)
    }

    func pruneReceipts(olderThan date: Date) async {
        await pruneReceipts(in: SupportKitTestFixture.queueScope, olderThan: date)
    }
}
