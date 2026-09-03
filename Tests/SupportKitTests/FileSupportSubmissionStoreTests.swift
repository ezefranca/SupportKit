import Foundation
@testable import SupportKit
import Testing

@Suite("Durable file submission store")
struct FileSupportSubmissionStoreTests {
    @Test
    func `case-distinct queue identifiers use separate filesystem and encryption namespaces`() async throws {
        // Arrange
        let baseDirectory = try SupportKitTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let uppercaseStore = try SupportKitTestFixture.fileStore(
            identifier: "Shared.Queue",
            baseDirectory: baseDirectory,
        )
        let lowercaseStore = try SupportKitTestFixture.fileStore(
            identifier: "shared.queue",
            baseDirectory: baseDirectory,
        )
        let item = QueuedSupportSubmission(submission: SupportKitTestFixture.submission())

        // Act
        try await uppercaseStore.enqueue(item, capacity: 10)
        let recovered = await lowercaseStore.pendingSubmission(
            withFingerprint: item.submission.contentFingerprint,
            since: .distantPast,
        )

        // Assert
        let uppercaseRoot = queueRoot(baseDirectory: baseDirectory, identifier: "Shared.Queue")
        let lowercaseRoot = queueRoot(baseDirectory: baseDirectory, identifier: "shared.queue")
        #expect(uppercaseRoot != lowercaseRoot)
        #expect(FileManager.default.fileExists(atPath: uppercaseRoot.path))
        #expect(FileManager.default.fileExists(atPath: lowercaseRoot.path))
        #expect(recovered == nil)
    }

    @Test
    func `a queued report survives construction of a new store instance`() async throws {
        // Arrange
        let baseDirectory = try SupportKitTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let item = QueuedSupportSubmission(submission: SupportKitTestFixture.submission())
        let firstStore = try SupportKitTestFixture.fileStore(
            identifier: "pending-persists",
            baseDirectory: baseDirectory,
        )

        // Act
        try await firstStore.enqueue(item, capacity: 10)
        let recoveredStore = try SupportKitTestFixture.fileStore(
            identifier: "pending-persists",
            baseDirectory: baseDirectory,
        )
        let recovered = await recoveredStore.dueSubmissions(
            before: SupportKitTestFixture.date,
            limit: 10,
        )

        // Assert
        #expect(recovered == [item])
        #expect(await recoveredStore.readyCount() == 1)
    }

    @Test
    func `retry state and its bounded failure reason survive a restart`() async throws {
        // Arrange
        let baseDirectory = try SupportKitTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let identifier = "retry-persists"
        let store = try SupportKitTestFixture.fileStore(identifier: identifier, baseDirectory: baseDirectory)
        let item = QueuedSupportSubmission(submission: SupportKitTestFixture.submission())
        let retryDate = SupportKitTestFixture.date.addingTimeInterval(120)
        let longReason = String(repeating: "r", count: 800)
        try await store.enqueue(item, capacity: 10)

        // Act
        try await store.markRetry(
            id: item.id,
            attemptCount: 3,
            nextAttemptAt: retryDate,
            failure: longReason,
        )
        let recoveredStore = try SupportKitTestFixture.fileStore(identifier: identifier, baseDirectory: baseDirectory)
        let recovered = await recoveredStore.pendingSubmission(
            withFingerprint: item.submission.contentFingerprint,
            since: .distantPast,
        )

        // Assert
        #expect(recovered?.attemptCount == 3)
        #expect(recovered?.nextAttemptAt == retryDate)
        #expect(recovered?.lastFailure?.count == 500)
        #expect(await recoveredStore.dueSubmissions(before: SupportKitTestFixture.date, limit: 10).isEmpty)
        #expect(await recoveredStore.dueSubmissions(before: retryDate, limit: 10) == [recovered])
    }

    @Test
    func `needs-attention state remains retained but is never returned as due`() async throws {
        // Arrange
        let baseDirectory = try SupportKitTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let identifier = "attention-persists"
        let store = try SupportKitTestFixture.fileStore(identifier: identifier, baseDirectory: baseDirectory)
        let item = QueuedSupportSubmission(submission: SupportKitTestFixture.submission())
        try await store.enqueue(item, capacity: 10)

        // Act
        try await store.markNeedsAttention(id: item.id, failure: "Fix gateway configuration.")
        let recoveredStore = try SupportKitTestFixture.fileStore(identifier: identifier, baseDirectory: baseDirectory)
        let recovered = await recoveredStore.pendingSubmission(
            withFingerprint: item.submission.contentFingerprint,
            since: .distantPast,
        )

        // Assert
        #expect(recovered?.state == .needsAttention)
        #expect(recovered?.lastFailure == "Fix gateway configuration.")
        #expect(await recoveredStore.readyCount() == 0)
        #expect(await recoveredStore.dueSubmissions(before: .distantFuture, limit: 10).isEmpty)
    }

