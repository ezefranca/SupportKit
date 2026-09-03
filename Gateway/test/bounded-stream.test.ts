import { describe, expect, it } from "vitest";
import { readBoundedByteStream } from "../src/adapters/web/bounded-stream";

const errors = {
  invalidContentLength: (): Error => new Error("invalid_content_length"),
  bodyTooLarge: (): Error => new Error("body_too_large"),
  bodyTooFragmented: (): Error => new Error("body_too_fragmented"),
};

describe("bounded Fetch stream reader", () => {
  it("rejects invalid configured limits", async () => {
    await expect(readBoundedByteStream(null, null, Number.POSITIVE_INFINITY, errors)).rejects.toThrow(
      "maximumBytes must be a positive safe integer",
    );
    await expect(readBoundedByteStream(null, null, 0, errors)).rejects.toThrow(
      "maximumBytes must be a positive safe integer",
    );
  });

  it("does not retain empty chunks and bounds adversarial fragmentation", async () => {
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        controller.enqueue(new Uint8Array());
      },
    });

    await expect(readBoundedByteStream(stream, null, 1, errors)).rejects.toThrow(
      "body_too_fragmented",
    );
  });

  it("accepts a bounded fragmented body", async () => {
    const chunks = [new Uint8Array(), new Uint8Array([1]), new Uint8Array(), new Uint8Array([2])];
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        const next = chunks.shift();
        if (next === undefined) {
          controller.close();
        } else {
          controller.enqueue(next);
        }
      },
    });

    await expect(readBoundedByteStream(stream, "2", 2, errors)).resolves.toEqual(
      new Uint8Array([1, 2]),
    );
  });
});
