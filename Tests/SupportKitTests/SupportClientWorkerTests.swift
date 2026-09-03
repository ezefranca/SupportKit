import Foundation
@testable import SupportKit
import Testing

@Suite("Support client delivery worker")
struct SupportClientWorkerTests {
    @Test
    func `submitting a due report wakes a worker sleeping for a distant retry`() async throws {
        // Arrange
        let store = InMemorySupportSubmissionStore()
        let transport = SupportTransportSpyingStub(outcomes: [
            .supportError(.retryable(code: 503, retryAfter: 3600, reason: "Unavailable.")),
            .accepted(status: .accepted),
        ])
        let delivery = DeliveryConfiguration(
            automaticallyDelivers: true,
            initialRetryDelay: 3600,
            maximumRetryDelay: 3600,
        )
        let client = try SupportClient(
            configuration: SupportKitTestFixture.configuration(delivery: delivery),
            transport: transport,
            store: store,
            now: { SupportKitTestFixture.date },
        )
        let retrying = PreparedSupportSubmission(
            submission: SupportKitTestFixture.submission(),
            ownerID: client.preparedSubmissionOwnerID,
        )
        let dueNow = PreparedSupportSubmission(submission: SupportKitTestFixture.submission(
            id: SupportKitTestFixture.secondReportID,
            message: "A distinct report",
            fingerprint: String(repeating: "b", count: 64),
        ), ownerID: client.preparedSubmissionOwnerID)
        _ = await client.submit(retrying)
        let retryWasPersisted = await eventually {
            await store.pendingSubmission(
                withFingerprint: retrying.submission.contentFingerprint,
                since: .distantPast,
            )?.attemptCount == 1
        }
        #expect(retryWasPersisted)
        for _ in 0 ..< 5 {
            await Task.yield()
        }

        // Act
        let result = await client.submit(dueNow)
        let newReportWasDelivered = await eventually {
            await store.acceptedReceipt(
                withFingerprint: dueNow.submission.contentFingerprint,
                since: .distantPast,
            ) != nil
        }
        await client.pauseDelivery()

        // Assert
        #expect(result == .queued(reportID: dueNow.id))
        #expect(newReportWasDelivered)
        #expect(await transport.submissions().map(\.id) == [retrying.id, dueNow.id])
        #expect(await store.pendingCount() == 1)
    }

    @Test
    func `pause retains a queued report and resume delivers it`() async throws {
        // Arrange
        let store = InMemorySupportSubmissionStore()
        let transport = SupportTransportSpyingStub(outcomes: [.accepted(status: .delivered)])
        let delivery = DeliveryConfiguration(automaticallyDelivers: false)
        let client = try SupportClient(
            configuration: SupportKitTestFixture.configuration(delivery: delivery),
            transport: transport,
            store: store,
            now: { SupportKitTestFixture.date },
        )
        let prepared = PreparedSupportSubmission(
            submission: SupportKitTestFixture.submission(),
            ownerID: client.preparedSubmissionOwnerID,
        )
        _ = await client.submit(prepared)

        // Act
        await client.pauseDelivery()
        let retainedWhilePaused = await client.pendingReportCount()
        await client.resumeDelivery()
        let deliveredAfterResume = await eventually {
            await store.acceptedReceipt(
                withFingerprint: prepared.submission.contentFingerprint,
                since: .distantPast,
            ) != nil
        }
        await client.pauseDelivery()

        // Assert
        #expect(retainedWhilePaused == 1)
        #expect(deliveredAfterResume)
        #expect(await client.pendingReportCount() == 0)
        #expect(await transport.submissions().map(\.id) == [prepared.id])
    }

    private func eventually(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool,
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}
