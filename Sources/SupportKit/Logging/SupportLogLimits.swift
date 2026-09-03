import Foundation

enum SupportLogLimits {
    static let maximumCapacity = 500
    static let maximumCategoryBytes = 256
    static let maximumMessageBytes = 16 * 1024
    static let maximumMetadataCount = 16
    static let maximumMetadataKeyBytes = 128
    static let maximumMetadataValueBytes = 2048

    static func boundedCategory(_ value: String) -> String {
        value.utf8.count <= maximumCategoryBytes ? value : "<oversized-category>"
    }

    static func boundedMessage(_ value: String) -> String {
        value.utf8.count <= maximumMessageBytes ? value : "<oversized-message>"
    }

    static func boundedMetadata(_ metadata: [String: String]) -> [String: String] {
        guard metadata.count <= maximumMetadataCount else { return [:] }
        return metadata.filter { key, value in
            key.utf8.count <= maximumMetadataKeyBytes
                && value.utf8.count <= maximumMetadataValueBytes
        }
    }
}
