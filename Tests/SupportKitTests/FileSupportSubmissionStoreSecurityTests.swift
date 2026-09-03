import Foundation
@testable import SupportKit
import Testing

@Suite("Durable file store security and coordination")
struct FileSupportSubmissionStoreSecurityTests {
    @Test
    func `pending reports are encrypted at rest`() async throws {
        // Arrange
        let baseDirectory = try SupportKitTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let identifier = "encrypted-at-rest"
        let privateMessage = "A private support report that must not appear on disk"
        let item = QueuedSupportSubmission(submission: SupportKitTestFixture.submission(
            message: privateMessage,
        ))
        let store = try SupportKitTestFixture.fileStore(
            identifier: identifier,
            baseDirectory: baseDirectory,
        )
        let pendingURL = pendingURL(
            baseDirectory: baseDirectory,
            identifier: identifier,
            reportID: item.id,
        )

        // Act
        try await store.enqueue(item, capacity: 10)
        let storedData = try Data(contentsOf: pendingURL)

        // Assert
        #expect(SupportQueueCipher.isEncrypted(storedData))
        #expect(storedData.range(of: Data(privateMessage.utf8)) == nil)
    }

    @Test
    func `two store instances atomically coalesce the same fingerprint`() async throws {
        // Arrange
        let baseDirectory = try SupportKitTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let identifier = "cross-instance-dedup"
        let firstStore = try SupportKitTestFixture.fileStore(
            identifier: identifier,
            baseDirectory: baseDirectory,
        )
        let secondStore = try SupportKitTestFixture.fileStore(
            identifier: identifier,
            baseDirectory: baseDirectory,
        )
        let first = QueuedSupportSubmission(submission: SupportKitTestFixture.submission())
        let second = QueuedSupportSubmission(submission: SupportKitTestFixture.submission(
            id: SupportKitTestFixture.secondReportID,
        ))

        // Act
        async let firstResult = firstStore.enqueueIfAbsent(
            first,
            duplicateSince: .distantPast,
            capacity: 10,
        )
        async let secondResult = secondStore.enqueueIfAbsent(
            second,
            duplicateSince: .distantPast,
            capacity: 10,
        )
        let results = try await [firstResult, secondResult]

        // Assert
        let enqueuedCount = results.count { result in
            if case .enqueued = result {
                true
            } else {
                false
            }
        }
        let duplicateCount = results.count { result in
            if case .duplicatePending = result {
                true
            } else {
                false
            }
        }
        #expect(enqueuedCount == 1)
        #expect(duplicateCount == 1)
        #expect(await firstStore.readyCount() == 1)
        #expect(await secondStore.readyCount() == 1)
    }

    @Test
    func `a persisted lease prevents another store from claiming until expiry`() async throws {
        // Arrange
        let baseDirectory = try SupportKitTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let identifier = "cross-instance-lease"
        let firstStore = try SupportKitTestFixture.fileStore(
            identifier: identifier,
            baseDirectory: baseDirectory,
        )
        let secondStore = try SupportKitTestFixture.fileStore(
            identifier: identifier,
            baseDirectory: baseDirectory,
        )
        let item = QueuedSupportSubmission(submission: SupportKitTestFixture.submission())
        let firstLeaseID = SupportKitTestFixture.reportID
        let secondLeaseID = SupportKitTestFixture.secondReportID
        let expiry = SupportKitTestFixture.date.addingTimeInterval(60)
        try await firstStore.enqueue(item, capacity: 10)

        // Act
        let firstClaim = try await firstStore.claimDueSubmissions(
            before: SupportKitTestFixture.date,
            limit: 1,
            leaseID: firstLeaseID,
            leaseExpiresAt: expiry,
        )
        let overlappingClaim = try await secondStore.claimDueSubmissions(
            before: SupportKitTestFixture.date,
            limit: 1,
            leaseID: secondLeaseID,
            leaseExpiresAt: expiry,
        )
        let recoveredClaim = try await secondStore.claimDueSubmissions(
            before: expiry,
            limit: 1,
            leaseID: secondLeaseID,
            leaseExpiresAt: expiry.addingTimeInterval(60),
        )

        // Assert
        #expect(firstClaim.map(\.id) == [item.id])
        #expect(overlappingClaim.isEmpty)
        #expect(recoveredClaim.map(\.id) == [item.id])
        #expect(recoveredClaim.first?.leaseID == secondLeaseID)
    }

