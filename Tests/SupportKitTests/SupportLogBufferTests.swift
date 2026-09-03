import Foundation
@testable import SupportKit
import Testing

@Suite("Support log buffer")
struct SupportLogBufferTests {
    @Test
    func `the buffer retains only the newest entries and applies read limits`() async {
        // Arrange
        let sut = SupportLogBuffer(capacity: 2)
        let firstDate = SupportKitTestFixture.date
        let secondDate = firstDate.addingTimeInterval(1)
        let thirdDate = firstDate.addingTimeInterval(2)

        // Act
        await sut.record(.debug, category: "flow", message: "first", timestamp: firstDate)
        await sut.record(.info, category: "flow", message: "second", timestamp: secondDate)
        await sut.record(.warning, category: "flow", message: "third", timestamp: thirdDate)
        let allRetained = await sut.recentEntries(limit: 10)
        let newestOnly = await sut.recentEntries(limit: 1)

        // Assert
        #expect(allRetained.map(\.message) == ["second", "third"])
        #expect(allRetained.map(\.timestamp) == [secondDate, thirdDate])
        #expect(newestOnly.map(\.message) == ["third"])
        #expect(await sut.recentEntries(limit: 0).isEmpty)
    }

    @Test
    func `zero capacity records nothing`() async {
        // Arrange
        let sut = SupportLogBuffer(capacity: 0)

        // Act
        await sut.record(category: "flow", message: "discarded")

        // Assert
        #expect(await sut.recentEntries(limit: 10).isEmpty)
    }

    @Test
    func `category, message, metadata keys, and metadata values are redacted before entering memory`() async throws {
        // Arrange
        let token = ["github", "_pat_", "abcdefghijklmnopqrstuvwx"].joined()
        let authorizationValue = ["Bear", "er ", "private", "-value"].joined()
        let sut = SupportLogBuffer(capacity: 5)

        // Act
        await sut.record(
            .error,
            category: "account person@example.com",
            message: "Request failed with \(token) from 10.0.0.8",
            metadata: [
                "authorization": authorizationValue,
                "contact": "person@example.com",
                "path": "/Users/alice/file.txt",
            ],
            timestamp: SupportKitTestFixture.date,
        )
        let entry = try #require(await sut.recentEntries(limit: 1).first)

        // Assert
        #expect(entry.category == "account <redacted-email>")
        #expect(entry.message == "Request failed with <redacted-github-token> from <redacted-ip>")
        #expect(entry.metadata["authorization"] == "<redacted>")
        #expect(entry.metadata["contact"] == "<redacted-email>")
        #expect(entry.metadata["path"] == "/Users/<redacted>/file.txt")
        #expect(!String(describing: entry).contains(token))
    }

    @Test
    func `removeAll clears retained breadcrumbs and accepts later records`() async {
        // Arrange
        let sut = SupportLogBuffer(capacity: 2)
        await sut.record(category: "flow", message: "before")

        // Act
        await sut.removeAll()
        let afterRemoval = await sut.recentEntries(limit: 10)
        await sut.record(category: "flow", message: "after")
        let afterReuse = await sut.recentEntries(limit: 10)

        // Assert
        #expect(afterRemoval.isEmpty)
        #expect(afterReuse.map(\.message) == ["after"])
    }

    @Test
    func `capacity is hard capped at five hundred entries`() async {
        // Arrange
        let sut = SupportLogBuffer(capacity: .max)

        // Act
        for index in 0 ... 500 {
            await sut.record(category: "capacity", message: "entry-\(index)")
        }
        let retained = await sut.recentEntries(limit: .max)

        // Assert
        #expect(retained.count == 500)
        #expect(retained.first?.message == "entry-1")
        #expect(retained.last?.message == "entry-500")
    }

