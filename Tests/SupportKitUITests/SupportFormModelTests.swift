import Foundation
@testable import SupportKit
@testable import SupportKitUI
import Testing

private let uiTestReportID = UUID(uuid: (
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00,
    0x40, 0x00,
    0x80, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x11,
))
private let uiTestDate = Date(timeIntervalSince1970: 1_700_000_000)

@Suite("Support form model")
@MainActor
struct SupportFormModelTests {
    @Test
    func `replacing a client rekeys form state and routes through only the replacement client`() async throws {
        // Arrange
        let form = SupportFormConfiguration(additionalFields: [], showsPayloadPreview: false)
        let originalStore = InMemorySupportSubmissionStore()
        let replacementStore = InMemorySupportSubmissionStore()
        let originalClient = try makeClient(
            projectID: "ui.original",
            form: form,
            store: originalStore,
        )
        let replacementClient = try makeClient(
            projectID: "ui.replacement",
            form: form,
            store: replacementStore,
        )
        let originalForm = SupportForm(client: originalClient)
        let replacementForm = SupportForm(client: replacementClient)
        let replacementContent = SupportFormContent(
            client: replacementClient,
            configuration: replacementClient.formConfiguration,
            theme: .default,
            onSubmission: { _ in },
        )
        replacementContent.model.subject = "Replacement subject"
        replacementContent.model.message = "Replacement message"

        // Act
        let result = await replacementContent.model.prepareForSubmission()
        let originalReports = await originalStore.dueSubmissions(
            in: uiScope(projectID: "ui.original"),
            before: .distantFuture,
            limit: 10,
        )
        let replacementReports = await replacementStore.dueSubmissions(
            in: uiScope(projectID: "ui.replacement"),
            before: .distantFuture,
            limit: 10,
        )

        // Assert
        #expect(originalForm.stateIdentity != replacementForm.stateIdentity)
        #expect(result == .queued(reportID: uiTestReportID))
        #expect(originalReports.isEmpty)
        #expect(replacementReports.count == 1)
        #expect(replacementReports.first?.submission.projectID == "ui.replacement")
    }

    @Test
    func `initial state reflects configured defaults`() throws {
        // Arrange
        let form = SupportFormConfiguration(
            additionalFields: [
                .init(id: "account", label: "Account", defaultValue: "Personal"),
                .init(id: "consent", label: "Consent", kind: .toggle, defaultValue: "true"),
            ],
            diagnosticsInitiallyIncluded: true,
        )
        let client = try makeClient(form: form)

        // Act
        let sut = SupportFormModel(client: client, configuration: form)

        // Assert
        #expect(sut.phase == .editing)
        #expect(sut.subject.isEmpty)
        #expect(sut.message.isEmpty)
        #expect(sut.includesDiagnostics)
        #expect(!sut.isBusy)
        #expect(!sut.isShowingPreview)
        #expect(sut.preparedSubmission == nil)
        #expect(sut.fieldStates.map(\.textValue) == ["Personal", "true"])
        #expect(sut.fieldStates.map(\.toggleValue) == [false, true])
    }

    @Test
    func `validation rejection moves to a user-safe failed phase`() async throws {
        // Arrange
        let form = SupportFormConfiguration(additionalFields: [])
        let sut = try SupportFormModel(client: makeClient(form: form), configuration: form)
        sut.subject = "Subject"
        sut.message = "   "

        // Act
        let result = await sut.prepareForSubmission()

        // Assert
        #expect(result == .rejected(.emptyMessage))
        #expect(sut.phase == .failed(message: "Enter a message."))
        #expect(!sut.isBusy)
        #expect(!sut.isShowingPreview)
        #expect(sut.preparedSubmission == nil)
    }

    @Test
    func `validation rejection uses the configured localized failure message`() async throws {
        // Arrange
        let form = SupportFormConfiguration(
            additionalFields: [],
            failureMessage: { failure in
                failure == .emptyMessage ? "Localized empty message" : "Localized failure"
            },
        )
        let sut = try SupportFormModel(client: makeClient(form: form), configuration: form)
        sut.subject = "Subject"

        // Act
        let result = await sut.prepareForSubmission()

        // Assert
        #expect(result == .rejected(.emptyMessage))
        #expect(sut.phase == .failed(message: "Localized empty message"))
    }

