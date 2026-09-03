import { applyD1Migrations } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { beforeAll, describe, expect, it } from "vitest";
import type { AcceptReportInput } from "../src/ServerCore/ports";
import { D1Persistence } from "../src/adapters/cloudflare/d1";
import { decodeGitHubTarget } from "../src/adapters/github/github-issue-tracker";
import { submission } from "./fixtures";

const PROJECT_ID = "state.hardening";
const REPORT_ID = "10000000-0000-4000-8000-000000000001";

beforeAll(async () => {
  await applyD1Migrations(env.SUPPORTKIT_DB, env.TEST_MIGRATIONS);
  await env.SUPPORTKIT_DB.prepare(
    `INSERT INTO projects (
         project_id, enabled, current_routing_revision, payload_retention_days
     ) VALUES (?, 1, 1, 2)`,
  )
    .bind(PROJECT_ID)
    .run();
  await insertRoute(1, "accepted-repository", '["support","bug"]', '["support"]');
  await insertRoute(2, "new-repository", '["new-label"]', '["new-label"]');
});

describe("D1 accepted-state invariants", () => {
  it("keeps the original route, key versions, and purge deadline on replay after rotation", async () => {
    const persistence = new D1Persistence(env.SUPPORTKIT_DB, decodeGitHubTarget);
    await setCurrentProject(1, 2);
    const original = reportInput(REPORT_ID, {
      encryptionVersion: 3,
      markerVersion: 4,
      routingRevision: 1,
      payloadPurgeAt: "2026-09-05T12:00:00Z",
    });
    const accepted = await persistence.acceptWithOutbox(original);
    expect(accepted.inserted).toBe(true);

    await setCurrentProject(2, 365);

    const replay = await persistence.acceptWithOutbox({
      ...original,
      encryptedPayload: { ciphertext: "rotated", iv: "rotated", keyVersion: 9 },
      markerVersion: 10,
      routingRevision: 2,
      payloadPurgeAt: "2027-09-03T12:00:00Z",
    });

    expect(replay.inserted).toBe(false);
    expect(replay.report).toMatchObject({
      routingRevision: 1,
      encryptionVersion: 3,
      markerVersion: 4,
      payloadPurgeAt: "2026-09-05T12:00:00Z",
    });
    const acceptedRoute = await persistence.findEnabledProjectRevision(PROJECT_ID, 1);
    const currentRoute = await persistence.findEnabledProject(PROJECT_ID);
    expect(acceptedRoute?.routingRevision).toBe(1);
    expect(acceptedRoute?.destination.repository).toBe("accepted-repository");
    expect(acceptedRoute?.defaultLabels).toEqual(["support"]);
    expect(currentRoute?.routingRevision).toBe(2);
    expect(currentRoute?.destination.repository).toBe("new-repository");

    await expect(persistence.acceptWithOutbox(reportInput(
      "10000000-0000-4000-8000-000000000099",
      { routingRevision: 1 },
    ))).rejects.toMatchObject({ code: "accepted_route_changed_during_ingestion" });

    await expect(env.SUPPORTKIT_DB.prepare(
      "UPDATE reports SET payload_purge_at = ? WHERE project_id = ? AND report_id = ?",
    )
      .bind("2027-09-05T12:00:00Z", PROJECT_ID, REPORT_ID)
      .run()).rejects.toThrow(/report_acceptance_snapshot_is_immutable/u);
    await expect(env.SUPPORTKIT_DB.prepare(
      "UPDATE reports SET payload_purge_at = ? WHERE project_id = ? AND report_id = ?",
    )
      .bind("2026-09-04T12:00:00Z", PROJECT_ID, REPORT_ID)
      .run()).resolves.toMatchObject({ success: true });
    await expect(env.SUPPORTKIT_DB.prepare(
      "UPDATE project_routes SET default_labels_json = '[]' WHERE project_id = ? AND routing_revision = 1",
    )
      .bind(PROJECT_ID)
      .run()).rejects.toThrow(/project_route_revision_is_immutable/u);
  });

  it("purges against the acceptance-time deadline even while a report is nonterminal", async () => {
    const reportID = "10000000-0000-4000-8000-000000000002";
    const persistence = new D1Persistence(env.SUPPORTKIT_DB, decodeGitHubTarget);
    await setCurrentProject(2, 2);
    await persistence.acceptWithOutbox(reportInput(reportID, {
      routingRevision: 2,
      payloadPurgeAt: "2026-09-04T12:00:00Z",
    }));

    await env.SUPPORTKIT_DB.prepare(
      "UPDATE projects SET payload_retention_days = 365 WHERE project_id = ?",
    )
      .bind(PROJECT_ID)
      .run();
    await persistence.purgeExpiredPayloads("2026-09-05T12:00:00Z");

    const report = await persistence.find(PROJECT_ID, reportID);
    expect(report).toMatchObject({
      status: "pending",
      payloadCiphertext: null,
      payloadIV: null,
      payloadPurgeAt: "2026-09-04T12:00:00Z",
      payloadPurgedAt: "2026-09-05T12:00:00Z",
    });
  });
});

