import Foundation
import Observation
import SupportKit

/// Observable state and actions for apps that build a custom SwiftUI form.
@MainActor
@Observable
public final class SupportFormModel {
    /// The editable report subject.
    public var subject = ""
    /// The editable free-form support message.
    public var message = ""
    /// Editable state for the configured additional fields.
    public var fieldStates: [SupportFormFieldState]
    /// Whether the next preparation may collect configured diagnostics.
    public var includesDiagnostics: Bool
    /// Whether the standard payload-preview sheet is presented.
    public var isShowingPreview = false
    /// The current support-flow presentation state.
    public private(set) var phase: SupportFormPhase = .editing
    /// The frozen report awaiting confirmation, when one exists.
    public private(set) var preparedSubmission: PreparedSupportSubmission?

    private let client: SupportClient
    private let configuration: SupportFormConfiguration
    private var activeReportID: UUID?
    @ObservationIgnored private var eventTask: Task<Void, Never>?

    /// Creates a model backed by a long-lived support client and explicit form configuration.
    ///
    /// - Parameters:
    ///   - client: The client that prepares, queues, and delivers reports.
    ///   - configuration: The form fields and copy to expose through this model.
    init(client: SupportClient, configuration: SupportFormConfiguration) {
        self.client = client
        self.configuration = configuration
        var identifiers = Set<String>()
        fieldStates = configuration.additionalFields
            .filter { identifiers.insert($0.id).inserted }
            .map(SupportFormFieldState.init)
        includesDiagnostics = configuration.diagnosticsInitiallyIncluded
        observeDeliveryEvents()
    }

    /// Creates a model using the form configuration validated by `client`.
    ///
    /// - Parameter client: The client that prepares, queues, and delivers reports.
    public convenience init(client: SupportClient) {
        self.init(client: client, configuration: client.formConfiguration)
    }

    isolated deinit {
        eventTask?.cancel()
    }

    /// Whether preparation or queueing is currently in progress.
    public var isBusy: Bool {
        phase == .preparing || phase == .submitting
    }

    /// Validates and freezes the current form, presenting a preview when configured.
    ///
    /// - Returns: A terminal result when preparation is rejected or preview is disabled; otherwise, `nil` while
    ///   the frozen report awaits confirmation. A concurrent call also returns `nil` while the model is busy.
    @discardableResult
    public func prepareForSubmission() async -> SupportSubmissionResult? {
        guard !isBusy else { return nil }
        phase = .preparing

        switch await client.prepare(makeDraft()) {
        case let .ready(prepared):
            preparedSubmission = prepared
            if configuration.showsPayloadPreview {
                phase = .reviewing
                isShowingPreview = true
                return nil
            }
            return await submitPrepared()
        case let .rejected(failure):
            let result = SupportSubmissionResult.rejected(failure)
            apply(result)
            return result
        }
    }

    /// Queues the exact report currently represented by ``preparedSubmission``.
    ///
    /// - Returns: The queueing result, or `nil` when there is no frozen report to submit.
    @discardableResult
    public func submitPrepared() async -> SupportSubmissionResult? {
        guard let preparedSubmission else { return nil }
        isShowingPreview = false
        phase = .submitting
        activeReportID = preparedSubmission.id
        let result = await client.submit(preparedSubmission)
        self.preparedSubmission = nil
        apply(result)
        return result
    }

    /// Discards the frozen preview and returns the model to editing.
    public func cancelPreview() {
        isShowingPreview = false
        preparedSubmission = nil
        if phase == .reviewing {
            phase = .editing
        }
    }

    /// Restores configured field defaults and clears transient presentation state.
    public func reset() {
        subject = ""
        message = ""
        fieldStates = configuration.additionalFields.map(SupportFormFieldState.init)
        includesDiagnostics = configuration.diagnosticsInitiallyIncluded
        preparedSubmission = nil
        activeReportID = nil
        isShowingPreview = false
        phase = .editing
    }

    private func makeDraft() -> SupportDraft {
        var responses: [String: String] = [:]
        for state in fieldStates {
            responses[state.id] = state.responseValue
        }
        return SupportDraft(
            subject: subject,
            message: message,
            responses: responses,
            includesDiagnostics: includesDiagnostics,
        )
    }

    private func apply(_ result: SupportSubmissionResult) {
        switch result {
        case let .queued(reportID), let .duplicatePending(reportID):
            activeReportID = reportID
            if case let .accepted(acceptedID, _) = phase, acceptedID == reportID {
                break
            }
            phase = .queued(reportID: reportID)
        case let .duplicateAccepted(receipt):
            activeReportID = receipt.reportID
            phase = .accepted(reportID: receipt.reportID, destinationURL: receipt.destinationURL)
        case let .rejected(failure):
            activeReportID = nil
            phase = .failed(message: configuration.failureMessage(failure))
        }
    }

    private func observeDeliveryEvents() {
        eventTask = Task { [weak self, client] in
            let events = await client.events()
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.apply(event)
            }
        }
    }

    private func apply(_ event: SupportDeliveryEvent) {
        switch event {
        case let .accepted(receipt) where receipt.reportID == activeReportID:
            phase = .accepted(reportID: receipt.reportID, destinationURL: receipt.destinationURL)
        case let .needsAttention(reportID, reason) where reportID == activeReportID:
            phase = .failed(message: reason)
        default:
            break
        }
    }
}