    @Test
    func `oversized raw fields and metadata are omitted before redaction`() async throws {
        // Arrange
        let sut = SupportLogBuffer(capacity: 5)
        let oversizedCategory = String(repeating: "é", count: 129)
        let oversizedMessage = String(repeating: "é", count: 8193)
        let excessiveMetadata = Dictionary(uniqueKeysWithValues: (0 ... 16).map {
            ("key-\($0)", "value-\($0)")
        })
        let oversizedKey = String(repeating: "é", count: 65)
        let oversizedValue = String(repeating: "é", count: 1025)

        // Act
        await sut.record(category: oversizedCategory, message: oversizedMessage)
        await sut.record(category: "fanout", message: "metadata", metadata: excessiveMetadata)
        await sut.record(
            category: "fields",
            message: "metadata",
            metadata: [
                "valid": "kept",
                oversizedKey: "omitted-key",
                "oversized-value": oversizedValue,
            ],
        )
        let entries = await sut.recentEntries(limit: 3)

        // Assert
        let oversizedEntry = try #require(entries.first)
        let metadataFanoutEntry = try #require(entries.dropFirst().first)
        let metadataBoundsEntry = try #require(entries.last)
        #expect(oversizedEntry.category == "<oversized-category>")
        #expect(oversizedEntry.message == "<oversized-message>")
        #expect(metadataFanoutEntry.metadata.isEmpty)
        #expect(metadataBoundsEntry.metadata == ["valid": "kept"])
    }

    @Test
    func `diagnostic log export applies entry and message caps with deterministic metadata ordering`() async throws {
        // Arrange
        let logs = SupportLogBuffer(capacity: 10)
        await logs.record(
            .info,
            category: "first",
            message: "discarded",
            timestamp: SupportKitTestFixture.date,
        )
        await logs.record(
            .warning,
            category: "second",
            message: "123456789",
            metadata: ["z": "last", "a": "first"],
            timestamp: SupportKitTestFixture.date.addingTimeInterval(1),
        )
        let configuration = DiagnosticsConfiguration(
            includesOperatingSystem: false,
            includesDeviceModel: false,
            includesApplicationVersion: false,
            includesThermalState: false,
            includesLowPowerMode: false,
            includesLogs: true,
            maximumLogEntries: 1,
            maximumLogMessageLength: 5,
        )
        let sut = SystemDiagnosticsProvider(configuration: configuration, logSource: logs)

        // Act
        let diagnostics = await sut.collectDiagnostics()
        let exported = try #require(diagnostics.first)

        // Assert
        #expect(diagnostics.count == 1)
        #expect(exported.key == "Recent app breadcrumbs")
        #expect(exported.sensitivity == .potentiallyIdentifying)
        #expect(exported.value.contains("[warning] [second] 12345 a=first z=last"))
        #expect(!exported.value.contains("discarded"))
        #expect(!exported.value.contains("123456"))
    }
}

@Suite("Untrusted log source bounds")
struct SystemDiagnosticsLogBoundTests {
    @Test
    func `provider caps both its request and entries returned by a noncompliant source`() async throws {
        // Arrange
        let entries = (0 ..< 5).map {
            SupportLogEntry(
                timestamp: SupportKitTestFixture.date,
                level: .info,
                category: "source",
                message: "entry-\($0)",
            )
        }
        let source = UnboundedLogSource(entries: entries)
        let sut = SystemDiagnosticsProvider(
            configuration: logConfiguration(maximumLogEntries: 3),
            logSource: source,
        )

        // Act
        let diagnostics = await sut.collectDiagnostics()
        let value = try #require(diagnostics.first?.value)

        // Assert
        #expect(await source.lastRequestedLimit() == 3)
        #expect(value.split(separator: "\n").count == 3)
        #expect(value.contains("entry-0"))
        #expect(value.contains("entry-2"))
        #expect(!value.contains("entry-3"))
    }

    @Test
    func `provider never requests more than the five hundred entry hard cap`() async {
        // Arrange
        let source = UnboundedLogSource(entries: [])
        let sut = SystemDiagnosticsProvider(
            configuration: logConfiguration(maximumLogEntries: .max),
            logSource: source,
        )

        // Act
        _ = await sut.collectDiagnostics()

        // Assert
        #expect(await source.lastRequestedLimit() == 500)
    }

