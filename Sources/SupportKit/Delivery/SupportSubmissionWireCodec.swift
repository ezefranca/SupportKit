import Foundation

enum SupportSubmissionWireCodec {
    static func encode(_ submission: SupportSubmission) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(submission)
    }
}
