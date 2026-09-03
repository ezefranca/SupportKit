import type { DeliveryMessage } from "../../ServerCore/domain";
import type {
  DeliveryDependencies,
  DeliveryDecision,
} from "../../ServerCore/delivery";
import { processDelivery } from "../../ServerCore/delivery";
import type { DeliveryPublisher } from "../../ServerCore/ports";
import { parseDeliveryMessage, ValidationError } from "../../ServerCore/validation";

export class CloudflareDeliveryQueue implements DeliveryPublisher {
  readonly #queue: Queue<DeliveryMessage>;

  constructor(queue: Queue<DeliveryMessage>) {
    this.#queue = queue;
  }

  async publish(messages: readonly DeliveryMessage[]): Promise<void> {
    await this.#queue.sendBatch(messages.map((body) => ({ body, contentType: "json" })));
  }
}

export async function consumeCloudflareBatch<TTarget>(
  batch: MessageBatch<DeliveryMessage>,
  dependencies: Readonly<DeliveryDependencies<TTarget>>,
): Promise<void> {
  for (const message of batch.messages) {
    try {
      const deliveryMessage = parseDeliveryMessage(message.body);
      applyDecision(message, await processDelivery(deliveryMessage, message.attempts, dependencies));
    } catch (error) {
      if (error instanceof ValidationError) {
        logError("invalid_queue_message", { queueMessageID: message.id, code: error.code });
        message.ack();
      } else {
        logError("queue_processing_failed", {
          queueMessageID: message.id,
          code: safeErrorCode(error),
        });
        message.retry({ delaySeconds: retryDelay(message.attempts) });
      }
    }
  }
}

function applyDecision(message: Message<DeliveryMessage>, decision: DeliveryDecision): void {
  if (decision.action === "ack") {
    message.ack();
  } else {
    message.retry({ delaySeconds: decision.delaySeconds });
  }
}

function retryDelay(attempts: number): number {
  return Math.min(30 * 2 ** Math.min(Math.max(attempts - 1, 0), 7), 3_600);
}

function safeErrorCode(error: unknown): string {
  return error instanceof Error ? error.name.slice(0, 80) : "unknown_error";
}

function logError(event: string, fields: Record<string, string | number | boolean>): void {
  console.error(JSON.stringify({ event, ...fields }));
}
