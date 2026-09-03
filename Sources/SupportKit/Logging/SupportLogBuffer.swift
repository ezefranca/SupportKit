import Foundation

/// An opt-in, bounded breadcrumb buffer. Values are redacted before entering memory.
public actor SupportLogBuffer: SupportLogSource {
    private let capacity: Int
    private let redactor: SupportRedactor
    private var entries: [SupportLogEntry] = []

    /// Creates a buffer that retains at most `capacity` redacted entries.
    ///
    /// - Parameters:
    ///   - capacity: The maximum number of newest entries to retain, clamped to zero through 500.
    ///   - redactor: The immutable redaction pipeline applied before values enter memory.
    public init(capacity: Int = 200, redactor: SupportRedactor = .init()) {
        self.capacity = min(max(0, capacity), SupportLogLimits.maximumCapacity)
        self.redactor = redactor
    }

    /// Redacts and records a structured breadcrumb.
    ///
    /// - Parameters:
    ///   - level: The event severity.
    ///   - category: A short subsystem or feature name.
    ///   - message: A bounded human-readable description.
    ///   - metadata: Structured context to redact before retention.
    ///   - timestamp: When the event occurred.
    public func record(
        _ level: SupportLogEntry.Level = .info,
        category: String,
        message: String,
        metadata: [String: String] = [:],
        timestamp: Date = .now,
    ) {
        guard capacity > 0 else { return }

        let entry = SupportLogEntry(
            timestamp: timestamp,
            level: level,
            category: redactor.redact(SupportLogLimits.boundedCategory(category)),
            message: redactor.redact(SupportLogLimits.boundedMessage(message)),
            metadata: redactor.redact(metadata: SupportLogLimits.boundedMetadata(metadata)),
        )
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// Returns up to `limit` of the most recently recorded entries.
    ///
    /// - Parameter limit: The maximum number of newest entries to return.
    /// - Returns: Redacted entries in their original chronological order.
    public func recentEntries(limit: Int) -> [SupportLogEntry] {
        guard limit > 0 else { return [] }
        return Array(entries.suffix(limit))
    }

    /// Removes every retained breadcrumb from memory.
    public func removeAll() {
        entries.removeAll(keepingCapacity: true)
    }
}
