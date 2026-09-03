import Foundation

/// Supplies explicitly recorded application breadcrumbs.
public protocol SupportLogSource: Sendable {
    /// Returns no more than `limit` recent entries.
    ///
    /// - Parameter limit: The maximum number of newest entries to return.
    /// - Returns: Already-redacted breadcrumbs in chronological order.
    func recentEntries(limit: Int) async -> [SupportLogEntry]
}
