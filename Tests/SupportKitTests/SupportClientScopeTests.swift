import Foundation
@testable import SupportKit
import Testing

@Suite("Client and queue ownership scopes")
struct SupportClientScopeTests {
    @Test
    func `a client rejects a prepared report owned by another client`() async throws {
        // Arrange
        let configuration = try SupportKitTestFixture.configuration()
        let store = InMemorySupportSubmissionStore()
        let firstTransport = SupportTransportSpyingStub(outcomes: [])
        let secondTransport = SupportTransportSpyingStub(outcomes: [])
        let firstClient = SupportClient(
            configuration: configuration,
            transport: firstTransport,
            store: store,
            now: { SupportKitTestFixture.date },
            makeID: { SupportKitTestFixture.reportID },
        )
        let secondClient = SupportClient(
            configuration: configuration,
            transport: secondTransport,
            store: store,
            now: { SupportKitTestFixture.date },
            makeID: { SupportKitTestFixture.secondReportID },
        )
        let prepared = try #require(await firstClient.prepare(
            .init(subject: "Subject", message: "Message"),
        ).prepared)

        // Act
        let result = await secondClient.submit(prepared)

        // Assert
        #expect(result == .rejected(.invalidPreparedSubmission))
        #expect(await firstClient.pendingReportCount() == 0)
        #expect(await secondClient.pendingReportCount() == 0)
        #expect(await firstTransport.submissions().isEmpty)
        #expect(await secondTransport.submissions().isEmpty)
    }

    @Test
    func `clients sharing one store only drain their own project scope`() async throws {
        // Arrange
        let store = InMemorySupportSubmissionStore()
        let alphaConfiguration = try SupportKitTestFixture.configuration(
            projectID: "project.alpha",
            queueIdentifier: "Shared.Queue",
        )
        let betaConfiguration = try SupportKitTestFixture.configuration(
            projectID: "project.beta",
            queueIdentifier: "Shared.Queue",
        )
        let alphaTransport = SupportTransportSpyingStub(outcomes: [.accepted()])
        let betaTransport = SupportTransportSpyingStub(outcomes: [.accepted()])
        let alphaClient = SupportClient(
            configuration: alphaConfiguration,
            transport: alphaTransport,
            store: store,
            now: { SupportKitTestFixture.date },
            makeID: { SupportKitTestFixture.reportID },
        )
        let betaClient = SupportClient(
            configuration: betaConfiguration,
            transport: betaTransport,
            store: store,
            now: { SupportKitTestFixture.date },
            makeID: { SupportKitTestFixture.reportID },
        )
        _ = await alphaClient.submit(.init(subject: "Alpha", message: "Alpha message"))
        _ = await betaClient.submit(.init(subject: "Beta", message: "Beta message"))

        // Act
        let alphaDelivery = await alphaClient.flush()
        let alphaPendingAfterFirstDrain = await alphaClient.pendingReportCount()
        let betaPendingAfterFirstDrain = await betaClient.pendingReportCount()
        let betaDelivery = await betaClient.flush()

        // Assert
        #expect(alphaConfiguration.queueScope != betaConfiguration.queueScope)
        #expect(alphaDelivery.accepted == 1)
        #expect(betaDelivery.accepted == 1)
        #expect(alphaPendingAfterFirstDrain == 0)
        #expect(betaPendingAfterFirstDrain == 1)
        #expect(await alphaTransport.submissions().map(\.projectID) == ["project.alpha"])
        #expect(await betaTransport.submissions().map(\.projectID) == ["project.beta"])
        #expect(await alphaClient.pendingReportCount() == 0)
        #expect(await betaClient.pendingReportCount() == 0)
    }

    @Test
    func `case-colliding logical names retain distinct stable scopes`() throws {
        // Arrange / Act
        let uppercase = try SupportConfiguration(projectID: "Project.ID")
        let lowercase = try SupportConfiguration(projectID: "project.id")
        let repeatedUppercase = try SupportConfiguration(projectID: "Project.ID")
        let roundTripped = try SupportConfiguration(
            projectID: uppercase.projectID,
            queueIdentifier: uppercase.queueIdentifier,
        )
        let uppercaseQueue = try SupportConfiguration(
            projectID: "project.id",
            queueIdentifier: "Shared.Queue",
        )
        let lowercaseQueue = try SupportConfiguration(
            projectID: "project.id",
            queueIdentifier: "shared.queue",
        )

        // Assert
        #expect(uppercase.queueIdentifier == "Project.ID")
        #expect(lowercase.queueIdentifier == "project.id")
        #expect(uppercase.queueScope != lowercase.queueScope)
        #expect(uppercase.queueScope == repeatedUppercase.queueScope)
        #expect(uppercase.queueScope == roundTripped.queueScope)
        #expect(uppercase.fileQueueIdentifier != lowercase.fileQueueIdentifier)
        #expect(uppercaseQueue.queueScope != lowercaseQueue.queueScope)
    }

    @Test
    func `one file store retains identical report IDs independently by scope`() async throws {
        // Arrange
        let baseDirectory = try SupportKitTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let store = try SupportKitTestFixture.fileStore(
            identifier: "shared-file-store",
            baseDirectory: baseDirectory,
        )
        let alpha = try SupportKitTestFixture.configuration(
            projectID: "file.alpha",
            queueIdentifier: "shared",
        )
        let beta = try SupportKitTestFixture.configuration(
            projectID: "file.beta",
            queueIdentifier: "shared",
        )
        let alphaItem = QueuedSupportSubmission(
            submission: SupportKitTestFixture.submission(
                message: "Alpha",
                fingerprint: String(repeating: "a", count: 64),
                projectID: alpha.projectID,
            ),
            queueScope: alpha.queueScope,
        )
        let betaItem = QueuedSupportSubmission(
            submission: SupportKitTestFixture.submission(
                message: "Beta",
                fingerprint: String(repeating: "b", count: 64),
                projectID: beta.projectID,
            ),
            queueScope: beta.queueScope,
        )

        // Act
        try await store.enqueue(alphaItem, capacity: 1)
        try await store.enqueue(betaItem, capacity: 1)
        let alphaDue = await store.dueSubmissions(
            in: alpha.queueScope,
            before: .distantFuture,
            limit: 10,
        )
        let betaDue = await store.dueSubmissions(
            in: beta.queueScope,
            before: .distantFuture,
            limit: 10,
        )

        // Assert
        #expect(alphaDue == [alphaItem])
        #expect(betaDue == [betaItem])
        #expect(await store.pendingCount(in: alpha.queueScope) == 1)
        #expect(await store.pendingCount(in: beta.queueScope) == 1)
    }

    @Test
    func `client never delivers or mutates a foreign item returned by a nonconforming store`() async throws {
        // Arrange
        let localConfiguration = try SupportKitTestFixture.configuration(projectID: "local.project")
        let foreignConfiguration = try SupportKitTestFixture.configuration(projectID: "foreign.project")
        let foreignItem = QueuedSupportSubmission(
            submission: SupportKitTestFixture.submission(projectID: foreignConfiguration.projectID),
            queueScope: foreignConfiguration.queueScope,
            leaseID: SupportKitTestFixture.reportID,
            leaseExpiresAt: .distantFuture,
        )
        let store = ScopeViolatingSubmissionStore(foreignItem: foreignItem)
        let transport = SupportTransportSpyingStub(outcomes: [.accepted()])
        let client = SupportClient(
            configuration: localConfiguration,
            transport: transport,
            store: store,
            now: { SupportKitTestFixture.date },
        )

        // Act
        let report = await client.flush()

        // Assert
        #expect(report.accepted == 0)
        #expect(await transport.submissions().isEmpty)
        #expect(await store.mutationScopes().isEmpty)
        #expect(await store.releaseScopes() == [localConfiguration.queueScope])
    }

    @Test(arguments: [
        "../" + String(repeating: "a", count: 61),
        String(repeating: "a", count: 63),
        String(repeating: "A", count: 64),
        String(repeating: "g", count: 64),
        String(repeating: "a", count: 65),
    ])
    func `malformed queue scope identifiers fail decoding`(identifier: String) {
        // Arrange
        let data = Data(#"{"identifier":"\#(identifier)"}"#.utf8)

        // Act / Assert
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(SupportQueueScope.self, from: data)
        }
    }
}