describe("D1 reconciliation leases", () => {
  it("allows one of eight rapid duplicates to claim and consume one due search", async () => {
    const reportID = "10000000-0000-4000-8000-000000000003";
    const persistence = new D1Persistence(env.SUPPORTKIT_DB, decodeGitHubTarget);
    await setCurrentProject(2, 2);
    await persistence.acceptWithOutbox(reportInput(reportID, { routingRevision: 2 }));
    await setReconciliationState(reportID, 0, "2026-09-03T12:00:00Z");

    const claims = await Promise.all(
      Array.from({ length: 8 }, (_, index) => persistence.claimForReconciliation(
        PROJECT_ID,
        reportID,
        `rapid-${String(index)}`,
        "2026-09-03T12:00:00Z",
        "2026-09-03T12:01:30Z",
      )),
    );
    const winner = claims.findIndex((claim) => claim !== null);
    expect(claims.filter((claim) => claim !== null)).toHaveLength(1);
    expect(winner).toBeGreaterThanOrEqual(0);

    await expect(persistence.completeReconciliationMiss(
      PROJECT_ID,
      reportID,
      `rapid-${String(winner)}`,
      "2026-09-03T12:00:05Z",
      "2026-09-03T12:10:05Z",
      8,
    )).resolves.toBe("scheduled");

    const earlyClaims = await Promise.all(
      Array.from({ length: 8 }, (_, index) => persistence.claimForReconciliation(
        PROJECT_ID,
        reportID,
        `early-${String(index)}`,
        "2026-09-03T12:00:10Z",
        "2026-09-03T12:01:40Z",
      )),
    );
    expect(earlyClaims.every((claim) => claim === null)).toBe(true);
    expect(await persistence.find(PROJECT_ID, reportID)).toMatchObject({
      status: "reconciling",
      reconciliationAttemptCount: 1,
      reconciliationNotBefore: "2026-09-03T12:10:05Z",
    });
  });

  it("makes newer delivery authoritative over a stale worker's eighth miss or terminal write", async () => {
    const reportID = "10000000-0000-4000-8000-000000000004";
    const persistence = new D1Persistence(env.SUPPORTKIT_DB, decodeGitHubTarget);
    await setCurrentProject(2, 2);
    await persistence.acceptWithOutbox(reportInput(reportID, { routingRevision: 2 }));
    await setReconciliationState(reportID, 7, "2026-09-03T12:00:00Z");

    const stale = await persistence.claimForReconciliation(
      PROJECT_ID,
      reportID,
      "stale-token",
      "2026-09-03T12:00:00Z",
      "2026-09-03T12:01:30Z",
    );
    const current = await persistence.claimForReconciliation(
      PROJECT_ID,
      reportID,
      "current-token",
      "2026-09-03T12:02:00Z",
      "2026-09-03T12:03:30Z",
    );
    expect(stale?.completedAttemptCount).toBe(7);
    expect(current?.completedAttemptCount).toBe(7);
    await expect(persistence.markReconciliationDelivered(
      PROJECT_ID,
      reportID,
      "current-token",
      "42",
      "https://tracker.example.test/items/42",
      "2026-09-03T12:02:05Z",
    )).resolves.toBe(true);

    await expect(persistence.completeReconciliationMiss(
      PROJECT_ID,
      reportID,
      "stale-token",
      "2026-09-03T12:02:06Z",
      "2026-09-03T12:12:06Z",
      8,
    )).resolves.toBe("stale");
    await expect(persistence.markReconciliationManualReview(
      PROJECT_ID,
      reportID,
      "stale-token",
      "destination_create_not_reconciled",
      "2026-09-03T12:02:07Z",
    )).resolves.toBe(false);
    expect(await persistence.find(PROJECT_ID, reportID)).toMatchObject({
      status: "delivered",
      destinationReference: "42",
      reconciliationAttemptCount: 7,
      lastErrorCode: null,
    });
  });

  it("moves only the eighth completed due miss to manual review", async () => {
    const reportID = "10000000-0000-4000-8000-000000000006";
    const persistence = new D1Persistence(env.SUPPORTKIT_DB, decodeGitHubTarget);
    await setCurrentProject(2, 2);
    await persistence.acceptWithOutbox(reportInput(reportID, { routingRevision: 2 }));
    await setReconciliationState(reportID, 7, "2026-09-03T12:00:00Z");
    await expect(persistence.claimForReconciliation(
      PROJECT_ID,
      reportID,
      "eighth-token",
      "2026-09-03T12:00:00Z",
      "2026-09-03T12:01:30Z",
    )).resolves.toEqual({ completedAttemptCount: 7 });
    await expect(persistence.completeReconciliationMiss(
      PROJECT_ID,
      reportID,
      "eighth-token",
      "2026-09-03T12:00:05Z",
      "2026-09-03T12:10:05Z",
      8,
    )).resolves.toBe("manual_review");
    expect(await persistence.find(PROJECT_ID, reportID)).toMatchObject({
      status: "manual_review",
      reconciliationAttemptCount: 8,
      reconciliationNotBefore: null,
      lastErrorCode: "destination_create_not_reconciled",
    });
  });

  it("atomically converts one expired creating lease directly into a reconciliation lease", async () => {
    const reportID = "10000000-0000-4000-8000-000000000005";
    const persistence = new D1Persistence(env.SUPPORTKIT_DB, decodeGitHubTarget);
    await setCurrentProject(2, 2);
    await persistence.acceptWithOutbox(reportInput(reportID, { routingRevision: 2 }));
    await env.SUPPORTKIT_DB.prepare(
      `UPDATE reports
          SET status = 'creating', lease_token = 'create-token',
              lease_expires_at = '2026-09-03T12:00:00Z'
        WHERE project_id = ? AND report_id = ?`,
    )
      .bind(PROJECT_ID, reportID)
      .run();

    const claims = await Promise.all(
      Array.from({ length: 8 }, (_, index) => persistence.claimCreatingForReconciliation(
        PROJECT_ID,
        reportID,
        `reconcile-${String(index)}`,
        "2026-09-03T12:01:00Z",
        "2026-09-03T12:02:30Z",
      )),
    );
    expect(claims.filter((claim) => claim !== null)).toHaveLength(1);
    const report = await persistence.find(PROJECT_ID, reportID);
    expect(report?.status).toBe("reconciling");
    expect(report?.leaseToken).toMatch(/^reconcile-/u);
    expect(report?.leaseExpiresAt).toBe("2026-09-03T12:02:30Z");
  });
});

