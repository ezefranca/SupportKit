import Foundation

/// One bounded technical fact attached to an opted-in support report.
public struct SupportDiagnostic: Codable, Equatable, Sendable {
    /// Indicates whether a diagnostic can help identify a user's environment.
    public enum Sensitivity: String, Codable, Sendable {
        /// Coarse technical state.
        case standard
        /// A value such as locale, time zone, path context, or logs.
        case potentiallyIdentifying
    }

    /// A short human-readable diagnostic name.
    public var key: String
    /// The diagnostic value after bounding and redaction.
    public var value: String
    /// The sensitivity displayed in the payload preview.
    public var sensitivity: Sensitivity

    /// Creates a diagnostic. Custom providers should minimize values at source.
    ///
    /// - Parameters:
    ///   - key: A short human-readable diagnostic name.
    ///   - value: A bounded technical value.
    ///   - sensitivity: Whether the value can help identify an environment.
    public init(key: String, value: String, sensitivity: Sensitivity = .standard) {
        self.key = key
        self.value = value
        self.sensitivity = sensitivity
    }
}
