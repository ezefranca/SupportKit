import Foundation
@testable import SupportKit
import Testing

@Suite("Local receipt observation")
struct SupportReceiptObservationTests {
    @Test
    func `deduplication and pruning use local observation rather than receiver time`() async throws {
        // Arrange
        let store = InMemorySupportSubmissionStore()
        let receipt = SupportKitTestFixture.receipt(acceptedAt: .distantPast)
        let fingerprint = String(repeating: "a", count: 64)
        try await store.markAccepted(
            id: receipt.reportID,
            receipt: receipt,
            fingerprint: fingerprint,
            recordedAt: SupportKitTestFixture.date,
        )

        // Act
        await store.pruneReceipts(olderThan: SupportKitTestFixture.date.addingTimeInterval(-1))
        let retained = await store.acceptedReceipt(
            withFingerprint: fingerprint,
            since: SupportKitTestFixture.date.addingTimeInterval(-1),
        )
        await store.pruneReceipts(olderThan: SupportKitTestFixture.date.addingTimeInterval(1))
        let pruned = await store.acceptedReceipt(withFingerprint: fingerprint, since: .distantPast)

        // Assert
        #expect(retained == receipt)
        #expect(pruned == nil)
    }

    @Test
    func `prepared submission timestamps cannot move the duplicate cutoff`() async throws {
        // Arrange
        let store = InMemorySupportSubmissionStore()
        let receipt = SupportKitTestFixture.receipt()
        let fingerprint = String(repeating: "a", count: 64)
        try await store.markAccepted(
            id: receipt.reportID,
            receipt: receipt,
            fingerprint: fingerprint,
            recordedAt: SupportKitTestFixture.date,
        )
        let client = try SupportClient(
            configuration: SupportKitTestFixture.configuration(),
            transport: SupportTransportSpyingStub(outcomes: []),
            store: store,
            now: { SupportKitTestFixture.date },
        )
        let futurePrepared = PreparedSupportSubmission(submission: SupportKitTestFixture.submission(
            id: SupportKitTestFixture.secondReportID,
            createdAt: SupportKitTestFixture.date.addingTimeInterval(365 * 24 * 60 * 60),
            fingerprint: fingerprint,
        ), ownerID: client.preparedSubmissionOwnerID)

        // Act
        let result = await client.submit(futurePrepared)

        // Assert
        #expect(result == .duplicateAccepted(receipt))
        #expect(await store.pendingCount() == 0)
    }
}
