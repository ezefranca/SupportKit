# Getting Started

Configure a support client, review a frozen report, and hand durable delivery to SupportKit.

## Overview

Add both `SupportKit` and `SupportKitUI` products when you want the ready-made SwiftUI form. Add only `SupportKit`
when your app provides its own interface.

### Configure the report pipeline

Create one validated ``SupportConfiguration`` for the application session. `projectID` is a non-secret routing value;
the receiver decides which allowlisted destination it represents.

```swift
func makeSupportClient(
    tokenProvider: @escaping SupportBearerTokenAuthorizer.TokenProvider
) throws -> SupportClient {
    guard let receiverURL = URL(string: "https://support.example.com/v1/reports") else {
        throw SupportConfigurationError.invalidEndpoint
    }

    let supportConfiguration = try SupportConfiguration(
        projectID: "com.example.reader",
        diagnostics: .default,
        delivery: DeliveryConfiguration(automaticallyDelivers: true)
    )
    let receiverConfiguration = try SupportGatewayTransport.Configuration(
        endpoint: receiverURL
    )

    return try SupportClient.live(
        configuration: supportConfiguration,
        transport: SupportGatewayTransport(
            configuration: receiverConfiguration,
            authorizer: SupportBearerTokenAuthorizer(tokenProvider: tokenProvider)
        )
    )
}

let supportClient = try makeSupportClient {
    try await supportIdentity.fetchShortLivedSupportToken()
}
```

Keep ``SupportClient`` alive while the app runs. The live factory creates an encrypted durable queue. No provider
credential belongs in `projectID`, the endpoint, app resources, or request headers. Use a server-side adapter to own
provider credentials. The placeholder token provider above should obtain a scoped, short-lived first-party assertion
or platform attestation; it must not return a provider credential shared by every app installation.

### Present a form

With the UI product imported, pass the same long-lived client to `SupportForm`:

```swift
import SupportKit
import SupportKitUI
import SwiftUI

struct HelpView: View {
    let supportClient: SupportClient

    var body: some View {
        SupportForm(client: supportClient)
    }
}
```

The standard form validates the draft, lets the user opt into diagnostics, and—by default—shows the exact redacted
payload before queueing it. A queued result means the report is safely stored, not necessarily remotely accepted.

### Integrate app lifecycle events

Call ``SupportClient/resumeDelivery()`` when the app enters the foreground or regains useful connectivity. Call
``SupportClient/pauseDelivery()`` when suspending in-process work. Pausing never deletes queued reports.

Observe ``SupportClient/events()`` to update app-specific UI after a queued report is accepted, scheduled for retry,
or retained for attention. Use ``SupportClient/pendingReportCount()`` for all retained reports and
``SupportClient/readyReportCount()`` for those in the automatic-delivery state.

## Next steps

- <doc:ConsentAndDiagnostics>
- <doc:OfflineDelivery>
- <doc:CustomTransports>
- <doc:SecurityAndPrivacy>
