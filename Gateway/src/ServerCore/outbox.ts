import type { DeliveryMessage } from "./domain";
import type { Clock, DeliveryPublisher, OutboxStore } from "./ports";

const OUTBOX_BATCH_SIZE = 25;

export type OutboxDependencies = {
  outbox: OutboxStore;
  publisher: DeliveryPublisher;
  clock: Clock;
};

export async function dispatchOutbox(
  dependencies: Readonly<OutboxDependencies>,
): Promise<{ published: number; failed: boolean }> {
  const now = dependencies.clock.now();
  const rows = await dependencies.outbox.listPending(now.toISOString(), OUTBOX_BATCH_SIZE);
  if (rows.length === 0) {
    return { published: 0, failed: false };
  }
  const messages: DeliveryMessage[] = rows.map((row) => ({
    schemaVersion: 1,
    projectID: row.projectID,
    reportID: row.reportID,
  }));
  try {
    await dependencies.publisher.publish(messages);
    const publishedAt = dependencies.clock.now().toISOString();
    await Promise.all(
      rows.map((row) => dependencies.outbox.markPublished(row.projectID, row.reportID, publishedAt)),
    );
    return { published: rows.length, failed: false };
  } catch {
    const retryAt = new Date(
      now.getTime() + outboxDelaySeconds(rows[0]?.publishAttemptCount ?? 0) * 1_000,
    );
    await Promise.all(
      rows.map((row) => dependencies.outbox.markRetry(
        row.projectID,
        row.reportID,
        retryAt.toISOString(),
        now.toISOString(),
      )),
    );
    return { published: 0, failed: true };
  }
}

export async function runScheduledMaintenance(
  dependencies: Readonly<OutboxDependencies>,
): Promise<{ published: number; failed: boolean }> {
  const now = dependencies.clock.now();
  const staleCutoff = new Date(now.getTime() - 10 * 60 * 1_000).toISOString();
  await dependencies.outbox.recoverStale(staleCutoff, now.toISOString());
  const result = await dispatchOutbox(dependencies);
  await dependencies.outbox.purgeExpiredPayloads(dependencies.clock.now().toISOString());
  return result;
}

function outboxDelaySeconds(attempts: number): number {
  const normalizedAttempts = Number.isSafeInteger(attempts) && attempts >= 0 ? attempts : 0;
  return Math.min(15 * 2 ** Math.min(normalizedAttempts, 8), 3_600);
}
