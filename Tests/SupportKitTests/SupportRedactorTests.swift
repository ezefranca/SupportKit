import Foundation
@testable import SupportKit
import Testing

private func redactionPEMBoundary(_ boundary: String, label: String) -> String {
    ["-----", boundary, " ", label, "-----"].joined()
}

@Suite("Support redaction")
struct SupportRedactorTests {
    struct RedactionCase: Sendable, CustomTestStringConvertible {
        let name: String
        let input: String
        let expectedFragment: String

        var testDescription: String {
            name
        }
    }

    static let builtInCases: [RedactionCase] = [
        .init(
            name: "fine-grained GitHub token",
            input: ["credential=", "github", "_pat_", "abcdefghijklmnopqrstuvwxyz0123456789"].joined(),
            expectedFragment: "<redacted-github-token>",
        ),
        .init(
            name: "classic GitHub token",
            input: ["credential=", "gh", "p_", "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"].joined(),
            expectedFragment: "<redacted-github-token>",
        ),
        .init(
            name: "OAuth GitHub token",
            input: ["credential=", "gh", "o_", "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"].joined(),
            expectedFragment: "<redacted-github-token>",
        ),
        .init(
            name: "vendor-neutral prefixed token",
            input: "credential=acme_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345",
            expectedFragment: "<redacted-prefixed-token>",
        ),
        .init(
            name: "case-insensitive bearer value",
            input: ["bEa", "ReR ", "opaque", "-private", "-credential"].joined(),
            expectedFragment: "Bearer <redacted>",
        ),
        .init(
            name: "case-insensitive basic authorization",
            input: ["bA", "sIc ", "dXNlcj", "pwYXNzd29yZA=="].joined(),
            expectedFragment: "Basic <redacted>",
        ),
        .init(
            name: "standalone JWT",
            input: [
                "eyJhbGci", "OiJIUzI1NiJ9", ".",
                "eyJzdWIi", "OiIxMjM0NTY3ODkwIn0", ".",
                "signature123",
            ].joined(),
            expectedFragment: "<redacted-jwt>",
        ),
        .init(
            name: "PEM private key",
            input: [
                redactionPEMBoundary("BEGIN", label: "OPENSSH PRIVATE KEY"),
                "private-key-material",
                redactionPEMBoundary("END", label: "OPENSSH PRIVATE KEY"),
            ].joined(separator: "\n"),
            expectedFragment: "<redacted-private-key>",
        ),
        .init(
            name: "truncated PEM private key",
            input: [
                redactionPEMBoundary("BEGIN", label: "PRIVATE KEY"),
                "truncated-private-key-material",
            ].joined(separator: "\n"),
            expectedFragment: "<redacted-private-key>",
        ),
        .init(
            name: "URL credentials",
            input: ["https://", "alice", ":", "private", "@example.com/path"].joined(),
            expectedFragment: "https://<redacted-credentials>@example.com/path",
        ),
        .init(
            name: "named API key",
            input: "api_key=super-secret-value",
            expectedFragment: "api_key=<redacted>",
        ),
        .init(
            name: "named refresh token",
            input: "refresh-token: definitely-private",
            expectedFragment: "refresh-token=<redacted>",
        ),
        .init(
            name: "email address",
            input: "Please reply to person+support@example.com",
            expectedFragment: "<redacted-email>",
        ),
        .init(
            name: "IPv4 address",
            input: "connected from 192.168.10.24",
            expectedFragment: "<redacted-ip>",
        ),
        .init(
            name: "IPv6 address",
            input: "connected from 2001:db8:85a3::8a2e:370:7334",
            expectedFragment: "<redacted-ip>",
        ),
        .init(
            name: "URL query value",
            input: "https://example.com/callback?code=private-code&mode=debug",
            expectedFragment: "?code=<redacted>",
        ),
        .init(
            name: "macOS home path",
            input: "failed at /Users/alice/Library/Application Support/App/file.db",
            expectedFragment: "/Users/<redacted>/Library",
        ),
        .init(
            name: "iOS container path",
            input: "/var/mobile/Containers/Data/Application/12345678-1234-1234-1234-123456789ABC/Documents/db",
            expectedFragment: "/var/mobile/Containers/Data/Application/<redacted>/Documents",
        ),
    ]

    @Test(arguments: builtInCases)
    func `built-in rules remove known private values`(testCase: RedactionCase) {
        // Arrange
        let sut = SupportRedactor()

        // Act
        let result = sut.redact(testCase.input)

        // Assert
        #expect(result.contains(testCase.expectedFragment))
        #expect(result != testCase.input)
    }

    @Test(arguments: ["ghp", "gho", "ghu", "ghs", "ghr"])
    func `all supported classic GitHub token families are redacted`(prefix: String) {
        // Arrange
        let secret = "\(prefix)_1234567890abcdefghijklmnop"
        let sut = SupportRedactor()

        // Act
        let result = sut.redact("before \(secret) after")

        // Assert
        #expect(result == "before <redacted-github-token> after")
        #expect(!result.contains(secret))
    }