function reportInput(
  reportID: string,
  overrides: {
    encryptionVersion?: number;
    markerVersion?: number;
    routingRevision?: number;
    payloadPurgeAt?: string;
  } = {},
): AcceptReportInput {
  const routingRevision = overrides.routingRevision ?? 1;
  return {
    submission: submission({
      id: reportID,
      idempotencyKey: reportID,
      projectID: PROJECT_ID,
    }),
    idempotencyKeyHash: reportID.replaceAll("-", "").padEnd(64, "0"),
    rawPayloadSha256: "d".repeat(64),
    encryptedPayload: {
      ciphertext: `ciphertext-${reportID}`,
      iv: `iv-${reportID}`,
      keyVersion: overrides.encryptionVersion ?? 1,
    },
    markerVersion: overrides.markerVersion ?? 1,
    routingRevision,
    acceptedAt: "2026-09-03T12:00:00Z",
    payloadPurgeAt: overrides.payloadPurgeAt ?? "2026-09-05T12:00:00Z",
  };
}

async function insertRoute(
  revision: number,
  repository: string,
  allowedLabels: string,
  defaultLabels: string,
): Promise<void> {
  await env.SUPPORTKIT_DB.prepare(
    `INSERT INTO project_routes (
         project_id, routing_revision, destination_adapter, destination_config_json,
         allowed_labels_json, default_labels_json
     ) VALUES (?, ?, 'github', ?, ?, ?)`,
  )
    .bind(
      PROJECT_ID,
      revision,
      JSON.stringify({
        owner: "example",
        repository,
        installationID: "1234",
        repositoryVisibility: "private",
      }),
      allowedLabels,
      defaultLabels,
    )
    .run();
}

async function setReconciliationState(
  reportID: string,
  completedAttempts: number,
  notBefore: string,
): Promise<void> {
  await env.SUPPORTKIT_DB.prepare(
    `UPDATE reports
        SET status = 'reconciling', reconciliation_attempt_count = ?,
            reconciliation_not_before = ?, lease_token = NULL, lease_expires_at = NULL
      WHERE project_id = ? AND report_id = ?`,
  )
    .bind(completedAttempts, notBefore, PROJECT_ID, reportID)
    .run();
}

async function setCurrentProject(revision: number, retentionDays: number): Promise<void> {
  await env.SUPPORTKIT_DB.prepare(
    `UPDATE projects
        SET current_routing_revision = ?, payload_retention_days = ?
      WHERE project_id = ?`,
  )
    .bind(revision, retentionDays, PROJECT_ID)
    .run();
}