    @Test
    func `accepted receipts survive restart and participate in fingerprint deduplication`() async throws {
        // Arrange
        let baseDirectory = try SupportKitTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let identifier = "receipt-persists"
        let store = try SupportKitTestFixture.fileStore(identifier: identifier, baseDirectory: baseDirectory)
        let item = QueuedSupportSubmission(submission: SupportKitTestFixture.submission())
        let receipt = SupportKitTestFixture.receipt()
        try await store.enqueue(item, capacity: 10)

        // Act
        try await store.markAccepted(
            id: item.id,
            receipt: receipt,
            fingerprint: item.submission.contentFingerprint,
            recordedAt: SupportKitTestFixture.date,
        )
        let recoveredStore = try SupportKitTestFixture.fileStore(identifier: identifier, baseDirectory: baseDirectory)
        let recoveredReceipt = await recoveredStore.acceptedReceipt(
            withFingerprint: item.submission.contentFingerprint,
            since: SupportKitTestFixture.date.addingTimeInterval(-1),
        )

        // Assert
        #expect(recoveredReceipt == receipt)
        #expect(await recoveredStore.readyCount() == 0)
        #expect(await recoveredStore.pendingSubmission(
            withFingerprint: item.submission.contentFingerprint,
            since: .distantPast,
        ) == nil)
    }

    @Test
    func `a receipt committed before pending cleanup prevents redelivery after a simulated crash`() async throws {
        // Arrange
        let baseDirectory = try SupportKitTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let identifier = "receipt-first-recovery"
        let store = try SupportKitTestFixture.fileStore(identifier: identifier, baseDirectory: baseDirectory)
        let item = QueuedSupportSubmission(submission: SupportKitTestFixture.submission())
        let receipt = SupportKitTestFixture.receipt()
        try await store.enqueue(item, capacity: 10)
        try await store.markAccepted(
            id: item.id,
            receipt: receipt,
            fingerprint: item.submission.contentFingerprint,
            recordedAt: SupportKitTestFixture.date,
        )
        let pendingURL = queueRoot(baseDirectory: baseDirectory, identifier: identifier)
            .appending(path: "Pending", directoryHint: .isDirectory)
            .appending(path: recordFilename(for: item))
        try encode(item).write(to: pendingURL, options: .atomic)

        // Act
        let recoveredStore = try SupportKitTestFixture.fileStore(identifier: identifier, baseDirectory: baseDirectory)
        let due = await recoveredStore.dueSubmissions(before: .distantFuture, limit: 10)

        // Assert
        #expect(due.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: pendingURL.path))
        #expect(await recoveredStore.acceptedReceipt(
            withFingerprint: item.submission.contentFingerprint,
            since: .distantPast,
        ) == receipt)
    }

    @Test
    func `corrupt queue files are quarantined without crashing healthy reads`() async throws {
        // Arrange
        let baseDirectory = try SupportKitTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let identifier = "corrupt-quarantine"
        let store = try SupportKitTestFixture.fileStore(identifier: identifier, baseDirectory: baseDirectory)
        let root = queueRoot(baseDirectory: baseDirectory, identifier: identifier)
        let pendingURL = root
            .appending(path: "Pending", directoryHint: .isDirectory)
            .appending(path: "broken.json")
        let corruptDirectory = root.appending(path: "Corrupt", directoryHint: .isDirectory)
        try Data("not-json".utf8).write(to: pendingURL)

        // Act
        let count = await store.readyCount()
        let pendingFiles = try FileManager.default.contentsOfDirectory(
            at: pendingURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil,
        )
        let corruptFiles = try FileManager.default.contentsOfDirectory(
            at: corruptDirectory,
            includingPropertiesForKeys: nil,
        )

        // Assert
        #expect(count == 0)
        #expect(pendingFiles.isEmpty)
        #expect(corruptFiles.count == 1)
        let corruptFile = try #require(corruptFiles.first)
        #expect(corruptFile.lastPathComponent.hasSuffix("-broken.json"))
    }

    @Test
    func `pending fingerprints ignore age while accepted fingerprints honor the suppression window`() async throws {
        // Arrange
        let baseDirectory = try SupportKitTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let store = try SupportKitTestFixture.fileStore(identifier: "dedup-window", baseDirectory: baseDirectory)
        let item = QueuedSupportSubmission(submission: SupportKitTestFixture.submission())
        try await store.enqueue(item, capacity: 10)

        // Act
        let pendingInside = await store.pendingSubmission(
            withFingerprint: item.submission.contentFingerprint,
            since: SupportKitTestFixture.date,
        )
        let pendingOutside = await store.pendingSubmission(
            withFingerprint: item.submission.contentFingerprint,
            since: SupportKitTestFixture.date.addingTimeInterval(1),
        )
        let receipt = SupportKitTestFixture.receipt()
        try await store.markAccepted(
            id: item.id,
            receipt: receipt,
            fingerprint: item.submission.contentFingerprint,
            recordedAt: SupportKitTestFixture.date,
        )
        let acceptedInside = await store.acceptedReceipt(
            withFingerprint: item.submission.contentFingerprint,
            since: SupportKitTestFixture.date,
        )
        let acceptedOutside = await store.acceptedReceipt(
            withFingerprint: item.submission.contentFingerprint,
            since: SupportKitTestFixture.date.addingTimeInterval(1),
        )

        // Assert
        #expect(pendingInside == item)
        #expect(pendingOutside == item)
        #expect(acceptedInside == receipt)
        #expect(acceptedOutside == nil)
    }

    @Test
    func `capacity rejects a distinct report but permits an idempotent rewrite of the same report`() async throws {
        // Arrange
        let baseDirectory = try SupportKitTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let store = try SupportKitTestFixture.fileStore(identifier: "capacity", baseDirectory: baseDirectory)
        let first = QueuedSupportSubmission(submission: SupportKitTestFixture.submission())
        let replacement = QueuedSupportSubmission(
            submission: first.submission,
            attemptCount: 2,
            lastFailure: "Retry",
        )
        let second = QueuedSupportSubmission(submission: SupportKitTestFixture.submission(
            id: SupportKitTestFixture.secondReportID,
            fingerprint: String(repeating: "b", count: 64),
        ))
        try await store.enqueue(first, capacity: 1)

        // Act
        try await store.enqueue(replacement, capacity: 1)

        // Assert
        await #expect(throws: SupportStoreError.queueFull) {
            try await store.enqueue(second, capacity: 1)
        }
        #expect(await store.readyCount() == 1)
        #expect(await store.pendingSubmission(
            withFingerprint: first.submission.contentFingerprint,
            since: .distantPast,
        )?.attemptCount == 2)
    }

    @Test
    func `delivery order is stable by retry date and creation date and respects the batch limit`() async throws {
        // Arrange
        let baseDirectory = try SupportKitTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let store = try SupportKitTestFixture.fileStore(identifier: "delivery-order", baseDirectory: baseDirectory)
        let later = QueuedSupportSubmission(
            submission: SupportKitTestFixture.submission(
                id: SupportKitTestFixture.secondReportID,
                createdAt: SupportKitTestFixture.date.addingTimeInterval(1),
                fingerprint: String(repeating: "b", count: 64),
            ),
            nextAttemptAt: SupportKitTestFixture.date.addingTimeInterval(20),
        )
        let earlier = QueuedSupportSubmission(
            submission: SupportKitTestFixture.submission(),
            nextAttemptAt: SupportKitTestFixture.date.addingTimeInterval(10),
        )
        try await store.enqueue(later, capacity: 10)
        try await store.enqueue(earlier, capacity: 10)

        // Act
        let firstDue = await store.dueSubmissions(before: .distantFuture, limit: 1)
        let allDue = await store.dueSubmissions(before: .distantFuture, limit: 10)

        // Assert
        #expect(firstDue.map(\.id) == [earlier.id])
        #expect(allDue.map(\.id) == [earlier.id, later.id])
    }

    private func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func queueRoot(baseDirectory: URL, identifier: String) -> URL {
        baseDirectory.appending(
            path: SupportQueueStorageNamespace.make(identifier: identifier),
            directoryHint: .isDirectory,
        )
    }

    private func recordFilename(for item: QueuedSupportSubmission) -> String {
        let namespace = SupportQueueStorageNamespace.make(identifier: item.queueScope.identifier)
        return "\(namespace)-\(item.id.uuidString.lowercased()).json"
    }
}
