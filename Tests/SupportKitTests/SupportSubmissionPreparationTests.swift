import Foundation
@testable import SupportKit
import Testing

@Suite("Submission preparation")
struct SupportSubmissionPreparationTests {
    @Test
    func `preparation trims, renders, and redacts every user-controlled payload section`() throws {
        // Arrange
        let form = SupportFormConfiguration(additionalFields: [
            .init(
                id: "topic",
                label: "Topic",
                kind: .picker(options: [.init(id: "bug", label: "Bug report")]),
                isRequired: true,
                defaultValue: "bug",
            ),
            .init(id: "consent", label: "Consent", kind: .toggle, defaultValue: "false"),
            .init(id: "email", label: "Reply person@example.com", kind: .email),
        ])
        let configuration = try SupportConfiguration(
            projectID: "test.project",
            form: form,
            diagnostics: .default,
            delivery: .init(automaticallyDelivers: false),
            reportTitlePrefix: "[Case]",
            labels: ["support", "from-app"],
        )
        let sut = SupportSubmissionPreparer(configuration: configuration, redactor: .init())
        let token = ["github", "_pat_", "abcdefghijklmnopqrstuvwxyz0123456789"].joined()
        let bearerSecret = ["opaque", "-bearer", "-credential"].joined()
        let draft = SupportDraft(
            subject: "  Login person@example.com  ",
            message: "\nBearer \(bearerSecret)\ngithub=\(token)\n",
            responses: ["consent": "true", "email": "person@example.com"],
        )
        let diagnostics = [
            SupportDiagnostic(key: "Path", value: "/Users/alice/Documents/private.log"),
        ]

        // Act
        let result = sut.prepare(
            draft: draft,
            id: SupportKitTestFixture.reportID,
            now: SupportKitTestFixture.date,
            diagnostics: diagnostics,
        )
        let submission = try #require(result.successValue)

        // Assert
        #expect(submission.title == "[Case] Login <redacted-email>")
        #expect(submission.message == "Bearer <redacted>\ngithub=<redacted-github-token>")
        #expect(submission.responses == [
            .init(id: "topic", label: "Topic", value: "Bug report"),
            .init(id: "consent", label: "Consent", value: "Yes"),
            .init(id: "email", label: "Reply person@example.com", value: "person@example.com"),
        ])
        #expect(submission.diagnostics == [
            .init(key: "Path", value: "/Users/<redacted>/Documents/private.log"),
        ])
        #expect(submission.labels == ["support", "from-app"])
        #expect(submission.idempotencyKey == SupportKitTestFixture.reportID.uuidString.lowercased())
        #expect(submission.contentFingerprint.count == 64)
        #expect(!submission.message.contains(token))
    }

    @Test
    func `fingerprints ignore response order but change with meaningful content`() {
        // Arrange
        let firstOrder = [
            SupportFieldResponse(id: "z", label: "Last", value: "2"),
            SupportFieldResponse(id: "a", label: "First", value: "1"),
        ]
        let reverseOrder = Array(firstOrder.reversed())

        // Act
        let first = SupportFingerprint.make(.init(
            projectID: "project",
            title: "Subject",
            message: "Message",
            responses: firstOrder,
            diagnostics: [],
            labels: [],
        ))
        let reordered = SupportFingerprint.make(.init(
            projectID: "project",
            title: "Subject",
            message: "Message",
            responses: reverseOrder,
            diagnostics: [],
            labels: [],
        ))
        let changed = SupportFingerprint.make(.init(
            projectID: "project",
            title: "Subject",
            message: "Changed",
            responses: firstOrder,
            diagnostics: [],
            labels: [],
        ))

        // Assert
        #expect(first == reordered)
        #expect(first != changed)
        #expect(first.count == 64)
    }

    @Test
    func `fingerprints scope every reviewed payload section`() {
        /// Arrange
        func fingerprint(
            projectID: String = "project",
            diagnostics: [SupportDiagnostic] = [],
            labels: [String] = ["support"],
        ) -> String {
            SupportFingerprint.make(.init(
                projectID: projectID,
                title: "[Support] Subject",
                message: "Message",
                responses: [],
                diagnostics: diagnostics,
                labels: labels,
            ))
        }
        let baseline = fingerprint()

        // Act / Assert
        #expect(baseline != fingerprint(projectID: "another-project"))
        #expect(baseline != fingerprint(diagnostics: [.init(key: "OS", value: "macOS")]))
        #expect(baseline != fingerprint(labels: ["private-support"]))
    }

    @Test
    func `secrets-only fields preserve intentional PII while still removing credentials`() throws {
        // Arrange
        let token = ["gh", "p_", "abcdefghijklmnopqrstuvwx"].joined()
        let form = SupportFormConfiguration(additionalFields: [
            .init(
                id: "contact",
                label: "Contact person@example.com",
                maximumLength: 200,
                redactionPolicy: .secretsOnly,
            ),
        ])
        let configuration = try SupportKitTestFixture.configuration(form: form)
        let sut = SupportSubmissionPreparer(configuration: configuration, redactor: .init())
        let draft = SupportDraft(
            subject: "Subject",
            message: "Message",
            responses: ["contact": "person@example.com \(token)"],
        )

        // Act
        let result = sut.prepare(
            draft: draft,
            id: SupportKitTestFixture.reportID,
            now: SupportKitTestFixture.date,
            diagnostics: [],
        )
        let response = try #require(result.successValue?.responses.first)

        // Assert
        #expect(response.label == "Contact person@example.com")
        #expect(response.value == "person@example.com <redacted-github-token>")
        #expect(!response.value.contains(token))
    }

    @Test
    func `the preview and queued report stay frozen after draft and log mutations`() async throws {
        // Arrange
        let logs = SupportLogBuffer(capacity: 10)
        await logs.record(
            category: "network",
            message: "First event for first@example.com",
            timestamp: SupportKitTestFixture.date,
        )
        let diagnostics = DiagnosticsConfiguration(
            includesOperatingSystem: false,
            includesDeviceModel: false,
            includesApplicationVersion: false,
            includesThermalState: false,
            includesLowPowerMode: false,
            includesLogs: true,
            maximumLogEntries: 10,
        )
        let configuration = try SupportKitTestFixture.configuration(diagnostics: diagnostics)
        let store = InMemorySupportSubmissionStore()
        let client = SupportClient(
            configuration: configuration,
            transport: SupportTransportSpyingStub(outcomes: []),
            store: store,
            logSource: logs,
            now: { SupportKitTestFixture.date },
            makeID: { SupportKitTestFixture.reportID },
        )
        var draft = SupportDraft(subject: "Original", message: "Original message", includesDiagnostics: true)

        // Act
        let preparation = await client.prepare(draft)
        let prepared = try #require(preparation.preparedValue)
        let originalPreview = prepared.preview
        draft.subject = "Changed"
        draft.message = "Changed message"
        await logs.record(
            category: "network",
            message: "Later event",
            timestamp: SupportKitTestFixture.date.addingTimeInterval(1),
        )
        let result = await client.submit(prepared)
        let queued = await store.dueSubmissions(before: SupportKitTestFixture.date, limit: 10)
        let submission = try #require(queued.first?.submission)

        // Assert
        #expect(result == .queued(reportID: SupportKitTestFixture.reportID))
        #expect(prepared.preview == originalPreview)
        #expect(submission.title == originalPreview.title)
        #expect(submission.message == originalPreview.message)
        #expect(submission.responses == originalPreview.responses)
        #expect(submission.diagnostics == originalPreview.diagnostics)
        #expect(!submission.diagnostics.map(\.value).joined().contains("Later event"))
        #expect(submission.diagnostics.map(\.value).joined().contains("<redacted-email>"))
    }

    @Test
    func `diagnostic count and value limits are applied before a preview is exposed`() async throws {
        // Arrange
        let provider = StaticDiagnosticsProvider(diagnostics: [
            .init(key: "One", value: "123456789"),
            .init(key: "Two", value: "abcdefghi"),
            .init(key: "Three", value: "ignored"),
        ])
        let diagnostics = DiagnosticsConfiguration(
            includesOperatingSystem: false,
            includesDeviceModel: false,
            includesApplicationVersion: false,
            includesThermalState: false,
            includesLowPowerMode: false,
            maximumDiagnosticCount: 2,
            maximumDiagnosticValueLength: 5,
            customProviders: [provider],
        )
        let configuration = try SupportKitTestFixture.configuration(diagnostics: diagnostics)
        let client = SupportClient(
            configuration: configuration,
            transport: SupportTransportSpyingStub(outcomes: []),
            store: InMemorySupportSubmissionStore(),
            now: { SupportKitTestFixture.date },
            makeID: { SupportKitTestFixture.reportID },
        )

        // Act
        let preparation = await client.prepare(
            .init(subject: "Subject", message: "Message", includesDiagnostics: true),
        )
        let prepared = try #require(preparation.preparedValue)

        // Assert
        #expect(prepared.preview.diagnostics == [
            .init(key: "One", value: "12345"),
            .init(key: "Two", value: "abcde"),
        ])
    }
}

private extension Result where Success == SupportSubmission, Failure == SupportSubmissionFailure {
    var successValue: SupportSubmission? {
        guard case let .success(value) = self else { return nil }
        return value
    }
}

private extension SupportPreparationResult {
    var preparedValue: PreparedSupportSubmission? {
        guard case let .ready(value) = self else { return nil }
        return value
    }
}
