import { MAX_DESTINATION_BODY_BYTES } from "./domain";
import type { StoredPayload } from "./domain";
import type { DestinationDocument } from "./ports";

export function buildDestinationDocument(
  payload: StoredPayload,
  marker: string,
): DestinationDocument {
  requireValidDestinationMarker(marker);
  const submission = payload.submission;
  const sections: string[] = [
    "## User message",
    codeBlock(submission.message),
  ];

  if (submission.responses.length > 0) {
    sections.push("## Form responses");
    for (const response of submission.responses) {
      sections.push(`### ${escapeHeading(response.label)}`, codeBlock(response.value));
    }
  }

  if (submission.diagnostics.length > 0) {
    sections.push("## Diagnostics");
    for (const diagnostic of submission.diagnostics) {
      const identifying = diagnostic.sensitivity === "potentiallyIdentifying" ? " · potentially identifying" : "";
      sections.push(`### ${escapeHeading(diagnostic.key)}${identifying}`, codeBlock(diagnostic.value));
    }
  }

  sections.push(
    "## Submission metadata",
    `- Report ID: \`${submission.id}\``,
    `- Client-created: \`${submission.createdAt}\``,
    `- Content fingerprint: \`${submission.contentFingerprint}\``,
    `- Server redactions applied: \`${String(payload.serverRedactionCount)}\``,
  );

  const trustedMarker = `<!-- ${marker} -->`;
  const suffix = `\n\n${trustedMarker}`;
  const suffixBytes = utf8Length(suffix);
  const content = sections.join("\n\n");
  const body = `${truncateUtf8(content, MAX_DESTINATION_BODY_BYTES - suffixBytes)}${suffix}`;
  return {
    title: truncateUtf8(neutralizeMentions(submission.title).replace(/[\r\n]+/gu, " "), 256, ""),
    body,
  };
}

export class InvalidDestinationMarkerError extends Error {
  constructor() {
    super("invalid_destination_marker");
    this.name = "InvalidDestinationMarkerError";
  }
}

/** Allows a marker to be safely embedded in one bounded HTML comment. */
export function requireValidDestinationMarker(marker: string): string {
  if (
    marker.length < 16
    || marker.length > 128
    || !/^[A-Za-z0-9._:-]+$/u.test(marker)
    || marker.includes("--")
  ) {
    throw new InvalidDestinationMarkerError();
  }
  return marker;
}

function codeBlock(value: string): string {
  return neutralizeMentions(value)
    .split("\n")
    .map((line) => `    ${line}`)
    .join("\n");
}

function escapeHeading(value: string): string {
  return neutralizeMentions(value)
    .replace(/([\\`*_{}()<>#+.!|~-])/gu, "\\$1")
    .replaceAll("[", "\\[")
    .replaceAll("]", "\\]");
}

function neutralizeMentions(value: string): string {
  return value.replaceAll("@", "@\u200B");
}

function truncateUtf8(
  value: string,
  maximumBytes: number,
  suffix = "\n\n_[Additional diagnostic content was truncated by the server.]_",
): string {
  if (utf8Length(value) <= maximumBytes) {
    return value;
  }
  const budget = Math.max(0, maximumBytes - utf8Length(suffix));
  let low = 0;
  let high = value.length;
  while (low < high) {
    const middle = Math.ceil((low + high) / 2);
    if (utf8Length(value.slice(0, middle)) <= budget) {
      low = middle;
    } else {
      high = middle - 1;
    }
  }
  let end = low;
  const code = value.charCodeAt(end - 1);
  if (code >= 0xd800 && code <= 0xdbff) {
    end -= 1;
  }
  return `${value.slice(0, end)}${suffix}`;
}

function utf8Length(value: string): number {
  return new TextEncoder().encode(value).byteLength;
}
