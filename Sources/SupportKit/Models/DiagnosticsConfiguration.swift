import Foundation

/// Controls every diagnostic category that SupportKit is allowed to collect.
public struct DiagnosticsConfiguration: Sendable {
    private static let maximumAllowedDiagnosticCount = 100
    private static let maximumAllowedDiagnosticValueLength = 20000
    private static let maximumAllowedLogEntries = 500
    private static let maximumAllowedLogMessageLength = 10000

    /// Whether to include the operating-system name and version.
    public let includesOperatingSystem: Bool
    /// Whether to include the coarse hardware model.
    public let includesDeviceModel: Bool
    /// Whether to include the host app's version and build number.
    public let includesApplicationVersion: Bool
    /// Whether to include the current process thermal state.
    public let includesThermalState: Bool
    /// Whether to include Low Power Mode state on supported platforms.
    public let includesLowPowerMode: Bool
    /// Whether to include the current locale as potentially identifying data.
    public let includesLocale: Bool
    /// Whether to include the current time zone as potentially identifying data.
    public let includesTimeZone: Bool
    /// Whether to include explicitly recorded, redacted application breadcrumbs.
    public let includesLogs: Bool
    /// The maximum number of recent log entries, clamped to zero through 500.
    public let maximumLogEntries: Int
    /// The maximum number of characters retained from each log message, capped at 10,000.
    public let maximumLogMessageLength: Int
    /// The maximum number of built-in and custom diagnostic values in one report, capped at 100.
    public let maximumDiagnosticCount: Int
    /// The maximum number of characters retained from each diagnostic value, capped at 20,000.
    public let maximumDiagnosticValueLength: Int
    /// Trusted app-specific providers invoked only after diagnostic consent.
    public let customProviders: [any SupportDiagnosticsProvider]

    /// Creates a bounded allowlist of diagnostic categories and providers.
    ///
    /// - Parameters:
    ///   - includesOperatingSystem: Whether to include the system name and version.
    ///   - includesDeviceModel: Whether to include the coarse hardware model.
    ///   - includesApplicationVersion: Whether to include the app version and build.
    ///   - includesThermalState: Whether to include process thermal state.
    ///   - includesLowPowerMode: Whether to include Low Power Mode state.
    ///   - includesLocale: Whether to include the potentially identifying locale.
    ///   - includesTimeZone: Whether to include the potentially identifying time zone.
    ///   - includesLogs: Whether to include explicitly recorded breadcrumbs.
    ///   - maximumLogEntries: The maximum recent breadcrumbs to include.
    ///   - maximumLogMessageLength: The maximum characters in each breadcrumb message.
    ///   - maximumDiagnosticCount: The maximum diagnostic values in one report.
    ///   - maximumDiagnosticValueLength: The maximum characters in each diagnostic value.
    ///   - customProviders: Additional trusted diagnostic providers.
    public init(
        includesOperatingSystem: Bool = true,
        includesDeviceModel: Bool = true,
        includesApplicationVersion: Bool = true,
        includesThermalState: Bool = true,
        includesLowPowerMode: Bool = true,
        includesLocale: Bool = false,
        includesTimeZone: Bool = false,
        includesLogs: Bool = false,
        maximumLogEntries: Int = 50,
        maximumLogMessageLength: Int = 1000,
        maximumDiagnosticCount: Int = 100,
        maximumDiagnosticValueLength: Int = 20000,
        customProviders: [any SupportDiagnosticsProvider] = [],
    ) {
        self.includesOperatingSystem = includesOperatingSystem
        self.includesDeviceModel = includesDeviceModel
        self.includesApplicationVersion = includesApplicationVersion
        self.includesThermalState = includesThermalState
        self.includesLowPowerMode = includesLowPowerMode
        self.includesLocale = includesLocale
        self.includesTimeZone = includesTimeZone
        self.includesLogs = includesLogs
        self.maximumLogEntries = min(max(0, maximumLogEntries), Self.maximumAllowedLogEntries)
        self.maximumLogMessageLength = min(
            max(0, maximumLogMessageLength),
            Self.maximumAllowedLogMessageLength,
        )
        self.maximumDiagnosticCount = min(
            max(0, maximumDiagnosticCount),
            Self.maximumAllowedDiagnosticCount,
        )
        self.maximumDiagnosticValueLength = min(
            max(0, maximumDiagnosticValueLength),
            Self.maximumAllowedDiagnosticValueLength,
        )
        self.customProviders = customProviders
    }

    /// The default: useful system state without locale, time zone, or logs.
    public static var `default`: Self {
        .init()
    }
}
