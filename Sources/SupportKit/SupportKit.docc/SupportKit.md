# ``SupportKit``

Build an offline-capable support workflow without putting provider credentials in an Apple app.

## Overview

SupportKit validates and redacts a ``SupportDraft``, freezes any opted-in diagnostics for review, persists the exact
payload before networking, and delivers it through an idempotent ``SupportTransport``. ``SupportClient`` is the main
actor-owned coordination API.

``SupportGatewayTransport`` is the included HTTPS receiver adapter. The app configures a non-secret
``SupportConfiguration/projectID``; the receiver maps it to an allowlisted destination and owns any provider
credentials. No destination credential is compiled into or delivered to the app.

The submission lifecycle separates review from side effects:

1. ``SupportClient/prepare(_:)`` validates, redacts, and freezes a report.
2. The app displays ``PreparedSupportSubmission/preview`` when user confirmation is required.
3. `SupportClient.submit(_:)` durably queues that exact prepared report.
4. The delivery worker claims queued reports, retries transient failures, and retains permanent failures for attention.

> Important: SupportKit improves privacy and delivery resilience, but it cannot guarantee that arbitrary app-provided
> diagnostics are non-sensitive. Keep collection opt-in, provide only bounded diagnostics, and review your own privacy
> disclosures.

### Create a client

```swift
let configuration = try SupportConfiguration(projectID: "my-app")
let endpoint = try SupportGatewayTransport.Configuration(
    endpoint: gatewayURL
)
let authorizer = SupportBearerTokenAuthorizer {
    try await supportIdentity.fetchShortLivedSupportToken()
}
let client = try SupportClient.live(
    configuration: configuration,
    transport: SupportGatewayTransport(
        configuration: endpoint,
        authorizer: authorizer
    )
)
```

Keep the client alive for the application session. Call ``SupportClient/resumeDelivery()`` when connectivity or
foreground state changes, and ``SupportClient/pauseDelivery()`` when the app needs to suspend only the in-process
worker. Reports already written to the durable queue remain available after a restart.

### Submit without SwiftUI

```swift
let result = await client.submit(
    SupportDraft(
        subject: "Export problem",
        message: "The export stays at 90%.",
        responses: ["category": "problem"],
        includesDiagnostics: true
    )
)
```

Inspect ``SupportSubmissionResult`` to distinguish a newly queued report from a pending duplicate, an already
accepted duplicate, or a validation/persistence rejection. Observe ``SupportClient/events()`` for later delivery state
without coupling application UI to the transport.

## Topics

### Configure reports

- ``SupportConfiguration``
- ``SupportFormConfiguration``
- ``SupportFormField``
- ``DiagnosticsConfiguration``
- ``DeliveryConfiguration``

### Learn the architecture

- <doc:GettingStarted>
- <doc:ConsentAndDiagnostics>
- <doc:OfflineDelivery>
- <doc:CustomTransports>
- <doc:SecurityAndPrivacy>
- <doc:ReliableDelivery>

### Prepare and submit

- ``SupportClient``
- ``SupportDraft``
- ``PreparedSupportSubmission``
- ``SupportPreparationResult``
- ``SupportSubmissionResult``
- ``SupportSubmissionFailure``
- ``SupportPayloadPreview``
- ``SupportSubmission``
- ``SupportFieldResponse``

### Observe delivery

- ``SupportDeliveryEvent``
- ``SupportDeliveryReport``
- ``SupportDeliveryReceipt``
- ``QueuedSupportSubmission``
- ``SupportQueueScope``
- ``SupportQueueRecordID``

### Privacy and diagnostics

- ``SupportRedactor``
- ``RedactionConfiguration``
- ``SupportRedactionRule``
- ``SystemDiagnosticsProvider``
- ``SupportDiagnosticsProvider``
- ``SupportDiagnostic``
- ``SupportLogBuffer``
- ``SupportLogSource``
- ``SupportLogEntry``

### Customize infrastructure

- ``SupportGatewayTransport``
- ``SupportTransport``
- ``SupportSubmissionStore``
- ``SupportRequestAuthorizer``
- ``SupportBearerTokenAuthorizer``
- ``SupportAuthorizationError``
- ``SupportHTTPClient``
- ``SupportGatewayTransport/Configuration``
- ``URLSessionSupportHTTPClient``
- ``AnonymousSupportRequestAuthorizer``
- ``FileSupportSubmissionStore``
- ``InMemorySupportSubmissionStore``
- ``SupportStoreEnqueueResult``
- ``SupportStoreError``
- ``SupportTransportError``
