import type {
  AcceptReportInput,
  AcceptedReport,
  OutboxEntry,
  OutboxStore,
  ProjectRegistry,
  ReconciliationClaim,
  ReconciliationMissResult,
  ReportStore,
} from "../../ServerCore/ports";
import { ProjectConfigurationError } from "../../ServerCore/ports";
import type { DeliveryState, StoredReport, SupportProject } from "../../ServerCore/domain";

type DestinationDecoder<TTarget> = (adapter: string, configuration: unknown) => TTarget;

type ProjectRow = {
  project_id: string;
  enabled: number;
  routing_revision: number;
  destination_adapter: string;
  destination_config_json: string;
  allowed_labels_json: string;
  default_labels_json: string;
  payload_retention_days: number;
};

type ReportRow = {
  project_id: string;
  report_id: string;
  idempotency_key_hash: string;
  raw_payload_sha256: string;
  content_fingerprint: string;
  payload_ciphertext: string | null;
  payload_iv: string | null;
  encryption_version: number;
  marker_version: number;
  routing_revision: number;
  status: string;
  attempt_count: number;
  reconciliation_attempt_count: number;
  lease_token: string | null;
  lease_expires_at: string | null;
  reconciliation_not_before: string | null;
  destination_reference: string | null;
  destination_url: string | null;
  last_error_code: string | null;
  accepted_at: string;
  payload_purge_at: string;
  updated_at: string;
  delivered_at: string | null;
  payload_purged_at: string | null;
};

type OutboxRow = {
  project_id: string;
  report_id: string;
  publish_attempt_count: number;
};

const PROJECT_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/u;
const ADAPTER_ID_PATTERN = /^[a-z][a-z0-9-]{0,63}$/u;
const DELIVERY_STATES = new Set<DeliveryState>([
  "pending",
  "authorizing",
  "creating",
  "retrying",
  "reconciling",
  "delivered",
  "permanent_failure",
  "manual_review",
]);

