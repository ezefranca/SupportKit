import { applyD1Migrations, createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { beforeAll, describe, expect, it } from "vitest";
import worker from "../src/index";
import { sha256Hex } from "../src/ServerCore/digest";
import { D1Persistence } from "../src/adapters/cloudflare/d1";
import { decodeGitHubTarget } from "../src/adapters/github/github-issue-tracker";
import { REPORT_ID, submission } from "./fixtures";

type WorkerRequest = Parameters<NonNullable<ExportedHandler<Env>["fetch"]>>[0];

beforeAll(async () => {
  await applyD1Migrations(env.SUPPORTKIT_DB, env.TEST_MIGRATIONS);
  await env.SUPPORTKIT_DB.prepare(
    `INSERT OR REPLACE INTO projects (
         project_id, enabled, current_routing_revision, payload_retention_days
     ) VALUES (?, 1, 1, 30)`,
  )
    .bind("test.project")
    .run();
  await env.SUPPORTKIT_DB.prepare(
    `INSERT OR IGNORE INTO project_routes (
         project_id, routing_revision, destination_adapter, destination_config_json,
         allowed_labels_json, default_labels_json
     ) VALUES (?, 1, ?, ?, ?, ?)`,
  )
    .bind(
      "test.project",
      "github",
      '{"owner":"example","repository":"private-repo","installationID":"1234","repositoryVisibility":"private"}',
      '["support","bug"]',
      '["support"]',
    )
    .run();
});

describe("POST /v1/reports", () => {
  it("durably accepts an exact Swift payload and encrypts its content", async () => {
    const rawBody = JSON.stringify(submission({ id: REPORT_ID.toUpperCase() }));
    const response = await sendReport(rawBody);
    const receipt = await response.json<{
      reportID: string;
      status: string;
      acceptedAt: string;
      destinationURL: string | null;
      destinationReference: string | null;
    }>();

    expect(response.status).toBe(202);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(receipt).toMatchObject({ reportID: REPORT_ID, status: "accepted" });
    const row = await env.SUPPORTKIT_DB.prepare(
      `SELECT payload_ciphertext, raw_payload_sha256, encryption_version,
              marker_version, routing_revision, accepted_at, payload_purge_at
         FROM reports WHERE project_id = ? AND report_id = ?`,
    )
      .bind("test.project", REPORT_ID)
      .first<{
        payload_ciphertext: string;
        raw_payload_sha256: string;
        encryption_version: number;
        marker_version: number;
        routing_revision: number;
        accepted_at: string;
        payload_purge_at: string;
      }>();
    expect(row).not.toBeNull();
    expect(row?.payload_ciphertext).not.toContain("sign-in button");
    expect(row?.raw_payload_sha256).toBe(await sha256Hex(rawBody));
    expect(row).toMatchObject({
      encryption_version: 1,
      marker_version: 1,
      routing_revision: 1,
    });
    expect(Date.parse(row?.payload_purge_at ?? "")).toBe(
      Date.parse(row?.accepted_at ?? "") + 30 * 24 * 60 * 60 * 1_000,
    );
  });

  it("returns duplicate for an identical replay", async () => {
    const rawBody = JSON.stringify(submission({ id: REPORT_ID.toUpperCase() }));
    const response = await sendReport(rawBody);
    const receipt = await response.json<{ status: string }>();
    expect(response.status).toBe(200);
    expect(receipt.status).toBe("duplicate");
  });

  it("resolves altered report-ID reuse by idempotency key instead of throwing a store error", async () => {
    const persistence = new D1Persistence(env.SUPPORTKIT_DB, decodeGitHubTarget);
    const existing = await persistence.acceptWithOutbox({
      submission: submission({
        id: "00000000-0000-4000-8000-000000000099",
        idempotencyKey: "00000000-0000-4000-8000-000000000099",
      }),
      idempotencyKeyHash: await sha256Hex(REPORT_ID),
      rawPayloadSha256: "d".repeat(64),
      encryptedPayload: { ciphertext: "not-stored", iv: "not-stored", keyVersion: 2 },
      markerVersion: 2,
      routingRevision: 1,
      acceptedAt: "2026-09-03T12:05:00Z",
      payloadPurgeAt: "2027-09-03T12:05:00Z",
    });
    expect(existing.inserted).toBe(false);
    expect(existing.report.reportID).toBe(REPORT_ID);
    expect(existing.report.rawPayloadSha256).not.toBe("d".repeat(64));
  });

  it("returns 409 for the same idempotency key with different raw bytes", async () => {
    const rawBody = JSON.stringify(submission({
      id: REPORT_ID.toUpperCase(),
      message: "A different report body.",
    }));
    const response = await sendReport(rawBody);
    const error = await response.json<{ code: string }>();
    expect(response.status).toBe(409);
    expect(error.code).toBe("idempotency_conflict");
  });

  it("rejects a digest that does not match the exact request bytes", async () => {
    const rawBody = JSON.stringify(submission({ id: REPORT_ID.toUpperCase() }));
    const response = await sendReport(rawBody, "b".repeat(64));
    const error = await response.json<{ code: string }>();
    expect(response.status).toBe(400);
    expect(error.code).toBe("payload_digest_mismatch");
  });
});

describe("GET /v1/reports/:id", () => {
  it("returns the scoped durable status without exposing payload data", async () => {
    await env.SUPPORTKIT_DB.prepare(
      `UPDATE reports
          SET status = 'delivered',
              destination_reference = '42',
              destination_url = 'https://github.com/example/private-repo/issues/42'
        WHERE project_id = ? AND report_id = ?`,
    )
      .bind("test.project", REPORT_ID)
      .run();
    const request = new Request(
      `https://gateway.example/v1/reports/${REPORT_ID}?projectID=test.project`,
      { headers: { "CF-Connecting-IP": "192.0.2.44" } },
    );
    const context = createExecutionContext();
    const response = await worker.fetch(asWorkerRequest(request), env, context);
    await waitOnExecutionContext(context);
    const status = await response.json<{
      reportID: string;
      projectID: string;
      status: string;
      acceptedAt: string;
      updatedAt: string;
      destinationURL: string | null;
      destinationReference: string | null;
    }>();
    expect(response.status).toBe(200);
    expect(status).toMatchObject({
      reportID: REPORT_ID,
      projectID: "test.project",
      status: "delivered",
      destinationURL: null,
      destinationReference: null,
    });
    expect(typeof status.acceptedAt).toBe("string");
    expect(typeof status.updatedAt).toBe("string");
  });
});

async function sendReport(rawBody: string, digest?: string): Promise<Response> {
  const request = new Request("https://gateway.example/v1/reports", {
    method: "POST",
    headers: {
      "CF-Connecting-IP": "192.0.2.44",
      "Content-Type": "application/json",
      "Idempotency-Key": REPORT_ID,
      "X-SupportKit-Payload-SHA256": digest ?? await sha256Hex(rawBody),
    },
    body: rawBody,
  });
  const context = createExecutionContext();
  const response = await worker.fetch(asWorkerRequest(request), env, context);
  await waitOnExecutionContext(context);
  return response;
}

function asWorkerRequest(request: Request): WorkerRequest {
  return request as unknown as WorkerRequest;
}
