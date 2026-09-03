import Foundation

/// A configuration problem detected before SupportKit accepts any reports.
public enum SupportConfigurationError: Error, Equatable, LocalizedError, Sendable {
    /// The project identifier is empty or contains unsupported characters.
    case invalidProjectIdentifier
    /// A transport endpoint is malformed or violates its security policy.
    case invalidEndpoint
    /// The durable queue identifier is empty or contains unsupported characters.
    case invalidQueueIdentifier
    /// A form field identifier is empty or contains unsupported characters.
    case invalidFieldIdentifier(String)
    /// A form contains more receiver-bound fields than SupportKit can safely send.
    case tooManyFormFields(maximum: Int)
    /// A form field label is empty or exceeds its receiver-safe length.
    case invalidFieldLabel(String)
    /// Top-level form copy is unsafe or exceeds the bounded UI limit.
    case invalidFormCopy(String)
    /// A field prompt or help value is unsafe or exceeds the bounded UI limit.
    case invalidFieldSupportingText(String)
    /// A form field default is malformed or exceeds its safe bound.
    case invalidFieldDefaultValue(String)
    /// Two form fields use the same identifier.
    case duplicateFieldIdentifier(String)
    /// A form field uses an identifier reserved for SupportKit's core fields.
    case reservedFieldIdentifier(String)
    /// A form field has a negative maximum length.
    case invalidFieldMaximumLength(String)
    /// A picker field has no choices.
    case emptyPickerOptions(String)
    /// A picker contains too many choices for bounded validation and rendering.
    case tooManyPickerOptions(field: String, maximum: Int)
    /// A picker option identifier is empty or contains unsupported characters.
    case invalidPickerOptionIdentifier(field: String, option: String)
    /// A picker option label is empty, untrimmed, unsafe, or too long.
    case invalidPickerOptionLabel(field: String, option: String)
    /// Two options in one picker use the same identifier.
    case duplicatePickerOptionIdentifier(field: String, option: String)
    /// A picker's default value does not identify one of its options.
    case invalidPickerDefaultValue(field: String, value: String)
    /// The configured report-title prefix is too long or malformed.
    case invalidReportTitlePrefix
    /// More destination labels were configured than the receiver contract supports.
    case tooManyLabels(maximum: Int)
    /// A destination label is empty, untrimmed, malformed, or too long.
    case invalidLabel(String)
    /// A destination label occurs more than once.
    case duplicateLabel(String)

    /// A localized explanation suitable for configuration diagnostics.
    public var errorDescription: String? {
        switch self {
        case .invalidProjectIdentifier:
            "The project identifier must contain only letters, numbers, dots, hyphens, and underscores."
        case .invalidEndpoint:
            "The receiver endpoint must be an HTTPS URL."
        case .invalidQueueIdentifier:
            "The queue identifier must contain only letters, numbers, dots, hyphens, and underscores."
        case let .invalidFieldIdentifier(identifier):
            "The field identifier \(identifier) is empty or contains unsupported characters."
        case let .tooManyFormFields(maximum):
            "The support form can contain at most \(maximum) additional fields."
        case let .invalidFieldLabel(identifier):
            "The field \(identifier) must have a nonempty label of at most 200 characters."
        case let .invalidFormCopy(name):
            "The form copy value \(name) contains unsupported characters or exceeds its safe limit."
        case let .invalidFieldSupportingText(identifier):
            "The field \(identifier) has prompt or help text that exceeds its safe limit."
        case let .invalidFieldDefaultValue(identifier):
            "The field \(identifier) has an invalid or oversized default value."
        case let .duplicateFieldIdentifier(identifier):
            "The form contains more than one field named \(identifier)."
        case let .reservedFieldIdentifier(identifier):
            "The field identifier \(identifier) is reserved by SupportKit."
        case let .invalidFieldMaximumLength(identifier):
            "The field \(identifier) cannot have a negative maximum length."
        case let .emptyPickerOptions(identifier):
            "The picker field \(identifier) must contain at least one option."
        case let .tooManyPickerOptions(field, maximum):
            "The picker field \(field) can contain at most \(maximum) options."
        case let .invalidPickerOptionIdentifier(field, option):
            "The picker option identifier \(option) in field \(field) is empty or contains unsupported characters."
        case let .invalidPickerOptionLabel(field, option):
            "The picker option \(option) in field \(field) must have a safe, trimmed, nonempty label."
        case let .duplicatePickerOptionIdentifier(field, option):
            "The picker field \(field) contains more than one option named \(option)."
        case let .invalidPickerDefaultValue(field, value):
            "The default value \(value) is not an option in picker field \(field)."
        case .invalidReportTitlePrefix:
            "The report title prefix must be trimmed and contain at most 100 characters."
        case let .tooManyLabels(maximum):
            "A support report can request at most \(maximum) destination labels."
        case let .invalidLabel(label):
            "The destination label \(label) must be trimmed, nonempty, and at most 100 characters."
        case let .duplicateLabel(label):
            "The destination label \(label) is configured more than once."
        }
    }
}
