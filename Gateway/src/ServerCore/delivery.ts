import type { DeliveryMessage, StoredReport, SupportProject } from "./domain";
import {
  buildDestinationDocument,
  InvalidDestinationMarkerError,
  requireValidDestinationMarker,
} from "./markdown";
import { resolveLabels } from "./ingestion";
import {
  IssueTrackerError,
  ProjectConfigurationError,
} from "./ports";
import type {
  Clock,
  IdentifierGenerator,
  IssueTracker,
  IssueTrackerSession,
  MarkerFactory,
  PayloadCipher,
  ProjectRegistry,
  ReconciliationClaim,
  ReportStore,
} from "./ports";
import { parseStoredPayload } from "./validation";

export type DeliveryDecision = { action: "ack" } | { action: "retry"; delaySeconds: number };

export type DeliveryDependencies<TTarget> = {
  reports: ReportStore;
  projects: ProjectRegistry<TTarget>;
  issueTracker: IssueTracker<TTarget>;
  payloadCipher: PayloadCipher;
  markerFactory: MarkerFactory;
  clock: Clock;
  identifiers: IdentifierGenerator;
};

const DELIVERY_LEASE_MILLISECONDS = 90_000;
const MAX_RECONCILIATION_ATTEMPTS = 8;
const RECONCILIATION_INTERVAL_SECONDS = 600;

/** Portable delivery state machine; queue/provider adapters only translate at its edges. */
export async function processDelivery<TTarget>(
  message: Readonly<DeliveryMessage>,
  queueAttempts: number,
  dependencies: Readonly<DeliveryDependencies<TTarget>>,
): Promise<DeliveryDecision> {
  let report = await dependencies.reports.find(message.projectID, message.reportID);
  if (report === null || isTerminal(report)) {
    return { action: "ack" };
  }

  if (report.status === "reconciling") {
    const now = dependencies.clock.now();
    const reconciliationLeaseToken = dependencies.identifiers.randomUUID();
    const claim = await dependencies.reports.claimForReconciliation(
      report.projectID,
      report.reportID,
      reconciliationLeaseToken,
      now.toISOString(),
      new Date(now.getTime() + DELIVERY_LEASE_MILLISECONDS).toISOString(),
    );
    if (claim === null) {
      return { action: "retry", delaySeconds: reconciliationRetryDelay(report, now) };
    }
    return reconcileReport(report, reconciliationLeaseToken, claim, dependencies);
  }
  if (report.status === "creating") {
    const now = dependencies.clock.now();
    if (!leaseHasExpired(report, now)) {
      return { action: "retry", delaySeconds: 30 };
    }
    const reconciliationLeaseToken = dependencies.identifiers.randomUUID();
    const claim = await dependencies.reports.claimCreatingForReconciliation(
      report.projectID,
      report.reportID,
      reconciliationLeaseToken,
      now.toISOString(),
      new Date(now.getTime() + DELIVERY_LEASE_MILLISECONDS).toISOString(),
    );
    if (claim === null) {
      return { action: "retry", delaySeconds: 30 };
    }
    return reconcileReport(report, reconciliationLeaseToken, claim, dependencies);
  }
  if (report.status === "authorizing" && !leaseHasExpired(report, dependencies.clock.now())) {
    return { action: "retry", delaySeconds: 30 };
  }

  const leaseToken = dependencies.identifiers.randomUUID();
  const now = dependencies.clock.now();
  const claimed = await dependencies.reports.claimForAuthorization(
    report.projectID,
    report.reportID,
    leaseToken,
    now.toISOString(),
    new Date(now.getTime() + DELIVERY_LEASE_MILLISECONDS).toISOString(),
  );
  if (!claimed) {
    return { action: "retry", delaySeconds: 30 };
  }
  report = await requireReport(dependencies.reports, report.projectID, report.reportID);

  let project: SupportProject<TTarget> | null;
  try {
    project = await loadAcceptedProject(report, dependencies);
  } catch (error) {
    if (error instanceof ProjectConfigurationError) {
      const transitioned = await dependencies.reports.markManualReview(
        report.projectID,
        report.reportID,
        leaseToken,
        error.code,
        dependencies.clock.now().toISOString(),
      );
      return transitioned ? { action: "ack" } : { action: "retry", delaySeconds: 30 };
    }
    throw error;
  }
  if (project === null) {
    const transitioned = await dependencies.reports.markManualReview(
      report.projectID,
      report.reportID,
      leaseToken,
      "accepted_route_unavailable",
      dependencies.clock.now().toISOString(),
    );
    return transitioned ? { action: "ack" } : { action: "retry", delaySeconds: 30 };
  }

  let storedPayload;
  try {
    if (report.payloadCiphertext === null || report.payloadIV === null) {
      throw new Error("encrypted_payload_missing");
    }
    storedPayload = parseStoredPayload(
      await dependencies.payloadCipher.decrypt(
        { ciphertext: report.payloadCiphertext, iv: report.payloadIV },
        report.encryptionVersion,
        report.projectID,
        report.reportID,
      ),
    );
  } catch {
    const transitioned = await dependencies.reports.markManualReview(
      report.projectID,
      report.reportID,
      leaseToken,
      "encrypted_payload_unavailable",
      dependencies.clock.now().toISOString(),
    );
    return transitioned ? { action: "ack" } : { action: "retry", delaySeconds: 30 };
  }

  const labels = resolveLabels(project, storedPayload.submission.labels);
  let session: IssueTrackerSession;
  try {
    session = await dependencies.issueTracker.open(project.destination);
    await session.validateTarget();
  } catch (error) {
    return handlePreCreateFailure(error, report, leaseToken, queueAttempts, dependencies);
  }

  let marker: string;
  try {
    marker = requireValidDestinationMarker(
      await dependencies.markerFactory.make(
        report.projectID,
        report.reportID,
        report.markerVersion,
      ),
    );
  } catch (error) {
    const transitioned = await dependencies.reports.markManualReview(
      report.projectID,
      report.reportID,
      leaseToken,
      error instanceof InvalidDestinationMarkerError
        ? "destination_marker_invalid"
        : "destination_marker_unavailable",
      dependencies.clock.now().toISOString(),
    );
    return transitioned ? { action: "ack" } : { action: "retry", delaySeconds: 30 };
  }
  const document = buildDestinationDocument(storedPayload, marker);
  try {
    const creatingAt = dependencies.clock.now();
    const transitioned = await dependencies.reports.markCreating(
      report.projectID,
      report.reportID,
      leaseToken,
      creatingAt.toISOString(),
      new Date(creatingAt.getTime() + DELIVERY_LEASE_MILLISECONDS).toISOString(),
    );
    if (!transitioned) {
      return { action: "retry", delaySeconds: 30 };
    }
  } catch {
    // The transition may have committed even if its response was lost. The next
    // delivery inspects durable state and reconciles; it never calls create here.
    return { action: "retry", delaySeconds: 60 };
  }

  try {
    const destination = validateDestinationItem(
      await session.create(document, labels),
      "ambiguous",
      "destination_create_invalid_response",
    );
    try {
      const transitioned = await dependencies.reports.markDelivered(
        report.projectID,
        report.reportID,
        leaseToken,
        destination.reference,
        destination.url,
        dependencies.clock.now().toISOString(),
      );
      if (!transitioned) {
        return { action: "retry", delaySeconds: 30 };
      }
    } catch {
      return { action: "retry", delaySeconds: 120 };
    }
    return { action: "ack" };
  } catch (error) {
    return handlePostCreateFailure(error, report, leaseToken, queueAttempts, dependencies);
  }
}

