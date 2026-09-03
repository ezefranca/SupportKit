# Reliable Delivery

Understand queueing, deduplication, retries, and reports that need attention.

## Overview

``SupportClient`` persists a validated report before any delivery attempt. A successful submit result therefore means
the report is durably queued or was recognized as a duplicate; it does not necessarily mean the remote destination has
already accepted it.

### Preserve one frozen payload

``SupportClient/prepare(_:)`` produces a ``PreparedSupportSubmission`` whose preview and delivery payload refer to the
same immutable report. Queueing that value does not recollect diagnostics or reread mutable form state. The client also
checks the encoded payload against ``DeliveryConfiguration/maximumSubmissionBytes`` before persistence. A prepared
value is bound to the ``SupportClient`` instance that created it. Passing it to another client returns
``SupportSubmissionFailure/invalidPreparedSubmission`` without writing to either queue.

Queued records use the stable ``SupportConfiguration/queueScope`` derived from the exact project and logical queue
identifiers. Every store lookup, claim, count, and state transition includes that scope. Clients sharing one store can
therefore use the same report UUID without observing or delivering each other's records. The public
``SupportConfiguration/queueIdentifier`` preserves its exact spelling so recreating a configuration is round-trip
safe; the file-backed store derives a hashed physical namespace instead of using that logical value as a path.

### Suppress duplicate work

Every ``SupportSubmission`` has a stable idempotency key and content fingerprint. The fingerprint covers the project,
final title and message, field responses, diagnostic keys, values and sensitivity, and destination labels. Atomic queue
operations suppress every matching pending report regardless of age; the configured suppression interval applies only
to accepted receipts. Re-submitting a matching report that previously required attention requeues the original report
identity so the receiver sees the same idempotency key.

The receiver must enforce the idempotency key as well. Client-side deduplication prevents common duplicate work, while
receiver-side idempotency covers ambiguous network outcomes such as a lost success response.

### Retry safely

Transient connectivity, throttling, and server errors schedule a bounded exponential retry. Server-provided retry
delays are honored within configured limits. Permanent or malformed responses move the report to a retained
needs-attention state instead of retrying forever.

Delivery workers claim reports with durable leases. A second cooperating worker cannot deliver an actively leased
report, and an abandoned report becomes eligible again after lease expiry. ``SupportClient/flush()`` is safe to call
when the app regains connectivity; only one flush runs inside a client at a time.

Use ``SupportClient/pendingReportCount()`` for all retained reports, including items that need attention. Use
``SupportClient/readyReportCount()`` for reports currently eligible for automatic delivery, and observe
``SupportClient/events()`` to update user-visible state after queueing.
