# Forms and Themes

Choose between theming the ready-made form and composing a fully custom interface.

## Overview

``SupportForm`` provides the standard support workflow: editable fields, explicit diagnostic consent, optional payload
review, durable queueing, and delivery status. Configure its copy and fields through `SupportFormConfiguration`, and
its visual tokens through ``SupportFormTheme``.

### Apply a theme

``SupportFormTheme`` groups semantic colors, Dynamic Type fonts, spacing, corner radius, control height, and submit
button treatment. Start from its initializer defaults and override only the tokens that express the host app's design:

```swift
let theme = SupportFormTheme(
    tint: .indigo,
    rowBackground: .indigo.opacity(0.08),
    titleFont: .largeTitle.bold(),
    cornerRadius: 16,
    minimumControlHeight: 48
)

SupportForm(client: supportClient, theme: theme)
```

Prefer semantic colors that retain contrast in light, dark, increased-contrast, and differentiated-without-color
environments. Use text-style-relative custom fonts so Dynamic Type continues to scale.

### Define form fields

Construct the `SupportFormConfiguration` before creating `SupportClient`, then let the form read the client's validated
configuration:

```swift
let form = SupportFormConfiguration(
    additionalFields: [
        SupportFormField(
            id: "reply_address",
            label: "Reply address",
            kind: .email,
            maximumLength: 200,
            redactionPolicy: .secretsOnly
        )
    ],
    diagnosticsInitiallyIncluded: false,
    showsPayloadPreview: true
)

let configuration = try SupportConfiguration(
    projectID: "my-app",
    form: form
)
```

Email fields default to secrets-only redaction so an intentional contact address survives while credential-shaped
content is still removed. Free-form subject, message, diagnostics, and logs use standard privacy redaction.

For toggle fields, localize the values that appear in the preview and destination with `toggleTrueLabel` and
`toggleFalseLabel`. They default to “Yes” and “No”.

### Build a custom interface

Create one long-lived ``SupportFormModel`` and bind controls to its mutable state. Call
``SupportFormModel/prepareForSubmission()`` from the primary action. When the phase becomes
``SupportFormPhase/reviewing``, render the prepared submission's `preview` and call
``SupportFormModel/submitPrepared()`` only after explicit confirmation.

Disable actions while ``SupportFormModel/isBusy`` is `true`. Show queued results as saved locally, not necessarily
delivered, and use the accepted state for confirmed remote ownership. Call ``SupportFormModel/reset()`` after the user
finishes with a report.

> Important: Do not rebuild a prepared payload from visible strings after review. Submit the model's frozen
> ``SupportFormModel/preparedSubmission`` so the queued data remains identical to what the user approved.
