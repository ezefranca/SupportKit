# Offline Delivery

Understand what queueing guarantees and how delivery resumes safely.

## Overview

``SupportClient`` persists a frozen report before attempting the network. Consequently,
``SupportSubmissionResult/queued(reportID:)`` means the local store owns the report. Remote ownership is confirmed
later by ``SupportDeliveryEvent/accepted(_:)`` or an accepted duplicate receipt.

### Resume rather than rebuild

The file-backed store survives process termination and protects records with authenticated encryption. On launch or
foreground entry, call ``SupportClient/resumeDelivery()``. The worker sends due reports, sleeps until the next retry,
and wakes when a newly queued report is due sooner. ``SupportClient/pauseDelivery()`` cancels only in-process work.

### Classify delivery outcomes

A transport should throw ``SupportTransportError/retryable(code:retryAfter:reason:)`` for connectivity, throttling,
and transient receiver failures. SupportKit applies bounded exponential backoff and honors safe receiver delays.
Permanent failures, invalid receipts, and oversized payloads are retained in a needs-attention state.

Submitting matching content again atomically reactivates a needs-attention record under its original report identifier
and idempotency key. This prevents a retry action from creating two logical reports.

### Coordinate more than one worker

Every ``SupportSubmissionStore`` implementation must atomically claim due records using durable leases. A lease keeps
cooperating processes from sending the same report concurrently; an expired lease makes abandoned work recoverable.
All operations must also index and filter by ``SupportQueueScope``; report identifiers alone are not unique across a
shared store. Acceptance must be stored before removing pending data. For the complete persistence contract, see
``SupportSubmissionStore``.

Client-side fingerprints reduce duplicate work, while receiver-side idempotency resolves ambiguous outcomes such as a
successful acceptance whose response was lost. A production receiver must treat the submission idempotency key as an
atomic uniqueness key.
