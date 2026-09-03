# SupportKit

[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138.svg?logo=swift)](https://swift.org)
[![CI](https://github.com/ezefranca/SupportKit/actions/workflows/ci.yml/badge.svg)](https://github.com/ezefranca/SupportKit/actions/workflows/ci.yml)
[![Documentation](https://img.shields.io/badge/DocC-Documentation-blue)](https://ezefranca.com/SupportKit/documentation/supportkit/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

SupportKit is a Swift package for collecting and delivering support reports from Apple apps. It includes a
customizable SwiftUI form, opt-in diagnostics, redaction, an encrypted offline queue, duplicate controls, and a
vendor-neutral server core.

Your app repository can be public or private. SupportKit routes by a non-secret project ID, so the support-ticket
destination is a separate deployment choice. The included GitHub adapter supports private or public destination
repositories, but every immutable route must explicitly declare the expected visibility and delivery fails closed if
GitHub reports a mismatch. Private is the recommended default.

> [!WARNING]
> GitHub issues in a public destination repository expose the complete support message, submitted fields, and any
> user-approved diagnostics to everyone. Choose `public` only as a deliberate product and privacy policy; the app's
> source repository visibility does not require the support destination to have the same visibility.

> [!IMPORTANT]
> SupportKit does **not** accept a GitHub token in the app. A token shipped in an IPA, app bundle, source
> file, or remotely delivered configuration is recoverable by an attacker. The app receives only a non-secret project
> ID and HTTPS receiver URL; a server-side destination adapter keeps any provider credential and routing allowlist.

## What it includes

- `SupportKit`: form models, redaction, diagnostics, bounded breadcrumbs, durable queue, retry policy, transport
  protocols, and the HTTPS receiver client.
- `SupportKitUI`: a ready-made SwiftUI form whose fields, copy, colors, fonts, spacing, and button treatment are
  configurable.
- `Gateway/src/ServerCore`: runtime-neutral TypeScript contracts and orchestration for authenticated ingestion, durable
  idempotency, encryption, outbox delivery, and ambiguous-result reconciliation.
- `Gateway/src/adapters`: a GitHub App issue-tracker adapter and an optional Cloudflare host adapter using D1, Queues, and
  edge rate limits. Either boundary can be replaced independently.
- Swift Testing coverage, a privacy manifest, DocC guides, security guidance, and pinned GitHub Actions.

## Requirements

- Swift 6.2 / Xcode 26 or newer
- iOS 17+, iPadOS 17+, macOS 14+, tvOS 17+, watchOS 10+, or visionOS 1+

The form targets SwiftUI. The core module can also be used programmatically.

## Installation

In Xcode, choose **File → Add Package Dependencies** and enter:

```text
https://github.com/ezefranca/SupportKit.git
```

Add `SupportKitUI` to an app target. It brings in the core `SupportKit` product.

Or add it to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/ezefranca/SupportKit.git", from: "1.0.0"),
]
```

## Quick start

Create one client for the life of the app. The standard form reads the client's validated form definition, so rendering
and submission always agree.

```swift
import SupportKit
import SupportKitUI
import SwiftUI

struct SupportFeature {
    let client: SupportClient

    static func live(
        tokenProvider: @escaping SupportBearerTokenAuthorizer.TokenProvider
    ) throws -> Self {
        guard let receiverURL = URL(string: "https://support.example.com/v1/reports") else {
            throw SupportConfigurationError.invalidEndpoint
        }
        let form = SupportFormConfiguration()
        let configuration = try SupportConfiguration(
            projectID: "my-app",
            form: form
        )
        let receiver = try SupportGatewayTransport.Configuration(
            endpoint: receiverURL
        )
        let client = try SupportClient.live(
            configuration: configuration,
            transport: SupportGatewayTransport(
                configuration: receiver,
                authorizer: SupportBearerTokenAuthorizer(tokenProvider: tokenProvider)
            )
        )
        return Self(client: client)
    }
}

struct HelpView: View {
    let support: SupportFeature

    var body: some View {
        SupportForm(client: support.client)
            .task {
                await support.client.resumeDelivery()
            }
    }
}
```

Handle bootstrap errors in your dependency container and provide a normal in-app fallback, such as a support website
or email address. Do not use `try!` or terminate the app because local storage is unavailable.

## Customize the form

```swift
let form = SupportFormConfiguration(
    title: "Talk to Acme",
    introduction: "Describe the problem and we’ll take a look.",
    additionalFields: [
        SupportFormField(
            id: "area",
            label: "Area",
            kind: .picker(options: [
                .init(id: "sync", label: "Sync"),
                .init(id: "billing", label: "Billing"),
                .init(id: "other", label: "Other"),
            ]),
            isRequired: true,
            defaultValue: "sync"
        ),
        SupportFormField(
            id: "steps",
            label: "Steps to reproduce",
            prompt: "1. Open…",
            kind: .multiline,
            maximumLength: 4_000
        ),
        SupportFormField(
            id: "follow_up",
            label: "May we follow up?",
            kind: .toggle,
            toggleTrueLabel: "Yes",
            toggleFalseLabel: "No"
        ),
    ]
)

let theme = SupportFormTheme(
    tint: .indigo,
    rowBackground: .indigo.opacity(0.08),
    titleFont: .largeTitle.weight(.semibold),
    fieldFont: .body,
    cornerRadius: 16,
    verticalSpacing: 14
)

let configuration = try SupportConfiguration(
    projectID: "my-app",
    form: form
)
let client = try SupportClient.live(configuration: configuration, transport: transport)

SupportForm(client: client, theme: theme)
```

Every static interface string on the standard form and preview is configurable through `SupportFormConfiguration` or
its field definitions, so apps can localize the copy without forking the UI. For a completely bespoke interface,
build a `SupportDraft` and call `SupportClient` directly.

## Diagnostics and consent

Diagnostics are granular. The default is useful but intentionally conservative:

| Category | Default | Notes |
|---|---:|---|
| OS version | On | Coarse platform state |
| Hardware model | On | For example, an iPhone model identifier |
| App version and build | On | Read from the host app bundle |
| Thermal state | On | Nominal, fair, serious, or critical |
| Low Power Mode | On | Enabled or disabled |
| Locale and time zone | Off | Potentially identifying |
| Breadcrumb logs | Off | Opt in explicitly and use the bounded buffer |
| Custom providers | None | Host-controlled, `Sendable` providers |

Apple platforms do not expose a supported API for literal device temperature. SupportKit reports
`ProcessInfo.thermalState`, which is the appropriate public signal.

The standard form leaves diagnostics off until the user opts in and shows the frozen report content before queueing.
Protocol metadata (schema, IDs, timestamp, routing ID, labels, and hashes) is not shown as user content. Configure
collection separately from consent:

```swift
let diagnostics = DiagnosticsConfiguration(
    includesOperatingSystem: true,
    includesDeviceModel: true,
    includesApplicationVersion: true,
    includesThermalState: true,
    includesLowPowerMode: false,
    includesLocale: false,
    includesTimeZone: false,
    includesLogs: true,
    maximumLogEntries: 30,
    maximumLogMessageLength: 500
)
```

### Safe breadcrumbs

SupportKit never scrapes unified logging or arbitrary files. Apps explicitly record bounded breadcrumbs, which are
redacted before entering the in-memory buffer:

```swift
let breadcrumbs = SupportLogBuffer(capacity: 200)

await breadcrumbs.record(
    .notice,
    category: "sync",
    message: "Upload paused",
    metadata: ["retryCount": "2", "authorization": "sensitive value"]
)
```

Pass the buffer as `logSource` when creating `SupportClient`. Never log credentials, health data, full URLs with query
values, document contents, or identifiers merely because redaction exists. Redaction is defense in depth, not consent.

## Offline delivery and duplicate behavior

Submitting queues the frozen, redacted report before networking starts. Pending reports survive process termination and
are retried with bounded exponential backoff. Call `resumeDelivery()` when the app becomes active; apps with permitted
background execution may also call `flush()` from their own background task.

SupportKit suppresses matching pending or recently accepted content locally. The receiver atomically accepts each
report ID and payload digest. Because GitHub does not support idempotency keys for issue creation, the adapter embeds a
stable marker and checks for it after ambiguous failures. This minimizes duplicates but cannot guarantee exactly-once
delivery across every upstream failure.

Storage, processes, accounts, and networks can still fail. SupportKit queues before sending, returns explicit outcomes,
quarantines corrupt records, bounds resource use, and contains no intentional process traps.

See [Reliability](Documentation/Reliability.md) for the exact state and retry semantics.

## Deploy the server boundary

An intermediary you control is required if a native app should create tickets with a secret provider credential. The
intermediary is an architectural boundary, not a hosting-vendor requirement. It owns:

- the allowlisted mapping from a non-secret `projectID` to a destination;
- any destination-provider credential;
- atomic acceptance and payload-digest conflict detection;
- encrypted report bodies and retention cleanup;
- per-actor and per-project rate limiting;
- queued ticket creation, retries, and reconciliation.

The included server core depends only on storage, outbox, queue, authentication, encryption, clock, and `IssueTracker`
ports. Follow [Gateway/README.md](Gateway/README.md) to implement those ports on your infrastructure or deploy the
included Cloudflare adapter. Cloudflare is optional. GitHub is also an adapter: replace it with another issue tracker
without changing the Swift package or portable delivery state machine.

When using the included GitHub adapter, install its GitHub App only on intended repositories, grant only **Issues:
write**, declare each immutable route's expected repository visibility, and never copy its private key or installation
token into the Apple app. Prefer a private support destination; a public one publishes report content and diagnostics.

Anonymous ingestion exists only as an explicit local/evaluation mode; rate limits do not make an anonymous client
authentic. Production apps should implement `SupportRequestAuthorizer` using a short-lived, project-scoped first-party
token or platform attestation and enforce the same project scope at the server.

## Security and privacy

- The URLSession client uses an ephemeral configuration, HTTPS, strict response limits, and rejects redirects.
- Reports are redacted before durable storage or transport. Default rules cover common GitHub tokens, bearer tokens,
  JWTs, credentialed URLs, common secret assignments, email addresses, IP addresses, query values, and user paths.
  An explicitly configured `.email` field preserves its validated reply address while still applying mandatory and
  app-specific credential rules; the preview makes that exception visible.
- The local queue is AES-GCM sealed with a random 256-bit install key held in Keychain, binds ciphertext to its queue
  and file identity, is excluded from backup, is atomically written, and also uses Apple file protection on supported
  platforms. Packaged macOS apps and extensions fail closed if the data-protection Keychain is unavailable; only
  unbundled command-line tools and SwiftPM test hosts may use the classic macOS Keychain compatibility path.
- The included privacy manifest conservatively declares Customer Support, Other Diagnostic Data, and an optional Email
  Address as linked to the user for app functionality, with no tracking. Host apps remain responsible for their complete
  App Store privacy answers and privacy policy.
- Prefer private receiving repositories with tightly limited collaborator access and an explicit retention policy. If
  a public destination is intentional, clearly disclose that report content and included diagnostics become public.

Read [SECURITY.md](SECURITY.md) before deployment and [Privacy](Documentation/Privacy.md) before enabling additional
diagnostics or logs.

### Unsafe vs. safe credential setup

```swift
// Unsafe: every user can recover this credential from the shipped app.
let embeddedGitHubToken = "do-not-put-a-token-here"

// Safe: the app knows only an HTTPS receiver and a non-secret routing ID.
let configuration = try SupportConfiguration(projectID: "my-app")
guard let receiverURL = URL(string: "https://support.example.com/v1/reports") else {
    throw SupportConfigurationError.invalidEndpoint
}
let receiver = try SupportGatewayTransport.Configuration(
    endpoint: receiverURL
)
let authorizer = SupportBearerTokenAuthorizer {
    try await supportIdentity.fetchShortLivedSupportToken()
}
let transport = SupportGatewayTransport(
    configuration: receiver,
    authorizer: authorizer
)
```

## Programmatic API

```swift
let result = await client.submit(
    SupportDraft(
        subject: "Sync stopped",
        message: "The progress indicator has not moved for ten minutes.",
        responses: ["category": "problem"],
        includesDiagnostics: true
    )
)

switch result {
case let .queued(reportID):
    print("Safely queued: \(reportID)")
case let .duplicatePending(reportID):
    print("Already queued: \(reportID)")
case let .duplicateAccepted(receipt):
    print("Already accepted: \(receipt.reportID)")
case let .rejected(reason):
    print(reason.localizedDescription)
}
```

## Documentation

- [Hosted DocC API and guides](https://ezefranca.com/SupportKit/documentation/supportkit/)
- [Hosted SupportKitUI API and form guides](https://ezefranca.com/SupportKit/documentation/supportkitui/)
- [Architecture](Documentation/Architecture.md)
- [Reliability model](Documentation/Reliability.md)
- [Privacy guide](Documentation/Privacy.md)
- [Security policy and deployment checklist](SECURITY.md)
- [Gateway deployment](Gateway/README.md)
- [Contributing](CONTRIBUTING.md)

## License

SupportKit is available under the MIT License. See [LICENSE](LICENSE).
