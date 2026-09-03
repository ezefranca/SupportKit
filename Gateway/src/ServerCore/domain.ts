export const MAX_REQUEST_BYTES = 256 * 1024;
export const MAX_DESTINATION_BODY_BYTES = 60_000;

export type SupportFieldResponse = {
  id: string;
  label: string;
  value: string;
};

export type DiagnosticSensitivity = "standard" | "potentiallyIdentifying";

export type SupportDiagnostic = {
  key: string;
  value: string;
  sensitivity: DiagnosticSensitivity;
};

/** Mirrors SupportKit's SupportSubmission Codable representation exactly. */
export type SupportSubmission = {
  schemaVersion: 1;
  id: string;
  idempotencyKey: string;
  projectID: string;
  createdAt: string;
  title: string;
  message: string;
  responses: SupportFieldResponse[];
  diagnostics: SupportDiagnostic[];
  labels: string[];
  contentFingerprint: string;
};

export type StoredPayload = {
  submission: SupportSubmission;
  serverRedactionCount: number;
};

export type EncryptedPayload = {
  ciphertext: string;
  iv: string;
};

export type VersionedEncryptedPayload = EncryptedPayload & {
  keyVersion: number;
};

export type SupportProject<TTarget> = {
  projectID: string;
  /** Immutable revision covering the destination and label policy. */
  routingRevision: number;
  destination: TTarget;
  allowedLabels: ReadonlySet<string>;
  defaultLabels: readonly string[];
  payloadRetentionDays: number;
};

export type DeliveryState =
  | "pending"
  | "authorizing"
  | "creating"
  | "retrying"
  | "reconciling"
  | "delivered"
  | "permanent_failure"
  | "manual_review";

export type StoredReport = {
  projectID: string;
  reportID: string;
  idempotencyKeyHash: string;
  rawPayloadSha256: string;
  contentFingerprint: string;
  payloadCiphertext: string | null;
  payloadIV: string | null;
  encryptionVersion: number;
  markerVersion: number;
  routingRevision: number;
  status: DeliveryState;
  attemptCount: number;
  reconciliationAttemptCount: number;
  leaseToken: string | null;
  leaseExpiresAt: string | null;
  reconciliationNotBefore: string | null;
  destinationReference: string | null;
  destinationURL: string | null;
  lastErrorCode: string | null;
  acceptedAt: string;
  payloadPurgeAt: string;
  updatedAt: string;
  deliveredAt: string | null;
  payloadPurgedAt: string | null;
};

export type DeliveryMessage = {
  schemaVersion: 1;
  projectID: string;
  reportID: string;
};

export type DeliveryReceiptStatus = "accepted" | "delivered" | "duplicate";

export type DeliveryReceipt = {
  reportID: string;
  status: DeliveryReceiptStatus;
  acceptedAt: string;
  destinationReference: string | null;
  destinationURL: string | null;
};

export type PublicStatus = "accepted" | "delivered" | "needsAttention";

export type ReportStatusResponse = {
  reportID: string;
  projectID: string;
  status: PublicStatus;
  acceptedAt: string;
  updatedAt: string;
  destinationReference: string | null;
  destinationURL: string | null;
};