/** Cloudflare D1 implementation of the portable persistence ports. */
export class D1Persistence<TTarget>
implements ProjectRegistry<TTarget>, ReportStore, OutboxStore {
  readonly #database: D1Database;
  readonly #decodeDestination: DestinationDecoder<TTarget>;

  constructor(database: D1Database, decodeDestination: DestinationDecoder<TTarget>) {
    this.#database = database;
    this.#decodeDestination = decodeDestination;
  }

  async findEnabledProject(projectID: string): Promise<SupportProject<TTarget> | null> {
    const row = await this.#database
      .prepare(
        `SELECT projects.project_id, projects.enabled,
                project_routes.routing_revision,
                project_routes.destination_adapter,
                project_routes.destination_config_json,
                project_routes.allowed_labels_json,
                project_routes.default_labels_json,
                projects.payload_retention_days
           FROM projects
           JOIN project_routes
             ON project_routes.project_id = projects.project_id
            AND project_routes.routing_revision = projects.current_routing_revision
          WHERE projects.project_id = ? AND projects.enabled = 1`,
      )
      .bind(projectID)
      .first<ProjectRow>();
    return row === null ? null : this.#parseProject(row);
  }

  async findEnabledProjectRevision(
    projectID: string,
    routingRevision: number,
  ): Promise<SupportProject<TTarget> | null> {
    const row = await this.#database
      .prepare(
        `SELECT projects.project_id, projects.enabled,
                project_routes.routing_revision,
                project_routes.destination_adapter,
                project_routes.destination_config_json,
                project_routes.allowed_labels_json,
                project_routes.default_labels_json,
                projects.payload_retention_days
           FROM projects
           JOIN project_routes
             ON project_routes.project_id = projects.project_id
            AND project_routes.routing_revision = ?
          WHERE projects.project_id = ? AND projects.enabled = 1`,
      )
      .bind(routingRevision, projectID)
      .first<ProjectRow>();
    return row === null ? null : this.#parseProject(row);
  }

  async find(projectID: string, reportID: string): Promise<StoredReport | null> {
    const row = await this.#selectReport(
      `WHERE project_id = ? AND report_id = ?`,
      projectID,
      reportID,
    );
    return row === null ? null : mapReport(row);
  }

  async acceptWithOutbox(input: Readonly<AcceptReportInput>): Promise<AcceptedReport> {
    const submission = input.submission;
    const results = await this.#database.batch([
      this.#database
        .prepare(
          `INSERT INTO reports (
               project_id, report_id, idempotency_key_hash, raw_payload_sha256,
               content_fingerprint, payload_ciphertext, payload_iv, encryption_version,
               marker_version, routing_revision, status, accepted_at, payload_purge_at,
               updated_at
           )
           SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?
             FROM projects
             JOIN project_routes
               ON project_routes.project_id = projects.project_id
              AND project_routes.routing_revision = projects.current_routing_revision
            WHERE projects.project_id = ?
              AND projects.enabled = 1
              AND projects.current_routing_revision = ?
           ON CONFLICT(project_id, idempotency_key_hash) DO NOTHING`,
        )
        .bind(
          submission.projectID,
          submission.id,
          input.idempotencyKeyHash,
          input.rawPayloadSha256,
          submission.contentFingerprint,
          input.encryptedPayload.ciphertext,
          input.encryptedPayload.iv,
          input.encryptedPayload.keyVersion,
          input.markerVersion,
          input.routingRevision,
          input.acceptedAt,
          input.payloadPurgeAt,
          input.acceptedAt,
          submission.projectID,
          input.routingRevision,
        ),
      this.#database
        .prepare(
          `INSERT INTO report_outbox (
               project_id, report_id, available_at, created_at, updated_at
           )
           SELECT project_id, report_id, ?, ?, ?
             FROM reports
            WHERE project_id = ?
              AND idempotency_key_hash = ?
              AND raw_payload_sha256 = ?
           ON CONFLICT(project_id, report_id) DO NOTHING`,
        )
        .bind(
          input.acceptedAt,
          input.acceptedAt,
          input.acceptedAt,
          submission.projectID,
          input.idempotencyKeyHash,
          input.rawPayloadSha256,
        ),
    ]);
    const insertResult = results[0];
    if (insertResult === undefined) {
      throw new Error("missing_d1_batch_result");
    }
    // Resolve by the unique idempotency key, not the submitted report ID. This
    // makes key reuse with a changed ID a deterministic core conflict.
    const row = await this.#selectReport(
      `WHERE project_id = ? AND idempotency_key_hash = ?`,
      submission.projectID,
      input.idempotencyKeyHash,
    );
    if (row === null) {
      throw new ProjectConfigurationError("accepted_route_changed_during_ingestion");
    }
    return { report: mapReport(row), inserted: insertResult.meta.changes === 1 };
  }

  async claimForAuthorization(
    projectID: string,
    reportID: string,
    leaseToken: string,
    now: string,
    leaseExpiresAt: string,
  ): Promise<boolean> {
    const result = await this.#database
      .prepare(
        `UPDATE reports
            SET status = 'authorizing',
                attempt_count = attempt_count + 1,
                lease_token = ?, lease_expires_at = ?, last_error_code = NULL,
                reconciliation_not_before = NULL, updated_at = ?
          WHERE project_id = ? AND report_id = ?
            AND (
                  status IN ('pending', 'retrying')
                  OR (
                      status = 'authorizing'
                      AND (
                          lease_expires_at IS NULL
                          OR datetime(lease_expires_at) IS NULL
                          OR datetime(lease_expires_at) <= datetime(?)
                      )
                  )
            )`,
      )
      .bind(leaseToken, leaseExpiresAt, now, projectID, reportID, now)
      .run();
    return result.meta.changes === 1;
  }

  async markCreating(
    projectID: string,
    reportID: string,
    leaseToken: string,
    now: string,
    leaseExpiresAt: string,
  ): Promise<boolean> {
    const result = await this.#database
      .prepare(
        `UPDATE reports
            SET status = 'creating', lease_expires_at = ?, updated_at = ?
          WHERE project_id = ? AND report_id = ?
            AND status = 'authorizing' AND lease_token = ?`,
      )
      .bind(leaseExpiresAt, now, projectID, reportID, leaseToken)
      .run();
    return result.meta.changes === 1;
  }

  async markRetrying(
    projectID: string,
    reportID: string,
    leaseToken: string,
    errorCode: string,
    now: string,
  ): Promise<boolean> {
    const result = await this.#database
      .prepare(
        `UPDATE reports
            SET status = 'retrying', last_error_code = ?, lease_token = NULL,
                lease_expires_at = NULL, reconciliation_not_before = NULL, updated_at = ?
          WHERE project_id = ? AND report_id = ?
            AND status IN ('authorizing', 'creating') AND lease_token = ?`,
      )
      .bind(errorCode, now, projectID, reportID, leaseToken)
      .run();
    return result.meta.changes === 1;
  }

  async scheduleReconciliationFromCreating(
    projectID: string,
    reportID: string,
    creatingLeaseToken: string,
    errorCode: string,
    now: string,
    notBefore: string,
  ): Promise<boolean> {
    const result = await this.#database
      .prepare(
        `UPDATE reports
            SET status = 'reconciling', last_error_code = ?, lease_token = NULL,
                lease_expires_at = NULL, reconciliation_not_before = ?, updated_at = ?
          WHERE project_id = ? AND report_id = ?
            AND status = 'creating' AND lease_token = ?`,
      )
      .bind(errorCode, notBefore, now, projectID, reportID, creatingLeaseToken)
      .run();
    return result.meta.changes === 1;
  }

  async claimCreatingForReconciliation(
    projectID: string,
    reportID: string,
    reconciliationLeaseToken: string,
    now: string,
    leaseExpiresAt: string,
  ): Promise<ReconciliationClaim | null> {
    const row = await this.#database
      .prepare(
        `UPDATE reports
            SET status = 'reconciling', lease_token = ?, lease_expires_at = ?,
                reconciliation_not_before = NULL,
                last_error_code = 'destination_create_outcome_unknown', updated_at = ?
          WHERE project_id = ? AND report_id = ? AND status = 'creating'
            AND (
                lease_expires_at IS NULL
                OR datetime(lease_expires_at) IS NULL
                OR datetime(lease_expires_at) <= datetime(?)
            )
          RETURNING reconciliation_attempt_count`,
      )
      .bind(reconciliationLeaseToken, leaseExpiresAt, now, projectID, reportID, now)
      .first<{ reconciliation_attempt_count: number }>();
    return row === null ? null : { completedAttemptCount: row.reconciliation_attempt_count };
  }

  async claimForReconciliation(
    projectID: string,
    reportID: string,
    reconciliationLeaseToken: string,
    now: string,
    leaseExpiresAt: string,
  ): Promise<ReconciliationClaim | null> {
    const row = await this.#database
      .prepare(
        `UPDATE reports
            SET lease_token = ?, lease_expires_at = ?, updated_at = ?
          WHERE project_id = ? AND report_id = ? AND status = 'reconciling'
            AND (
                reconciliation_not_before IS NULL
                OR datetime(reconciliation_not_before) IS NULL
                OR datetime(reconciliation_not_before) <= datetime(?)
            )
            AND (
                lease_expires_at IS NULL
                OR datetime(lease_expires_at) IS NULL
                OR datetime(lease_expires_at) <= datetime(?)
            )
          RETURNING reconciliation_attempt_count`,
      )
      .bind(reconciliationLeaseToken, leaseExpiresAt, now, projectID, reportID, now, now)
      .first<{ reconciliation_attempt_count: number }>();
    return row === null ? null : { completedAttemptCount: row.reconciliation_attempt_count };
  }

  async rescheduleReconciliation(
    projectID: string,
    reportID: string,
    reconciliationLeaseToken: string,
    errorCode: string,
    now: string,
    notBefore: string,
  ): Promise<boolean> {
    const result = await this.#database
      .prepare(
        `UPDATE reports
            SET last_error_code = ?, lease_token = NULL, lease_expires_at = NULL,
                reconciliation_not_before = ?, updated_at = ?
          WHERE project_id = ? AND report_id = ? AND status = 'reconciling'
            AND lease_token = ?`,
      )
      .bind(errorCode, notBefore, now, projectID, reportID, reconciliationLeaseToken)
      .run();
    return result.meta.changes === 1;
  }

  async completeReconciliationMiss(
    projectID: string,
    reportID: string,
    reconciliationLeaseToken: string,
    now: string,
    notBefore: string,
    maximumAttempts: number,
  ): Promise<ReconciliationMissResult> {
    const row = await this.#database
      .prepare(
        `UPDATE reports
            SET reconciliation_attempt_count = reconciliation_attempt_count + 1,
                status = CASE
                    WHEN reconciliation_attempt_count + 1 >= ? THEN 'manual_review'
                    ELSE 'reconciling'
                END,
                last_error_code = CASE
                    WHEN reconciliation_attempt_count + 1 >= ?
                    THEN 'destination_create_not_reconciled'
                    ELSE 'destination_create_not_found_yet'
                END,
                lease_token = NULL, lease_expires_at = NULL,
                reconciliation_not_before = CASE
                    WHEN reconciliation_attempt_count + 1 >= ? THEN NULL
                    ELSE ?
                END,
                updated_at = ?
          WHERE project_id = ? AND report_id = ? AND status = 'reconciling'
            AND lease_token = ?
          RETURNING status`,
      )
      .bind(
        maximumAttempts,
        maximumAttempts,
        maximumAttempts,
        notBefore,
        now,
        projectID,
        reportID,
        reconciliationLeaseToken,
      )
      .first<{ status: string }>();
    if (row === null) {
      return "stale";
    }
    return row.status === "manual_review" ? "manual_review" : "scheduled";
  }

  async markReconciliationDelivered(
    projectID: string,
    reportID: string,
    reconciliationLeaseToken: string,
    destinationReference: string,
    destinationURL: string,
    now: string,
  ): Promise<boolean> {
    const result = await this.#database
      .prepare(
        `UPDATE reports
            SET status = 'delivered', destination_reference = ?, destination_url = ?,
                last_error_code = NULL, lease_token = NULL, lease_expires_at = NULL,
                reconciliation_not_before = NULL, delivered_at = ?, updated_at = ?
          WHERE project_id = ? AND report_id = ? AND status = 'reconciling'
            AND lease_token = ?`,
      )
      .bind(
        destinationReference,
        destinationURL,
        now,
        now,
        projectID,
        reportID,
        reconciliationLeaseToken,
      )
      .run();
    return result.meta.changes === 1;
  }

  async markReconciliationManualReview(
    projectID: string,
    reportID: string,
    reconciliationLeaseToken: string,
    errorCode: string,
    now: string,
  ): Promise<boolean> {
    const result = await this.#database
      .prepare(
        `UPDATE reports
            SET status = 'manual_review', last_error_code = ?, lease_token = NULL,
                lease_expires_at = NULL, reconciliation_not_before = NULL, updated_at = ?
          WHERE project_id = ? AND report_id = ? AND status = 'reconciling'
            AND lease_token = ?`,
      )
      .bind(errorCode, now, projectID, reportID, reconciliationLeaseToken)
      .run();
    return result.meta.changes === 1;
  }

  async markDelivered(
    projectID: string,
    reportID: string,
    leaseToken: string,
    destinationReference: string,
    destinationURL: string,
    now: string,
  ): Promise<boolean> {
    const result = await this.#database
      .prepare(
        `UPDATE reports
            SET status = 'delivered', destination_reference = ?, destination_url = ?,
                last_error_code = NULL, lease_token = NULL, lease_expires_at = NULL,
                reconciliation_not_before = NULL, delivered_at = ?, updated_at = ?
          WHERE project_id = ? AND report_id = ?
            AND status = 'creating' AND lease_token = ?`,
      )
      .bind(destinationReference, destinationURL, now, now, projectID, reportID, leaseToken)
      .run();
    return result.meta.changes === 1;
  }

  async markPermanentFailure(
    projectID: string,
    reportID: string,
    leaseToken: string,
    errorCode: string,
    now: string,
  ): Promise<boolean> {
    return this.#markTerminal(
      projectID,
      reportID,
      leaseToken,
      "permanent_failure",
      errorCode,
      now,
    );
  }

  async markManualReview(
    projectID: string,
    reportID: string,
    leaseToken: string,
    errorCode: string,
    now: string,
  ): Promise<boolean> {
    return this.#markTerminal(projectID, reportID, leaseToken, "manual_review", errorCode, now);
  }

  async listPending(now: string, limit: number): Promise<OutboxEntry[]> {
    const result = await this.#database
      .prepare(
        `SELECT project_id, report_id, publish_attempt_count
           FROM report_outbox
          WHERE published_at IS NULL AND available_at <= ?
          ORDER BY available_at ASC
          LIMIT ?`,
      )
      .bind(now, limit)
      .all<OutboxRow>();
    return result.results.map((row) => ({
      projectID: row.project_id,
      reportID: row.report_id,
      publishAttemptCount: row.publish_attempt_count,
    }));
  }

  async markPublished(projectID: string, reportID: string, now: string): Promise<void> {
    await this.#database
      .prepare(
        `UPDATE report_outbox
            SET published_at = ?, publish_attempt_count = publish_attempt_count + 1,
                last_error_code = NULL, updated_at = ?
          WHERE project_id = ? AND report_id = ?`,
      )
      .bind(now, now, projectID, reportID)
      .run();
  }

  async markRetry(
    projectID: string,
    reportID: string,
    availableAt: string,
    now: string,
  ): Promise<void> {
    await this.#database
      .prepare(
        `UPDATE report_outbox
            SET publish_attempt_count = publish_attempt_count + 1,
                available_at = ?, last_error_code = 'queue_send_failed', updated_at = ?
          WHERE project_id = ? AND report_id = ?`,
      )
      .bind(availableAt, now, projectID, reportID)
      .run();
  }

  async recoverStale(cutoff: string, now: string): Promise<void> {
    await this.#database
      .prepare(
        `UPDATE report_outbox
            SET published_at = NULL, available_at = ?, updated_at = ?
          WHERE published_at IS NOT NULL
            AND published_at <= ?
            AND EXISTS (
                SELECT 1 FROM reports
                 WHERE reports.project_id = report_outbox.project_id
                   AND reports.report_id = report_outbox.report_id
                   AND reports.status IN (
                       'pending', 'authorizing', 'creating', 'retrying', 'reconciling'
                   )
                   AND reports.updated_at <= ?
            )`,
      )
      .bind(now, now, cutoff, cutoff)
      .run();
  }

  async purgeExpiredPayloads(now: string): Promise<void> {
    await this.#database
      .prepare(
        `UPDATE reports
            SET payload_ciphertext = NULL, payload_iv = NULL,
                payload_purged_at = ?, updated_at = ?
          WHERE payload_ciphertext IS NOT NULL
            AND datetime(payload_purge_at) <= datetime(?)`,
      )
      .bind(now, now, now)
      .run();
  }

  async #selectReport(clause: string, ...bindings: readonly string[]): Promise<ReportRow | null> {
    return this.#database
      .prepare(
        `SELECT project_id, report_id, idempotency_key_hash, raw_payload_sha256,
                content_fingerprint, payload_ciphertext, payload_iv, encryption_version,
                marker_version, routing_revision, status, attempt_count,
                reconciliation_attempt_count, lease_token, lease_expires_at,
                reconciliation_not_before, destination_reference, destination_url,
                last_error_code, accepted_at, payload_purge_at, updated_at, delivered_at,
                payload_purged_at
           FROM reports
          ${clause}`,
      )
      .bind(...bindings)
      .first<ReportRow>();
  }

  #parseProject(row: ProjectRow): SupportProject<TTarget> {
    if (
      row.enabled !== 1
      || !PROJECT_ID_PATTERN.test(row.project_id)
      || !isPositiveVersion(row.routing_revision)
      || !ADAPTER_ID_PATTERN.test(row.destination_adapter)
      || !Number.isSafeInteger(row.payload_retention_days)
      || row.payload_retention_days < 1
      || row.payload_retention_days > 365
    ) {
      throw new ProjectConfigurationError("invalid_project_configuration");
    }
    const allowedLabels = parseConfiguredLabels(row.allowed_labels_json);
    const defaultLabels = parseConfiguredLabels(row.default_labels_json);
    if (defaultLabels.some((label) => !allowedLabels.includes(label))) {
      throw new ProjectConfigurationError("default_label_not_allowed");
    }
    let configuration: unknown;
    try {
      configuration = JSON.parse(row.destination_config_json);
    } catch {
      throw new ProjectConfigurationError("invalid_destination_configuration");
    }
    return {
      projectID: row.project_id,
      routingRevision: row.routing_revision,
      destination: this.#decodeDestination(row.destination_adapter, configuration),
      allowedLabels: new Set(allowedLabels),
      defaultLabels,
      payloadRetentionDays: row.payload_retention_days,
    };
  }

  async #markTerminal(
    projectID: string,
    reportID: string,
    leaseToken: string,
    status: "permanent_failure" | "manual_review",
    errorCode: string,
    now: string,
  ): Promise<boolean> {
    const result = await this.#database
      .prepare(
        `UPDATE reports
            SET status = ?, last_error_code = ?, lease_token = NULL,
                lease_expires_at = NULL, reconciliation_not_before = NULL, updated_at = ?
          WHERE project_id = ? AND report_id = ?
            AND status IN ('authorizing', 'creating') AND lease_token = ?`,
      )
      .bind(status, errorCode, now, projectID, reportID, leaseToken)
      .run();
    return result.meta.changes === 1;
  }
}