async function reconcileReport<TTarget>(
  report: StoredReport,
  reconciliationLeaseToken: string,
  claim: Readonly<ReconciliationClaim>,
  dependencies: Readonly<DeliveryDependencies<TTarget>>,
): Promise<DeliveryDecision> {
  if (claim.completedAttemptCount >= MAX_RECONCILIATION_ATTEMPTS) {
    return finishReconciliationManualReview(
      report,
      reconciliationLeaseToken,
      "destination_create_not_reconciled",
      dependencies,
    );
  }

  let project: SupportProject<TTarget> | null;
  try {
    project = await loadAcceptedProject(report, dependencies);
  } catch (error) {
    if (error instanceof ProjectConfigurationError) {
      return finishReconciliationManualReview(
        report,
        reconciliationLeaseToken,
        error.code,
        dependencies,
      );
    }
    return rescheduleClaimedReconciliation(
      report,
      reconciliationLeaseToken,
      "accepted_route_lookup_unavailable",
      RECONCILIATION_INTERVAL_SECONDS,
      dependencies,
    );
  }
  if (project === null) {
    return finishReconciliationManualReview(
      report,
      reconciliationLeaseToken,
      "accepted_route_unavailable",
      dependencies,
    );
  }

  let marker: string;
  try {
    marker = requireValidDestinationMarker(
      await dependencies.markerFactory.make(
        report.projectID,
        report.reportID,
        report.markerVersion,
      ),
    );
  } catch (error) {
    return finishReconciliationManualReview(
      report,
      reconciliationLeaseToken,
      error instanceof InvalidDestinationMarkerError
        ? "destination_marker_invalid"
        : "destination_marker_unavailable",
      dependencies,
    );
  }

  let session: IssueTrackerSession;
  try {
    session = await dependencies.issueTracker.open(project.destination);
    await session.validateTarget();
  } catch (error) {
    if (error instanceof IssueTrackerError && error.kind === "permanent") {
      return finishReconciliationManualReview(
        report,
        reconciliationLeaseToken,
        error.code,
        dependencies,
      );
    }
    return rescheduleClaimedReconciliation(
      report,
      reconciliationLeaseToken,
      error instanceof IssueTrackerError ? error.code : "destination_reconcile_unavailable",
      reconciliationDelay(error),
      dependencies,
    );
  }

  try {
    const foundDestination = await session.findByMarker(marker);
    if (foundDestination !== null) {
      const destination = validateDestinationItem(
        foundDestination,
        "retryable",
        "destination_reconcile_invalid_response",
      );
      const transitioned = await dependencies.reports.markReconciliationDelivered(
        report.projectID,
        report.reportID,
        reconciliationLeaseToken,
        destination.reference,
        destination.url,
        dependencies.clock.now().toISOString(),
      );
      return transitioned ? { action: "ack" } : { action: "retry", delaySeconds: 30 };
    }
    const now = dependencies.clock.now();
    const result = await dependencies.reports.completeReconciliationMiss(
      report.projectID,
      report.reportID,
      reconciliationLeaseToken,
      now.toISOString(),
      new Date(now.getTime() + RECONCILIATION_INTERVAL_SECONDS * 1_000).toISOString(),
      MAX_RECONCILIATION_ATTEMPTS,
    );
    if (result === "manual_review") {
      return { action: "ack" };
    }
    return {
      action: "retry",
      delaySeconds: result === "scheduled" ? RECONCILIATION_INTERVAL_SECONDS : 30,
    };
  } catch (error) {
    if (error instanceof IssueTrackerError && error.kind === "permanent") {
      return finishReconciliationManualReview(
        report,
        reconciliationLeaseToken,
        error.code,
        dependencies,
      );
    }
    return rescheduleClaimedReconciliation(
      report,
      reconciliationLeaseToken,
      error instanceof IssueTrackerError ? error.code : "destination_reconcile_unavailable",
      reconciliationDelay(error),
      dependencies,
    );
  }
}

