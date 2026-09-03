import CryptoKit
import Foundation

private enum SupportStoreFileLimits {
    static let maximumDirectoryEntriesPerRead = 10000
    static let maximumEncryptedRecordBytes = 512 * 1024
    static let maximumReceiptRecords = 10000
    static let readChunkBytes = 64 * 1024
}

extension FileSupportSubmissionStore {
    func markAccepted(
        recordID: SupportQueueRecordID,
        receipt: SupportDeliveryReceipt,
        fingerprint: String,
        recordedAt: Date,
        using key: SymmetricKey,
    ) throws {
        guard receipt.reportID == recordID.reportID else { throw SupportStoreError.cannotPersist }
        let stored = StoredSupportReceipt(
            queueScope: recordID.queueScope,
            receipt: receipt,
            contentFingerprint: fingerprint,
            recordedAt: recordedAt,
        )

        let existingReceipts = loadStoredReceipts(using: key)
        let scopedReceipts = existingReceipts.filter { $0.queueScope == recordID.queueScope }
        if !scopedReceipts.contains(where: { $0.receipt.reportID == recordID.reportID }),
           scopedReceipts.count >= SupportStoreFileLimits.maximumReceiptRecords {
            let removalCount = scopedReceipts.count - SupportStoreFileLimits.maximumReceiptRecords + 1
            for expired in scopedReceipts
                .sorted(by: Self.receiptAgeOrder)
                .prefix(removalCount) {
                removeIfPresent(receiptURL(for: expired.receipt.reportID, in: recordID.queueScope))
            }
        }

        // Receipt first: if the process stops before removal, the valid receipt
        // suppresses the pending item on the next locked read.
        try write(
            stored,
            to: receiptURL(for: recordID.reportID, in: recordID.queueScope),
            using: key,
        )
        removeIfPresent(pendingURL(for: recordID.reportID, in: recordID.queueScope))
    }

    func applyRetry(
        to item: inout QueuedSupportSubmission,
        attemptCount: Int,
        nextAttemptAt: Date,
        failure: String,
    ) {
        item.attemptCount = max(0, attemptCount)
        item.nextAttemptAt = nextAttemptAt
        item.lastFailure = SupportTextSafety.boundedFailureReason(failure)
        item.state = .ready
        item.leaseID = nil
        item.leaseExpiresAt = nil
    }

    func applyNeedsAttention(to item: inout QueuedSupportSubmission, failure: String) {
        item.lastFailure = SupportTextSafety.boundedFailureReason(failure)
        item.state = .needsAttention
        item.leaseID = nil
        item.leaseExpiresAt = nil
    }

    func removeAcceptedPending(
        from pending: [QueuedSupportSubmission],
        using key: SymmetricKey,
    ) -> [QueuedSupportSubmission] {
        let receiptKeys = Set(loadStoredReceipts(using: key).map {
            SupportQueueRecordID(queueScope: $0.queueScope, reportID: $0.receipt.reportID)
        })
        return pending.filter { item in
            let recordKey = item.recordID
            guard receiptKeys.contains(recordKey) else { return true }
            removeIfPresent(pendingURL(for: item.id, in: item.queueScope))
            return false
        }
    }

    func loadPendingItems(using key: SymmetricKey) -> [QueuedSupportSubmission] {
        loadFiles(in: pendingDirectory, as: QueuedSupportSubmission.self, using: key)
    }

    func loadPendingItem(
        id: UUID,
        in scope: SupportQueueScope,
        using key: SymmetricKey,
    ) -> QueuedSupportSubmission? {
        loadFile(
            at: pendingURL(for: id, in: scope),
            as: QueuedSupportSubmission.self,
            using: key,
        )
    }

    func loadStoredReceipts(using key: SymmetricKey) -> [StoredSupportReceipt] {
        loadFiles(in: receiptDirectory, as: StoredSupportReceipt.self, using: key)
    }

