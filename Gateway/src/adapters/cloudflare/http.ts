import { readBoundedByteStream } from "../web/bounded-stream";

export class HttpError extends Error {
  readonly status: number;
  readonly code: string;
  readonly safeMessage: string;
  readonly retryAfterSeconds: number | null;
  readonly allow: string | null;

  constructor(
    status: number,
    code: string,
    safeMessage: string,
    retryAfterSeconds: number | null = null,
    allow: string | null = null,
  ) {
    super(safeMessage);
    this.name = "HttpError";
    this.status = status;
    this.code = code;
    this.safeMessage = safeMessage;
    this.retryAfterSeconds = retryAfterSeconds;
    this.allow = allow;
  }
}

export async function readBoundedBody(request: Request, maximumBytes: number): Promise<Uint8Array> {
  return readBoundedByteStream(
    request.body,
    request.headers.get("content-length"),
    maximumBytes,
    {
      invalidContentLength: () => new HttpError(400, "invalid_content_length", "Content-Length is invalid."),
      bodyTooLarge: () => new HttpError(413, "payload_too_large", "The support report is too large."),
      bodyTooFragmented: () => new HttpError(
        413,
        "payload_too_fragmented",
        "The support report stream is too fragmented.",
      ),
    },
  );
}

export function decodeJsonBytes(bytes: Uint8Array): unknown {
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes);
  } catch {
    throw new HttpError(400, "invalid_utf8", "The request body must be valid UTF-8.");
  }
  try {
    const parsed: unknown = JSON.parse(text);
    return parsed;
  } catch {
    throw new HttpError(400, "invalid_json", "The request body must be valid JSON.");
  }
}

export function jsonResponse(
  value: unknown,
  status: number,
  requestID: string,
  extraHeaders?: HeadersInit,
): Response {
  const headers = new Headers(extraHeaders);
  headers.set("Cache-Control", "no-store, max-age=0");
  headers.set("Content-Type", "application/json; charset=utf-8");
  headers.set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'");
  headers.set("Referrer-Policy", "no-referrer");
  headers.set("X-Content-Type-Options", "nosniff");
  headers.set("X-Request-ID", requestID);
  return new Response(JSON.stringify(value), { status, headers });
}

export function errorResponse(error: HttpError, requestID: string): Response {
  const headers = new Headers();
  if (error.retryAfterSeconds !== null) {
    headers.set("Retry-After", String(error.retryAfterSeconds));
  }
  if (error.allow !== null) {
    headers.set("Allow", error.allow);
  }
  return jsonResponse(
    { code: error.code, message: error.safeMessage, requestID },
    error.status,
    requestID,
    headers,
  );
}

export function requireJsonContentType(request: Request): void {
  const contentType = request.headers.get("content-type");
  if (contentType === null || !/^application\/json(?:\s*;.*)?$/i.test(contentType)) {
    throw new HttpError(415, "unsupported_media_type", "Content-Type must be application/json.");
  }
}
