import Foundation

/// Applies deterministic, local redaction before data reaches disk or the network.
public struct SupportRedactor: Sendable {
    private static let maximumRuleInputBytes = 256 * 1024
    private static let maximumMatchesPerRule = 10000
    private static let maximumRuleOutputBytes = 256 * 1024
    private static let oversizedValue = "<oversized-redaction-value>"

    /// NSRegularExpression is immutable after initialization. This wrapper is
    /// never mutated and is shared only for concurrent matching operations.
    private final class CompiledRule: @unchecked Sendable {
        let expression: NSRegularExpression
        let replacement: String

        init?(_ rule: SupportRedactionRule) {
            guard let expression = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) else {
                return nil
            }
            self.expression = expression
            replacement = rule.replacement
        }
    }

    private let secretRules: [CompiledRule]
    private let privacyRules: [CompiledRule]

    /// Compiles an immutable redaction pipeline for repeated concurrent use.
    ///
    /// - Parameter configuration: Optional privacy categories and app-specific rules.
    public init(configuration: RedactionConfiguration = .default) {
        secretRules = (RedactionConfiguration.mandatorySecretRules + configuration.rules).compactMap(CompiledRule.init)
        privacyRules = configuration.privacyRules.compactMap(CompiledRule.init)
    }

    /// Removes mandatory credential patterns and configured privacy patterns.
    ///
    /// - Parameter input: Arbitrary user-controlled text.
    /// - Returns: Text after mandatory and configured rules run in deterministic order.
    public func redact(_ input: String) -> String {
        apply(privacyRules, to: redactSecrets(in: input))
    }

    /// Removes credential patterns that cannot be disabled by configuration.
    ///
    /// - Parameter input: Text that may contain credentials.
    /// - Returns: Text with mandatory credential-shaped values replaced.
    public func redactSecrets(in input: String) -> String {
        apply(secretRules, to: input)
    }

    /// Redacts values and replaces values for known-sensitive keys wholesale.
    ///
    /// - Parameter metadata: Structured, user-controlled keys and values.
    /// - Returns: A dictionary whose keys and values are redacted.
    public func redact(metadata: [String: String]) -> [String: String] {
        metadata.reduce(into: [:]) { result, pair in
            if Self.isSensitiveKey(pair.key) {
                result[redact(pair.key)] = "<redacted>"
            } else {
                result[redact(pair.key)] = redact(pair.value)
            }
        }
    }

    private func apply(_ rules: [CompiledRule], to input: String) -> String {
        guard input.utf8.count <= Self.maximumRuleInputBytes else {
            return Self.oversizedValue
        }
        return rules.reduce(input) { value, rule in
            apply(rule, to: value)
        }
    }

    private func apply(_ rule: CompiledRule, to input: String) -> String {
        guard input.utf8.count <= Self.maximumRuleInputBytes else {
            return Self.oversizedValue
        }

        let source = input as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        var output = ""
        output.reserveCapacity(min(input.utf8.count, Self.maximumRuleOutputBytes))
        var outputBytes = 0
        var previousEnd = 0
        var exceeded = false
        var matchCount = 0
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(100))

        rule.expression.enumerateMatches(
            in: input,
            options: [.reportProgress],
            range: fullRange,
        ) { match, flags, stop in
            guard !flags.contains(.internalError), clock.now < deadline else {
                exceeded = true
                stop.pointee = true
                return
            }
            guard let match else { return }
            guard matchCount < Self.maximumMatchesPerRule else {
                exceeded = true
                stop.pointee = true
                return
            }
            matchCount += 1
            let unmatchedRange = NSRange(
                location: previousEnd,
                length: match.range.location - previousEnd,
            )
            let unmatched = source.substring(with: unmatchedRange)
            let replacement = rule.expression.replacementString(
                for: match,
                in: input,
                offset: 0,
                template: rule.replacement,
            )
            let addedBytes = unmatched.utf8.count + replacement.utf8.count
            guard addedBytes <= Self.maximumRuleOutputBytes - outputBytes else {
                exceeded = true
                stop.pointee = true
                return
            }
            output.append(unmatched)
            output.append(replacement)
            outputBytes += addedBytes
            previousEnd = NSMaxRange(match.range)
        }
        guard !exceeded else { return Self.oversizedValue }

        let suffix = source.substring(from: previousEnd)
        guard suffix.utf8.count <= Self.maximumRuleOutputBytes - outputBytes else {
            return Self.oversizedValue
        }
        output.append(suffix)
        return output
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter(\.isLetter)
        return ["apikey", "authorization", "cookie", "password", "secret", "session", "token"]
            .contains { normalized.contains($0) }
    }
}
