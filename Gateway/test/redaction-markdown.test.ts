import { describe, expect, it } from "vitest";
import { buildDestinationDocument } from "../src/ServerCore/markdown";
import {
  destinationMarker,
  HMACMarkerFactory,
  WebCryptoPayloadCipher,
} from "../src/adapters/crypto/web-crypto";
import { redactSubmission } from "../src/ServerCore/redaction";
import { parseStoredPayload } from "../src/ServerCore/validation";
import { submission } from "./fixtures";

describe("defense-in-depth redaction and Markdown rendering", () => {
  it("redacts complete and truncated private-key blocks", () => {
    const delimiter = (kind: "BEGIN" | "END", label: string): string => [
      "-----",
      `${kind} ${label}`,
      "-----",
    ].join("");
    const complete = [
      delimiter("BEGIN", "ENCRYPTED PRIVATE KEY"),
      "sensitive-complete-key-material",
      delimiter("END", "ENCRYPTED PRIVATE KEY"),
    ].join("\n");
    const truncated = [
      delimiter("BEGIN", "OPENSSH PRIVATE KEY"),
      "sensitive-truncated-key-material",
    ].join("\n");

    const completePayload = redactSubmission(submission({ message: complete }));
    const truncatedPayload = redactSubmission(submission({ message: truncated }));

    expect(completePayload.submission.message).toBe("[REDACTED_PRIVATE_KEY]");
    expect(truncatedPayload.submission.message).toBe("[REDACTED_PRIVATE_KEY]");
  });

  it("redacts credentials and neutralizes mentions while preserving the trusted marker", () => {
    const fineGrainedSentinel = ["github", "_pat_", "abcdefghijklmnopqrstuvwxyz", "123456"].join("");
    const legacySentinel = ["gh", "p_", "abcdefghijklmnopqrstuvwxyz", "123456"].join("");
    const credentialedURL = ["https://", "diagnostic-user", ":diagnostic-password", "@example.invalid/private"].join("");
    const payload = redactSubmission(
      submission({
        title: "Help @maintainer",
        message: `tokens=${fineGrainedSentinel} ${legacySentinel}; callback=${credentialedURL}`,
      }),
    );
    const document = buildDestinationDocument(payload, "supportkit-report-trusted-marker");

    expect(document.title).toContain("@\u200Bmaintainer");
    expect(document.body).toContain("[REDACTED]");
    expect(document.body).not.toContain(fineGrainedSentinel);
    expect(document.body).not.toContain(legacySentinel);
    expect(document.body).not.toContain(credentialedURL);
    expect(document.body).toContain("[REDACTED_CREDENTIAL_URL]");
    expect(document.body).toContain("<!-- supportkit-report-trusted-marker -->");
    expect(new TextEncoder().encode(document.body).byteLength).toBeLessThanOrEqual(60_000);
  });

  it("uses independent marker key material", async () => {
    const reportID = "00000000-0000-4000-8000-000000000001";
    const first = await destinationMarker(
      "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
      1,
      "test.project",
      reportID,
    );
    const second = await destinationMarker(
      "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
      1,
      "test.project",
      reportID,
    );
    expect(first).not.toBe(second);
  });

  it("decrypts and reconciles with pinned old key versions after active-key rotation", async () => {
    const keyOne = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    const keyTwo = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB";
    const firstEncryptionRing = JSON.stringify({ activeVersion: 1, keys: { 1: keyOne } });
    const rotatedEncryptionRing = JSON.stringify({
      activeVersion: 2,
      keys: { 1: keyOne, 2: keyTwo },
    });
    const payload = redactSubmission(submission());
    const firstCipher = new WebCryptoPayloadCipher(firstEncryptionRing);
    const encrypted = await firstCipher.encrypt(payload, "test.project", submission().id);
    expect(encrypted.keyVersion).toBe(1);

    const rotatedCipher = new WebCryptoPayloadCipher(rotatedEncryptionRing);
    await expect(rotatedCipher.decrypt(
      encrypted,
      encrypted.keyVersion,
      "test.project",
      submission().id,
    )).resolves.toEqual(payload);
    const secondEncrypted = await rotatedCipher.encrypt(payload, "test.project", submission().id);
    expect(secondEncrypted.keyVersion).toBe(2);

    const firstMarkerFactory = new HMACMarkerFactory(firstEncryptionRing);
    const rotatedMarkerFactory = new HMACMarkerFactory(rotatedEncryptionRing);
    const originalMarker = await firstMarkerFactory.make("test.project", submission().id, 1);
    expect(await rotatedMarkerFactory.make("test.project", submission().id, 1)).toBe(originalMarker);
    expect(await rotatedMarkerFactory.make("test.project", submission().id, 2)).not.toBe(originalMarker);
  });

  it("fails closed when a report references a key version absent from a ring", async () => {
    const key = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    const ring = JSON.stringify({ activeVersion: 2, keys: { 2: key } });
    const cipher = new WebCryptoPayloadCipher(ring);
    const marker = new HMACMarkerFactory(ring);
    await expect(cipher.decrypt(
      { ciphertext: "unreadable", iv: "unreadable" },
      1,
      "test.project",
      submission().id,
    )).rejects.toThrow("missing_report_encryption_key_version");
    await expect(marker.make("test.project", submission().id, 1))
      .rejects.toThrow("missing_issue_marker_key_version");
    expect(() => new WebCryptoPayloadCipher('{"activeVersion":2,"keys":{"1":"bad"}}'))
      .toThrow();
  });

  it("keeps a bounded high redaction count structurally deliverable", () => {
    const repeatedAssignments = "secret=abcd,".repeat(18_000);
    const input = submission({ message: repeatedAssignments });
    expect(new TextEncoder().encode(JSON.stringify(input)).byteLength).toBeLessThan(256 * 1_024);

    const payload = redactSubmission(input);
    expect(payload.serverRedactionCount).toBeGreaterThan(10_000);
    expect(new TextEncoder().encode(payload.submission.message).byteLength).toBeGreaterThan(256 * 1_024);
    expect(parseStoredPayload(payload)).toEqual(payload);
  });
});
