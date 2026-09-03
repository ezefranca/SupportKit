import Foundation

private struct ClaimedSupportSubmission {
    let item: QueuedSupportSubmission
    let leaseID: UUID
}

private enum DeliveryAttemptOutcome {
    case accepted
    case retryScheduled
    case needsAttention
    case stop
}

public extension SupportClient {
    /// Attempts currently due reports serially, up to the configured batch size.
    ///
    /// - Returns: Aggregate outcomes and the number of reports remaining in the automatic-delivery state.
    @discardableResult
    func flush() async -> SupportDeliveryReport {
        guard !isFlushing else {
            return await SupportDeliveryReport(remainingReady: store.readyCount(in: configuration.queueScope))
        }
        isFlushing = true
        defer { isFlushing = false }

        var report = SupportDeliveryReport()
        deliveryLoop: for _ in 0 ..< configuration.delivery.deliveryBatchSize {
            guard !Task.isCancelled,
                  let claim = await claimNextDueSubmission()
            else { break }
            guard await validateOwnership(of: claim) else { break }
            guard !Task.isCancelled else {
                await store.releaseLease(recordID: claim.item.recordID, leaseID: claim.leaseID)
                break
            }

            switch await deliver(claim.item, leaseID: claim.leaseID) {
            case .accepted:
                report.accepted += 1
            case .retryScheduled:
                report.retryScheduled += 1
            case .needsAttention:
                report.needsAttention += 1
            case .stop:
                break deliveryLoop
            }
        }

        report.remainingReady = await store.readyCount(in: configuration.queueScope)
        await store.pruneReceipts(
            in: configuration.queueScope,
            olderThan: now().addingTimeInterval(-configuration.delivery.receiptRetentionInterval),
        )
        return report
    }
}

private extension SupportClient {
    func claimNextDueSubmission() async -> ClaimedSupportSubmission? {
        let claimTime = now()
        let leaseID = UUID()
        do {
            let items = try await store.claimDueSubmissions(
                in: configuration.queueScope,
                before: claimTime,
                limit: 1,
                leaseID: leaseID,
                leaseExpiresAt: claimTime.addingTimeInterval(configuration.delivery.deliveryLeaseDuration),
            )
            guard let item = items.first else { return nil }
            return ClaimedSupportSubmission(item: item, leaseID: leaseID)
        } catch {
            return nil
        }
    }

    func validateOwnership(of claim: ClaimedSupportSubmission) async -> Bool {
        guard claim.item.queueScope == configuration.queueScope,
              claim.item.submission.projectID == configuration.projectID
        else {
            // A broken custom store may return a foreign item. Release only the
            // local identity requested by this client; never mutate foreign scope.
            await store.releaseLease(
                recordID: .init(queueScope: configuration.queueScope, reportID: claim.item.id),
                leaseID: claim.leaseID,
            )
            return false
        }
        return true
    }

    func deliver(_ item: QueuedSupportSubmission, leaseID: UUID) async -> DeliveryAttemptOutcome {
        do {
            let receipt = try await transport.submit(item.submission)
            try await store.markAccepted(
                recordID: item.recordID,
                receipt: receipt,
                fingerprint: item.submission.contentFingerprint,
                leaseID: leaseID,
                recordedAt: now(),
            )
            emit(.accepted(receipt))
            return .accepted
        } catch is CancellationError {
            await store.releaseLease(recordID: item.recordID, leaseID: leaseID)
            return .stop
        } catch let error as SupportTransportError {
            switch error {
            case let .retryable(_, serverDelay, reason):
                return await scheduleRetry(
                    for: item,
                    leaseID: leaseID,
                    serverDelay: serverDelay,
                    reason: safeFailureReason(reason),
                )
            case .permanent, .invalidResponse, .payloadTooLarge:
                return await markNeedsAttention(
                    item,
                    leaseID: leaseID,
                    reason: safeFailureReason(error.safeReason),
                )
            }
        } catch {
            return await scheduleRetry(
                for: item,
                leaseID: leaseID,
                serverDelay: nil,
                reason: "Delivery was interrupted.",
            )
        }
    }

    func scheduleRetry(
        for item: QueuedSupportSubmission,
        leaseID: UUID,
        serverDelay: TimeInterval?,
        reason: String,
    ) async -> DeliveryAttemptOutcome {
        let attempt = item.attemptCount == .max ? Int.max : item.attemptCount + 1
        let delay = retryPolicy.delay(afterAttempt: attempt, serverDelay: serverDelay, reportID: item.id)
        let nextAttempt = now().addingTimeInterval(delay)
        do {
            try await store.markRetry(
                recordID: item.recordID,
                leaseID: leaseID,
                attemptCount: attempt,
                nextAttemptAt: nextAttempt,
                failure: reason,
            )
            emit(.retryScheduled(reportID: item.id, attempt: attempt, nextAttemptAt: nextAttempt))
            return .retryScheduled
        } catch {
            return .stop
        }
    }

    func markNeedsAttention(
        _ item: QueuedSupportSubmission,
        leaseID: UUID,
        reason: String,
    ) async -> DeliveryAttemptOutcome {
        do {
            try await store.markNeedsAttention(
                recordID: item.recordID,
                leaseID: leaseID,
                failure: reason,
            )
            emit(.needsAttention(reportID: item.id, reason: reason))
            return .needsAttention
        } catch {
            return .stop
        }
    }
}
