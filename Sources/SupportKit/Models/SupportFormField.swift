import Foundation

/// A configurable additional field rendered by `SupportForm`.
public struct SupportFormField: Identifiable, Sendable {
    /// Controls privacy scrubbing for the user's value. Credential patterns
    /// are always removed regardless of this setting.
    public enum RedactionPolicy: Sendable {
        /// Apply credential and configured personal-data rules.
        case standard
        /// Preserve intentional personal data while still removing credentials.
        case secretsOnly
    }

    /// The SwiftUI control used to collect the response.
    public enum Kind: Sendable {
        /// A single-line text field.
        case text
        /// A vertically expanding text field.
        case multiline
        /// An email-address field that defaults to secrets-only redaction.
        case email
        /// A Boolean toggle, rendered as Yes or No in the report.
        case toggle
        /// A picker whose stable option IDs are rendered as labels.
        case picker(options: [Option])
    }

    /// One stable option in a picker field.
    public struct Option: Identifiable, Hashable, Sendable {
        /// The stable value stored by the form.
        public let id: String
        /// The user-visible and report-visible label.
        public let label: String

        /// Creates a picker option.
        ///
        /// - Parameters:
        ///   - id: The stable value stored by the form.
        ///   - label: The user-visible and report-visible label.
        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }

    /// A stable identifier unique within the form.
    public let id: String
    /// The user-visible field label.
    public let label: String
    /// Optional placeholder copy.
    public let prompt: String?
    /// Optional supporting copy rendered below the control.
    public let help: String?
    /// The control and validation kind.
    public let kind: Kind
    /// Whether the field must contain an accepted value.
    public let isRequired: Bool
    /// The maximum user-value length, or `nil` for no field-specific limit.
    public let maximumLength: Int?
    /// The initial string value or stable picker option ID.
    public let defaultValue: String
    /// The personal-data policy applied after mandatory credential removal.
    public let redactionPolicy: RedactionPolicy
    /// The rendered report value for an enabled toggle.
    public let toggleTrueLabel: String
    /// The rendered report value for a disabled toggle.
    public let toggleFalseLabel: String

    /// Creates an additional form field.
    ///
    /// Email fields default to ``RedactionPolicy/secretsOnly`` so an address
    /// intentionally supplied for a reply remains useful. Other kinds default
    /// to ``RedactionPolicy/standard``.
    ///
    /// - Parameters:
    ///   - id: A stable identifier unique within the form.
    ///   - label: The user-visible field label.
    ///   - prompt: Optional placeholder copy.
    ///   - help: Optional supporting copy below the control.
    ///   - kind: The control and validation kind.
    ///   - isRequired: Whether the field must contain an accepted value.
    ///   - maximumLength: The maximum user-value length, or `nil` for no field-specific limit.
    ///   - defaultValue: The initial value or stable picker option identifier.
    ///   - redactionPolicy: An explicit privacy policy, or `nil` to select the safe default for `kind`.
    ///   - toggleTrueLabel: The report and preview value used when a toggle is enabled.
    ///   - toggleFalseLabel: The report and preview value used when a toggle is disabled.
    public init(
        id: String,
        label: String,
        prompt: String? = nil,
        help: String? = nil,
        kind: Kind = .text,
        isRequired: Bool = false,
        maximumLength: Int? = 1000,
        defaultValue: String = "",
        redactionPolicy: RedactionPolicy? = nil,
        toggleTrueLabel: String = "Yes",
        toggleFalseLabel: String = "No",
    ) {
        self.id = id
        self.label = label
        self.prompt = prompt
        self.help = help
        self.kind = kind
        self.isRequired = isRequired
        self.maximumLength = maximumLength
        self.defaultValue = defaultValue
        self.redactionPolicy = redactionPolicy ?? (Self.isEmail(kind) ? .secretsOnly : .standard)
        self.toggleTrueLabel = toggleTrueLabel
        self.toggleFalseLabel = toggleFalseLabel
    }

    private static func isEmail(_ kind: Kind) -> Bool {
        if case .email = kind {
            true
        } else {
            false
        }
    }
}
