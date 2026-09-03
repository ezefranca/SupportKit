import { describe, expect, it } from "vitest";
import { parseSubmission, ValidationError } from "../src/ServerCore/validation";
import { resolveLabels } from "../src/ServerCore/ingestion";
import type { SupportProject } from "../src/ServerCore/domain";
import { submission } from "./fixtures";

describe("SupportSubmission validation", () => {
  it("accepts the exact Swift Codable shape and normalizes UUID casing", () => {
    const input = submission({ id: "00000000-0000-4000-8000-000000000001".toUpperCase() });
    expect(parseSubmission(input)).toEqual(submission());
  });

  it("rejects unknown fields", () => {
    const input: Record<string, unknown> = { ...submission(), repository: "attacker/repo" };
    expect(() => parseSubmission(input)).toThrow(ValidationError);
    try {
      parseSubmission(input);
    } catch (error) {
      expect(error).toMatchObject({ code: "unknown_field", path: "$.repository" });
    }
  });

  it("requires the body UUID and idempotency key to match", () => {
    const input = submission({ idempotencyKey: "00000000-0000-4000-8000-000000000002" });
    expect(() => parseSubmission(input)).toThrow(
      expect.objectContaining({ code: "idempotency_mismatch" }),
    );
  });

  it("accepts multibyte text within the Swift character caps and the 256 KiB wire cap", () => {
    const emoji = "🧑🏽‍💻";
    const input = submission({
      title: emoji.repeat(120),
      message: emoji.repeat(10_000),
      responses: [{ id: "unicode", label: emoji.repeat(40), value: emoji.repeat(1_000) }],
      diagnostics: [{
        key: emoji.repeat(40),
        value: emoji.repeat(4_000),
        sensitivity: "standard",
      }],
      labels: [emoji.repeat(20)],
    });

    expect(new TextEncoder().encode(JSON.stringify(input)).byteLength).toBeLessThan(256 * 1_024);
    expect(parseSubmission(input)).toEqual(input);
  });
});

describe("server-side label policy", () => {
  it("silently intersects requested labels with the project allowlist", () => {
    const project: SupportProject<{ tracker: string }> = {
      projectID: "test.project",
      routingRevision: 1,
      destination: { tracker: "fake" },
      allowedLabels: new Set(["support", "bug"]),
      defaultLabels: ["support"],
      payloadRetentionDays: 30,
    };
    expect(resolveLabels(project, ["bug", "attacker-controlled-label"])).toEqual([
      "support",
      "bug",
    ]);
  });
});
