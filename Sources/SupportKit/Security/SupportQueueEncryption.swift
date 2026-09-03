import CryptoKit
import Foundation
import Security

enum SupportQueueEncryptionError: Error {
    case invalidKeyData
    case invalidEnvelope
    case keychain(OSStatus)
    case unavailableCombinedRepresentation
}

protocol SupportQueueEncryptionKeyProviding: Sendable {
    func key() async throws -> SymmetricKey
}

/// Isolates blocking Security.framework calls from application actors.
actor SupportQueueEncryptionKeyProvider: SupportQueueEncryptionKeyProviding {
    private static let servicePrefix = "dev.supportkit.queue-encryption.v1"

    private let service: String
    private let account: String
    private var cachedKey: SymmetricKey?
    #if os(macOS)
        private let allowsLegacyKeychainFallback: Bool
        private var usesDataProtectionKeychain = true
    #endif

    init(
        identifier: String,
        hostNamespace: String = SupportQueueHostNamespace.current,
        service: String? = nil,
        allowsLegacyKeychainFallback: Bool? = nil,
    ) {
        account = identifier
        self.service = service ?? "\(Self.servicePrefix).\(hostNamespace)"
        #if os(macOS)
            self.allowsLegacyKeychainFallback = allowsLegacyKeychainFallback
                ?? Self.allowsLegacyFallback(bundleURL: Bundle.main.bundleURL)
        #endif
    }

    func key() throws -> SymmetricKey {
        if let cachedKey {
            return cachedKey
        }

        while true {
            if let stored = try loadKeyData() {
                guard stored.count == 32 else {
                    throw SupportQueueEncryptionError.invalidKeyData
                }
                let key = SymmetricKey(data: stored)
                cachedKey = key
                return key
            }

            let generatedKey = SymmetricKey(size: .bits256)
            let generatedData = generatedKey.withUnsafeBytes { Data($0) }
            var addQuery = baseQuery()
            addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            addQuery[kSecValueData] = generatedData

            let status = SecItemAdd(addQuery as CFDictionary, nil)
            #if os(macOS)
                if status == errSecMissingEntitlement,
                   usesDataProtectionKeychain,
                   allowsLegacyKeychainFallback {
                    usesDataProtectionKeychain = false
                    continue
                }
            #endif
            switch status {
            case errSecSuccess:
                cachedKey = generatedKey
                return generatedKey
            case errSecDuplicateItem:
                // A cooperating process won key creation. Never overwrite that
                // key: existing queue files may already depend on it.
                guard let stored = try loadKeyData(), stored.count == 32 else {
                    throw SupportQueueEncryptionError.invalidKeyData
                }
                let key = SymmetricKey(data: stored)
                cachedKey = key
                return key
            case errSecInteractionNotAllowed:
                throw SupportQueueEncryptionError.keychain(status)
            default:
                throw SupportQueueEncryptionError.keychain(status)
            }
        }
    }

    private func loadKeyData() throws -> Data? {
        var query = baseQuery()
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        #if os(macOS)
            if status == errSecMissingEntitlement,
               usesDataProtectionKeychain,
               allowsLegacyKeychainFallback {
                // SwiftPM test bundles and unsandboxed macOS tools do not have
                // a data-protection Keychain entitlement. The classic macOS
                // Keychain still honors the explicit ThisDeviceOnly class.
                usesDataProtectionKeychain = false
                return try loadKeyData()
            }
        #endif
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw SupportQueueEncryptionError.invalidKeyData
            }
            return data
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            throw SupportQueueEncryptionError.keychain(status)
        default:
            throw SupportQueueEncryptionError.keychain(status)
        }
    }

    private func baseQuery() -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
        ]
        #if os(macOS)
            if usesDataProtectionKeychain {
                query[kSecUseDataProtectionKeychain] = true
            }
        #endif
        return query
    }

    #if os(macOS)
        static func allowsLegacyFallback(bundleURL: URL) -> Bool {
            !["app", "appex"].contains(bundleURL.pathExtension.lowercased())
        }
    #endif

    func deleteKey() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            cachedKey = nil
        default:
            throw SupportQueueEncryptionError.keychain(status)
        }
    }
}

struct EphemeralQueueKeyProvider: SupportQueueEncryptionKeyProviding {
    private let storedKey: SymmetricKey

    init(keyData: Data = Data(repeating: 0xA5, count: 32)) throws {
        guard keyData.count == 32 else {
            throw SupportQueueEncryptionError.invalidKeyData
        }
        storedKey = SymmetricKey(data: keyData)
    }

    func key() async throws -> SymmetricKey {
        storedKey
    }
}

enum SupportQueueCipher {
    private static let magic = Data([0x53, 0x4B, 0x51, 0x01]) // "SKQ" + format version 1

    static func isEncrypted(_ data: Data) -> Bool {
        data.starts(with: magic)
    }

    static func seal(_ plaintext: Data, using key: SymmetricKey, authenticating associatedData: Data) throws -> Data {
        let sealedBox = try AES.GCM.seal(plaintext, using: key, authenticating: associatedData)
        guard let combined = sealedBox.combined else {
            throw SupportQueueEncryptionError.unavailableCombinedRepresentation
        }

        var result = magic
        result.append(combined)
        return result
    }

    static func open(_ encrypted: Data, using key: SymmetricKey, authenticating associatedData: Data) throws -> Data {
        guard isEncrypted(encrypted) else { throw SupportQueueEncryptionError.invalidEnvelope }
        let combined = Data(encrypted.dropFirst(magic.count))
        let sealedBox = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(sealedBox, using: key, authenticating: associatedData)
    }
}
