import Foundation
@testable import SupportKit
import Testing

private func pemBoundary(_ boundary: String, label: String) -> String {
    ["-----", boundary, " ", label, "-----"].joined()
}

@Suite("Private-key redaction boundaries")
struct SupportPEMRedactionTests {
    private let privateKey = [
        pemBoundary("BEGIN", label: "RSA PRIVATE KEY"),
        "highly-sensitive-private-key-material",
        pemBoundary("END", label: "RSA PRIVATE KEY"),
    ].joined(separator: "\n")

    @Test
    func `private keys are redacted before logs enter memory`() async throws {
        // Arrange
        let buffer = SupportLogBuffer()

        // Act
        await buffer.record(category: "crypto", message: privateKey)
        let entry = try #require(await buffer.recentEntries(limit: 1).first)

        // Assert
        #expect(entry.message == "<redacted-private-key>")
        #expect(!entry.message.contains("highly-sensitive"))
    }

    @Test
    func `private keys are redacted before a custom transport receives a report`() async throws {
        // Arrange
        let transport = SupportTransportSpyingStub(outcomes: [.accepted()])
        let client = try SupportClient(
            configuration: SupportKitTestFixture.configuration(),
            transport: transport,
            store: InMemorySupportSubmissionStore(),
            now: { SupportKitTestFixture.date },
            makeID: { SupportKitTestFixture.reportID },
        )

        // Act
        _ = await client.submit(.init(subject: "Key exposure", message: privateKey))
        _ = await client.flush()
        let submission = try #require(await transport.submissions().first)

        // Assert
        #expect(submission.message == "<redacted-private-key>")
        #expect(!submission.message.contains("highly-sensitive"))
    }
}
