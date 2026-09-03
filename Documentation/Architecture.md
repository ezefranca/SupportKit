# Architecture

SupportKit separates policy, persistence, presentation, and external delivery so an app can adopt only the layers it
needs. Dependencies point inward toward value types and protocols; neither the core client nor the UI knows about a
specific GitHub repository or credential.

## Packages and responsibilities

| Boundary | Responsibility | Important types |
|---|---|---|
| Models | Immutable payloads and validated configuration | `SupportConfiguration`, `SupportDraft`, `SupportSubmission` |
| Privacy | Local deterministic redaction and explicit diagnostic collection | `SupportRedactor`, `DiagnosticsConfiguration` |
| Persistence | Queue-before-network storage and durable acceptance receipts | `SupportSubmissionStore`, `FileSupportSubmissionStore` |
| Delivery | Retry timing, serialization, and HTTP classification | `SupportClient`, `SupportGatewayTransport` |
| Presentation | SwiftUI fields, consent, preview, and status | `SupportForm`, `SupportFormModel`, `SupportFormTheme` |
| Server core | Routing, durable ingestion, abuse controls, and delivery orchestration | Runtime-neutral ports and state machines |
| Host adapters | HTTP, persistence, queues, authentication, and rate limits | Included Cloudflare adapter or host implementations |
| Destination adapters | Ticket creation and ambiguous-result reconciliation | Included GitHub App adapter or another `IssueTracker` |

`SupportClient` is an actor. It owns mutable delivery state, serializes flushes, and emits bounded asynchronous events.
Public models crossing actor boundaries conform to `Sendable`. The ready-made form and its observable model are
main-actor isolated.

## Report flow

1. The form creates a draft and records the user's diagnostic consent.
2. `SupportClient` validates, bounds, redacts, and freezes the report for preview.
3. Confirmation atomically writes the frozen report to the encrypted local queue.
4. The transport posts the same bytes and idempotency key to the receiver.
5. The server persists the encrypted report and returns a durable receipt.
6. The client stores that receipt before deleting its pending record.
7. A server worker creates or reconciles the ticket through an `IssueTracker` adapter.

Preparation returns a `PreparedSupportSubmission`. It freezes diagnostics and redaction output, so the content previewed
by the user is the content queued and retried. The value is accepted only by the `SupportClient` instance that prepared
it. Transport serialization adds no new diagnostic data.

## Dependency injection

The production composition uses:

- `FileSupportSubmissionStore`
- `SupportGatewayTransport`
- `URLSessionSupportHTTPClient`
- `SystemDiagnosticsProvider`
- optionally, `SupportLogBuffer`

Tests and specialized hosts can provide their own `SupportSubmissionStore`, `SupportTransport`, `SupportHTTPClient`,
`SupportRequestAuthorizer`, `SupportDiagnosticsProvider`, or `SupportLogSource`. Protocol requirements are asynchronous
where implementations may perform I/O and all dependencies are `Sendable`.

Each queue record carries an opaque configuration scope derived from the exact project and logical queue identifiers.
Store operations use scope plus report ID as the record identity. This keeps shared injected stores and case-colliding
logical queue names isolated, including when two clients generate the same UUID.

## Trust boundaries

The app is an untrusted network client. A modified build can invent project IDs, labels, timestamps, diagnostics, and
payloads. Therefore the receiving server, not the app:

- maps project IDs to fixed destinations;
- intersects requested labels with a server-side allowlist;
- applies request and field-size limits again;
- enforces rate limits and optional first-party authentication;
- holds destination credentials;
- treats every string as untrusted Markdown content.

The destination system is a separate privacy boundary. Prefer private support projects, limit collaborators, and
configure retention appropriate for customer support data. If a public issue destination is intentional, treat the
report message, submitted fields, and included diagnostics as public data; this choice is independent of whether the
app's source repository is public or private.

## Extending SupportKit

Use a custom diagnostic provider for an app-specific fact that is safe and useful:

```swift
import SupportKit

struct DatabaseHealthProvider: SupportDiagnosticsProvider {
    func collectDiagnostics() async -> [SupportDiagnostic] {
        [SupportDiagnostic(key: "Database migration", value: "42")]
    }
}
```

Use a custom authorizer to attach a short-lived assertion issued by infrastructure you control. Do not attach a static
secret shared by every app installation.

Implement a different `SupportTransport` only when its receiver can durably accept an idempotency key. A successful
return from that protocol means ownership has transferred to the receiver; it does not merely mean an HTTP socket was
opened.

On the server, implement the runtime-neutral storage, queue, authentication, and `IssueTracker` ports. The included
Cloudflare and GitHub implementations are adapters around those contracts; neither appears in the portable ingestion
or delivery state machine.
