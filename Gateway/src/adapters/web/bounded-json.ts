import { readBoundedByteStream } from "./bounded-stream";

export async function readBoundedJsonResponse(
  response: Response,
  maximumBytes: number,
): Promise<unknown> {
  if (response.body === null) {
    throw new Error("response_body_missing");
  }
  // Cloudflare's generated Response body is typed as ReadableStream<any> even
  // though Fetch byte streams yield Uint8Array chunks. Narrow at this adapter boundary.
  const body = response.body as unknown as ReadableStream<Uint8Array>;
  const bytes = await readBoundedByteStream(
    body,
    response.headers.get("content-length"),
    maximumBytes,
    {
      invalidContentLength: () => new Error("response_size_invalid"),
      bodyTooLarge: () => new Error("response_too_large"),
      bodyTooFragmented: () => new Error("response_too_fragmented"),
    },
  );
  const text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes);
  const value: unknown = JSON.parse(text);
  return value;
}
