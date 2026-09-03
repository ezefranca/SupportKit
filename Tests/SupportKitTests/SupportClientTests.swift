import Foundation
@testable import SupportKit
import Testing

@Suite("Support client")
struct SupportClientTests {
    @Test
    func `a matching queued fingerprint is returned as a pending duplicate`() async throws {
        // Arrange
        let store = InMemorySupportSubmissionStore()
        let transport = SupportTransportSpyingStub(outcomes: [])
        let client = try SupportClient(
            configuration: SupportKitTestFixture.configuration(),
            transport: transport,
            store: store,
            now: { SupportKitTestFixture.date },
            makeID: { SupportKitTestFixture.reportID },
        )
        let draft = SupportDraft(subject: "Cannot sign in", message: "The button does nothing.")

        // Act
        let first = await client.submit(draft)
        let duplicate = await client.submit(draft)

        // Assert
        #expect(first == .queued(reportID: SupportKitTestFixture.reportID))
        #expect(duplicate == .duplicatePending(reportID: SupportKitTestFixture.reportID))
        #expect(await store.readyCount() == 1)
        #expect(await transport.submissions().isEmpty)
    }

    @Test
    func `a matching durable receipt is returned without a second transport call`() async throws {
        // Arrange
        let destinationURL = try #require(URL(string: "https://github.com/example/project/issues/42"))
        let store = InMemorySupportSubmissionStore()
        let transport = SupportTransportSpyingStub(outcomes: [
            .accepted(status: .delivered, destinationURL: destinationURL, destinationReference: "42"),
        ])
        let client = try SupportClient(
            configuration: SupportKitTestFixture.configuration(),
            transport: transport,
            store: store,
            now: { SupportKitTestFixture.date },
            makeID: { SupportKitTestFixture.reportID },
        )
        let draft = SupportDraft(subject: "Cannot sign in", message: "The button does nothing.")

        // Act
        _ = await client.submit(draft)
        let delivery = await client.flush()
        let duplicate = await client.submit(draft)

        // Assert
        #expect(delivery.accepted == 1)
        guard case let .duplicateAccepted(receipt) = duplicate else {
            Issue.record("Expected the accepted receipt to suppress the duplicate")
            return
        }
        #expect(receipt.reportID == SupportKitTestFixture.reportID)
        #expect(receipt.status == .delivered)
        #expect(receipt.destinationURL == destinationURL)
        #expect(await transport.submissions().count == 1)
        #expect(await store.readyCount() == 0)
    }

    @Test
    func `two concurrent submissions of one prepared payload create one queue item`() async throws {
        // Arrange
        let store = InMemorySupportSubmissionStore()
        let transport = SupportTransportSpyingStub(outcomes: [])
        let client = try SupportClient(
            configuration: SupportKitTestFixture.configuration(),
            transport: transport,
            store: store,
            now: { SupportKitTestFixture.date },
            makeID: { SupportKitTestFixture.reportID },
        )
        let preparation = await client.prepare(
            .init(subject: "Cannot sign in", message: "The button does nothing."),
        )
        guard case let .ready(prepared) = preparation else {
            Issue.record("Expected a valid draft to prepare")
            return
        }

        // Act
        async let first = client.submit(prepared)
        async let second = client.submit(prepared)
        let results = await [first, second]
        let delivery = await client.flush()

        // Assert
        let queuedCount = results.count { $0 == .queued(reportID: SupportKitTestFixture.reportID) }
        let duplicateCount = results.count { $0 == .duplicatePending(reportID: SupportKitTestFixture.reportID) }
        #expect(queuedCount == 1)
        #expect(duplicateCount == 1)
        #expect(delivery.accepted == 1)
        #expect(await transport.submissions().count == 1)
        #expect(await store.readyCount() == 0)
    }

    @Test
    func `queue capacity failures remain nonthrowing and honestly rejected`() async throws {
        // Arrange
        let delivery = DeliveryConfiguration(automaticallyDelivers: false, maximumStoredSubmissions: 1)
        let store = InMemorySupportSubmissionStore()
        let client = try SupportClient(
            configuration: SupportKitTestFixture.configuration(delivery: delivery),
            transport: SupportTransportSpyingStub(outcomes: []),
            store: store,
            now: { SupportKitTestFixture.date },
        )
        let first = PreparedSupportSubmission(
            submission: SupportKitTestFixture.submission(),
            ownerID: client.preparedSubmissionOwnerID,
        )
        let second = PreparedSupportSubmission(submission: SupportKitTestFixture.submission(
            id: SupportKitTestFixture.secondReportID,
            message: "A different report",
            fingerprint: String(repeating: "b", count: 64),
        ), ownerID: client.preparedSubmissionOwnerID)

        // Act
        let accepted = await client.submit(first)
        let rejected = await client.submit(second)

        // Assert
        #expect(accepted == .queued(reportID: SupportKitTestFixture.reportID))
        #expect(rejected == .rejected(.queueFull))
        #expect(await store.readyCount() == 1)
    }

