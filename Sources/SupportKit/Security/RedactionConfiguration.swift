import Foundation

/// Controls privacy-oriented redaction while keeping credential scrubbing mandatory.
public struct RedactionConfiguration: Sendable {
    private static let maximumCustomRuleCount = 32

    /// Additional app-specific secret rules. These run after SupportKit's
    /// mandatory credential rules and cannot be bypassed by field policy.
    public let rules: [SupportRedactionRule]
    /// Whether ordinary redaction removes email-like values.
    public let redactsEmailAddresses: Bool
    /// Whether ordinary redaction removes IPv4 and IPv6-like values.
    public let redactsIPAddresses: Bool
    /// Whether ordinary redaction removes values from URL query items.
    public let redactsURLQueryValues: Bool
    /// Whether ordinary redaction removes common Apple user and container paths.
    public let redactsUserPaths: Bool

    /// Creates privacy rules. Credential scrubbing remains enabled regardless
    /// of these arguments.
    ///
    /// - Parameters:
    ///   - rules: App-specific rules appended after mandatory credential patterns.
    ///   - redactsEmailAddresses: Whether standard redaction removes email-like values.
    ///   - redactsIPAddresses: Whether standard redaction removes IP-address-like values.
    ///   - redactsURLQueryValues: Whether standard redaction removes URL query values.
    ///   - redactsUserPaths: Whether standard redaction removes common Apple user paths.
    public init(
        rules: [SupportRedactionRule] = [],
        redactsEmailAddresses: Bool = true,
        redactsIPAddresses: Bool = true,
        redactsURLQueryValues: Bool = true,
        redactsUserPaths: Bool = true,
    ) {
        self.rules = Array(rules.prefix(Self.maximumCustomRuleCount))
        self.redactsEmailAddresses = redactsEmailAddresses
        self.redactsIPAddresses = redactsIPAddresses
        self.redactsURLQueryValues = redactsURLQueryValues
        self.redactsUserPaths = redactsUserPaths
    }

    /// The standard configuration with common privacy rules enabled.
    public static var `default`: Self {
        .init()
    }

    static let mandatorySecretRules: [SupportRedactionRule] = [
        .init(
            validatedPattern: #"\bBearer\s+[^\s,;]+"#,
            replacement: "Bearer <redacted>",
            options: [.caseInsensitive],
        ),
        .init(
            validatedPattern: #"\bBasic\s+[A-Za-z0-9+/=]{8,}"#,
            replacement: "Basic <redacted>",
            options: [.caseInsensitive],
        ),
        .init(
            validatedPattern: #"\b(?:github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9_]{20,})\b"#,
            replacement: "<redacted-github-token>",
        ),
        .init(
            validatedPattern: #"\b[A-Za-z][A-Za-z0-9]{1,16}_[A-Za-z0-9_]{20,}\b"#,
            replacement: "<redacted-prefixed-token>",
        ),
        .init(
            validatedPattern: #"-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----"#
                + #"[\s\S]{0,262144}?(?:-----END (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----|\z)"#,
            replacement: "<redacted-private-key>",
        ),
        .init(
            validatedPattern: #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}(?:\.[A-Za-z0-9_-]{8,})?\b"#,
            replacement: "<redacted-jwt>",
        ),
        .init(
            validatedPattern: #"https?://[^/@\s:]+:[^/@\s]+@"#,
            replacement: "https://<redacted-credentials>@",
            options: [.caseInsensitive],
        ),
        .init(
            validatedPattern: #"\b(api[_-]?key|access[_-]?token|refresh[_-]?token|authorization"#
                + #"|cookie|password|secret|session[_-]?token)\b\s*[:=]\s*[^\s,;]+"#,
            replacement: "$1=<redacted>",
            options: [.caseInsensitive],
        ),
    ]

    var privacyRules: [SupportRedactionRule] {
        var selected: [SupportRedactionRule] = []
        if redactsEmailAddresses {
            selected.append(Self.emailRule)
        }
        if redactsIPAddresses {
            selected.append(contentsOf: [Self.ipv4Rule, Self.ipv6Rule])
        }
        if redactsURLQueryValues {
            selected.append(Self.queryValueRule)
        }
        if redactsUserPaths {
            selected.append(contentsOf: [Self.macOSUserPathRule, Self.appleContainerPathRule])
        }
        return selected
    }

    private static let emailRule = SupportRedactionRule(
        validatedPattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
        replacement: "<redacted-email>",
        options: [.caseInsensitive],
    )
    private static let ipv4Rule = SupportRedactionRule(
        validatedPattern: #"(?<![A-Fa-f0-9:])(?:\d{1,3}\.){3}\d{1,3}(?![A-Fa-f0-9:])"#,
        replacement: "<redacted-ip>",
    )
    private static let ipv6Rule = SupportRedactionRule(
        validatedPattern: #"(?<![A-Fa-f0-9:])(?:"#
            + #"(?:[A-Fa-f0-9]{1,4}:){7}[A-Fa-f0-9]{1,4}"#
            + #"|(?:[A-Fa-f0-9]{1,4}:){1,7}:"#
            + #"|(?:[A-Fa-f0-9]{1,4}:){1,6}:[A-Fa-f0-9]{1,4}"#
            + #"|(?:[A-Fa-f0-9]{1,4}:){1,5}(?::[A-Fa-f0-9]{1,4}){1,2}"#
            + #"|(?:[A-Fa-f0-9]{1,4}:){1,4}(?::[A-Fa-f0-9]{1,4}){1,3}"#
            + #"|(?:[A-Fa-f0-9]{1,4}:){1,3}(?::[A-Fa-f0-9]{1,4}){1,4}"#
            + #"|(?:[A-Fa-f0-9]{1,4}:){1,2}(?::[A-Fa-f0-9]{1,4}){1,5}"#
            + #"|[A-Fa-f0-9]{1,4}:(?:(?::[A-Fa-f0-9]{1,4}){1,6})"#
            + #"|:(?:(?::[A-Fa-f0-9]{1,4}){1,7}|:)"#
            + #")(?![A-Fa-f0-9:])"#,
        replacement: "<redacted-ip>",
    )
    private static let queryValueRule = SupportRedactionRule(
        validatedPattern: #"([?&][^=\s&#]+)=([^&#\s]+)"#,
        replacement: "$1=<redacted>",
    )
    private static let macOSUserPathRule = SupportRedactionRule(
        validatedPattern: #"/Users/[^/\s]+/"#,
        replacement: "/Users/<redacted>/",
    )
    private static let appleContainerPathRule = SupportRedactionRule(
        validatedPattern: #"/var/mobile/Containers/Data/Application/[A-Fa-f0-9-]+"#,
        replacement: "/var/mobile/Containers/Data/Application/<redacted>",
    )
}
