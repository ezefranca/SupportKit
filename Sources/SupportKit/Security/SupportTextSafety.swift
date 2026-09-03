import Foundation

enum SupportTextSafety {
    static func isWireSafe(_ value: String) -> Bool {
        !value.unicodeScalars.contains(where: isUnsafe)
    }

    static func removingUnsafeScalars(from value: String) -> String {
        String(value.unicodeScalars.filter { !isUnsafe($0) })
    }

    static func boundedSingleLine(_ value: String, maximumBytes: Int) -> String? {
        guard value.utf8.count <= maximumBytes else { return nil }
        let safe = removingUnsafeScalars(from: value)
        let normalized = safe.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }

    static func boundedFailureReason(_ value: String) -> String {
        guard let normalized = boundedSingleLine(value, maximumBytes: 4096) else {
            return "Delivery failed."
        }
        return String(normalized.prefix(500))
    }

    private static func isUnsafe(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return value <= 0x08
            || (0x0B ... 0x0C).contains(value)
            || (0x0E ... 0x1F).contains(value)
            || (0x7F ... 0x9F).contains(value)
            || value == 0x061C
            || value == 0x200E
            || value == 0x200F
            || (0x202A ... 0x202E).contains(value)
            || (0x2066 ... 0x2069).contains(value)
    }
}