    @Test
    func `an unavailable durable store remains nonthrowing and does not start delivery`() async throws {
        // Arrange
        let store = EnqueueFailingSubmissionStore()
        let transport = SupportTransportSpyingStub(outcomes: [])
        let client = try SupportClient(
            configuration: SupportKitTestFixture.configuration(),
            transport: transport,
            store: store,
            now: { SupportKitTestFixture.date },
            makeID: { SupportKitTestFixture.reportID },
        )

        // Act
        let result = await client.submit(.init(subject: "Subject", message: "Message"))

        // Assert
        #expect(result == .rejected(.queueUnavailable))
        #expect(await store.enqueueCount() == 1)
        #expect(await transport.submissions().isEmpty)
    }

    @Test
    func `retryable transport failures persist their attempt and server-directed delay`() async throws {
        // Arrange
        let store = InMemorySupportSubmissionStore()
        let transport = SupportTransportSpyingStub(outcomes: [
            .supportError(.retryable(code: 429, retryAfter: 45, reason: "Rate limited.")),
        ])
        let client = try SupportClient(
            configuration: SupportKitTestFixture.configuration(),
            transport: transport,
            store: store,
            now: { SupportKitTestFixture.date },
            makeID: { SupportKitTestFixture.reportID },
        )
        let preparation = await client.prepare(.init(subject: "Subject", message: "Message"))
        guard case let .ready(prepared) = preparation else {
            Issue.record("Expected preparation to succeed")
            return
        }
        _ = await client.submit(prepared)

        // Act
        let report = await client.flush()
        let persisted = await store.pendingSubmission(
            withFingerprint: prepared.submission.contentFingerprint,
            since: .distantPast,
        )

        // Assert
        #expect(report == SupportDeliveryReport(
            accepted: 0,
            retryScheduled: 1,
            needsAttention: 0,
            remainingReady: 1,
        ))
        #expect(persisted?.attemptCount == 1)
        #expect(persisted?.nextAttemptAt == SupportKitTestFixture.date.addingTimeInterval(45))
        #expect(persisted?.lastFailure == "Rate limited.")
        #expect(persisted?.state == .ready)
    }

    @Test
    func `an unexpected connectivity error uses the sanitized generic retry reason`() async throws {
        // Arrange
        let store = InMemorySupportSubmissionStore()
        let transport = SupportTransportSpyingStub(outcomes: [.connectivityError])
        let client = try SupportClient(
            configuration: SupportKitTestFixture.configuration(),
            transport: transport,
            store: store,
            now: { SupportKitTestFixture.date },
            makeID: { SupportKitTestFixture.reportID },
        )
        let preparation = await client.prepare(.init(subject: "Subject", message: "Message"))
        guard case let .ready(prepared) = preparation else {
            Issue.record("Expected preparation to succeed")
            return
        }
        _ = await client.submit(prepared)

        // Act
        let report = await client.flush()
        let persisted = await store.pendingSubmission(
            withFingerprint: prepared.submission.contentFingerprint,
            since: .distantPast,
        )

        // Assert
        #expect(report.retryScheduled == 1)
        #expect(persisted?.attemptCount == 1)
        #expect(persisted?.lastFailure == "Delivery was interrupted.")
    }

    struct TerminalFailureCase: Sendable, CustomTestStringConvertible {
        let name: String
        let error: SupportTransportError
        let expectedReason: String

        var testDescription: String {
            name
        }
    }

    static let terminalFailures: [TerminalFailureCase] = [
        .init(
            name: "permanent rejection",
            error: .permanent(code: 422, reason: "Invalid payload."),
            expectedReason: "Invalid payload.",
        ),
        .init(
            name: "invalid response",
            error: .invalidResponse,
            expectedReason: "The support receiver returned an invalid response.",
        ),
        .init(
            name: "oversized payload",
            error: .payloadTooLarge,
            expectedReason: "The support report is too large for the receiver.",
        ),
    ]

    @Test(arguments: terminalFailures)
    func `non-retryable delivery failures are retained for attention`(testCase: TerminalFailureCase) async throws {
        // Arrange
        let store = InMemorySupportSubmissionStore()
        let transport = SupportTransportSpyingStub(outcomes: [.supportError(testCase.error)])
        let client = try SupportClient(
            configuration: SupportKitTestFixture.configuration(),
            transport: transport,
            store: store,
            now: { SupportKitTestFixture.date },
            makeID: { SupportKitTestFixture.reportID },
        )
        let preparation = await client.prepare(.init(subject: "Subject", message: "Message"))
        guard case let .ready(prepared) = preparation else {
            Issue.record("Expected preparation to succeed")
            return
        }
        _ = await client.submit(prepared)

        // Act
        let report = await client.flush()
        let persisted = await store.pendingSubmission(
            withFingerprint: prepared.submission.contentFingerprint,
            since: .distantPast,
        )

        // Assert
        #expect(report.needsAttention == 1)
        #expect(report.retryScheduled == 0)
        #expect(report.remainingReady == 0)
        #expect(persisted?.state == .needsAttention)
        #expect(persisted?.lastFailure == testCase.expectedReason)
        #expect(await transport.submissions().count == 1)
    }

    @Test
    func `a retry waits until due and then reuses the exact frozen submission`() async throws {
        // Arrange
        let clock = LockedTestClock(now: SupportKitTestFixture.date)
        let store = InMemorySupportSubmissionStore()
        let transport = SupportTransportSpyingStub(outcomes: [
            .supportError(.retryable(code: 503, retryAfter: 30, reason: "Unavailable.")),
            .accepted(status: .accepted),
        ])
        let client = try SupportClient(
            configuration: SupportKitTestFixture.configuration(),
            transport: transport,
            store: store,
            now: { clock.value },
            makeID: { SupportKitTestFixture.reportID },
        )
        _ = await client.submit(.init(subject: "Subject", message: "Message"))

        // Act
        let first = await client.flush()
        let tooEarly = await client.flush()
        clock.value = SupportKitTestFixture.date.addingTimeInterval(30)
        let whenDue = await client.flush()
        let submissions = await transport.submissions()

        // Assert
        #expect(first.retryScheduled == 1)
        #expect(tooEarly == SupportDeliveryReport(remainingReady: 1))
        #expect(whenDue.accepted == 1)
        #expect(submissions.count == 2)
        #expect(submissions.first == submissions.last)
        #expect(await store.readyCount() == 0)
    }

    @Test
    func `concurrent flushes are single-flight`() async throws {
        // Arrange
        let store = InMemorySupportSubmissionStore()
        let transport = GatedSupportTransport()
        let client = try SupportClient(
            configuration: SupportKitTestFixture.configuration(),
            transport: transport,
            store: store,
            now: { SupportKitTestFixture.date },
            makeID: { SupportKitTestFixture.reportID },
        )
        _ = await client.submit(.init(subject: "Subject", message: "Message"))

        // Act
        let firstFlush = Task { await client.flush() }
        await transport.waitUntilStarted()
        let overlappingFlush = await client.flush()
        await transport.release()
        let completedFlush = await firstFlush.value

        // Assert
        #expect(overlappingFlush == SupportDeliveryReport(remainingReady: 1))
        #expect(completedFlush.accepted == 1)
        #expect(await transport.submissionCount() == 1)
        #expect(await store.readyCount() == 0)
    }
}

private final class LockedTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Date

    init(now: Date) {
        storedValue = now
    }

    var value: Date {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}

private actor GatedSupportTransport: SupportTransport {
    private var capturedSubmissions: [SupportSubmission] = []
    private var deliveryContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasStarted = false
    private var isReleased = false

    func submit(_ submission: SupportSubmission) async throws -> SupportDeliveryReceipt {
        capturedSubmissions.append(submission)
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        if !isReleased {
            await withCheckedContinuation { continuation in
                deliveryContinuation = continuation
            }
        }

        return SupportKitTestFixture.receipt(reportID: submission.id)
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        deliveryContinuation?.resume()
        deliveryContinuation = nil
    }

    func submissionCount() -> Int {
        capturedSubmissions.count
    }
}