    func loadFiles<Value: Codable>(
        in directory: URL,
        as type: Value.Type,
        using key: SymmetricKey,
    ) -> [Value] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
        ) else { return [] }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard urls.count < SupportStoreFileLimits.maximumDirectoryEntriesPerRead else { break }
            urls.append(url)
        }

        var values: [Value] = []
        for url in urls {
            if let value = loadFile(at: url, as: type, using: key) {
                values.append(value)
            }
        }
        return values
    }

    func loadFile<Value: Codable>(
        at url: URL,
        as type: Value.Type,
        using key: SymmetricKey,
    ) -> Value? {
        do {
            let storedData = try boundedStoredData(at: url)
            let plaintext = try SupportQueueCipher.open(
                storedData,
                using: key,
                authenticating: associatedData(for: url),
            )
            return try Self.decoder().decode(type, from: plaintext)
        } catch {
            quarantine(url)
            return nil
        }
    }

    private func boundedStoredData(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              values.fileSize.map({ $0 <= SupportStoreFileLimits.maximumEncryptedRecordBytes }) != false
        else {
            throw SupportQueueEncryptionError.invalidEnvelope
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        if let fileSize = values.fileSize {
            data.reserveCapacity(fileSize)
        }

        while data.count <= SupportStoreFileLimits.maximumEncryptedRecordBytes {
            let remaining = SupportStoreFileLimits.maximumEncryptedRecordBytes + 1 - data.count
            let chunkSize = min(SupportStoreFileLimits.readChunkBytes, remaining)
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= SupportStoreFileLimits.maximumEncryptedRecordBytes else {
            throw SupportQueueEncryptionError.invalidEnvelope
        }
        return data
    }

    func write(_ value: some Encodable, to url: URL, using key: SymmetricKey) throws {
        do {
            let plaintext = try Self.encoder().encode(value)
            let encrypted = try SupportQueueCipher.seal(
                plaintext,
                using: key,
                authenticating: associatedData(for: url),
            )
            try encrypted.write(
                to: url,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication],
            )
            try Self.applyStorageAttributes(to: url)
        } catch {
            throw SupportStoreError.cannotPersist
        }
    }

    func quarantine(_ url: URL) {
        guard url.deletingLastPathComponent() != corruptDirectory else { return }
        let destination = corruptDirectory.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)")
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            try Self.applyStorageAttributes(to: destination)
        } catch {
            // Quarantine is best-effort; callers still receive an empty/failed read.
        }
    }

    func associatedData(for url: URL) -> Data {
        let parent = url.deletingLastPathComponent().lastPathComponent
        return Data("SupportKit.Queue.v1|\(identifier)|\(parent)|\(url.lastPathComponent)".utf8)
    }

    func pendingURL(for id: UUID, in scope: SupportQueueScope) -> URL {
        pendingDirectory.appending(path: recordFilename(for: id, in: scope))
    }

    func receiptURL(for id: UUID, in scope: SupportQueueScope) -> URL {
        receiptDirectory.appending(path: recordFilename(for: id, in: scope))
    }

    private func recordFilename(for id: UUID, in scope: SupportQueueScope) -> String {
        let namespace = SupportQueueStorageNamespace.make(identifier: scope.identifier)
        return "\(namespace)-\(id.uuidString.lowercased()).json"
    }

    func removeIfPresent(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch where (error as NSError).code == NSFileNoSuchFileError {
            // The desired postcondition already holds.
        } catch {
            // Cleanup is retried on the next locked read.
        }
    }

    static func applyStorageAttributes(to url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)

        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path,
            )
        #endif
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func receiptAgeOrder(_ lhs: StoredSupportReceipt, _ rhs: StoredSupportReceipt) -> Bool {
        if lhs.recordedAt == rhs.recordedAt {
            return lhs.receipt.reportID.uuidString < rhs.receipt.reportID.uuidString
        }
        return lhs.recordedAt < rhs.recordedAt
    }
}
