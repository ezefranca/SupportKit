# Consent and Diagnostics

Collect only bounded support context the user intentionally approves.

## Overview

Diagnostics are disabled in each ``SupportDraft`` unless the caller sets `includesDiagnostics`. The standard UI
exposes that choice through localized copy in ``SupportFormConfiguration`` and can show the exact frozen payload
before persistence. Keep consent specific to the report; do not treat a previous choice as blanket permission.

### Choose built-in categories

``DiagnosticsConfiguration`` independently controls operating-system, device, app-version, thermal, low-power,
locale, time-zone, and log information. It also caps the number and length of collected values.

```swift
let diagnostics = DiagnosticsConfiguration(
    includesOperatingSystem: true,
    includesDeviceModel: true,
    includesApplicationVersion: true,
    includesThermalState: false,
    includesLowPowerMode: false,
    includesLocale: true,
    includesTimeZone: true,
    includesLogs: true,
    maximumLogEntries: 50,
    maximumLogMessageLength: 500
)
```

Thermal state is a coarse system condition, not a hardware temperature reading. SupportKit does not use private APIs
to infer device temperature.

### Supply safe custom diagnostics

Implement ``SupportDiagnosticsProvider`` for app-specific, inexpensive values such as an import format or database
schema version. Mark values ``SupportDiagnostic/Sensitivity/potentiallyIdentifying`` when they can distinguish an
environment. Return bounded summaries instead of full documents, identifiers, paths, or unrestricted state dumps.

Use ``SupportLogBuffer`` as a bounded, redacting source rather than attaching arbitrary log files. Credential
redaction is mandatory, but pattern matching cannot prove arbitrary text is anonymous. Avoid recording secrets in the
first place.

### Preserve intentional contact data

An email form field defaults to ``SupportFormField/RedactionPolicy/secretsOnly`` so an address entered for a reply can
survive while credential-shaped material is still removed. Subject, message, diagnostics, and logs use standard
privacy redaction. Explain any contact-data use and retention in the host app's privacy disclosure.
