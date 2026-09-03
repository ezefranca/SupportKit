import Foundation
@testable import SupportKit
import Testing

@Suite("Needs-attention report recovery")
struct SupportSubmissionAttentionTests {
    @Test
    func `atomic enqueue requeues an in-memory attention item under its original identity`() async throws {
        // Arrange
        let store = InMemorySupportSubmissionStore()
        let original = QueuedSupportSubmission(
            submission: SupportKitTestFixture.submission(),
            attemptCount: 3,
            lastFailure: "Rejected",
            state: .needsAttention,
        )
        let replacementDate = SupportKitTestFixture.date.addingTimeInterval(60)
        let replacement = QueuedSupportSubmission(submission: SupportKitTestFixture.submission(
            id: SupportKitTestFixture.secondReportID,
            createdAt: replacementDate,
        ))
        try await store.enqueue(original, capacity: 10)

        // Act
        let result = try await store.enqueueIfAbsent(
            replacement,
            duplicateSince: .distantPast,
            capacity: 10,
        )
        let recovered = await store.pendingSubmission(
            withFingerprint: original.submission.contentFingerprint,
            since: .distantPast,
        )

        // Assert
        #expect(result == .enqueued(reportID: original.id))
        #expect(recovered?.submission == original.submission)
        #expect(recovered?.state == .ready)
        #expect(recovered?.attemptCount == 0)
        #expect(recovered?.nextAttemptAt == replacementDate)
        #expect(recovered?.lastFailure == nil)
        #expect(await store.pendingCount() == 1)
    }

    @Test
    func `atomic enqueue durably requeues an attention item under its original identity`() async throws {
        // Arrange
        let baseDirectory = try SupportKitTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let identifier = "attention-requeue"
        let store = try SupportKitTestFixture.fileStore(
            identifier: identifier,
            baseDirectory: baseDirectory,
        )
        let original = QueuedSupportSubmission(
            submission: SupportKitTestFixture.submission(),
            attemptCount: 2,
            lastFailure: "Rejected",
            state: .needsAttention,
        )
        let replacementDate = SupportKitTestFixture.date.addingTimeInterval(60)
        let replacement = QueuedSupportSubmission(submission: SupportKitTestFixture.submission(
            id: SupportKitTestFixture.secondReportID,
            createdAt: replacementDate,
        ))
        try await store.enqueue(original, capacity: 10)

        // Act
        let result = try await store.enqueueIfAbsent(
            replacement,
            duplicateSince: .distantPast,
            capacity: 10,
        )
        let recoveredStore = try SupportKitTestFixture.fileStore(
            identifier: identifier,
            baseDirectory: baseDirectory,
        )
        let recovered = await recoveredStore.pendingSubmission(
            withFingerprint: original.submission.contentFingerprint,
            since: .distantPast,
        )

        // Assert
        #expect(result == .enqueued(reportID: original.id))
        #expect(recovered?.submission == original.submission)
        #expect(recovered?.state == .ready)
        #expect(recovered?.attemptCount == 0)
        #expect(recovered?.nextAttemptAt == replacementDate)
        #expect(recovered?.lastFailure == nil)
        #expect(await recoveredStore.pendingCount() == 1)
        #expect(await recoveredStore.readyCount() == 1)
    }

    @Test
    func `client counts retained attention items and requeues the original report`() async throws {
        // Arrange
        let store = InMemorySupportSubmissionStore()
        let transport = SupportTransportSpyingStub(outcomes: [
            .supportError(.permanent(code: 422, reason: "Rejected.")),
        ])
        let client = try SupportClient(
            configuration: SupportKitTestFixture.configuration(),
            transport: transport,
            store: store,
            now: { SupportKitTestFixture.date },
        )
        let original = PreparedSupportSubmission(
            submission: SupportKitTestFixture.submission(),
            ownerID: client.preparedSubmissionOwnerID,
        )
        let replacement = PreparedSupportSubmission(submission: SupportKitTestFixture.submission(
            id: SupportKitTestFixture.secondReportID,
            createdAt: SupportKitTestFixture.date.addingTimeInterval(60),
        ), ownerID: client.preparedSubmissionOwnerID)
        _ = await client.submit(original)
        _ = await client.flush()
        let pendingAttentionCount = await client.pendingReportCount()
        let readyAttentionCount = await client.readyReportCount()

        // Act
        let result = await client.submit(replacement)

        // Assert
        #expect(pendingAttentionCount == 1)
        #expect(readyAttentionCount == 0)
        #expect(result == .queued(reportID: original.id))
        #expect(await client.pendingReportCount() == 1)
        #expect(await client.readyReportCount() == 1)
    }

    @Test
    func `changed diagnostic consent never reactivates a broader reviewed payload`() async throws {
        // Arrange
        let diagnostics = DiagnosticsConfiguration(
            includesOperatingSystem: false,
            includesDeviceModel: false,
            includesApplicationVersion: false,
            includesThermalState: false,
            includesLowPowerMode: false,
            customProviders: [StaticDiagnosticsProvider(diagnostics: [
                .init(key: "Environment", value: "Approved detail"),
            ])],
        )
        let configuration = try SupportKitTestFixture.configuration(diagnostics: diagnostics)
        let store = InMemorySupportSubmissionStore()
        let firstClient = SupportClient(
            configuration: configuration,
            transport: SupportTransportSpyingStub(outcomes: []),
            store: store,
            now: { SupportKitTestFixture.date },
            makeID: { SupportKitTestFixture.reportID },
        )
        let secondClient = SupportClient(
            configuration: configuration,
            transport: SupportTransportSpyingStub(outcomes: []),
            store: store,
            now: { SupportKitTestFixture.date.addingTimeInterval(60) },
            makeID: { SupportKitTestFixture.secondReportID },
        )
        let draftWithDiagnostics = SupportDraft(
            subject: "Subject",
            message: "Message",
            includesDiagnostics: true,
        )
        let first = try #require(await firstClient.prepare(draftWithDiagnostics).prepared)
        _ = await firstClient.submit(first)
        try await store.markNeedsAttention(id: SupportKitTestFixture.reportID, failure: "Rejected")

        // Act
        let withoutDiagnostics = try #require(await secondClient.prepare(.init(
            subject: "Subject",
            message: "Message",
            includesDiagnostics: false,
        )).prepared)
        let distinctResult = await secondClient.submit(withoutDiagnostics)
        let exactMatch = try #require(await secondClient.prepare(draftWithDiagnostics).prepared)
        let exactResult = await secondClient.submit(exactMatch)

        // Assert
        #expect(distinctResult == .queued(reportID: SupportKitTestFixture.secondReportID))
        #expect(exactResult == .queued(reportID: SupportKitTestFixture.reportID))
        #expect(await store.pendingCount() == 2)
    }
}

private extension SupportPreparationResult {
    var prepared: PreparedSupportSubmission? {
        guard case let .ready(prepared) = self else { return nil }
        return prepared
    }
}
