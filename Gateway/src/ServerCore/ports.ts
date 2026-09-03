import type {
  DeliveryMessage,
  EncryptedPayload,
  VersionedEncryptedPayload,
  StoredPayload,
  StoredReport,
  SupportProject,
  SupportSubmission,
} from "./domain";

export type AcceptedReport = {
  report: StoredReport;
  inserted: boolean;
};

export type OutboxEntry = {
  projectID: string;
  reportID: string;
  publishAttemptCount: number;
};

export type RequestAuthenticationInput = {
  authorization: string | null;
  method: string;
  path: string;
};

export type AuthenticatedRequest = {
  actorID: string | null;
  /** Null is permitted only for the explicitly anonymous evaluation adapter. */
  allowedProjectIDs: ReadonlySet<string> | null;
};

export type AuthenticationResult =
  | { status: "allowed"; principal: AuthenticatedRequest }
  | { status: "denied"; code: string }
  | { status: "unavailable"; code: string };

export type RequestAuthenticator = {
  authenticate(input: Readonly<RequestAuthenticationInput>): Promise<AuthenticationResult>;
};

export type ProjectRegistry<TTarget> = {
  findEnabledProject(projectID: string): Promise<SupportProject<TTarget> | null>;
  /** Resolves the exact immutable route accepted with a report; never falls forward. */
  findEnabledProjectRevision(
    projectID: string,
    routingRevision: number,
  ): Promise<SupportProject<TTarget> | null>;
};

export type ProjectAdmissionControl = {
  allow(projectID: string): Promise<boolean>;
};

export type AcceptReportInput = {
  submission: SupportSubmission;
  idempotencyKeyHash: string;
  rawPayloadSha256: string;
  encryptedPayload: VersionedEncryptedPayload;
  markerVersion: number;
  routingRevision: number;
  acceptedAt: string;
  payloadPurgeAt: string;
};

export type ReconciliationClaim = {
  /** Completed not-found searches before this lease was atomically acquired. */
  completedAttemptCount: number;
};

export type ReconciliationMissResult = "scheduled" | "manual_review" | "stale";

export type ReportStore = {
  /** Atomically persists a report, its immutable acceptance snapshot, and its outbox row. */
  acceptWithOutbox(input: Readonly<AcceptReportInput>): Promise<AcceptedReport>;
  find(projectID: string, reportID: string): Promise<StoredReport | null>;
  claimForAuthorization(
    projectID: string,
    reportID: string,
    leaseToken: string,
    now: string,
    leaseExpiresAt: string,
  ): Promise<boolean>;
  markCreating(
    projectID: string,
    reportID: string,
    leaseToken: string,
    now: string,
    leaseExpiresAt: string,
  ): Promise<boolean>;
  markRetrying(
    projectID: string,
    reportID: string,
    leaseToken: string,
    errorCode: string,
    now: string,
  ): Promise<boolean>;
  scheduleReconciliationFromCreating(
    projectID: string,
    reportID: string,
    creatingLeaseToken: string,
    errorCode: string,
    now: string,
    notBefore: string,
  ): Promise<boolean>;
  claimCreatingForReconciliation(
    projectID: string,
    reportID: string,
    reconciliationLeaseToken: string,
    now: string,
    leaseExpiresAt: string,
  ): Promise<ReconciliationClaim | null>;
  /** Claims only a due, unleased/expired reconciliation row. */
  claimForReconciliation(
    projectID: string,
    reportID: string,
    reconciliationLeaseToken: string,
    now: string,
    leaseExpiresAt: string,
  ): Promise<ReconciliationClaim | null>;
  rescheduleReconciliation(
    projectID: string,
    reportID: string,
    reconciliationLeaseToken: string,
    errorCode: string,
    now: string,
    notBefore: string,
  ): Promise<boolean>;
  completeReconciliationMiss(
    projectID: string,
    reportID: string,
    reconciliationLeaseToken: string,
    now: string,
    notBefore: string,
    maximumAttempts: number,
  ): Promise<ReconciliationMissResult>;
  markReconciliationDelivered(
    projectID: string,
    reportID: string,
    reconciliationLeaseToken: string,
    destinationReference: string,
    destinationURL: string,
    now: string,
  ): Promise<boolean>;
  markReconciliationManualReview(
    projectID: string,
    reportID: string,
    reconciliationLeaseToken: string,
    errorCode: string,
    now: string,
  ): Promise<boolean>;
  markDelivered(
    projectID: string,
    reportID: string,
    leaseToken: string,
    destinationReference: string,
    destinationURL: string,
    now: string,
  ): Promise<boolean>;
  markPermanentFailure(
    projectID: string,
    reportID: string,
    leaseToken: string,
    errorCode: string,
    now: string,
  ): Promise<boolean>;
  markManualReview(
    projectID: string,
    reportID: string,
    leaseToken: string,
    errorCode: string,
    now: string,
  ): Promise<boolean>;
};

export type OutboxStore = {
  listPending(now: string, limit: number): Promise<OutboxEntry[]>;
  markPublished(projectID: string, reportID: string, now: string): Promise<void>;
  markRetry(
    projectID: string,
    reportID: string,
    availableAt: string,
    now: string,
  ): Promise<void>;
  recoverStale(cutoff: string, now: string): Promise<void>;
  purgeExpiredPayloads(now: string): Promise<void>;
};

export type DeliveryPublisher = {
  publish(messages: readonly DeliveryMessage[]): Promise<void>;
};

export type PayloadCipher = {
  encrypt(payload: StoredPayload, projectID: string, reportID: string): Promise<VersionedEncryptedPayload>;
  decrypt(
    payload: EncryptedPayload,
    keyVersion: number,
    projectID: string,
    reportID: string,
  ): Promise<unknown>;
};

export type MarkerFactory = {
  readonly activeVersion: number;
  make(projectID: string, reportID: string, keyVersion: number): Promise<string>;
};

export type DestinationDocument = {
  title: string;
  body: string;
};

export type DestinationItem = {
  reference: string;
  url: string;
};

export type IssueTrackerSession = {
  validateTarget(): Promise<void>;
  create(document: Readonly<DestinationDocument>, labels: readonly string[]): Promise<DestinationItem>;
  findByMarker(marker: string): Promise<DestinationItem | null>;
};

export type IssueTracker<TTarget> = {
  open(target: Readonly<TTarget>): Promise<IssueTrackerSession>;
};

export type TrackerFailureKind = "retryable" | "permanent" | "ambiguous";

export class IssueTrackerError extends Error {
  readonly kind: TrackerFailureKind;
  readonly code: string;
  readonly retryAfterSeconds: number | null;

  constructor(kind: TrackerFailureKind, code: string, retryAfterSeconds: number | null = null) {
    super(code);
    this.name = "IssueTrackerError";
    this.kind = kind;
    this.code = code;
    this.retryAfterSeconds = retryAfterSeconds;
  }
}

export type Clock = {
  now(): Date;
};

export type IdentifierGenerator = {
  randomUUID(): string;
};

export class ProjectConfigurationError extends Error {
  readonly code: string;

  constructor(code: string) {
    super(code);
    this.name = "ProjectConfigurationError";
    this.code = code;
  }
}
