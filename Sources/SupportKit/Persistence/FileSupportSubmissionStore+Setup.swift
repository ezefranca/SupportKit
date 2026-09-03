import Darwin
import Foundation

extension FileSupportSubmissionStore {
    static func prepareStorage(identifier: String, baseDirectory: URL?) throws -> StorageSetup {
        guard SupportIdentifierValidator.isValid(identifier) else {
            throw SupportConfigurationError.invalidQueueIdentifier
        }

        let fileManager = FileManager.default
        let base: URL
        if let baseDirectory {
            base = baseDirectory
        } else if let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
        ).first {
            base = applicationSupport
                .appending(path: "SupportKit", directoryHint: .isDirectory)
                .appending(path: SupportQueueHostNamespace.current, directoryHint: .isDirectory)
        } else {
            throw SupportStoreError.cannotCreateDirectory
        }

        let root = base.appending(path: identifier, directoryHint: .isDirectory)
        let pending = root.appending(path: "Pending", directoryHint: .isDirectory)
        let receipts = root.appending(path: "Receipts", directoryHint: .isDirectory)
        let corrupt = root.appending(path: "Corrupt", directoryHint: .isDirectory)
        let lockFile = root.appending(path: ".queue.lock")

        var descriptor: Int32 = -1
        do {
            for directory in [root, pending, receipts, corrupt] {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try applyStorageAttributes(to: directory)
            }

            descriptor = lockFile.withUnsafeFileSystemRepresentation { path in
                guard let path else { return -1 }
                return Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
            }
            guard descriptor >= 0 else {
                throw SupportStoreError.cannotCreateDirectory
            }
            try applyStorageAttributes(to: lockFile)
            return StorageSetup(
                pendingDirectory: pending,
                receiptDirectory: receipts,
                corruptDirectory: corrupt,
                lockFileDescriptor: descriptor,
            )
        } catch {
            if descriptor >= 0 {
                _ = Darwin.close(descriptor)
            }
            throw SupportStoreError.cannotCreateDirectory
        }
    }
}