    @Test
    func `preparation opens review and cancellation returns to editing`() async throws {
        // Arrange
        let form = SupportFormConfiguration(additionalFields: [], showsPayloadPreview: true)
        let sut = try SupportFormModel(client: makeClient(form: form), configuration: form)
        sut.subject = "Subject"
        sut.message = "Message"

        // Act
        let result = await sut.prepareForSubmission()
        let prepared = try #require(sut.preparedSubmission)
        sut.cancelPreview()

        // Assert
        #expect(result == nil)
        #expect(prepared.id == uiTestReportID)
        #expect(prepared.preview.title == "[Support] Subject")
        #expect(sut.phase == .editing)
        #expect(!sut.isShowingPreview)
        #expect(sut.preparedSubmission == nil)
        #expect(sut.subject == "Subject")
        #expect(sut.message == "Message")
    }

    @Test
    func `confirmed preview exposes the submitting phase then finishes queued`() async throws {
        // Arrange
        let form = SupportFormConfiguration(additionalFields: [], showsPayloadPreview: true)
        let store = GatedUISubmissionStore()
        let client = try makeClient(form: form, store: store)
        let sut = SupportFormModel(client: client, configuration: form)
        sut.subject = "Subject"
        sut.message = "Message"
        _ = await sut.prepareForSubmission()

        // Act
        let submissionTask = Task { await sut.submitPrepared() }
        await store.waitUntilEnqueueStarted()
        let phaseDuringEnqueue = sut.phase
        let busyDuringEnqueue = sut.isBusy
        let previewDuringEnqueue = sut.isShowingPreview
        await store.releaseEnqueue()
        let result = await submissionTask.value

        // Assert
        #expect(phaseDuringEnqueue == .submitting)
        #expect(busyDuringEnqueue)
        #expect(!previewDuringEnqueue)
        #expect(result == .queued(reportID: uiTestReportID))
        #expect(sut.phase == .queued(reportID: uiTestReportID))
        #expect(sut.preparedSubmission == nil)
        #expect(!sut.isBusy)
        #expect(await store.readyCount(in: uiScope()) == 1)
    }

    @Test
    func `a form without preview prepares and queues in one action`() async throws {
        // Arrange
        let form = SupportFormConfiguration(additionalFields: [], showsPayloadPreview: false)
        let store = InMemorySupportSubmissionStore()
        let sut = try SupportFormModel(
            client: makeClient(form: form, store: store),
            configuration: form,
        )
        sut.subject = "Subject"
        sut.message = "Message"

        // Act
        let result = await sut.prepareForSubmission()

        // Assert
        #expect(result == .queued(reportID: uiTestReportID))
        #expect(sut.phase == .queued(reportID: uiTestReportID))
        #expect(!sut.isShowingPreview)
        #expect(sut.preparedSubmission == nil)
        #expect(await store.readyCount(in: uiScope()) == 1)
    }

    @Test
    func `an existing accepted fingerprint moves the form to accepted with its destination URL`() async throws {
        // Arrange
        let form = SupportFormConfiguration(additionalFields: [], showsPayloadPreview: true)
        let store = InMemorySupportSubmissionStore()
        let destinationURL = try #require(URL(string: "https://github.com/example/project/issues/42"))
        let transport = UITransportSpyingStub(destinationURL: destinationURL)
        let client = try makeClient(form: form, store: store, transport: transport)
        let draft = SupportDraft(subject: "Subject", message: "Message")
        _ = await client.submit(draft)
        _ = await client.flush()
        let sut = SupportFormModel(client: client, configuration: form)
        sut.subject = draft.subject
        sut.message = draft.message

        // Act
        _ = await sut.prepareForSubmission()
        let result = await sut.submitPrepared()

        // Assert
        guard case let .duplicateAccepted(receipt) = result else {
            Issue.record("Expected the previous accepted receipt")
            return
        }
        #expect(receipt.destinationURL == destinationURL)
        #expect(sut.phase == .accepted(reportID: uiTestReportID, destinationURL: destinationURL))
        #expect(await transport.submissionCount() == 1)
    }

