import Foundation

enum SupportIdentifierValidator {
    static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 100,
              let first = value.utf8.first,
              isASCIIAlphaNumeric(first)
        else { return false }

        return value.utf8.allSatisfy {
            isASCIIAlphaNumeric($0) || $0 == 0x2E || $0 == 0x2D || $0 == 0x5F
        }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte)
            || (0x41 ... 0x5A).contains(byte)
            || (0x61 ... 0x7A).contains(byte)
    }
}
