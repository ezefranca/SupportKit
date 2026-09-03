import CryptoKit
import Darwin
import Foundation

/// An actor-isolated, encrypted queue with cross-process atomic operations.
public actor FileSupportSubmissionStore: SupportSubmissionStore {
    struct StorageSetup {
        let pendingDirectory: URL
        let receiptDirectory: URL
        let corruptDirectory: URL
        let lockFileDescriptor: Int32
    }

    private static let processLock = NSLock()

    let identifier: String
    let pendingDirectory: URL
    let receiptDirectory: URL
    let corruptDirectory: URL
    private let lockFileDescriptor: Int32
    private let encryptionKeyProvider: any SupportQueueEncryptionKeyProviding

    /// Opens or creates an encrypted queue with cross-process locking.
    ///
    /// - Parameters:
    ///   - identifier: A validated logical queue namespace. Exact spelling matters; the store hashes it into separate
    ///     filesystem and encryption-key namespaces.
    ///   - baseDirectory: An optional queue root. The default is Application Support.
    /// - Throws: ``SupportStoreError`` when the directory, lock, or key cannot be prepared.
    public init(identifier: String, baseDirectory: URL? = nil) throws {
        guard SupportIdentifierValidator.isValid(identifier) else {
            throw SupportConfigurationError.invalidQueueIdentifier
        }
        let storageIdentifier = SupportQueueStorageNamespace.make(identifier: identifier)
        let setup = try Self.prepareStorage(identifier: storageIdentifier, baseDirectory: baseDirectory)
        self.identifier = storageIdentifier
        pendingDirectory = setup.pendingDirectory
        receiptDirectory = setup.receiptDirectory
        corruptDirectory = setup.corruptDirectory
        lockFileDescriptor = setup.lockFileDescriptor
        encryptionKeyProvider = SupportQueueEncryptionKeyProvider(identifier: storageIdentifier)
    }

    init(
        identifier: String,
        baseDirectory: URL? = nil,
        encryptionKeyProvider: any SupportQueueEncryptionKeyProviding,
    ) throws {
        guard SupportIdentifierValidator.isValid(identifier) else {
            throw SupportConfigurationError.invalidQueueIdentifier
        }
        let storageIdentifier = SupportQueueStorageNamespace.make(identifier: identifier)
        let setup = try Self.prepareStorage(identifier: storageIdentifier, baseDirectory: baseDirectory)
        self.identifier = storageIdentifier
        pendingDirectory = setup.pendingDirectory
        receiptDirectory = setup.receiptDirectory
        corruptDirectory = setup.corruptDirectory
        lockFileDescriptor = setup.lockFileDescriptor
        self.encryptionKeyProvider = encryptionKeyProvider
    }

    deinit {
        _ = Darwin.close(lockFileDescriptor)
    }

    public func enqueue(_ item: QueuedSupportSubmission, capacity: Int) async throws {
        guard SupportQueueScope.isValid(item.queueScope.identifier) else {
            throw SupportStoreError.cannotPersist
        }
        let key = try await encryptionKey()
        try withExclusiveLock {
            let items = removeAcceptedPending(from: loadPendingItems(using: key), using: key)
            let scopedItems = items.filter { $0.queueScope == item.queueScope }
            guard capacity > 0,
                  scopedItems.count < capacity || scopedItems.contains(where: { $0.id == item.id })
            else {
                throw SupportStoreError.queueFull
            }
            try write(item, to: pendingURL(for: item.id, in: item.queueScope), using: key)
        }
    }

    public func enqueueIfAbsent(
        _ item: QueuedSupportSubmission,
        duplicateSince date: Date,
        capacity: Int,
    ) async throws -> SupportStoreEnqueueResult {
        guard SupportQueueScope.isValid(item.queueScope.identifier) else {
            throw SupportStoreError.cannotPersist
        }
        let key = try await encryptionKey()
        return try withExclusiveLock {
            let receipts = loadStoredReceipts(using: key)
            if let receipt = receipts
                .filter({
                    $0.queueScope == item.queueScope
                        && $0.contentFingerprint == item.submission.contentFingerprint
                        && $0.recordedAt >= date
                })
                .max(by: Self.receiptRecencyOrder)?
                .receipt {
                return .duplicateAccepted(receipt)
            }

            let validReceiptKeys = Set(receipts.map {
                SupportQueueRecordID(queueScope: $0.queueScope, reportID: $0.receipt.reportID)
            })
            var pending = loadPendingItems(using: key)
            pending.removeAll { queued in
                let recordKey = queued.recordID
                guard validReceiptKeys.contains(recordKey) else { return false }
                removeIfPresent(pendingURL(for: queued.id, in: queued.queueScope))
                return true
            }

            if var duplicate = pending.first(where: {
                $0.queueScope == item.queueScope
                    && $0.submission.contentFingerprint == item.submission.contentFingerprint
            }) {
                if duplicate.state == .needsAttention {
                    duplicate.attemptCount = 0
                    duplicate.nextAttemptAt = item.submission.createdAt
                    duplicate.lastFailure = nil
                    duplicate.state = .ready
                    duplicate.leaseID = nil
                    duplicate.leaseExpiresAt = nil
                    try write(
                        duplicate,
                        to: pendingURL(for: duplicate.id, in: duplicate.queueScope),
                        using: key,
                    )
                    return .enqueued(reportID: duplicate.id)
                }
                return .duplicatePending(reportID: duplicate.id)
            }

            let scopedPendingCount = pending.count { $0.queueScope == item.queueScope }
            guard capacity > 0, scopedPendingCount < capacity else {
                throw SupportStoreError.queueFull
            }
            try write(item, to: pendingURL(for: item.id, in: item.queueScope), using: key)
            return .enqueued(reportID: item.id)
        }
    }

    public func dueSubmissions(
        in scope: SupportQueueScope,
        before date: Date,
        limit: Int,
    ) async -> [QueuedSupportSubmission] {
        guard limit > 0, let key = try? await encryptionKeyProvider.key() else { return [] }
        return (try? withExclusiveLock {
            dueSubmissions(in: scope, before: date, limit: limit, using: key)
        }) ?? []
    }

    public func claimDueSubmissions(
        in scope: SupportQueueScope,
        before date: Date,
        limit: Int,
        leaseID: UUID,
        leaseExpiresAt: Date,
    ) async throws -> [QueuedSupportSubmission] {
        guard SupportQueueScope.isValid(scope.identifier) else {
            throw SupportStoreError.cannotPersist
        }
        guard limit > 0, leaseExpiresAt > date else { return [] }
        let key = try await encryptionKey()
        return try withExclusiveLock {
            let due = dueSubmissions(in: scope, before: date, limit: limit, using: key)
            return try due.map { item in
                var leased = item
                leased.leaseID = leaseID
                leased.leaseExpiresAt = leaseExpiresAt
                try write(leased, to: pendingURL(for: leased.id, in: scope), using: key)
                return leased
            }
        }
    }

    public func nextReadyDate(in scope: SupportQueueScope) async -> Date? {
        await nextReadyDate(in: scope, relativeTo: .now)
    }

    public func nextReadyDate(in scope: SupportQueueScope, relativeTo date: Date) async -> Date? {
        guard let key = try? await encryptionKeyProvider.key() else { return nil }
        return try? withExclusiveLock {
            let items = removeAcceptedPending(from: loadPendingItems(using: key), using: key)
            return items
                .filter { $0.queueScope == scope && $0.state == .ready }
                .map { item in
                    if Self.hasActiveLease(item, at: date), let leaseExpiresAt = item.leaseExpiresAt {
                        return max(item.nextAttemptAt, leaseExpiresAt)
                    }
                    return item.nextAttemptAt
                }
                .min()
        }
    }

    public func pendingSubmission(
        in scope: SupportQueueScope,
        withFingerprint fingerprint: String,
        since _: Date,
    ) async -> QueuedSupportSubmission? {
        guard let key = try? await encryptionKeyProvider.key() else { return nil }
        return try? withExclusiveLock {
            removeAcceptedPending(from: loadPendingItems(using: key), using: key)
                .filter {
                    $0.queueScope == scope && $0.submission.contentFingerprint == fingerprint
                }
                .max(by: Self.pendingRecencyOrder)
        }
    }

    public func acceptedReceipt(
        in scope: SupportQueueScope,
        withFingerprint fingerprint: String,
        since date: Date,
    ) async -> SupportDeliveryReceipt? {
        guard let key = try? await encryptionKeyProvider.key() else { return nil }
        return try? withExclusiveLock {
            loadStoredReceipts(using: key)
                .filter {
                    $0.queueScope == scope
                        && $0.contentFingerprint == fingerprint
                        && $0.recordedAt >= date
                }
                .max(by: Self.receiptRecencyOrder)?
                .receipt
        }
    }
}

