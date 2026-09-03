import { MAX_REQUEST_BYTES } from "./domain";
import type {
  DiagnosticSensitivity,
  DeliveryMessage,
  StoredPayload,
  SupportDiagnostic,
  SupportFieldResponse,
  SupportSubmission,
} from "./domain";

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const LOWERCASE_UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const PROJECT_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/;
const FIELD_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$/;
const ISO8601_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$/;
const MAX_STORED_TEXT_BYTES = MAX_REQUEST_BYTES * 4;

export class ValidationError extends Error {
  readonly code: string;
  readonly path: string;

  constructor(code: string, path: string, message: string) {
    super(message);
    this.name = "ValidationError";
    this.code = code;
    this.path = path;
  }
}

export function parseSubmission(value: unknown): SupportSubmission {
  return parseSubmissionWithTextLimit(value, MAX_REQUEST_BYTES);
}

function parseSubmissionWithTextLimit(
  value: unknown,
  maximumTextBytes: number,
): SupportSubmission {
  const root = requireRecord(value, "$", [
    "schemaVersion",
    "id",
    "idempotencyKey",
    "projectID",
    "createdAt",
    "title",
    "message",
    "responses",
    "diagnostics",
    "labels",
    "contentFingerprint",
  ]);

  if (root["schemaVersion"] !== 1) {
    throw new ValidationError("unsupported_schema", "$.schemaVersion", "schemaVersion must be 1.");
  }

  const rawID = requireString(root["id"], "$.id", 36, 36);
  if (!UUID_PATTERN.test(rawID)) {
    throw new ValidationError("invalid_uuid", "$.id", "id must be a canonical UUID.");
  }
  const id = rawID.toLowerCase();

  const idempotencyKey = requireString(root["idempotencyKey"], "$.idempotencyKey", 36, 36);
  if (!LOWERCASE_UUID_PATTERN.test(idempotencyKey)) {
    throw new ValidationError(
      "invalid_idempotency_key",
      "$.idempotencyKey",
      "idempotencyKey must be a lowercase canonical UUID.",
    );
  }
  if (id !== idempotencyKey) {
    throw new ValidationError(
      "idempotency_mismatch",
      "$.idempotencyKey",
      "id and idempotencyKey must identify the same report.",
    );
  }

  const projectID = requireString(root["projectID"], "$.projectID", 1, 100);
  if (!PROJECT_ID_PATTERN.test(projectID)) {
    throw new ValidationError("invalid_project", "$.projectID", "projectID has an invalid format.");
  }

  const createdAt = requireString(root["createdAt"], "$.createdAt", 20, 40);
  if (!ISO8601_PATTERN.test(createdAt) || !Number.isFinite(Date.parse(createdAt))) {
    throw new ValidationError("invalid_date", "$.createdAt", "createdAt must be an ISO 8601 UTC timestamp.");
  }

  const title = requireText(root["title"], "$.title", 1, maximumTextBytes, true);
  const message = requireText(root["message"], "$.message", 1, maximumTextBytes, true);
  const responses = parseResponses(root["responses"], maximumTextBytes);
  const diagnostics = parseDiagnostics(root["diagnostics"], maximumTextBytes);
  const labels = parseLabels(root["labels"], maximumTextBytes);
  const contentFingerprint = requireString(root["contentFingerprint"], "$.contentFingerprint", 64, 64);
  if (!SHA256_PATTERN.test(contentFingerprint)) {
    throw new ValidationError(
      "invalid_fingerprint",
      "$.contentFingerprint",
      "contentFingerprint must be a lowercase SHA-256 hex digest.",
    );
  }
  const totalTextBytes = byteLength(title)
    + byteLength(message)
    + responses.reduce(
      (total, response) => total + byteLength(response.id) + byteLength(response.label) + byteLength(response.value),
      0,
    )
    + diagnostics.reduce(
      (total, diagnostic) => total + byteLength(diagnostic.key) + byteLength(diagnostic.value),
      0,
    )
    + labels.reduce((total, label) => total + byteLength(label), 0);
  if (totalTextBytes > maximumTextBytes) {
    throw new ValidationError(
      "payload_text_too_large",
      "$",
      "Combined support report text is too large.",
    );
  }

  return {
    schemaVersion: 1,
    id,
    idempotencyKey,
    projectID,
    createdAt,
    title,
    message,
    responses,
    diagnostics,
    labels,
    contentFingerprint,
  };
}

