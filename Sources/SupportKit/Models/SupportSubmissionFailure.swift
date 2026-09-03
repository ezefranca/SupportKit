import Foundation

/// A user-correctable reason SupportKit rejected a report before queueing it.
public enum SupportSubmissionFailure: Error, Equatable, LocalizedError, Sendable {
    /// The report subject is empty after trimming whitespace.
    case emptySubject
    /// The report message is empty after trimming whitespace.
    case emptyMessage
    /// The report subject exceeds the configured maximum character count.
    case subjectTooLong(maximum: Int)
    /// The report message exceeds the configured maximum character count.
    case messageTooLong(maximum: Int)
    /// A required additional field, identified by its display label, is empty.
    case requiredField(String)
    /// An additional field exceeds its configured maximum character count.
    case fieldTooLong(label: String, maximum: Int)
    /// An email field, identified by its display label, is not a valid address.
    case invalidEmail(String)
    /// A picker value does not match one of the field's configured options.
    case invalidSelection(String)
    /// A user-controlled value contains unsafe control or text-direction characters.
    case unsupportedCharacters(String)
    /// The prepared, encoded report exceeds the configured durable-payload limit.
    case payloadTooLarge(maximumBytes: Int)
    /// The prepared report does not belong to this client and configuration.
    case invalidPreparedSubmission
    /// SupportKit could not safely persist the report.
    case queueUnavailable
    /// The durable queue has reached its configured capacity.
    case queueFull

    /// A default user-facing explanation that hosts can localize or replace.
    public var errorDescription: String? {
        switch self {
        case .emptySubject: "Enter a subject."
        case .emptyMessage: "Enter a message."
        case let .subjectTooLong(maximum): "Keep the subject under \(maximum) characters."
        case let .messageTooLong(maximum): "Keep the message under \(maximum) characters."
        case let .requiredField(label): "Complete \(label)."
        case let .fieldTooLong(label, maximum): "Keep \(label) under \(maximum) characters."
        case let .invalidEmail(label): "Enter a valid email address for \(label)."
        case let .invalidSelection(label): "Choose a valid option for \(label)."
        case let .unsupportedCharacters(label): "Remove unsupported control characters from \(label)."
        case let .payloadTooLarge(maximumBytes):
            "This report is too large to save. Keep it under \(maximumBytes) bytes."
        case .invalidPreparedSubmission: "Prepare this report again before sending it."
        case .queueUnavailable: "This report could not be saved safely. Please try again."
        case .queueFull: "The support queue is full. Please try again after pending reports are sent."
        }
    }
}