    @Test
    func `a plaintext queue record is rejected and quarantined`() async throws {
        // Arrange
        let baseDirectory = try SupportKitTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let identifier = "plaintext-rejection"
        let store = try SupportKitTestFixture.fileStore(
            identifier: identifier,
            baseDirectory: baseDirectory,
        )
        let item = QueuedSupportSubmission(submission: SupportKitTestFixture.submission())
        let pendingURL = pendingURL(
            baseDirectory: baseDirectory,
            identifier: identifier,
            reportID: item.id,
        )
        try encode(item).write(to: pendingURL, options: .atomic)

        // Act
        let recovered = await store.pendingSubmission(
            withFingerprint: item.submission.contentFingerprint,
            since: .distantPast,
        )
        let quarantinedFiles = try FileManager.default.contentsOfDirectory(
            at: corruptDirectory(baseDirectory: baseDirectory, identifier: identifier),
            includingPropertiesForKeys: nil,
        )

        // Assert
        #expect(recovered == nil)
        #expect(!FileManager.default.fileExists(atPath: pendingURL.path))
        #expect(quarantinedFiles.count == 1)
    }

    @Test
    func `an oversized encrypted record is quarantined without an unbounded read`() async throws {
        // Arrange
        let baseDirectory = try SupportKitTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let identifier = "oversized-record"
        let store = try SupportKitTestFixture.fileStore(
            identifier: identifier,
            baseDirectory: baseDirectory,
        )
        let oversizedURL = pendingURL(
            baseDirectory: baseDirectory,
            identifier: identifier,
            reportID: SupportKitTestFixture.reportID,
        )
        let oversizedByteCount = 512 * 1024 + 1
        let created = FileManager.default.createFile(atPath: oversizedURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversizedURL)
        try handle.truncate(atOffset: UInt64(oversizedByteCount))
        try handle.close()

        // Act
        let readyCount = await store.readyCount()
        let quarantinedFiles = try FileManager.default.contentsOfDirectory(
            at: corruptDirectory(baseDirectory: baseDirectory, identifier: identifier),
            includingPropertiesForKeys: [.fileSizeKey],
        )

        // Assert
        #expect(created)
        #expect(readyCount == 0)
        #expect(!FileManager.default.fileExists(atPath: oversizedURL.path))
        let quarantined = try #require(quarantinedFiles.first)
        #expect(quarantinedFiles.count == 1)
        #expect(try quarantined.resourceValues(forKeys: [.fileSizeKey]).fileSize == oversizedByteCount)
    }

    private func pendingURL(
        baseDirectory: URL,
        identifier: String,
        reportID: UUID,
        queueScope: SupportQueueScope = SupportKitTestFixture.queueScope,
    ) -> URL {
        let storageNamespace = SupportQueueStorageNamespace.make(identifier: identifier)
        let recordNamespace = SupportQueueStorageNamespace.make(identifier: queueScope.identifier)
        return baseDirectory
            .appending(path: storageNamespace, directoryHint: .isDirectory)
            .appending(path: "Pending", directoryHint: .isDirectory)
            .appending(path: "\(recordNamespace)-\(reportID.uuidString.lowercased()).json")
    }

    private func corruptDirectory(baseDirectory: URL, identifier: String) -> URL {
        baseDirectory
            .appending(
                path: SupportQueueStorageNamespace.make(identifier: identifier),
                directoryHint: .isDirectory,
            )
            .appending(path: "Corrupt", directoryHint: .isDirectory)
    }

    private func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
