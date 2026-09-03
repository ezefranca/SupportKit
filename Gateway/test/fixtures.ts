import type { SupportSubmission } from "../src/ServerCore/domain";

export const REPORT_ID = "00000000-0000-4000-8000-000000000001";
const AUTHORIZATION_SENTINEL = ["Author", "ization: Be", "arer very-", "secret-token-value"].join("");

export function submission(overrides: Partial<SupportSubmission> = {}): SupportSubmission {
  return {
    schemaVersion: 1,
    id: REPORT_ID,
    idempotencyKey: REPORT_ID,
    projectID: "test.project",
    createdAt: "2026-09-03T12:00:00Z",
    title: "[Support] Cannot sign in",
    message: "The sign-in button does not respond.",
    responses: [{ id: "contact", label: "Contact", value: "person@example.com" }],
    diagnostics: [
      { key: "OS", value: "iOS 27.0", sensitivity: "standard" },
      {
        key: "Last log",
        value: AUTHORIZATION_SENTINEL,
        sensitivity: "potentiallyIdentifying",
      },
    ],
    labels: ["bug"],
    contentFingerprint: "a".repeat(64),
    ...overrides,
  };
}