    @Test
    func `provider rebounds raw entry fields then redacts before configured truncation`() async throws {
        // Arrange
        let oversizedCategory = String(repeating: "é", count: 129)
        let oversizedMessage = String(repeating: "é", count: 8193)
        let excessiveMetadata = Dictionary(uniqueKeysWithValues: (0 ... 16).map {
            ("fanout-\($0)", "must-not-appear-\($0)")
        })
        let oversizedKey = String(repeating: "é", count: 65)
        let oversizedValue = String(repeating: "é", count: 1025)
        let source = UnboundedLogSource(entries: [
            .init(
                timestamp: SupportKitTestFixture.date,
                level: .error,
                category: oversizedCategory,
                message: oversizedMessage,
                metadata: excessiveMetadata,
            ),
            .init(
                timestamp: SupportKitTestFixture.date,
                level: .warning,
                category: "network",
                message: "person@example.com",
                metadata: [
                    "valid": "kept",
                    oversizedKey: "omitted-key",
                    "oversized-value": oversizedValue,
                ],
            ),
        ])
        let sut = SystemDiagnosticsProvider(
            configuration: logConfiguration(maximumLogEntries: 2, maximumLogMessageLength: 10),
            logSource: source,
        )

        // Act
        let diagnostics = await sut.collectDiagnostics()
        let value = try #require(diagnostics.first?.value)
        let lines = value.split(separator: "\n")

        // Assert
        try #require(lines.count == 2)
        #expect(lines[0].contains("<oversized-category>"))
        #expect(lines[0].hasSuffix("<oversized"))
        #expect(!lines[0].contains("must-not-appear"))
        #expect(lines[1].contains("<redacted-"))
        #expect(!lines[1].contains("person@"))
        #expect(lines[1].contains("valid=kept"))
        #expect(!lines[1].contains("omitted-key"))
        #expect(!lines[1].contains("oversized-value"))
    }

    @Test
    func `aggregate log diagnostic obeys the configured value limit`() async throws {
        // Arrange
        let source = UnboundedLogSource(entries: [
            .init(
                timestamp: SupportKitTestFixture.date,
                level: .info,
                category: "first",
                message: String(repeating: "a", count: 100),
            ),
            .init(
                timestamp: SupportKitTestFixture.date,
                level: .info,
                category: "second",
                message: String(repeating: "b", count: 100),
            ),
        ])
        let sut = SystemDiagnosticsProvider(
            configuration: logConfiguration(
                maximumLogEntries: 2,
                maximumLogMessageLength: 100,
                maximumDiagnosticValueLength: 80,
            ),
            logSource: source,
        )

        // Act
        let diagnostics = await sut.collectDiagnostics()
        let value = try #require(diagnostics.first?.value)

        // Assert
        #expect(value.count == 80)
    }
}

private actor UnboundedLogSource: SupportLogSource {
    private let entries: [SupportLogEntry]
    private var requestedLimits: [Int] = []

    init(entries: [SupportLogEntry]) {
        self.entries = entries
    }

    func recentEntries(limit: Int) -> [SupportLogEntry] {
        requestedLimits.append(limit)
        return entries
    }

    func lastRequestedLimit() -> Int? {
        requestedLimits.last
    }
}

private func logConfiguration(
    maximumLogEntries: Int,
    maximumLogMessageLength: Int = 1000,
    maximumDiagnosticValueLength: Int = 20000,
) -> DiagnosticsConfiguration {
    DiagnosticsConfiguration(
        includesOperatingSystem: false,
        includesDeviceModel: false,
        includesApplicationVersion: false,
        includesThermalState: false,
        includesLowPowerMode: false,
        includesLocale: false,
        includesTimeZone: false,
        includesLogs: true,
        maximumLogEntries: maximumLogEntries,
        maximumLogMessageLength: maximumLogMessageLength,
        maximumDiagnosticValueLength: maximumDiagnosticValueLength,
    )
}
