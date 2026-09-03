import CryptoKit
import Foundation
@testable import SupportKit
import Testing

@Suite("Queue payload encryption")
struct SupportQueueEncryptionTests {
    @Test
    func `AES-GCM ciphertext round-trips without retaining plaintext`() throws {
        // Arrange
        let key = SymmetricKey(data: Data(repeating: 0x11, count: 32))
        let plaintext = Data("private support message".utf8)
        let associatedData = Data("pending/report.json".utf8)

        // Act
        let encrypted = try SupportQueueCipher.seal(
            plaintext,
            using: key,
            authenticating: associatedData,
        )
        let recovered = try SupportQueueCipher.open(
            encrypted,
            using: key,
            authenticating: associatedData,
        )

        // Assert
        #expect(SupportQueueCipher.isEncrypted(encrypted))
        #expect(encrypted != plaintext)
        #expect(encrypted.range(of: plaintext) == nil)
        #expect(recovered == plaintext)
    }

    @Test
    func `fresh nonces produce different ciphertext for the same payload`() throws {
        // Arrange
        let key = SymmetricKey(data: Data(repeating: 0x22, count: 32))
        let plaintext = Data("same report".utf8)
        let associatedData = Data("same-file".utf8)

        // Act
        let first = try SupportQueueCipher.seal(plaintext, using: key, authenticating: associatedData)
        let second = try SupportQueueCipher.seal(plaintext, using: key, authenticating: associatedData)

        // Assert
        #expect(first != second)
        #expect(try SupportQueueCipher.open(first, using: key, authenticating: associatedData) == plaintext)
        #expect(try SupportQueueCipher.open(second, using: key, authenticating: associatedData) == plaintext)
    }

    @Test
    func `wrong keys, changed file identity, and ciphertext tampering fail closed`() throws {
        // Arrange
        let key = SymmetricKey(data: Data(repeating: 0x33, count: 32))
        let wrongKey = SymmetricKey(data: Data(repeating: 0x44, count: 32))
        let associatedData = Data("pending/report.json".utf8)
        let encrypted = try SupportQueueCipher.seal(
            Data("sensitive report".utf8),
            using: key,
            authenticating: associatedData,
        )
        var tampered = encrypted
        let finalIndex = tampered.index(before: tampered.endIndex)
        tampered[finalIndex] ^= 0x01

        // Act / Assert
        #expect(throws: (any Error).self) {
            _ = try SupportQueueCipher.open(encrypted, using: wrongKey, authenticating: associatedData)
        }
        #expect(throws: (any Error).self) {
            _ = try SupportQueueCipher.open(
                encrypted,
                using: key,
                authenticating: Data("receipts/report.json".utf8),
            )
        }
        #expect(throws: (any Error).self) {
            _ = try SupportQueueCipher.open(tampered, using: key, authenticating: associatedData)
        }
    }

    @Test
    func `plaintext bytes are rejected instead of bypassing authenticated encryption`() throws {
        // Arrange
        let plaintext = Data("unencrypted queue record".utf8)
        let key = SymmetricKey(data: Data(repeating: 0x55, count: 32))

        // Act / Assert
        #expect(!SupportQueueCipher.isEncrypted(plaintext))
        #expect(throws: SupportQueueEncryptionError.self) {
            _ = try SupportQueueCipher.open(
                plaintext,
                using: key,
                authenticating: Data("queue-file".utf8),
            )
        }
    }

    #if os(macOS)
        @Test
        func `legacy macOS Keychain fallback is limited to non-app hosts`() {
            // Act / Assert
            #expect(!SupportQueueEncryptionKeyProvider.allowsLegacyFallback(
                bundleURL: URL(fileURLWithPath: "/Applications/Example.app"),
            ))
            #expect(!SupportQueueEncryptionKeyProvider.allowsLegacyFallback(
                bundleURL: URL(fileURLWithPath: "/Applications/Example.app/PlugIns/Widget.appex"),
            ))
            #expect(SupportQueueEncryptionKeyProvider.allowsLegacyFallback(
                bundleURL: URL(fileURLWithPath: "/usr/local/bin/support-tool"),
            ))
        }

        @Test
        func `the production provider persists and cleans up a device-local key`() async throws {
            // Arrange
            let service = "dev.supportkit.tests.\(UUID().uuidString)"
            let account = "keychain-fallback"
            let firstProvider = SupportQueueEncryptionKeyProvider(
                identifier: account,
                service: service,
            )

            do {
                // Act
                let firstKey = try await firstProvider.key()
                let secondProvider = SupportQueueEncryptionKeyProvider(
                    identifier: account,
                    service: service,
                )
                let recoveredKey = try await secondProvider.key()
                let firstData = firstKey.withUnsafeBytes { Data($0) }
                let recoveredData = recoveredKey.withUnsafeBytes { Data($0) }
                try await firstProvider.deleteKey()

                // Assert
                #expect(firstData.count == 32)
                #expect(recoveredData == firstData)
            } catch {
                try? await firstProvider.deleteKey()
                throw error
            }
        }
    #endif
}