export function parseDeliveryMessage(value: unknown): DeliveryMessage {
  const root = requireRecord(value, "$", ["schemaVersion", "projectID", "reportID"]);
  if (root["schemaVersion"] !== 1) {
    throw new ValidationError(
      "unsupported_delivery_schema",
      "$.schemaVersion",
      "Delivery message schema must be 1.",
    );
  }
  const projectID = requireString(root["projectID"], "$.projectID", 1, 100);
  const reportID = requireString(root["reportID"], "$.reportID", 36, 36);
  if (!PROJECT_ID_PATTERN.test(projectID) || !LOWERCASE_UUID_PATTERN.test(reportID)) {
    throw new ValidationError(
      "invalid_delivery_message",
      "$",
      "Delivery message identifiers are invalid.",
    );
  }
  return { schemaVersion: 1, projectID, reportID };
}

export function parseStoredPayload(value: unknown): StoredPayload {
  const root = requireRecord(value, "$", ["submission", "serverRedactionCount"]);
  const serverRedactionCount = root["serverRedactionCount"];
  if (
    typeof serverRedactionCount !== "number"
    || !Number.isSafeInteger(serverRedactionCount)
    || serverRedactionCount < 0
    || serverRedactionCount > MAX_REQUEST_BYTES
  ) {
    throw new ValidationError(
      "invalid_stored_payload",
      "$.serverRedactionCount",
      "Stored server redaction count is invalid.",
    );
  }
  return {
    // Known redaction replacements can be longer than the matched credential.
    // Four times the bounded ingress size is above the worst replacement ratio
    // while still imposing a deterministic ceiling on decrypted data.
    submission: parseSubmissionWithTextLimit(root["submission"], MAX_STORED_TEXT_BYTES),
    serverRedactionCount,
  };
}

export function isProjectID(value: string): boolean {
  return PROJECT_ID_PATTERN.test(value);
}

export function isLowercaseUUID(value: string): boolean {
  return LOWERCASE_UUID_PATTERN.test(value);
}

export function isLowercaseSha256(value: string): boolean {
  return SHA256_PATTERN.test(value);
}

function parseResponses(value: unknown, maximumTextBytes: number): SupportFieldResponse[] {
  if (!Array.isArray(value) || value.length > 24) {
    throw new ValidationError("invalid_responses", "$.responses", "responses must contain at most 24 items.");
  }
  const seenIDs = new Set<string>();
  let valueBytes = 0;
  return value.map((item, index) => {
    const path = `$.responses[${String(index)}]`;
    const record = requireRecord(item, path, ["id", "label", "value"]);
    const id = requireString(record["id"], `${path}.id`, 1, 100);
    if (!FIELD_ID_PATTERN.test(id) || seenIDs.has(id)) {
      throw new ValidationError("invalid_field_id", `${path}.id`, "Response IDs must be valid and unique.");
    }
    seenIDs.add(id);
    const label = requireText(record["label"], `${path}.label`, 1, maximumTextBytes, true);
    const responseValue = requireText(record["value"], `${path}.value`, 1, maximumTextBytes, false);
    valueBytes += byteLength(responseValue);
    if (valueBytes > maximumTextBytes) {
      throw new ValidationError("responses_too_large", "$.responses", "Combined response values are too large.");
    }
    return { id, label, value: responseValue };
  });
}