extension FileSupportSubmissionStore {
    func encryptionKey() async throws -> SymmetricKey {
        do {
            return try await encryptionKeyProvider.key()
        } catch {
            throw SupportStoreError.cannotPersist
        }
    }

    private func dueSubmissions(
        in scope: SupportQueueScope,
        before date: Date,
        limit: Int,
        using key: SymmetricKey,
    ) -> [QueuedSupportSubmission] {
        removeAcceptedPending(from: loadPendingItems(using: key), using: key)
            .filter {
                $0.queueScope == scope
                    && $0.state == .ready
                    && $0.nextAttemptAt <= date
                    && !Self.hasActiveLease($0, at: date)
            }
            .sorted(by: Self.deliveryOrder)
            .prefix(limit)
            .map(\.self)
    }

    func withExclusiveLock<Result>(_ operation: () throws -> Result) throws -> Result {
        try Self.processLock.withLock {
            try lockFile()
            defer { unlockFile() }
            return try operation()
        }
    }

    private func lockFile() throws {
        var lock = Darwin.flock()
        lock.l_start = 0
        lock.l_len = 0
        lock.l_pid = 0
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)

        while fcntl(lockFileDescriptor, F_SETLKW, &lock) == -1 {
            guard errno == EINTR else { throw SupportStoreError.cannotPersist }
        }
    }

    private func unlockFile() {
        var lock = Darwin.flock()
        lock.l_start = 0
        lock.l_len = 0
        lock.l_pid = 0
        lock.l_type = Int16(F_UNLCK)
        lock.l_whence = Int16(SEEK_SET)

        while fcntl(lockFileDescriptor, F_SETLK, &lock) == -1, errno == EINTR {}
    }

    private static func hasActiveLease(_ item: QueuedSupportSubmission, at date: Date) -> Bool {
        item.leaseID != nil && item.leaseExpiresAt.map { $0 > date } == true
    }

    private static func deliveryOrder(_ lhs: QueuedSupportSubmission, _ rhs: QueuedSupportSubmission) -> Bool {
        if lhs.nextAttemptAt == rhs.nextAttemptAt {
            if lhs.submission.createdAt == rhs.submission.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.submission.createdAt < rhs.submission.createdAt
        }
        return lhs.nextAttemptAt < rhs.nextAttemptAt
    }

    private static func pendingRecencyOrder(
        _ lhs: QueuedSupportSubmission,
        _ rhs: QueuedSupportSubmission,
    ) -> Bool {
        if lhs.submission.createdAt == rhs.submission.createdAt {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.submission.createdAt < rhs.submission.createdAt
    }

    private static func receiptRecencyOrder(_ lhs: StoredSupportReceipt, _ rhs: StoredSupportReceipt) -> Bool {
        if lhs.recordedAt == rhs.recordedAt {
            return lhs.receipt.reportID.uuidString < rhs.receipt.reportID.uuidString
        }
        return lhs.recordedAt < rhs.recordedAt
    }
}