function mapReport(row: ReportRow): StoredReport {
  if (!DELIVERY_STATES.has(row.status as DeliveryState)) {
    throw new Error("invalid_report_status_in_database");
  }
  const status = row.status as DeliveryState;
  if (
    !isPositiveVersion(row.encryption_version)
    || !isPositiveVersion(row.marker_version)
    || !isPositiveVersion(row.routing_revision)
    || !isValidStoredTimestamp(row.accepted_at)
    || !isValidStoredTimestamp(row.payload_purge_at)
  ) {
    throw new Error("invalid_report_metadata_in_database");
  }
  return {
    projectID: row.project_id,
    reportID: row.report_id,
    idempotencyKeyHash: row.idempotency_key_hash,
    rawPayloadSha256: row.raw_payload_sha256,
    contentFingerprint: row.content_fingerprint,
    payloadCiphertext: row.payload_ciphertext,
    payloadIV: row.payload_iv,
    encryptionVersion: row.encryption_version,
    markerVersion: row.marker_version,
    routingRevision: row.routing_revision,
    status,
    attemptCount: row.attempt_count,
    reconciliationAttemptCount: row.reconciliation_attempt_count,
    leaseToken: row.lease_token,
    leaseExpiresAt: row.lease_expires_at,
    reconciliationNotBefore: row.reconciliation_not_before,
    destinationReference: row.destination_reference,
    destinationURL: row.destination_url,
    lastErrorCode: row.last_error_code,
    acceptedAt: row.accepted_at,
    payloadPurgeAt: row.payload_purge_at,
    updatedAt: row.updated_at,
    deliveredAt: row.delivered_at,
    payloadPurgedAt: row.payload_purged_at,
  };
}

function parseConfiguredLabels(json: string): string[] {
  let parsed: unknown;
  try {
    parsed = JSON.parse(json);
  } catch {
    throw new ProjectConfigurationError("invalid_project_labels");
  }
  if (
    !Array.isArray(parsed)
    || parsed.length > 10
    || parsed.some((label) => typeof label !== "string" || label.length < 1 || label.length > 100)
  ) {
    throw new ProjectConfigurationError("invalid_project_labels");
  }
  const labels = parsed.filter((label): label is string => typeof label === "string");
  if (new Set(labels).size !== labels.length) {
    throw new ProjectConfigurationError("invalid_project_labels");
  }
  return labels;
}

function isPositiveVersion(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 1 && value <= 999_999_999;
}

function isValidStoredTimestamp(value: string): boolean {
  return value.length <= 64 && Number.isFinite(Date.parse(value));
}
