import Foundation

/// Editable input supplied to ``SupportClient`` for validation and preparation.
public struct SupportDraft: Equatable, Sendable {
    /// A short report summary.
    public var subject: String
    /// The free-form support request.
    public var message: String
    /// Additional field values keyed by ``SupportFormField/id``.
    public var responses: [String: String]
    /// Whether configured diagnostics may be collected for this preparation.
    public var includesDiagnostics: Bool

    /// Creates editable support input. No data is collected until preparation.
    ///
    /// - Parameters:
    ///   - subject: A short report summary.
    ///   - message: The user's free-form support request.
    ///   - responses: Additional values keyed by configured field identifier.
    ///   - includesDiagnostics: Whether preparation may collect configured diagnostics.
    public init(
        subject: String,
        message: String,
        responses: [String: String] = [:],
        includesDiagnostics: Bool = false,
    ) {
        self.subject = subject
        self.message = message
        self.responses = responses
        self.includesDiagnostics = includesDiagnostics
    }
}
