import CryptoKit
import Foundation

/// An opaque, stable ownership boundary for records in a support queue.
///
/// SupportKit derives a scope from the exact project and queue identifiers in a
/// ``SupportConfiguration``. Stores use the value for every lookup, claim, and
/// state transition so one shared store can safely serve multiple clients.
public struct SupportQueueScope: Codable, Equatable, Hashable, Sendable {
    /// The lowercase SHA-256 representation of the scoped configuration identity.
    public let identifier: String

    init(projectID: String, queueIdentifier: String) {
        identifier = SupportScopeDigest.make(
            domain: "SupportKit.QueueScope.v1",
            components: [projectID, queueIdentifier],
        )
    }

    /// Decodes a validated opaque scope identifier.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let identifier = try container.decode(String.self, forKey: .identifier)
        guard Self.isValid(identifier) else {
            throw DecodingError.dataCorruptedError(
                forKey: .identifier,
                in: container,
                debugDescription: "A queue scope must be exactly 64 lowercase hexadecimal characters.",
            )
        }
        self.identifier = identifier
    }

    /// Encodes the validated opaque scope identifier.
    public func encode(to encoder: Encoder) throws {
        guard Self.isValid(identifier) else {
            throw EncodingError.invalidValue(
                identifier,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "A queue scope must be exactly 64 lowercase hexadecimal characters.",
                ),
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(identifier, forKey: .identifier)
    }

    static func isValid(_ identifier: String) -> Bool {
        identifier.utf8.count == 64 && identifier.utf8.allSatisfy {
            (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case identifier
    }
}

enum SupportQueueStorageNamespace {
    static func make(identifier: String) -> String {
        "queue-\(SupportScopeDigest.make(domain: "SupportKit.FileQueue.v1", components: [identifier]))"
    }
}

private enum SupportScopeDigest {
    static func make(domain: String, components: [String]) -> String {
        let values = [domain] + components
        let canonical = values.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return SHA256.hash(data: Data(canonical.utf8)).map {
            let hex = String($0, radix: 16)
            return hex.count == 1 ? "0\(hex)" : hex
        }.joined()
    }
}
