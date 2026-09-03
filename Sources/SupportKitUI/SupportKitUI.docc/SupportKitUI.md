# ``SupportKitUI``

Add a configurable SwiftUI support form backed by SupportKit's privacy and delivery pipeline.

## Overview

Create a long-lived `SupportClient`, then pass it to ``SupportForm``. The form uses the exact
`SupportFormConfiguration` validated by that client, lets the user opt into diagnostics, and previews the frozen
payload before it is queued.

Keep that client stable for the lifetime of one support flow. When the destination or project changes, pass a distinct
client instance; the ready-made form keys its editable state to client identity and starts a fresh flow rather than
submitting new fields through the previous client.

```swift
import SupportKit
import SupportKitUI
import SwiftUI

struct HelpView: View {
    let client: SupportClient

    var body: some View {
        SupportForm(client: client)
    }
}
```

Supply `SupportFormConfiguration` to the client's `SupportConfiguration` during application setup. The form reads
that validated value from the client. Supply a ``SupportFormTheme`` when presenting the form to customize colors,
typography, spacing, control sizing, and button treatment.

The form communicates immediate queueing outcomes through its `onSubmission` closure. It also observes delivery
events for the active report, so a queued state can become accepted or failed without application polling.

### Customize the ready-made form

```swift
let theme = SupportFormTheme(
    tint: .indigo,
    rowBackground: .indigo.opacity(0.08),
    titleFont: .largeTitle.bold(),
    cornerRadius: 16,
    submitButtonAppearance: .prominent
)

SupportForm(client: client, theme: theme) { result in
    // Record app-specific, non-sensitive telemetry if needed.
}
```

All default fonts support Dynamic Type. Custom fonts should use relative text styles so the form remains legible at
accessibility sizes. Color choices should preserve contrast in both light and dark appearances.

For complete layout control, bind your own controls to ``SupportFormModel`` and render its ``SupportFormPhase``. The
model preserves the same prepare-review-submit flow as the ready-made form.

## Topics

### Present the form

- ``SupportForm``
- ``SupportFormModel``
- ``SupportFormPhase``

### Learn the UI flow

- <doc:CustomizingTheForm>

### Customize appearance

- ``SupportFormTheme``

### Build a custom form

- ``SupportFormFieldState``