    @Test
    func `a second prepare action is ignored while diagnostics are still preparing`() async throws {
        // Arrange
        let provider = GatedUIDiagnosticsProvider()
        let form = SupportFormConfiguration(
            additionalFields: [],
            diagnosticsInitiallyIncluded: true,
            showsPayloadPreview: true,
        )
        let diagnostics = DiagnosticsConfiguration(
            includesOperatingSystem: false,
            includesDeviceModel: false,
            includesApplicationVersion: false,
            includesThermalState: false,
            includesLowPowerMode: false,
            customProviders: [provider],
        )
        let sut = try SupportFormModel(
            client: makeClient(form: form, diagnostics: diagnostics),
            configuration: form,
        )
        sut.subject = "Subject"
        sut.message = "Message"

        // Act
        let firstPreparation = Task { await sut.prepareForSubmission() }
        await provider.waitUntilStarted()
        let phaseWhileWaiting = sut.phase
        let secondResult = await sut.prepareForSubmission()
        await provider.release()
        let firstResult = await firstPreparation.value

        // Assert
        #expect(phaseWhileWaiting == .preparing)
        #expect(secondResult == nil)
        #expect(firstResult == nil)
        #expect(sut.phase == .reviewing)
        #expect(sut.isShowingPreview)
    }

    @Test
    func `reset restores all defaults from every terminal and review-related property`() async throws {
        // Arrange
        let form = SupportFormConfiguration(
            additionalFields: [
                .init(id: "name", label: "Name", defaultValue: "Default"),
                .init(id: "consent", label: "Consent", kind: .toggle, defaultValue: "true"),
            ],
            diagnosticsInitiallyIncluded: true,
            showsPayloadPreview: true,
        )
        let sut = try SupportFormModel(client: makeClient(form: form), configuration: form)
        sut.subject = "Subject"
        sut.message = "Message"
        sut.fieldStates[0].textValue = "Changed"
        sut.fieldStates[1].toggleValue = false
        sut.includesDiagnostics = false
        _ = await sut.prepareForSubmission()

        // Act
        sut.reset()

        // Assert
        #expect(sut.phase == .editing)
        #expect(sut.subject.isEmpty)
        #expect(sut.message.isEmpty)
        #expect(sut.includesDiagnostics)
        #expect(sut.fieldStates[0].textValue == "Default")
        #expect(sut.fieldStates[1].toggleValue)
        #expect(sut.preparedSubmission == nil)
        #expect(!sut.isShowingPreview)
    }

    @Test
    func `submit without a prepared payload is a no-op`() async throws {
        // Arrange
        let form = SupportFormConfiguration(additionalFields: [])
        let sut = try SupportFormModel(client: makeClient(form: form), configuration: form)

        // Act
        let result = await sut.submitPrepared()

        // Assert
        #expect(result == nil)
        #expect(sut.phase == .editing)
    }

    private func makeClient(
        projectID: String = "ui.tests",
        form: SupportFormConfiguration,
        diagnostics: DiagnosticsConfiguration = .init(
            includesOperatingSystem: false,
            includesDeviceModel: false,
            includesApplicationVersion: false,
            includesThermalState: false,
            includesLowPowerMode: false,
        ),
        store: any SupportSubmissionStore = InMemorySupportSubmissionStore(),
        transport: any SupportTransport = UITransportSpyingStub(),
    ) throws -> SupportClient {
        let configuration = try SupportConfiguration(
            projectID: projectID,
            form: form,
            diagnostics: diagnostics,
            delivery: .init(automaticallyDelivers: false),
        )
        return SupportClient(
            configuration: configuration,
            transport: transport,
            store: store,
            now: { uiTestDate },
            makeID: { uiTestReportID },
        )
    }
}

private func uiScope(projectID: String = "ui.tests") -> SupportQueueScope {
    SupportQueueScope(projectID: projectID, queueIdentifier: projectID)
}

private actor UITransportSpyingStub: SupportTransport {
    private let destinationURL: URL?
    private var capturedSubmissions: [SupportSubmission] = []

    init(destinationURL: URL? = nil) {
        self.destinationURL = destinationURL
    }

    func submit(_ submission: SupportSubmission) async throws -> SupportDeliveryReceipt {
        capturedSubmissions.append(submission)
        return SupportDeliveryReceipt(
            reportID: submission.id,
            status: .delivered,
            acceptedAt: Date(timeIntervalSince1970: 1_700_000_000),
            destinationURL: destinationURL,
            destinationReference: "42",
        )
    }

    func submissionCount() -> Int {
        capturedSubmissions.count
    }
}

private actor GatedUIDiagnosticsProvider: SupportDiagnosticsProvider {
    private var collectionContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasStarted = false
    private var isReleased = false

    func collectDiagnostics() async -> [SupportDiagnostic] {
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        if !isReleased {
            await withCheckedContinuation { continuation in
                collectionContinuation = continuation
            }
        }
        return [.init(key: "Test", value: "Value")]
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        collectionContinuation?.resume()
        collectionContinuation = nil
    }
}
