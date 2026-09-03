import Foundation
@testable import SupportKit

enum SupportKitTestFixture {
    static let queueScope = SupportQueueScope(
        projectID: "test.project",
        queueIdentifier: "test.project",
    )
    static let reportID = UUID(uuid: (
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00,
        0x40, 0x00,
        0x80, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    ))
    static let secondReportID = UUID(uuid: (
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00,
        0x40, 0x00,
        0x80, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
    ))
    static let date = Date(timeIntervalSince1970: 1_700_000_000)

    static func configuration(
        form: SupportFormConfiguration = .init(additionalFields: []),
        diagnostics: DiagnosticsConfiguration = .init(
            includesOperatingSystem: false,
            includesDeviceModel: false,
            includesApplicationVersion: false,
            includesThermalState: false,
            includesLowPowerMode: false,
        ),
        delivery: DeliveryConfiguration = .init(automaticallyDelivers: false),
        projectID: String = "test.project",
        queueIdentifier: String? = nil,
    ) throws -> SupportConfiguration {
        try SupportConfiguration(
            projectID: projectID,
            form: form,
            diagnostics: diagnostics,
            delivery: delivery,
            queueIdentifier: queueIdentifier,
        )
    }

    static func submission(
        id: UUID = reportID,
        createdAt: Date = date,
        title: String = "[Support] Cannot sign in",
        message: String = "The sign-in button does not respond.",
        responses: [SupportFieldResponse] = [],
        diagnostics: [SupportDiagnostic] = [],
        labels: [String] = ["support"],
        fingerprint: String = String(repeating: "a", count: 64),
        projectID: String = "test.project",
    ) -> SupportSubmission {
        SupportSubmission(
            id: id,
            projectID: projectID,
            createdAt: createdAt,
            title: title,
            message: message,
            responses: responses,
            diagnostics: diagnostics,
            labels: labels,
            contentFingerprint: fingerprint,
        )
    }

    static func receipt(
        reportID: UUID = reportID,
        status: SupportDeliveryReceipt.Status = .accepted,
        acceptedAt: Date = date,
        destinationURL: URL? = URL(string: "https://github.com/example/project/issues/42"),
        destinationReference: String? = "42",
    ) -> SupportDeliveryReceipt {
        SupportDeliveryReceipt(
            reportID: reportID,
            status: status,
            acceptedAt: acceptedAt,
            destinationURL: destinationURL,
            destinationReference: destinationReference,
        )
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "SupportKitTests-\(UUID().uuidString)",
            directoryHint: .isDirectory,
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func fileStore(
        identifier: String,
        baseDirectory: URL,
    ) throws -> FileSupportSubmissionStore {
        try FileSupportSubmissionStore(
            identifier: identifier,
            baseDirectory: baseDirectory,
            encryptionKeyProvider: EphemeralQueueKeyProvider(),
        )
    }
}

extension QueuedSupportSubmission {
    init(
        submission: SupportSubmission,
        attemptCount: Int = 0,
        nextAttemptAt: Date? = nil,
        lastFailure: String? = nil,
        state: State = .ready,
        leaseID: UUID? = nil,
        leaseExpiresAt: Date? = nil,
    ) {
        self.init(
            submission: submission,
            queueScope: SupportQueueScope(
                projectID: submission.projectID,
                queueIdentifier: submission.projectID,
            ),
            attemptCount: attemptCount,
            nextAttemptAt: nextAttemptAt,
            lastFailure: lastFailure,
            state: state,
            leaseID: leaseID,
            leaseExpiresAt: leaseExpiresAt,
        )
    }
}

enum TestConnectivityError: Error, Sendable {
    case offline
}

actor SupportTransportSpyingStub: SupportTransport {
    enum Outcome: Sendable {
        case accepted(
            status: SupportDeliveryReceipt.Status = .accepted,
            destinationURL: URL? = nil,
            destinationReference: String? = nil,
        )
        case supportError(SupportTransportError)
        case connectivityError
    }

    private var outcomes: [Outcome]
    private var capturedSubmissions: [SupportSubmission] = []
    private let acceptedAt: Date

    init(outcomes: [Outcome], acceptedAt: Date = SupportKitTestFixture.date) {
        self.outcomes = outcomes
        self.acceptedAt = acceptedAt
    }

    func submit(_ submission: SupportSubmission) async throws -> SupportDeliveryReceipt {
        capturedSubmissions.append(submission)
        let outcome = outcomes.isEmpty ? .accepted() : outcomes.removeFirst()

        switch outcome {
        case let .accepted(status, destinationURL, destinationReference):
            return SupportDeliveryReceipt(
                reportID: submission.id,
                status: status,
                acceptedAt: acceptedAt,
                destinationURL: destinationURL,
                destinationReference: destinationReference,
            )
        case let .supportError(error):
            throw error
        case .connectivityError:
            throw TestConnectivityError.offline
        }
    }

    func submissions() -> [SupportSubmission] {
        capturedSubmissions
    }
}

actor SupportHTTPClientSpyingStub: SupportHTTPClient {
    enum Outcome: Sendable {
        case response(data: Data, statusCode: Int, headers: [String: String] = [:])
        case supportError(SupportTransportError)
        case connectivityError
    }

    private let outcome: Outcome
    private var capturedRequests: [URLRequest] = []
    private var capturedMaximumResponseBytes: [Int] = []

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    func data(
        for request: URLRequest,
        maximumResponseBytes: Int,
    ) async throws -> (Data, HTTPURLResponse) {
        capturedRequests.append(request)
        capturedMaximumResponseBytes.append(maximumResponseBytes)

        switch outcome {
        case let .response(data, statusCode, headers):
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: statusCode,
                      httpVersion: "HTTP/1.1",
                      headerFields: headers,
                  )
            else {
                throw URLError(.badServerResponse)
            }
            return (data, response)
        case let .supportError(error):
            throw error
        case .connectivityError:
            throw TestConnectivityError.offline
        }
    }

