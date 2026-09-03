import type { StoredPayload, SupportSubmission } from "./domain";

type RedactionResult = {
  value: string;
  count: number;
};

const PEM_PATTERN =
  /-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----[\s\S]{0,262144}?(?:-----END (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----|$)/gu;
const CREDENTIALED_URL_PATTERN =
  /\b(?:https?|ftp):\/\/[^\s/?#@]+(?::[^\s/?#@]*)?@[^\s<>"']+/giu;
const GITHUB_FINE_GRAINED_TOKEN_PATTERN = /\bgithub_pat_[A-Za-z0-9_]{20,255}\b/gu;
const GITHUB_LEGACY_TOKEN_PATTERN = /\bgh[pousr]_[A-Za-z0-9]{20,255}\b/gu;
const PREFIXED_TOKEN_PATTERN = /\b[A-Za-z][A-Za-z0-9]{1,16}_[A-Za-z0-9_]{20,}\b/gu;
const JWT_PATTERN = /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/gu;
const AUTH_PATTERN = /\b(?:Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}/giu;
const ASSIGNMENT_PATTERN =
  /\b(authorization|api[-_ ]?key|access[-_ ]?token|refresh[-_ ]?token|password|passwd|secret)\b(\s*[:=]\s*)([^\s,;]{4,})/giu;
const EMAIL_PATTERN = /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,63}\b/giu;
const IPV4_PATTERN = /\b(?:\d{1,3}\.){3}\d{1,3}\b/gu;

export function redactSubmission(submission: SupportSubmission): StoredPayload {
  let count = 0;
  const title = redactSecrets(submission.title);
  const message = redactSecrets(submission.message);
  count += title.count + message.count;

  const responses = submission.responses.map((response) => {
    const label = redactSecrets(response.label);
    const value = redactSecrets(response.value);
    count += label.count + value.count;
    return { ...response, label: label.value, value: value.value };
  });

  const diagnostics = submission.diagnostics.map((diagnostic) => {
    const key = redactSecrets(diagnostic.key);
    const secretSafe = redactSecrets(diagnostic.value);
    const identifyingSafe = redactDiagnosticIdentifiers(secretSafe.value);
    count += key.count + secretSafe.count + identifyingSafe.count;
    return { ...diagnostic, key: key.value, value: identifyingSafe.value };
  });

  return {
    submission: {
      ...submission,
      title: title.value,
      message: message.value,
      responses,
      diagnostics,
    },
    serverRedactionCount: count,
  };
}

export function redactSecrets(value: string): RedactionResult {
  let result = value;
  let count = 0;
  const replace = (pattern: RegExp, replacement: string): void => {
    result = result.replace(pattern, () => {
      count += 1;
      return replacement;
    });
  };
  replace(PEM_PATTERN, "[REDACTED_PRIVATE_KEY]");
  replace(CREDENTIALED_URL_PATTERN, "[REDACTED_CREDENTIAL_URL]");
  replace(GITHUB_FINE_GRAINED_TOKEN_PATTERN, "[REDACTED_TOKEN]");
  replace(GITHUB_LEGACY_TOKEN_PATTERN, "[REDACTED_TOKEN]");
  replace(PREFIXED_TOKEN_PATTERN, "[REDACTED_TOKEN]");
  replace(JWT_PATTERN, "[REDACTED_JWT]");
  replace(AUTH_PATTERN, "[REDACTED_AUTHORIZATION]");
  result = result.replace(ASSIGNMENT_PATTERN, (_match, key: string, separator: string) => {
    count += 1;
    return `${key}${separator}[REDACTED]`;
  });
  return { value: result, count };
}

function redactDiagnosticIdentifiers(value: string): RedactionResult {
  let result = value;
  let count = 0;
  result = result.replace(EMAIL_PATTERN, () => {
    count += 1;
    return "[REDACTED_EMAIL]";
  });
  result = result.replace(IPV4_PATTERN, (candidate) => {
    const octets = candidate.split(".").map(Number);
    if (octets.length !== 4 || octets.some((octet) => octet > 255)) {
      return candidate;
    }
    count += 1;
    return "[REDACTED_IP]";
  });
  return { value: result, count };
}