async function handlePreCreateFailure<TTarget>(
  error: unknown,
  report: StoredReport,
  leaseToken: string,
  queueAttempts: number,
  dependencies: Readonly<DeliveryDependencies<TTarget>>,
): Promise<DeliveryDecision> {
  if (error instanceof IssueTrackerError && error.kind === "permanent") {
    const transitioned = await dependencies.reports.markPermanentFailure(
      report.projectID,
      report.reportID,
      leaseToken,
      error.code,
      dependencies.clock.now().toISOString(),
    );
    return transitioned ? { action: "ack" } : { action: "retry", delaySeconds: 30 };
  }
  const code = error instanceof IssueTrackerError ? error.code : "destination_authorization_unknown";
  const transitioned = await dependencies.reports.markRetrying(
    report.projectID,
    report.reportID,
    leaseToken,
    code,
    dependencies.clock.now().toISOString(),
  );
  if (!transitioned) {
    return { action: "retry", delaySeconds: 30 };
  }
  return {
    action: "retry",
    delaySeconds: error instanceof IssueTrackerError
      ? (error.retryAfterSeconds ?? retryDelay(queueAttempts))
      : retryDelay(queueAttempts),
  };
}

async function handlePostCreateFailure<TTarget>(
  error: unknown,
  report: StoredReport,
  creatingLeaseToken: string,
  queueAttempts: number,
  dependencies: Readonly<DeliveryDependencies<TTarget>>,
): Promise<DeliveryDecision> {
  if (!(error instanceof IssueTrackerError) || error.kind === "ambiguous") {
    const code = error instanceof IssueTrackerError ? error.code : "destination_create_unknown";
    const now = dependencies.clock.now();
    const transitioned = await dependencies.reports.scheduleReconciliationFromCreating(
      report.projectID,
      report.reportID,
      creatingLeaseToken,
      code,
      now.toISOString(),
      new Date(now.getTime() + RECONCILIATION_INTERVAL_SECONDS * 1_000).toISOString(),
    );
    return {
      action: "retry",
      delaySeconds: transitioned ? RECONCILIATION_INTERVAL_SECONDS : 30,
    };
  }
  if (error.kind === "permanent") {
    const transitioned = await dependencies.reports.markPermanentFailure(
      report.projectID,
      report.reportID,
      creatingLeaseToken,
      error.code,
      dependencies.clock.now().toISOString(),
    );
    return transitioned ? { action: "ack" } : { action: "retry", delaySeconds: 30 };
  }
  const transitioned = await dependencies.reports.markRetrying(
    report.projectID,
    report.reportID,
    creatingLeaseToken,
    error.code,
    dependencies.clock.now().toISOString(),
  );
  if (!transitioned) {
    return { action: "retry", delaySeconds: 30 };
  }
  return {
    action: "retry",
    delaySeconds: error.retryAfterSeconds ?? retryDelay(queueAttempts),
  };
}