    func requests() -> [URLRequest] {
        capturedRequests
    }

    func maximumResponseByteLimits() -> [Int] {
        capturedMaximumResponseBytes
    }
}

actor SupportRequestAuthorizerSpy: SupportRequestAuthorizer {
    private var capturedBodies: [Data] = []
    private var capturedRequests: [URLRequest] = []

    func authorize(_ request: URLRequest, body: Data) async throws -> URLRequest {
        capturedRequests.append(request)
        capturedBodies.append(body)
        var authorized = request
        authorized.setValue("ephemeral-test-proof", forHTTPHeaderField: "X-Test-Authorization")
        return authorized
    }

    func bodies() -> [Data] {
        capturedBodies
    }

    func requests() -> [URLRequest] {
        capturedRequests
    }
}

struct StaticDiagnosticsProvider: SupportDiagnosticsProvider {
    let diagnostics: [SupportDiagnostic]

    func collectDiagnostics() async -> [SupportDiagnostic] {
        diagnostics
    }
}

actor EnqueueFailingSubmissionStore: SupportSubmissionStore {
    private var capturedEnqueueCount = 0

    func enqueue(_ item: QueuedSupportSubmission, capacity: Int) throws {
        _ = item
        _ = capacity
        capturedEnqueueCount += 1
        throw SupportStoreError.cannotPersist
    }

    func enqueueIfAbsent(
        _ item: QueuedSupportSubmission,
        duplicateSince date: Date,
        capacity: Int,
    ) throws -> SupportStoreEnqueueResult {
        _ = date
        try enqueue(item, capacity: capacity)
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
        return []
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
    ) throws {
        _ = recordID
        _ = receipt
        _ = fingerprint
        _ = recordedAt
    }

    func markAccepted(
        recordID: SupportQueueRecordID,
        receipt: SupportDeliveryReceipt,
        fingerprint: String,
        leaseID: UUID,
        recordedAt: Date,
    ) throws {
        _ = leaseID
        try markAccepted(
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
    ) throws {
        _ = recordID
        _ = attemptCount
        _ = nextAttemptAt
        _ = failure
    }

    func markRetry(
        recordID: SupportQueueRecordID,
        leaseID: UUID,
        attemptCount: Int,
        nextAttemptAt: Date,
        failure: String,
    ) throws {
        _ = leaseID
        try markRetry(
            recordID: recordID,
            attemptCount: attemptCount,
            nextAttemptAt: nextAttemptAt,
            failure: failure,
        )
    }

    func markNeedsAttention(recordID: SupportQueueRecordID, failure: String) throws {
        _ = recordID
        _ = failure
    }

    func markNeedsAttention(
        recordID: SupportQueueRecordID,
        leaseID: UUID,
        failure: String,
    ) throws {
        _ = leaseID
        try markNeedsAttention(recordID: recordID, failure: failure)
    }

    func releaseLease(recordID: SupportQueueRecordID, leaseID: UUID) {
        _ = recordID
        _ = leaseID
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

    func enqueueCount() -> Int {
        capturedEnqueueCount
    }
}
