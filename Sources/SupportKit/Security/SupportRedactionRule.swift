import Foundation

/// A custom-redaction rule that cannot be applied safely.
public enum SupportRedactionRuleError: Error, Equatable, LocalizedError, Sendable {
    /// The regular-expression pattern exceeds SupportKit's bounded compile limit.
    case patternTooLong
    /// The replacement template exceeds SupportKit's bounded expansion limit.
    case replacementTooLong
    /// The expression can produce an empty match and therefore unbounded replacements.
    case emptyMatch
    /// The replacement contains a malformed or out-of-range capture reference.
    case invalidCaptureReference

    /// A localized explanation suitable for configuration diagnostics.
    public var errorDescription: String? {
        switch self {
        case .patternTooLong: "The redaction pattern is too long."
        case .replacementTooLong: "The redaction replacement is too long."
        case .emptyMatch: "The redaction pattern must consume at least one character."
        case .invalidCaptureReference: "The redaction replacement contains an invalid capture reference."
        }
    }
}

/// A validated regular-expression replacement appended to the redaction pipeline.
public struct SupportRedactionRule: Equatable, Sendable {
    private static let maximumPatternBytes = 4096
    private static let maximumReplacementBytes = 64

    /// The ICU-compatible regular-expression pattern.
    public let pattern: String
    /// The replacement template applied to every match.
    public let replacement: String
    /// Foundation regular-expression options fixed at initialization.
    public let options: NSRegularExpression.Options

    /// Validates and creates a custom rule.
    ///
    /// - Parameters:
    ///   - pattern: An ICU-compatible regular expression.
    ///   - replacement: The replacement template applied to every match.
    ///   - options: Foundation regular-expression options fixed at initialization.
    /// - Throws: A Foundation regular-expression error for an invalid pattern, or
    ///   ``SupportRedactionRuleError`` when a bound or replacement invariant is violated.
    public init(
        pattern: String,
        replacement: String = "<redacted>",
        options: NSRegularExpression.Options = [],
    ) throws {
        guard pattern.utf8.count <= Self.maximumPatternBytes else {
            throw SupportRedactionRuleError.patternTooLong
        }
        guard replacement.utf8.count <= Self.maximumReplacementBytes else {
            throw SupportRedactionRuleError.replacementTooLong
        }

        let expression = try NSRegularExpression(pattern: pattern, options: options)
        guard !Self.canMatchWithoutConsuming(expression) else {
            throw SupportRedactionRuleError.emptyMatch
        }
        guard Self.hasValidCaptureReferences(replacement, captureCount: expression.numberOfCaptureGroups) else {
            throw SupportRedactionRuleError.invalidCaptureReference
        }
        self.pattern = pattern
        self.replacement = replacement
        self.options = options
    }

    init(validatedPattern pattern: String, replacement: String, options: NSRegularExpression.Options = []) {
        self.pattern = pattern
        self.replacement = replacement
        self.options = options
    }

    private static func canMatchWithoutConsuming(_ expression: NSRegularExpression) -> Bool {
        // The empty probe catches expressions such as `.*`; the nonempty probes
        // also catch boundary/lookaround-only expressions such as `\\b`.
        ["", "x", " ", "0", "\n"].contains { probe in
            let range = NSRange(probe.startIndex ..< probe.endIndex, in: probe)
            return expression.matches(in: probe, range: range).contains { $0.range.length == 0 }
        }
    }

    private static func hasValidCaptureReferences(_ template: String, captureCount: Int) -> Bool {
        let characters = Array(template)
        var index = 0
        var referenceCount = 0
        while index < characters.count {
            if characters[index] == "\\" {
                index += 1
                guard index < characters.count else { return false }
                index += 1
                continue
            }
            guard characters[index] == "$" else {
                index += 1
                continue
            }

            index += 1
            let digitStart = index
            var reference = 0
            while index < characters.count,
                  let digit = asciiDigit(characters[index]) {
                guard reference <= (Int.max - digit) / 10 else { return false }
                reference = reference * 10 + digit
                index += 1
            }
            guard index > digitStart, reference <= captureCount else { return false }
            referenceCount += 1
            guard referenceCount <= 1 else { return false }
        }
        return true
    }

    private static func asciiDigit(_ character: Character) -> Int? {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first,
              (0x30 ... 0x39).contains(scalar.value)
        else { return nil }
        return Int(scalar.value - 0x30)
    }
}