    @Test
    func `redaction handles Unicode and secrets spanning multiple log lines`() {
        // Arrange
        let token = ["github", "_pat_", "abcdefghijklmnopqrstuvwx"].joined()
        let input = "User 👩🏽‍💻 reported:\nemail=user@example.com\ntoken=\(token)"
        let sut = SupportRedactor()

        // Act
        let result = sut.redact(input)

        // Assert
        #expect(result.contains("👩🏽‍💻"))
        #expect(result.contains("<redacted-email>"))
        #expect(result.contains("<redacted-github-token>"))
        #expect(!result.contains(token))
    }

    @Test
    func `metadata values are dropped based on normalized sensitive keys`() {
        // Arrange
        let metadata = [
            "X-API_Key": "api-value",
            "sessionToken": "token-value",
            "Cookie": "cookie-value",
            "screen": "account user@example.com",
        ]
        let sut = SupportRedactor()

        // Act
        let result = sut.redact(metadata: metadata)

        // Assert
        #expect(result["X-API_Key"] == "<redacted>")
        #expect(result["sessionToken"] == "<redacted>")
        #expect(result["Cookie"] == "<redacted>")
        #expect(result["screen"] == "account <redacted-email>")
        #expect(!result.values.contains("api-value"))
    }

    @Test
    func `privacy rules are optional but mandatory credential rules cannot be disabled`() {
        // Arrange
        let secret = ["opaque", "-private", "-credential"].joined()
        let configuration = RedactionConfiguration(
            rules: [],
            redactsEmailAddresses: false,
            redactsIPAddresses: false,
            redactsURLQueryValues: false,
            redactsUserPaths: false,
        )
        let sut = SupportRedactor(configuration: configuration)
        let input = "person@example.com 192.168.1.10 Bearer \(secret)"

        // Act
        let standard = sut.redact(input)
        let secretsOnly = sut.redactSecrets(in: input)

        // Assert
        #expect(standard == "person@example.com 192.168.1.10 Bearer <redacted>")
        #expect(secretsOnly == standard)
        #expect(!standard.contains(secret))
    }

    @Test
    func `a validated custom rule participates in the deterministic pipeline`() throws {
        // Arrange
        let rule = try SupportRedactionRule(
            pattern: #"customer-[0-9]{4}"#,
            replacement: "customer-<redacted>",
        )
        let sut = SupportRedactor(configuration: .init(rules: [rule]))

        // Act
        let first = sut.redact("customer-1234 customer-9876")
        let second = sut.redact("customer-1234 customer-9876")

        // Assert
        #expect(first == "customer-<redacted> customer-<redacted>")
        #expect(second == first)
    }

    @Test
    func `an invalid host-supplied regular expression is rejected at configuration time`() {
        // Arrange / Act / Assert
        #expect(throws: (any Error).self) {
            _ = try SupportRedactionRule(pattern: "[")
        }
    }

    @Test
    func `unsafe custom replacement templates are rejected before use`() {
        // Arrange / Act / Assert
        #expect(throws: SupportRedactionRuleError.invalidCaptureReference) {
            _ = try SupportRedactionRule(pattern: #"(secret)"#, replacement: "$2")
        }
        #expect(throws: SupportRedactionRuleError.invalidCaptureReference) {
            _ = try SupportRedactionRule(pattern: #"(secret)"#, replacement: "$1$1")
        }
        #expect(throws: SupportRedactionRuleError.invalidCaptureReference) {
            _ = try SupportRedactionRule(pattern: #"(secret)"#, replacement: "$")
        }
        #expect(throws: SupportRedactionRuleError.emptyMatch) {
            _ = try SupportRedactionRule(pattern: #".*"#)
        }
        #expect(throws: SupportRedactionRuleError.emptyMatch) {
            _ = try SupportRedactionRule(pattern: #"\b"#)
        }
        #expect(throws: SupportRedactionRuleError.patternTooLong) {
            _ = try SupportRedactionRule(pattern: String(repeating: "x", count: 4097))
        }
        #expect(throws: SupportRedactionRuleError.replacementTooLong) {
            _ = try SupportRedactionRule(pattern: "secret", replacement: String(repeating: "x", count: 65))
        }
    }

    @Test
    func `custom replacements cannot amplify output beyond the redaction work bound`() throws {
        // Arrange
        let rule = try SupportRedactionRule(pattern: ".", replacement: String(repeating: "x", count: 64))
        let sut = SupportRedactor(configuration: .init(rules: [rule]))
        let input = String(repeating: "a", count: 10000)

        // Act
        let output = sut.redact(input)

        // Assert
        #expect(output == "<oversized-redaction-value>")
        #expect(!output.contains(input))
    }
}
