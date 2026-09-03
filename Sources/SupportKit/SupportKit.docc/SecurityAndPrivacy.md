# Security and Privacy

Keep credentials off the device and make every collected value intentional.

## Overview

When using the included HTTPS transport, SupportKit sends reports to the fixed endpoint in
``SupportGatewayTransport/Configuration/endpoint``. The production receiver should authenticate the app using a
short-lived proof when appropriate, map the non-secret ``SupportConfiguration/projectID`` to an allowlisted
destination, and keep provider credentials server-side. Never embed a provider access token or private key in an
Apple-platform application.

Prefer a private support destination. If a server route intentionally creates issues in a public repository, the
message, submitted fields, and any included diagnostics become public. That destination policy is independent of
whether the app's source repository is public or private.

### Redact before persistence

``SupportRedactor`` applies mandatory credential patterns before configurable privacy rules. Mandatory rules remove
common authorization values, provider-token formats, JSON Web Tokens, URL credentials, and named secrets. They remain active
even when all optional ``RedactionConfiguration`` privacy toggles are disabled.

Standard redaction also removes configured categories such as email addresses, IP addresses, URL query values, and
common user-directory paths. Add narrowly scoped ``SupportRedactionRule`` values for application-specific secrets.
Redaction is defense in depth, not proof that arbitrary text is anonymous; avoid collecting unnecessary values.

### Ask before collecting diagnostics

``DiagnosticsConfiguration`` controls each built-in diagnostic category, log limits, value limits, and custom
providers. The ready-made UI makes diagnostics an explicit user choice and shows the frozen
``SupportPayloadPreview`` before queueing when preview is enabled.

Custom ``SupportDiagnosticsProvider`` implementations should return bounded, support-relevant values. Do not collect
passwords, authentication material, precise location, full file contents, or unrestricted logs. ``SupportLogBuffer``
redacts entries before retaining its bounded in-memory history.

### Protect queued reports

``SupportClient/live(configuration:transport:redactor:logSource:)`` creates an encrypted
``FileSupportSubmissionStore``. Queue records use authenticated encryption and Apple file-protection attributes where
available. Encryption keys are device-local and stored through Keychain Services. The store accepts only versioned,
authenticated envelopes; plaintext, corrupted, or relocated records fail closed and are quarantined. Treat destination
links returned by your receiver as user-visible data and accept only trusted HTTPS destinations in application UI.

Packaged macOS apps and extensions fail closed when the data-protection Keychain is unavailable. Only unbundled
command-line tools and SwiftPM test hosts may use the classic macOS Keychain compatibility path; SupportKit never falls
back to a key stored in preferences or a file.

The bundled privacy manifest conservatively marks Customer Support, Other Diagnostic Data, and the optional Email
Address category as linked to the user for app functionality, because a preserved reply address can associate the
report's contents. It declares no tracking or tracking domains.

> Note: Apps remain responsible for an accurate privacy manifest, retention policy, receiver access controls, and
> deletion procedures for support data after the receiver accepts a report.
