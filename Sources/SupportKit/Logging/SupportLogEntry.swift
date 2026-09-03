import Foundation

/// One bounded, structured application breadcrumb.
public struct SupportLogEntry: Codable, Equatable, Sendable {
    /// The severity chosen by the host app.
    public enum Level: String, Codable, CaseIterable, Sendable {
        /// Detailed development context.
        case debug
        /// Routine informational context.
        case info
        /// A noteworthy state transition.
        case notice
        /// A recoverable unexpected condition.
        case warning
        /// A failed application operation.
        case error
    }

    /// When the host recorded the breadcrumb.
    public let timestamp: Date
    /// The host-selected severity.
    public let level: Level
    /// A short subsystem or feature name.
    public let category: String
    /// A bounded human-readable event description.
    public let message: String
    /// Structured context whose sensitive keys and values are redacted.
    public let metadata: [String: String]

    /// Creates a breadcrumb value. Prefer ``SupportLogBuffer/record(_:category:message:metadata:timestamp:)``
    /// so data is redacted before entering memory.
    ///
    /// - Parameters:
    ///   - timestamp: When the host recorded the event.
    ///   - level: The host-selected severity.
    ///   - category: A short subsystem or feature name.
    ///   - message: A bounded human-readable description.
    ///   - metadata: Structured context containing no intentional secrets.
    public init(
        timestamp: Date,
        level: Level,
        category: String,
        message: String,
        metadata: [String: String] = [:],
    ) {
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.metadata = metadata
    }
}