async function loadAcceptedProject<TTarget>(
  report: StoredReport,
  dependencies: Readonly<DeliveryDependencies<TTarget>>,
): Promise<SupportProject<TTarget> | null> {
  return dependencies.projects.findEnabledProjectRevision(
    report.projectID,
    report.routingRevision,
  );
}

async function finishReconciliationManualReview<TTarget>(
  report: StoredReport,
  reconciliationLeaseToken: string,
  errorCode: string,
  dependencies: Readonly<DeliveryDependencies<TTarget>>,
): Promise<DeliveryDecision> {
  const transitioned = await dependencies.reports.markReconciliationManualReview(
    report.projectID,
    report.reportID,
    reconciliationLeaseToken,
    errorCode,
    dependencies.clock.now().toISOString(),
  );
  return transitioned ? { action: "ack" } : { action: "retry", delaySeconds: 30 };
}

async function rescheduleClaimedReconciliation<TTarget>(
  report: StoredReport,
  reconciliationLeaseToken: string,
  errorCode: string,
  delaySeconds: number,
  dependencies: Readonly<DeliveryDependencies<TTarget>>,
): Promise<DeliveryDecision> {
  const now = dependencies.clock.now();
  const transitioned = await dependencies.reports.rescheduleReconciliation(
    report.projectID,
    report.reportID,
    reconciliationLeaseToken,
    errorCode,
    now.toISOString(),
    new Date(now.getTime() + delaySeconds * 1_000).toISOString(),
  );
  return { action: "retry", delaySeconds: transitioned ? delaySeconds : 30 };
}

async function requireReport(
  reports: ReportStore,
  projectID: string,
  reportID: string,
): Promise<StoredReport> {
  const report = await reports.find(projectID, reportID);
  if (report === null) {
    throw new Error("report_disappeared");
  }
  return report;
}

function isTerminal(report: StoredReport): boolean {
  return report.status === "delivered"
    || report.status === "permanent_failure"
    || report.status === "manual_review";
}

function leaseHasExpired(report: StoredReport, now: Date): boolean {
  if (report.leaseExpiresAt === null) {
    return true;
  }
  const expiration = Date.parse(report.leaseExpiresAt);
  return !Number.isFinite(expiration) || expiration <= now.getTime();
}

function retryDelay(attempts: number): number {
  const normalizedAttempts = Number.isSafeInteger(attempts) && attempts >= 1 ? attempts : 1;
  return Math.min(30 * 2 ** Math.min(normalizedAttempts - 1, 7), 3_600);
}

function reconciliationDelay(error: unknown): number {
  const proposed = error instanceof IssueTrackerError
    ? error.retryAfterSeconds
    : null;
  return Number.isFinite(proposed) && proposed !== null && proposed >= 30
    ? Math.min(proposed, 3_600)
    : RECONCILIATION_INTERVAL_SECONDS;
}

function reconciliationRetryDelay(report: StoredReport, now: Date): number {
  const timestamps = [report.leaseExpiresAt, report.reconciliationNotBefore]
    .map((value) => value === null ? Number.NaN : Date.parse(value))
    .filter((value) => Number.isFinite(value) && value > now.getTime());
  if (timestamps.length === 0) {
    return 30;
  }
  return Math.max(30, Math.min(
    RECONCILIATION_INTERVAL_SECONDS,
    Math.ceil((Math.min(...timestamps) - now.getTime()) / 1_000),
  ));
}

function validateDestinationItem(
  item: { reference: string; url: string },
  failureKind: "ambiguous" | "retryable",
  errorCode: string,
): { reference: string; url: string } {
  let url: URL;
  try {
    url = new URL(item.url);
  } catch {
    throw new IssueTrackerError(failureKind, errorCode);
  }
  if (
    item.reference.length < 1
    || item.reference.length > 256
    || item.url.length > 2_048
    || url.protocol !== "https:"
    || url.username !== ""
    || url.password !== ""
  ) {
    throw new IssueTrackerError(failureKind, errorCode);
  }
  return item;
}
