import Foundation

/// Supplies trusted, app-specific diagnostic facts after user consent.
public protocol SupportDiagnosticsProvider: Sendable {
    /// Collects bounded diagnostics. Implementations should honor cancellation
    /// and avoid returning secrets or raw customer content.
    ///
    /// - Returns: Support-relevant diagnostic facts to bound and redact before preview.
    func collectDiagnostics() async -> [SupportDiagnostic]
}
