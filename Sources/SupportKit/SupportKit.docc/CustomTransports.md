# Custom Transports and Server Adapters

Connect SupportKit to a provider-neutral receiver without weakening its delivery guarantees.

## Overview

``SupportTransport`` is the boundary between the durable client and a remote receiver. A successful `submit(_:)`
return means the receiver durably owns the report and can suppress repeated requests using
``SupportSubmission/idempotencyKey``. It must not mean only that an asynchronous request was accepted into volatile
memory.

### Implement a transport

Map transient and terminal failures explicitly:

```swift
struct CompanySupportTransport: SupportTransport {
    let receiver: CompanyReceiver

    func submit(_ submission: SupportSubmission) async throws -> SupportDeliveryReceipt {
        do {
            return try await receiver.accept(submission)
        } catch let error as CompanyReceiver.Throttled {
            throw SupportTransportError.retryable(
                code: 429,
                retryAfter: error.retryAfter,
                reason: "The support service asked us to retry later."
            )
        } catch is CompanyReceiver.InvalidProject {
            throw SupportTransportError.permanent(
                code: 404,
                reason: "This support destination is unavailable."
            )
        }
    }
}
```

Keep failure reasons bounded and free of response bodies, credentials, or internal server detail. Preserve task
cancellation rather than reclassifying it as a retryable failure.

### Design the server adapter

Treat ``SupportConfiguration/projectID`` as an opaque, non-secret lookup key. The server maps it to an allowlisted
repository, ticket queue, or help-desk project. Validate the complete request schema, enforce payload limits and rate
limits, and reject client-provided destination overrides.

Atomically reserve ``SupportSubmission/idempotencyKey`` before invoking the provider. Store the resulting
``SupportDeliveryReceipt`` so repeated requests return the original durable outcome. Keep provider credentials in a
secret manager and grant only the permissions needed to create reports.

As one included adapter example, the GitHub integration uses a GitHub App installation token scoped to the allowlisted
repository rather than a personal access token. Its immutable route explicitly expects private or public repository
visibility and fails closed if GitHub metadata differs. Prefer private: an issue in a public destination exposes the
report and included diagnostics, independently of the app source repository's visibility. The included
``SupportGatewayTransport`` supplies a fixed HTTPS request shape, payload digest, response cap, redirect blocking, and
optional ``SupportRequestAuthorizer`` hook for short-lived attestation.

### Replace persistence only when necessary

A custom ``SupportSubmissionStore`` must implement atomic duplicate lookup and insertion, needs-attention requeueing,
capacity enforcement, durable delivery leases, authoritative acceptance, and receipt retention. It must treat
``SupportQueueRecordID`` as the complete record key and apply its ``SupportQueueScope`` to duplicate checks, counts,
claims, and mutations. There are no best-effort default implementations. Start with
``FileSupportSubmissionStore`` unless the host has a concrete storage integration requirement.