function parseDiagnostics(value: unknown, maximumTextBytes: number): SupportDiagnostic[] {
  if (!Array.isArray(value) || value.length > 100) {
    throw new ValidationError(
      "invalid_diagnostics",
      "$.diagnostics",
      "diagnostics must contain at most 100 items.",
    );
  }
  let valueBytes = 0;
  return value.map((item, index) => {
    const path = `$.diagnostics[${String(index)}]`;
    const record = requireRecord(item, path, ["key", "value", "sensitivity"]);
    const key = requireText(record["key"], `${path}.key`, 1, maximumTextBytes, true);
    const diagnosticValue = requireText(record["value"], `${path}.value`, 1, maximumTextBytes, false);
    const rawSensitivity = requireString(record["sensitivity"], `${path}.sensitivity`, 8, 24);
    if (rawSensitivity !== "standard" && rawSensitivity !== "potentiallyIdentifying") {
      throw new ValidationError(
        "invalid_sensitivity",
        `${path}.sensitivity`,
        "Diagnostic sensitivity is invalid.",
      );
    }
    valueBytes += byteLength(diagnosticValue);
    if (valueBytes > maximumTextBytes) {
      throw new ValidationError(
        "diagnostics_too_large",
        "$.diagnostics",
        "Combined diagnostic values are too large.",
      );
    }
    const sensitivity: DiagnosticSensitivity = rawSensitivity;
    return { key, value: diagnosticValue, sensitivity };
  });
}

function parseLabels(value: unknown, maximumTextBytes: number): string[] {
  if (!Array.isArray(value) || value.length > 10) {
    throw new ValidationError("invalid_labels", "$.labels", "labels must contain at most 10 items.");
  }
  const seen = new Set<string>();
  return value.map((item, index) => {
    const label = requireText(item, `$.labels[${String(index)}]`, 1, maximumTextBytes, true);
    if (seen.has(label)) {
      throw new ValidationError("duplicate_label", `$.labels[${String(index)}]`, "labels must be unique.");
    }
    seen.add(label);
    return label;
  });
}

function requireRecord(value: unknown, path: string, allowedKeys: readonly string[]): Record<string, unknown> {
  if (!isRecord(value)) {
    throw new ValidationError("invalid_object", path, `${path} must be an object.`);
  }
  const record = value;
  const actualKeys = Object.keys(record);
  for (const key of actualKeys) {
    if (!allowedKeys.includes(key)) {
      throw new ValidationError("unknown_field", `${path}.${key}`, `Unknown field: ${path}.${key}.`);
    }
  }
  for (const key of allowedKeys) {
    if (!Object.hasOwn(record, key)) {
      throw new ValidationError("missing_field", `${path}.${key}`, `Missing field: ${path}.${key}.`);
    }
  }
  return record;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function requireText(
  value: unknown,
  path: string,
  minimumBytes: number,
  maximumBytes: number,
  requireTrimmed: boolean,
): string {
  const text = requireString(value, path, minimumBytes, maximumBytes);
  if (hasForbiddenControlCharacter(text)) {
    throw new ValidationError("invalid_control_character", path, `${path} contains a forbidden control character.`);
  }
  if (requireTrimmed && text !== text.trim()) {
    throw new ValidationError("untrimmed_text", path, `${path} must not have leading or trailing whitespace.`);
  }
  if (text.trim().length === 0) {
    throw new ValidationError("empty_text", path, `${path} must not be empty.`);
  }
  return text;
}

function requireString(value: unknown, path: string, minimumBytes: number, maximumBytes: number): string {
  if (typeof value !== "string") {
    throw new ValidationError("invalid_string", path, `${path} must be a string.`);
  }
  const bytes = byteLength(value);
  if (bytes < minimumBytes || bytes > maximumBytes) {
    throw new ValidationError(
      "invalid_length",
      path,
      `${path} must be between ${String(minimumBytes)} and ${String(maximumBytes)} UTF-8 bytes.`,
    );
  }
  return value;
}

function byteLength(value: string): number {
  return new TextEncoder().encode(value).byteLength;
}

function hasForbiddenControlCharacter(value: string): boolean {
  for (const character of value) {
    const codePoint = character.codePointAt(0);
    if (codePoint !== undefined && (codePoint <= 0x08 || (codePoint >= 0x0b && codePoint <= 0x0c) || (codePoint >= 0x0e && codePoint <= 0x1f) || codePoint === 0x7f)) {
      return true;
    }
  }
  return false;
}
