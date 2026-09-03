import CryptoKit
import Foundation

enum SupportQueueHostNamespace {
    static let current = make(
        bundleIdentifier: Bundle.main.bundleIdentifier,
        fallbackSeed: Bundle.main.bundleURL.standardizedFileURL.path,
    )

    static func make(bundleIdentifier: String?, fallbackSeed: String) -> String {
        let identity = if let bundleIdentifier, !bundleIdentifier.isEmpty {
            "bundle:\(bundleIdentifier)"
        } else {
            "unbundled:\(fallbackSeed)"
        }
        let digest = SHA256.hash(data: Data(identity.utf8))
        let suffix = digest.prefix(16).map {
            let hex = String($0, radix: 16)
            return hex.count == 1 ? "0\(hex)" : hex
        }.joined()
        return "host-\(suffix)"
    }
}