private extension SupportPreparationResult {
    var prepared: PreparedSupportSubmission? {
        guard case let .ready(prepared) = self else { return nil }
        return prepared
    }
}

private actor ScopeViolatingSubmissionStore: SupportSubmissionStore {
    private let foreignItem: QueuedSupportSubmission
    private var hasReturnedForeignItem = false
    private var recordedMutationScopes: [SupportQueueScope] = []
    private var recordedReleaseScopes: [SupportQueueScope] = []

    init(foreignItem: QueuedSupportSubmission) {
        self.foreignItem = foreignItem
    }

    func enqueue(_ item: QueuedSupportSubmission, capacity: Int) throws {
        _ = item
        _ = capacity
    }

    func enqueueIfAbsent(
        _ item: QueuedSupportSubmission,
        duplicateSince date: Date,
        capacity: Int,
    ) throws -> SupportStoreEnqueueResult {
        _ = date
        _ = capacity
        return .enqueued(reportID: item.id)
    }

    func dueSubmissions(
        in scope: SupportQueueScope,
        before date: Date,
        limit: Int,
    ) -> [QueuedSupportSubmission] {
        _ = scope
        _ = date
        _ = limit
        return []
    }

    func claimDueSubmissions(
        in scope: SupportQueueScope,
        before date: Date,
        limit: Int,
        leaseID: UUID,
        leaseExpiresAt: Date,
    ) -> [QueuedSupportSubmission] {
        _ = scope
        _ = date
        _ = limit
        _ = leaseID
        _ = leaseExpiresAt
        guard !hasReturnedForeignItem else { return [] }
        hasReturnedForeignItem = true
        return [foreignItem]
    }

    func nextReadyDate(in scope: SupportQueueScope) -> Date? {
        _ = scope
        return nil
    }

    func nextReadyDate(in scope: SupportQueueScope, relativeTo date: Date) -> Date? {
        _ = scope
        _ = date
        return nil
    }

    func pendingSubmission(
        in scope: SupportQueueScope,
        withFingerprint fingerprint: String,
        since date: Date,
    ) -> QueuedSupportSubmission? {
        _ = scope
        _ = fingerprint
        _ = date
        return nil
    }

    func acceptedReceipt(
        in scope: SupportQueueScope,
        withFingerprint fingerprint: String,
        since date: Date,
    ) -> SupportDeliveryReceipt? {
        _ = scope
        _ = fingerprint
        _ = date
        return nil
    }

    func markAccepted(
        recordID: SupportQueueRecordID,
        receipt: SupportDeliveryReceipt,
        fingerprint: String,
        recordedAt: Date,
    ) {
        _ = receipt
        _ = fingerprint
        _ = recordedAt
        recordedMutationScopes.append(recordID.queueScope)
    }

    func markAccepted(
        recordID: SupportQueueRecordID,
        receipt: SupportDeliveryReceipt,
        fingerprint: String,
        leaseID: UUID,
        recordedAt: Date,
    ) {
        _ = leaseID
        markAccepted(
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
    ) {
        _ = attemptCount
        _ = nextAttemptAt
        _ = failure
        recordedMutationScopes.append(recordID.queueScope)
    }

    func markRetry(
        recordID: SupportQueueRecordID,
        leaseID: UUID,
        attemptCount: Int,
        nextAttemptAt: Date,
        failure: String,
    ) {
        _ = leaseID
        markRetry(
            recordID: recordID,
            attemptCount: attemptCount,
            nextAttemptAt: nextAttemptAt,
            failure: failure,
        )
    }

    func markNeedsAttention(recordID: SupportQueueRecordID, failure: String) {
        _ = failure
        recordedMutationScopes.append(recordID.queueScope)
    }

    func markNeedsAttention(
        recordID: SupportQueueRecordID,
        leaseID: UUID,
        failure: String,
    ) {
        _ = leaseID
        markNeedsAttention(recordID: recordID, failure: failure)
    }

    func releaseLease(recordID: SupportQueueRecordID, leaseID: UUID) {
        _ = leaseID
        recordedReleaseScopes.append(recordID.queueScope)
    }

    func pendingCount(in scope: SupportQueueScope) -> Int {
        _ = scope
        return 0
    }

    func readyCount(in scope: SupportQueueScope) -> Int {
        _ = scope
        return 0
    }

    func pruneReceipts(in scope: SupportQueueScope, olderThan date: Date) {
        _ = scope
        _ = date
    }

    func mutationScopes() -> [SupportQueueScope] {
        recordedMutationScopes
    }

    func releaseScopes() -> [SupportQueueScope] {
        recordedReleaseScopes
    }
}
