import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// Collects coarse Apple-platform state without persistent identifiers.
public struct SystemDiagnosticsProvider: SupportDiagnosticsProvider {
    private let configuration: DiagnosticsConfiguration
    private let logSource: (any SupportLogSource)?
    private let redactor: SupportRedactor
    private let bundle: Bundle
    private let processInfo: ProcessInfo

    /// Creates a provider with injectable process and bundle context for tests.
    ///
    /// - Parameters:
    ///   - configuration: Enabled categories and collection bounds.
    ///   - logSource: An optional bounded source of redacted breadcrumbs.
    ///   - redactor: The final redaction pipeline for collected values.
    ///   - bundle: The bundle used for application name and version metadata.
    ///   - processInfo: The source of operating-system, power, and thermal state.
    public init(
        configuration: DiagnosticsConfiguration = .default,
        logSource: (any SupportLogSource)? = nil,
        redactor: SupportRedactor = .init(),
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo,
    ) {
        self.configuration = configuration
        self.logSource = logSource
        self.redactor = redactor
        self.bundle = bundle
        self.processInfo = processInfo
    }

    /// Collects only diagnostic categories enabled by the configuration.
    ///
    /// - Returns: Bounded and redacted diagnostics in stable category order.
    public func collectDiagnostics() async -> [SupportDiagnostic] {
        guard configuration.maximumDiagnosticCount > 0 else { return [] }
        var diagnostics: [SupportDiagnostic] = []

        if diagnostics.count < configuration.maximumDiagnosticCount, configuration.includesOperatingSystem {
            diagnostics.append(.init(key: "Operating system", value: processInfo.operatingSystemVersionString))
        }
        if diagnostics.count < configuration.maximumDiagnosticCount, configuration.includesDeviceModel {
            diagnostics.append(.init(key: "Hardware model", value: Self.hardwareModel()))
        }
        if diagnostics.count < configuration.maximumDiagnosticCount, configuration.includesApplicationVersion {
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? "Unknown"
            let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "Unknown"
            let build = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "Unknown"
            diagnostics.append(.init(key: "Application", value: "\(name) \(version) (\(build))"))
        }
        if diagnostics.count < configuration.maximumDiagnosticCount, configuration.includesThermalState {
            diagnostics.append(.init(key: "Thermal state", value: Self.thermalStateName(processInfo.thermalState)))
        }
        if diagnostics.count < configuration.maximumDiagnosticCount, configuration.includesLowPowerMode {
            diagnostics.append(.init(
                key: "Low Power Mode",
                value: processInfo.isLowPowerModeEnabled ? "Enabled" : "Disabled",
            ))
        }
        if diagnostics.count < configuration.maximumDiagnosticCount, configuration.includesLocale {
            diagnostics.append(.init(
                key: "Locale",
                value: Locale.current.identifier,
                sensitivity: .potentiallyIdentifying,
            ))
        }
        if diagnostics.count < configuration.maximumDiagnosticCount, configuration.includesTimeZone {
            diagnostics.append(.init(
                key: "Time zone",
                value: TimeZone.current.identifier,
                sensitivity: .potentiallyIdentifying,
            ))
        }
        if diagnostics.count < configuration.maximumDiagnosticCount,
           configuration.includesLogs,
           let logSource {
            let entries = await logSource.recentEntries(limit: configuration.maximumLogEntries)
            let formatted = formattedLogs(entries.prefix(configuration.maximumLogEntries))
            if !formatted.isEmpty {
                diagnostics.append(.init(
                    key: "Recent app breadcrumbs",
                    value: formatted,
                    sensitivity: .potentiallyIdentifying,
                ))
            }
        }

        return diagnostics.map {
            .init(key: redactor.redact($0.key), value: redactor.redact($0.value), sensitivity: $0.sensitivity)
        }
    }

    private func format(_ entry: SupportLogEntry) -> String {
        let safeCategory = redactor.redact(SupportLogLimits.boundedCategory(entry.category))
        let safeMessage = redactor.redact(SupportLogLimits.boundedMessage(entry.message))
        let message = String(safeMessage.prefix(configuration.maximumLogMessageLength))
        let metadata = redactor.redact(metadata: SupportLogLimits.boundedMetadata(entry.metadata))
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let suffix = metadata.isEmpty ? "" : " \(metadata)"
        let timestamp = entry.timestamp.timeIntervalSinceReferenceDate.isFinite
            ? entry.timestamp.ISO8601Format()
            : "unknown"
        return "[\(timestamp)] [\(entry.level.rawValue)] [\(safeCategory)] \(message)\(suffix)"
    }

    private func formattedLogs(_ entries: some Sequence<SupportLogEntry>) -> String {
        let maximumLength = configuration.maximumDiagnosticValueLength
        guard maximumLength > 0 else { return "" }

        var output = ""
        for entry in entries {
            let line = format(entry)
            let separator = output.isEmpty ? "" : "\n"
            let remaining = maximumLength - output.count - separator.count
            guard remaining > 0 else { break }
            output += separator + String(line.prefix(remaining))
            if line.count > remaining {
                break
            }
        }
        return output
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }

    private static func hardwareModel() -> String {
        #if canImport(Darwin)
            var size = 0
            guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return "Unknown" }
            var bytes = [CChar](repeating: 0, count: size)
            guard sysctlbyname("hw.machine", &bytes, &size, nil, 0) == 0 else { return "Unknown" }
            let modelBytes = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return String(bytes: modelBytes, encoding: .utf8) ?? "Unknown"
        #else
            return "Unknown"
        #endif
    }
}
