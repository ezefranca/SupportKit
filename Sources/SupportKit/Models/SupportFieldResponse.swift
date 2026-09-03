import Foundation

/// One validated, rendered additional-field response in a report.
public struct SupportFieldResponse: Codable, Equatable, Sendable {
    /// The stable field identifier.
    public let id: String
    /// The configured human-readable label.
    public let label: String
    /// The rendered and redacted user value.
    public let value: String

    /// Creates a response value, primarily for custom storage integrations.
    ///
    /// - Parameters:
    ///   - id: The stable configured field identifier.
    ///   - label: The human-readable field label.
    ///   - value: The rendered, already-redacted response.
    public init(id: String, label: String, value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}
