import { sha256Hex, timingSafeHexEqual } from "./digest";
import { redactSubmission } from "./redaction";
import type {
  AuthenticatedRequest,
  PayloadCipher,
  MarkerFactory,
  ProjectAdmissionControl,
  ProjectRegistry,
  ReportStore,
} from "./ports";
import type { AcceptedReport } from "./ports";
import { ProjectConfigurationError } from "./ports";
import { MAX_REQUEST_BYTES } from "./domain";
import type { SupportProject } from "./domain";
import { parseStoredPayload, parseSubmission } from "./validation";

export type IngestSubmissionInput = {
  rawBody: Uint8Array;
  claimedRawPayloadSha256: string;
  idempotencyKey: string;
  principal: AuthenticatedRequest;
};

export type IngestionDependencies<TTarget> = {
  projects: ProjectRegistry<TTarget>;
  reports: ReportStore;
  payloadCipher: PayloadCipher;
  markerFactory: MarkerFactory;
  admission: ProjectAdmissionControl;
  now(): Date;
};

export type IngestionFailureKind =
  | "invalid"
  | "forbidden"
  | "not_found"
  | "conflict"
  | "rate_limited";

export class IngestionError extends Error {
  readonly kind: IngestionFailureKind;
  readonly code: string;

  constructor(kind: IngestionFailureKind, code: string, message: string) {
    super(message);
    this.name = "IngestionError";
    this.kind = kind;
    this.code = code;
  }
}

/** Portable report acceptance orchestration. No host/storage/provider types cross this boundary. */
export async function ingestSubmission<TTarget>(
  input: Readonly<IngestSubmissionInput>,
  dependencies: Readonly<IngestionDependencies<TTarget>>,
): Promise<AcceptedReport> {
  if (input.rawBody.byteLength > MAX_REQUEST_BYTES) {
    throw new IngestionError(
      "invalid",
      "payload_too_large",
      "The support report is too large.",
    );
  }
  const rawPayloadSha256 = await sha256Hex(input.rawBody);
  if (!timingSafeHexEqual(input.claimedRawPayloadSha256, rawPayloadSha256)) {
    throw new IngestionError(
      "invalid",
      "payload_digest_mismatch",
      "The request payload digest does not match.",
    );
  }

  const submission = parseSubmission(parseJSON(input.rawBody));
  if (submission.idempotencyKey !== input.idempotencyKey) {
    throw new IngestionError(
      "conflict",
      "idempotency_mismatch",
      "The Idempotency-Key header does not match the report body.",
    );
  }
  if (!projectIsAllowed(input.principal, submission.projectID)) {
    throw new IngestionError(
      "forbidden",
      "project_not_authorized",
      "The authenticated assertion is not valid for this project.",
    );
  }

  if (!await dependencies.admission.allow(submission.projectID)) {
    throw new IngestionError(
      "rate_limited",
      "rate_limited",
      "Too many support reports were submitted.",
    );
  }

  const project = await dependencies.projects.findEnabledProject(submission.projectID);
  if (project === null) {
    throw new IngestionError(
      "not_found",
      "project_not_found",
      "The support project is not available.",
    );
  }

  // Re-validate the server-created representation before it crosses the atomic
  // acceptance boundary. Stored validation has a bounded expansion allowance
  // because replacement markers can be longer than short matched secrets.
  const redactedPayload = parseStoredPayload(redactSubmission(submission));
  const encryptedPayload = await dependencies.payloadCipher.encrypt(
    redactedPayload,
    submission.projectID,
    submission.id,
  );
  const markerVersion = dependencies.markerFactory.activeVersion;
  if (
    !isPositiveVersion(encryptedPayload.keyVersion)
    || !isPositiveVersion(markerVersion)
    || !isPositiveVersion(project.routingRevision)
    || !Number.isSafeInteger(project.payloadRetentionDays)
    || project.payloadRetentionDays < 1
    || project.payloadRetentionDays > 365
  ) {
    throw new ProjectConfigurationError("invalid_acceptance_snapshot");
  }
  const acceptedAt = dependencies.now();
  const accepted = await dependencies.reports.acceptWithOutbox({
    submission,
    idempotencyKeyHash: await sha256Hex(input.idempotencyKey),
    rawPayloadSha256,
    encryptedPayload,
    markerVersion,
    routingRevision: project.routingRevision,
    acceptedAt: acceptedAt.toISOString(),
    payloadPurgeAt: new Date(
      acceptedAt.getTime() + project.payloadRetentionDays * 24 * 60 * 60 * 1_000,
    ).toISOString(),
  });
  if (
    accepted.report.reportID !== submission.id
    || !timingSafeHexEqual(accepted.report.rawPayloadSha256, rawPayloadSha256)
  ) {
    throw new IngestionError(
      "conflict",
      "idempotency_conflict",
      "This Idempotency-Key was already used for a different payload.",
    );
  }
  return accepted;
}

function isPositiveVersion(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 1 && value <= 999_999_999;
}

export function projectIsAllowed(principal: AuthenticatedRequest, projectID: string): boolean {
  return principal.allowedProjectIDs === null || principal.allowedProjectIDs.has(projectID);
}

export function resolveLabels<TTarget>(
  project: Readonly<SupportProject<TTarget>>,
  requested: readonly string[],
): string[] {
  const labels = new Set(project.defaultLabels);
  for (const label of requested) {
    if (project.allowedLabels.has(label)) {
      labels.add(label);
    }
  }
  return Array.from(labels).slice(0, 10);
}

function parseJSON(bytes: Uint8Array): unknown {
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes);
  } catch {
    throw new IngestionError("invalid", "invalid_utf8", "The request body must be valid UTF-8.");
  }
  try {
    const value: unknown = JSON.parse(text);
    return value;
  } catch {
    throw new IngestionError("invalid", "invalid_json", "The request body must be valid JSON.");
  }
}
