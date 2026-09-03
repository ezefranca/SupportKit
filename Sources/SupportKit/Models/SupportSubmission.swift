import Foundation

/// The immutable, redacted wire payload persisted and sent by SupportKit.
public struct SupportSubmission: Codable, Equatable, Identifiable, Sendable {
    /// The schema version emitted by this release.
    public static let currentSchemaVersion = 1

    /// The encoded payload schema version.
    public let schemaVersion: Int
    /// The stable report identifier.
    public let id: UUID
    /// The key a receiver uses to atomically suppress duplicate delivery.
    public let idempotencyKey: String
    /// The non-secret receiver routing identifier.
    public let projectID: String
    /// When SupportKit froze the report.
    public let createdAt: Date
    /// The final redacted destination title.
    public let title: String
    /// The final redacted free-form message.
    public let message: String
    /// Validated, rendered, and redacted additional-field responses.
    public let responses: [SupportFieldResponse]
    /// Opted-in, bounded, and redacted diagnostics.
    public let diagnostics: [SupportDiagnostic]
    /// Destination-defined report labels.
    public let labels: [String]
    /// A canonical hash of routing, content, diagnostics, and labels used for deduplication.
    public let contentFingerprint: String

    init(
        id: UUID,
        projectID: String,
        createdAt: Date,
        title: String,
        message: String,
        responses: [SupportFieldResponse],
        diagnostics: [SupportDiagnostic],
        labels: [String],
        contentFingerprint: String,
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        idempotencyKey = id.uuidString.lowercased()
        self.projectID = projectID
        self.createdAt = createdAt
        self.title = title
        self.message = message
        self.responses = responses
        self.diagnostics = diagnostics
        self.labels = labels
        self.contentFingerprint = contentFingerprint
    }
}
