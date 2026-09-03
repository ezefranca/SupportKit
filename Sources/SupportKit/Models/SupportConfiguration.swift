import Foundation

/// Top-level configuration shared by the core client and SwiftUI form.
public struct SupportConfiguration: Sendable {
    private static let maximumLabelCount = 10
    private static let maximumLabelLength = 100
    private static let maximumReportTitlePrefixLength = 100

    /// A non-secret identifier mapped to an allowlisted destination by your receiver.
    public let projectID: String
    /// The validated fields, copy, and preview behavior exposed to the app's form.
    public let form: SupportFormConfiguration
    /// The diagnostic categories and bounds available after user consent.
    public let diagnostics: DiagnosticsConfiguration
    /// Durable queue, retry, deduplication, and worker limits.
    public let delivery: DeliveryConfiguration
    /// The validated logical queue name. The live store derives a collision-resistant filesystem namespace from it.
    public let queueIdentifier: String
    /// Text prepended to the redacted subject when creating the report title.
    public let reportTitlePrefix: String
    /// Labels forwarded to the configured support destination.
    public let labels: [String]
    /// The opaque stable scope passed to durable-store operations for this configuration.
    public let queueScope: SupportQueueScope

    let fileQueueIdentifier: String

    /// Creates and validates the complete client configuration.
    ///
    /// - Parameters:
    ///   - projectID: A non-secret identifier mapped to an allowlisted destination by the receiver.
    ///   - form: The fields, copy, and preview behavior for support requests.
    ///   - diagnostics: The diagnostic categories and collection bounds.
    ///   - delivery: Durable queue, deduplication, retry, and worker limits.
    ///   - queueIdentifier: A logical queue name. Its exact spelling is preserved and participates in scope
    ///     derivation. Defaults to `projectID`.
    ///   - reportTitlePrefix: Text prepended to every redacted report subject.
    ///   - labels: Destination-defined labels attached to reports.
    /// - Throws: ``SupportConfigurationError`` when an identifier or form definition is invalid.
    public init(
        projectID: String,
        form: SupportFormConfiguration = .init(),
        diagnostics: DiagnosticsConfiguration = .default,
        delivery: DeliveryConfiguration = .init(),
        queueIdentifier: String? = nil,
        reportTitlePrefix: String = "[Support]",
        labels: [String] = ["support"],
    ) throws {
        try form.validate()
        guard SupportIdentifierValidator.isValid(projectID) else {
            throw SupportConfigurationError.invalidProjectIdentifier
        }
        let identifier = queueIdentifier ?? projectID
        guard SupportIdentifierValidator.isValid(identifier) else {
            throw SupportConfigurationError.invalidQueueIdentifier
        }
        guard reportTitlePrefix.utf8.count <= 8 * 1024 else {
            throw SupportConfigurationError.invalidReportTitlePrefix
        }
        let trimmedPrefix = reportTitlePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPrefix == reportTitlePrefix,
              reportTitlePrefix.count <= Self.maximumReportTitlePrefixLength,
              SupportTextSafety.isWireSafe(reportTitlePrefix)
        else {
            throw SupportConfigurationError.invalidReportTitlePrefix
        }
        guard labels.count <= Self.maximumLabelCount else {
            throw SupportConfigurationError.tooManyLabels(maximum: Self.maximumLabelCount)
        }
        var uniqueLabels = Set<String>()
        for label in labels {
            guard label.utf8.count <= 8 * 1024 else {
                throw SupportConfigurationError.invalidLabel(label)
            }
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed == label,
                  label.count <= Self.maximumLabelLength,
                  SupportTextSafety.isWireSafe(label)
            else {
                throw SupportConfigurationError.invalidLabel(label)
            }
            guard uniqueLabels.insert(label).inserted else {
                throw SupportConfigurationError.duplicateLabel(label)
            }
        }

        let queueScope = SupportQueueScope(projectID: projectID, queueIdentifier: identifier)
        self.projectID = projectID
        self.form = form
        self.diagnostics = diagnostics
        self.delivery = delivery
        self.queueIdentifier = identifier
        self.reportTitlePrefix = reportTitlePrefix
        self.labels = labels
        self.queueScope = queueScope
        fileQueueIdentifier = "scope-\(queueScope.identifier)"
    }
}
