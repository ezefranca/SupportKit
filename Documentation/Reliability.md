# Reliability model

SupportKit is designed to preserve a report across ordinary connectivity loss, process termination, retriable server
errors, and ambiguous HTTP responses. It reports outcomes instead of claiming impossible guarantees.

## Client states

A report moves from `prepared` to `ready` after an atomic local write. A retriable failure keeps it in `ready` with a
future attempt date. Receiver acceptance writes a receipt before the pending record is removed. Permanent failures move
to `needsAttention` until the host app or user retries them.

Each queued report is one atomically replaced, AES-GCM-sealed file. A random 256-bit install key lives in Keychain;
authenticated additional data binds ciphertext to its queue, directory, and filename. Accepted receipts are encrypted
and stored separately. On success the store writes the receipt first and removes the pending file second. If the process
stops between those operations, the next read observes the receipt and removes the stale pending copy without sending
it again. Plaintext, corrupt, or unauthentic files are moved aside rather
than decoded with partial data or crashing the host app.

The default queue capacity is 100 reports. A full or unavailable queue returns a `SupportSubmissionFailure`; SupportKit
does not discard the oldest customer report silently.

Prepared reports are accepted only by the `SupportClient` instance that created them. Durable records are separately
bound to a stable configuration scope. Every store claim and mutation includes that scope, so a client cannot drain a
different project's reports from a shared store.

## Retry classification

The bundled HTTPS transport retries connectivity failures, HTTP 408, 425, 429, and 5xx. It honors a valid `Retry-After`
header, otherwise uses bounded exponential backoff with deterministic jitter. Most other 4xx responses need operator or
configuration attention and are not retried forever.

A flush is actor-serialized and processes a bounded batch. Automatic delivery is opportunistic: the in-process task
runs while the host process is allowed to execute. Apple operating systems may suspend or terminate an app at any time,
so hosts should call `resumeDelivery()` on activation. A host that has a legitimate background-processing mode can call
`flush()` from its own scheduled task.

## Duplicate controls

There are three different duplicate problems:

1. **Repeated user action.** The client fingerprints the project, final title and message, field responses, diagnostic
   keys, values and sensitivity, and destination labels. Every matching pending report is suppressed regardless of its
   age. The configured suppression interval applies only to accepted receipts.
2. **Repeated server request.** The same project, idempotency key, and raw payload digest returns the original durable
   receipt. Reusing a key with different bytes is a conflict.
3. **Ambiguous destination response.** The server embeds a stable hidden report marker in the ticket body. If creation
   times out after the destination may have committed it, the adapter searches for the marker before another create
   attempt. The included GitHub adapter implements this behavior.

GitHub's issue-creation API has no idempotency-key parameter. Reconciliation substantially reduces duplicates but
cannot make an absolute exactly-once promise across all possible upstream failures. The server favors preserving an
accepted report and exposes manual-review state when certainty cannot be established safely.

## Meaning of success

- `SupportSubmissionResult.queued`: the app owns a durable local copy and delivery may occur later.
- `SupportDeliveryReceipt.Status.accepted`: the receiver owns a durable copy and the app may delete its queued copy.
- `.delivered`: the server knows the destination accepted the ticket.
- `.duplicate`: the server had already accepted these exact idempotent bytes.
- `needsAttention`: automatic retry would not safely fix the failure.

Observe `SupportClient.events()` for delivery telemetry. Never block the user's UI waiting for GitHub issue creation.

## Operational responsibilities

Reliability still depends on the deployment:

- monitor the dead-letter queue, storage errors, destination rate limits, and adapter credential health;
- alert on reports in `manual_review` or `permanent_failure`;
- back up server configuration, not customer payloads beyond the declared retention policy;
- test credential rotation and repository removal;
- keep the app's fallback support route visible when bootstrap or local storage fails.
