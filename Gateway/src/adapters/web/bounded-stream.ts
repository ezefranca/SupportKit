const MAXIMUM_STREAM_CHUNKS = 8_192;

export type BoundedStreamErrors = {
  invalidContentLength: () => Error;
  bodyTooLarge: () => Error;
  bodyTooFragmented: () => Error;
};

/**
 * Reads a Fetch byte stream without allowing either bytes or chunk metadata to
 * grow without bound. `maximumBytes` is trusted configuration, so an invalid
 * value is a programmer error rather than an HTTP error.
 */
export async function readBoundedByteStream(
  stream: ReadableStream<Uint8Array> | null,
  contentLength: string | null,
  maximumBytes: number,
  errors: BoundedStreamErrors,
): Promise<Uint8Array> {
  if (!Number.isSafeInteger(maximumBytes) || maximumBytes <= 0) {
    throw new RangeError("maximumBytes must be a positive safe integer");
  }

  if (contentLength !== null) {
    if (!/^\d+$/u.test(contentLength)) {
      throw errors.invalidContentLength();
    }
    const declaredBytes = Number(contentLength);
    if (!Number.isSafeInteger(declaredBytes)) {
      throw errors.invalidContentLength();
    }
    if (declaredBytes > maximumBytes) {
      throw errors.bodyTooLarge();
    }
  }

  if (stream === null) {
    return new Uint8Array();
  }

  const reader = stream.getReader();
  const chunks: Uint8Array[] = [];
  let byteCount = 0;
  let chunkCount = 0;
  try {
    let result = await reader.read();
    while (!result.done) {
      chunkCount += 1;
      if (chunkCount > MAXIMUM_STREAM_CHUNKS) {
        await cancelReader(reader, "body_too_fragmented");
        throw errors.bodyTooFragmented();
      }

      const chunk = result.value;
      if (chunk.byteLength > 0) {
        byteCount += chunk.byteLength;
        if (byteCount > maximumBytes) {
          await cancelReader(reader, "body_too_large");
          throw errors.bodyTooLarge();
        }
        chunks.push(chunk);
      }
      result = await reader.read();
    }
  } finally {
    reader.releaseLock();
  }

  const body = new Uint8Array(byteCount);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return body;
}

async function cancelReader(
  reader: ReadableStreamDefaultReader<Uint8Array>,
  reason: string,
): Promise<void> {
  try {
    await reader.cancel(reason);
  } catch {
    // Preserve the deterministic bounded-read error even if the remote source's
    // cancellation hook itself fails.
  }
}
