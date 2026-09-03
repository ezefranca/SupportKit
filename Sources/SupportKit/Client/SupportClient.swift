import Foundation

/// The actor-owned entry point for validation, privacy processing, durable
/// queueing, deduplication, and delivery.
public actor SupportClient {
    private struct WorkerSleep {
        let id: UUID
        let task: Task<Void, Never>
    }

    let configuration: SupportConfiguration
    let transport: any SupportTransport
    let store: any SupportSubmissionStore
    private let redactor: SupportRedactor
    private let diagnosticsProvider: SystemDiagnosticsProvider
    let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID
    let retryPolicy: SupportRetryPolicy
    nonisolated let preparedSubmissionOwnerID = UUID()

    // swiftformat:disable modifierOrder
    /// The exact validated form configuration owned by this client.
    nonisolated public let formConfiguration: SupportFormConfiguration
    // swiftformat:enable modifierOrder

    private var workerTask: Task<Void, Never>?
    private var workerID: UUID?
    private var workerSleep: WorkerSleep?
    private var deliveryWakeGeneration: UInt = 0
    var isFlushing = false
    private var eventContinuations: [UUID: AsyncStream<SupportDeliveryEvent>.Continuation] = [:]

    /// Creates a client with explicit transport and persistence dependencies.
    ///
    /// - Parameters:
    ///   - configuration: The validated report, privacy, and delivery policy.
    ///   - transport: The receiver adapter used for delivery.
    ///   - store: A store that provides atomic enqueueing and exclusive delivery leases.
    ///   - redactor: The redactor applied before payloads are frozen.
    ///   - logSource: An optional bounded source of already-redacted application logs.
    ///   - now: A clock override for deterministic scheduling.
    ///   - makeID: A report-identifier generator override for deterministic preparation.
    public init(
        configuration: SupportConfiguration,
        transport: any SupportTransport,
        store: any SupportSubmissionStore,
        redactor: SupportRedactor = .init(),
        logSource: (any SupportLogSource)? = nil,
        now: @escaping @Sendable () -> Date = { .now },
        makeID: @escaping @Sendable () -> UUID = { UUID() },
    ) {
        self.configuration = configuration
        self.transport = transport
        self.store = store
        self.redactor = redactor
        diagnosticsProvider = SystemDiagnosticsProvider(
            configuration: configuration.diagnostics,
            logSource: logSource,
            redactor: redactor,
        )
        self.now = now
        self.makeID = makeID
        retryPolicy = SupportRetryPolicy(configuration: configuration.delivery)
        formConfiguration = configuration.form
    }

    /// Creates a client with the encrypted, file-backed store under Application Support.
    ///
    /// - Parameters:
    ///   - configuration: The validated report, privacy, and delivery policy.
    ///   - transport: The receiver adapter used for delivery.
    ///   - redactor: The redactor applied before payloads are frozen.
    ///   - logSource: An optional bounded source of already-redacted application logs.
    /// - Returns: A client configured with ``FileSupportSubmissionStore``.
    /// - Throws: ``SupportStoreError`` when the durable store cannot be prepared.
    public static func live(
        configuration: SupportConfiguration,
        transport: any SupportTransport,
        redactor: SupportRedactor = .init(),
        logSource: (any SupportLogSource)? = nil,
    ) throws -> SupportClient {
        let store = try FileSupportSubmissionStore(identifier: configuration.fileQueueIdentifier)
        return SupportClient(
            configuration: configuration,
            transport: transport,
            store: store,
            redactor: redactor,
            logSource: logSource,
        )
    }

    /// Validates and redacts a draft into an immutable payload for review.
    ///
    /// - Parameter draft: The mutable user input to validate and sanitize.
    /// - Returns: A frozen report ready for review, or a user-correctable rejection.
    public func prepare(_ draft: SupportDraft) async -> SupportPreparationResult {
        guard SupportDraftPreparationBudget.fits(
            draft,
            form: configuration.form,
            maximumBytes: configuration.delivery.maximumSubmissionBytes,
        ) else {
            return .rejected(.payloadTooLarge(maximumBytes: configuration.delivery.maximumSubmissionBytes))
        }

        let createdAt = now()
        let id = makeID()
        let preparer = SupportSubmissionPreparer(configuration: configuration, redactor: redactor)
        let validation = preparer.validate(draft)
        guard case let .success(validatedDraft) = validation else {
            guard case let .failure(failure) = validation else {
                return .rejected(.queueUnavailable)
            }
            return .rejected(failure)
        }

        let collectedDiagnostics = await SupportDiagnosticCollector(
            configuration: configuration.diagnostics,
            systemProvider: diagnosticsProvider,
        ).collect(ifRequested: draft.includesDiagnostics)
        let submission = preparer.prepare(
            validatedDraft: validatedDraft,
            id: id,
            now: createdAt,
            diagnostics: collectedDiagnostics,
        )

        if let failure = wirePayloadFailure(for: submission) {
            return .rejected(failure)
        }

        return .ready(PreparedSupportSubmission(submission: submission, ownerID: preparedSubmissionOwnerID))
    }

    /// Prepares and durably queues a draft in one operation.
    ///
    /// Use ``prepare(_:)`` followed by the prepared-submission overload of `submit(_:)` when the user must
    /// review the exact frozen payload before queueing it.
    ///
    /// - Parameter draft: The mutable user input to sanitize and queue.
    /// - Returns: The queue or deduplication result, or a user-correctable rejection.
    @discardableResult
    public func submit(_ draft: SupportDraft) async -> SupportSubmissionResult {
        switch await prepare(draft) {
        case let .ready(prepared):
            await submit(prepared)
        case let .rejected(failure):
            .rejected(failure)
        }
    }

    /// Durably queues the exact payload represented by `prepared.preview`.
    ///
    /// - Parameter prepared: The immutable payload previously returned by ``prepare(_:)``.
    /// - Returns: The atomic queue or deduplication result.
    @discardableResult
    public func submit(_ prepared: PreparedSupportSubmission) async -> SupportSubmissionResult {
        guard prepared.ownerID == preparedSubmissionOwnerID else {
            return .rejected(.invalidPreparedSubmission)
        }
        let submission = prepared.submission
        guard submission.projectID == configuration.projectID else {
            return .rejected(.invalidPreparedSubmission)
        }
        if let failure = wirePayloadFailure(for: submission) {
            return .rejected(failure)
        }
        let duplicateSince = now().addingTimeInterval(-configuration.delivery.duplicateSuppressionInterval)
        do {
            let result = try await store.enqueueIfAbsent(
                QueuedSupportSubmission(submission: submission, queueScope: configuration.queueScope),
                duplicateSince: duplicateSince,
                capacity: configuration.delivery.maximumStoredSubmissions,
            )
            switch result {
            case let .enqueued(reportID):
                emit(.queued(reportID: reportID))
                wakeOrScheduleAutomaticDelivery()
                return .queued(reportID: reportID)
            case let .duplicatePending(reportID):
                return .duplicatePending(reportID: reportID)
            case let .duplicateAccepted(receipt):
                return .duplicateAccepted(receipt)
            }
        } catch SupportStoreError.queueFull {
            return .rejected(.queueFull)
        } catch {
            return .rejected(.queueUnavailable)
        }
    }

    /// Starts or resumes delivery, for example when the app enters the foreground.
    public func resumeDelivery() {
        wakeOrScheduleAutomaticDelivery(force: true)
    }

    /// Cancels only SupportKit's in-process worker. Persisted reports remain safe.
    public func pauseDelivery() {
        deliveryWakeGeneration &+= 1
        workerID = nil
        workerTask?.cancel()
        workerTask = nil
        workerSleep?.task.cancel()
        workerSleep = nil
    }

    /// Returns the number of reports awaiting delivery or user attention.
    public func pendingReportCount() async -> Int {
        await store.pendingCount(in: configuration.queueScope)
    }

    /// Returns the number of reports in the automatic-delivery state.
    public func readyReportCount() async -> Int {
        await store.readyCount(in: configuration.queueScope)
    }

    /// Creates a bounded event stream suitable for status UI or app telemetry.
    ///
    /// - Returns: A stream that keeps the newest 100 delivery events for a slow consumer.
    public func events() -> AsyncStream<SupportDeliveryEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(100)) { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(id) }
            }
        }
    }
}

