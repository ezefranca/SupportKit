import Foundation
@testable import SupportKit
import Testing

@Suite("Support client payload preflight")
struct SupportClientPayloadLimitTests {
    @Test
    func `an oversized draft is rejected before queue persistence`() async throws {
        // Arrange
        let form = SupportFormConfiguration(
            messageMaximumLength: 5000,
            additionalFields: [],
        )
        let delivery = DeliveryConfiguration(
            automaticallyDelivers: false,
            maximumSubmissionBytes: 1024,
        )
        let store = EnqueueFailingSubmissionStore()
        let transport = SupportTransportSpyingStub(outcomes: [])
        let client = try SupportClient(
            configuration: SupportKitTestFixture.configuration(
                form: form,
                delivery: delivery,
            ),
            transport: transport,
            store: store,
            now: { SupportKitTestFixture.date },
            makeID: { SupportKitTestFixture.reportID },
        )
        let draft = SupportDraft(
            subject: "Large report",
            message: String(repeating: "x", count: 2000),
        )

        // Act
        let result = await client.submit(draft)

        // Assert
        #expect(result == .rejected(.payloadTooLarge(maximumBytes: 1024)))
        #expect(await store.enqueueCount() == 0)
        #expect(await transport.submissions().isEmpty)
    }

    @Test
    func `an oversized externally prepared payload is rejected before queue persistence`() async throws {
        // Arrange
        let delivery = DeliveryConfiguration(
            automaticallyDelivers: false,
            maximumSubmissionBytes: 1024,
        )
        let store = EnqueueFailingSubmissionStore()
        let transport = SupportTransportSpyingStub(outcomes: [])
        let client = try SupportClient(
            configuration: SupportKitTestFixture.configuration(delivery: delivery),
            transport: transport,
            store: store,
        )
        let prepared = PreparedSupportSubmission(submission: SupportKitTestFixture.submission(
            message: String(repeating: "x", count: 2000),
        ), ownerID: client.preparedSubmissionOwnerID)

        // Act
        let result = await client.submit(prepared)

        // Assert
        #expect(result == .rejected(.payloadTooLarge(maximumBytes: 1024)))
        #expect(await store.enqueueCount() == 0)
        #expect(await transport.submissions().isEmpty)
    }

    @Test
    func `raw draft budget is enforced before diagnostic collection and redaction`() async throws {
        // Arrange
        let diagnosticsProvider = DiagnosticProviderCountingSpy()
        let diagnostics = DiagnosticsConfiguration(
            includesOperatingSystem: false,
            includesDeviceModel: false,
            includesApplicationVersion: false,
            includesThermalState: false,
            includesLowPowerMode: false,
            customProviders: [diagnosticsProvider],
        )
        let form = SupportFormConfiguration(additionalFields: [
            .init(id: "details", label: "Details", maximumLength: nil),
        ])
        let delivery = DeliveryConfiguration(
            automaticallyDelivers: false,
            maximumSubmissionBytes: 1024,
        )
        let client = try SupportClient(
            configuration: SupportKitTestFixture.configuration(
                form: form,
                diagnostics: diagnostics,
                delivery: delivery,
            ),
            transport: SupportTransportSpyingStub(outcomes: []),
            store: InMemorySupportSubmissionStore(),
        )
        let draft = SupportDraft(
            subject: "Budget",
            message: "A small message",
            responses: ["details": "Bearer \(String(repeating: "x", count: 2000))"],
            includesDiagnostics: true,
        )

        // Act
        let result = await client.prepare(draft)

        // Assert
        guard case let .rejected(failure) = result else {
            Issue.record("Expected the raw draft budget to reject the report")
            return
        }
        #expect(failure == .payloadTooLarge(maximumBytes: 1024))
        #expect(await diagnosticsProvider.callCount() == 0)
    }

    @Test
    func `invalid form input is rejected before diagnostic collection`() async throws {
        // Arrange
        let diagnosticsProvider = DiagnosticProviderCountingSpy()
        let diagnostics = DiagnosticsConfiguration(customProviders: [diagnosticsProvider])
        let client = try SupportClient(
            configuration: SupportKitTestFixture.configuration(diagnostics: diagnostics),
            transport: SupportTransportSpyingStub(outcomes: []),
            store: InMemorySupportSubmissionStore(),
        )

        // Act
        let result = await client.prepare(.init(subject: " ", message: "Message", includesDiagnostics: true))

        // Assert
        guard case let .rejected(failure) = result else {
            Issue.record("Expected validation to fail")
            return
        }
        #expect(failure == .emptySubject)
        #expect(await diagnosticsProvider.callCount() == 0)
    }
}

private actor DiagnosticProviderCountingSpy: SupportDiagnosticsProvider {
    private var count = 0

    func collectDiagnostics() -> [SupportDiagnostic] {
        count += 1
        return []
    }

    func callCount() -> Int {
        count
    }
}
