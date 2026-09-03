import Foundation
@testable import SupportKit
import Testing

@Suite("Submission store atomicity and leases")
struct SupportSubmissionStoreAtomicityTests {
    private let firstLeaseID = UUID(uuid: (
        0x10, 0x00, 0x00, 0x00,
        0x00, 0x00,
        0x40, 0x00,
        0x80, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    ))
    private let secondLeaseID = UUID(uuid: (
        0x20, 0x00, 0x00, 0x00,
        0x00, 0x00,
        0x40, 0x00,
        0x80, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
    ))

    @Test
    func `concurrent atomic enqueue coalesces matching fingerprints with different IDs`() async {
        // Arrange
        let store = InMemorySupportSubmissionStore()
        let first = QueuedSupportSubmission(submission: SupportKitTestFixture.submission())
        let second = QueuedSupportSubmission(submission: SupportKitTestFixture.submission(
            id: SupportKitTestFixture.secondReportID,
        ))

        // Act
        async let firstResult = store.enqueueIfAbsent(
            first,
            duplicateSince: .distantPast,
            capacity: 10,
        )
        async let secondResult = store.enqueueIfAbsent(
            second,
            duplicateSince: .distantPast,
            capacity: 10,
        )
        let results = try? await [firstResult, secondResult]

        // Assert
        let unwrappedResults = results ?? []
        #expect(unwrappedResults.count(where: \SupportStoreEnqueueResult.isEnqueued) == 1)
        #expect(unwrappedResults.count(where: \SupportStoreEnqueueResult.isDuplicatePending) == 1)
        #expect(await store.readyCount() == 1)
    }

    @Test
    func `an active lease excludes a report until its expiry`() async throws {
        // Arrange
        let store = InMemorySupportSubmissionStore()
        let item = QueuedSupportSubmission(submission: SupportKitTestFixture.submission())
        let leaseExpiry = SupportKitTestFixture.date.addingTimeInterval(60)
        try await store.enqueue(item, capacity: 10)

        // Act
        let firstClaim = try await store.claimDueSubmissions(
            before: SupportKitTestFixture.date,
            limit: 1,
            leaseID: firstLeaseID,
            leaseExpiresAt: leaseExpiry,
        )
        let overlappingClaim = try await store.claimDueSubmissions(
            before: SupportKitTestFixture.date,
            limit: 1,
            leaseID: secondLeaseID,
            leaseExpiresAt: leaseExpiry,
        )
        let nextReadyDate = await store.nextReadyDate(relativeTo: SupportKitTestFixture.date)
        let claimAfterExpiry = try await store.claimDueSubmissions(
            before: leaseExpiry,
            limit: 1,
            leaseID: secondLeaseID,
            leaseExpiresAt: leaseExpiry.addingTimeInterval(60),
        )

        // Assert
        #expect(firstClaim.map(\.id) == [item.id])
        #expect(firstClaim.first?.leaseID == firstLeaseID)
        #expect(firstClaim.first?.leaseExpiresAt == leaseExpiry)
        #expect(overlappingClaim.isEmpty)
        #expect(nextReadyDate == leaseExpiry)
        #expect(claimAfterExpiry.map(\.id) == [item.id])
        #expect(claimAfterExpiry.first?.leaseID == secondLeaseID)
    }

    @Test
    func `only the lease owner can schedule a retry and a successful update clears the lease`() async throws {
        // Arrange
        let store = InMemorySupportSubmissionStore()
        let item = QueuedSupportSubmission(submission: SupportKitTestFixture.submission())
        let leaseExpiry = SupportKitTestFixture.date.addingTimeInterval(60)
        let retryDate = leaseExpiry.addingTimeInterval(30)
        try await store.enqueue(item, capacity: 10)
        _ = try await store.claimDueSubmissions(
            before: SupportKitTestFixture.date,
            limit: 1,
            leaseID: firstLeaseID,
            leaseExpiresAt: leaseExpiry,
        )

        // Act / Assert
        await #expect(throws: SupportStoreError.leaseLost) {
            try await store.markRetry(
                id: item.id,
                leaseID: secondLeaseID,
                attemptCount: 1,
                nextAttemptAt: retryDate,
                failure: "Offline",
            )
        }
        try await store.markRetry(
            id: item.id,
            leaseID: firstLeaseID,
            attemptCount: 1,
            nextAttemptAt: retryDate,
            failure: "Offline",
        )
        let persisted = await store.pendingSubmission(
            withFingerprint: item.submission.contentFingerprint,
            since: .distantPast,
        )
        #expect(persisted?.attemptCount == 1)
        #expect(persisted?.nextAttemptAt == retryDate)
        #expect(persisted?.leaseID == nil)
        #expect(persisted?.leaseExpiresAt == nil)
    }

    @Test
    func `release ignores a different worker and succeeds for the lease owner`() async throws {
        // Arrange
        let store = InMemorySupportSubmissionStore()
        let item = QueuedSupportSubmission(submission: SupportKitTestFixture.submission())
        try await store.enqueue(item, capacity: 10)
        _ = try await store.claimDueSubmissions(
            before: SupportKitTestFixture.date,
            limit: 1,
            leaseID: firstLeaseID,
            leaseExpiresAt: SupportKitTestFixture.date.addingTimeInterval(60),
        )

        // Act
        await store.releaseLease(id: item.id, leaseID: secondLeaseID)
        let afterWrongWorker = await store.dueSubmissions(before: SupportKitTestFixture.date, limit: 1)
        await store.releaseLease(id: item.id, leaseID: firstLeaseID)
        let afterOwner = await store.dueSubmissions(before: SupportKitTestFixture.date, limit: 1)

        // Assert
        #expect(afterWrongWorker.isEmpty)
        #expect(afterOwner.map(\.id) == [item.id])
    }
}

private extension SupportStoreEnqueueResult {
    var isEnqueued: Bool {
        if case .enqueued = self {
            true
        } else {
            false
        }
    }

    var isDuplicatePending: Bool {
        if case .duplicatePending = self {
            true
        } else {
            false
        }
    }
}