extension SupportClient {
    func safeFailureReason(_ reason: String) -> String {
        guard let bounded = SupportTextSafety.boundedSingleLine(reason, maximumBytes: 4096) else {
            return "Delivery failed."
        }
        return SupportTextSafety.boundedFailureReason(redactor.redact(bounded))
    }

    private func wakeOrScheduleAutomaticDelivery(force: Bool = false) {
        guard force || configuration.delivery.automaticallyDelivers || workerTask != nil else { return }

        deliveryWakeGeneration &+= 1
        workerSleep?.task.cancel()
        workerSleep = nil
        guard workerTask == nil else { return }

        let id = UUID()
        workerID = id
        workerTask = Task { [weak self] in
            await self?.deliveryLoop(workerID: id)
        }
    }

    private func deliveryLoop(workerID: UUID) async {
        defer { workerDidFinish(id: workerID) }

        while !Task.isCancelled {
            _ = await flush()
            guard !Task.isCancelled else { return }

            let observedGeneration = deliveryWakeGeneration
            let referenceDate = now()
            guard let nextDate = await store.nextReadyDate(
                in: configuration.queueScope,
                relativeTo: referenceDate,
            ) else {
                if observedGeneration != deliveryWakeGeneration {
                    continue
                }
                return
            }
            if observedGeneration != deliveryWakeGeneration {
                continue
            }

            // Periodic rescans bound clock-change and external-store latency.
            let delay = min(max(0.25, nextDate.timeIntervalSince(now())), 24 * 60 * 60)
            let sleepID = UUID()
            let task = Task {
                _ = try? await Task.sleep(for: .seconds(delay))
            }
            workerSleep = WorkerSleep(id: sleepID, task: task)
            await task.value
            if workerSleep?.id == sleepID {
                workerSleep = nil
            }
        }
    }

    private func workerDidFinish(id: UUID) {
        guard workerID == id else { return }
        workerSleep?.task.cancel()
        workerSleep = nil
        workerTask = nil
        workerID = nil
    }

    private func wirePayloadFailure(for submission: SupportSubmission) -> SupportSubmissionFailure? {
        do {
            let payload = try SupportSubmissionWireCodec.encode(submission)
            guard payload.count <= configuration.delivery.maximumSubmissionBytes else {
                return .payloadTooLarge(maximumBytes: configuration.delivery.maximumSubmissionBytes)
            }
            return nil
        } catch {
            return .queueUnavailable
        }
    }

    func emit(_ event: SupportDeliveryEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations[id] = nil
    }
}
