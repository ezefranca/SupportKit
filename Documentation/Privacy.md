# Privacy guide

Support reports are user content and may contain sensitive information even when the UI asks only for a bug
description. Treat the complete path—from the text field through local storage, server logs, durable storage, queues,
and the chosen ticket destination—as a customer-data system.

## Defaults

SupportKit's default diagnostic configuration includes OS version, hardware model, app version/build, thermal state,
and Low Power Mode. Locale, time zone, logs, and custom diagnostics are off. The standard form leaves all diagnostics
off until the user opts in and previews the frozen payload.

No persistent device identifier, advertising identifier, contacts, location, photo, microphone input, or unified log is
collected by SupportKit.

Thermal state is a coarse enum supplied by `ProcessInfo`. SupportKit does not attempt private API access to a literal
temperature sensor.

## Data minimization checklist

- Ask only for fields support staff will act on.
- Keep diagnostics optional and explain their purpose next to the toggle.
- Do not pre-enable diagnostic consent merely to increase collection.
- Prefer state categories to raw identifiers or complete database records.
- Bound custom provider output and breadcrumb volume.
- Never record authentication material, URLs with private query values, health data, document contents, or user input in
  breadcrumbs.
- Prefer a private receiving support project. If the destination is public, disclose that the report and included
  diagnostics are publicly readable and collect only content suitable for publication.
- Purge server payloads and destination tickets according to a published retention schedule.
- Give users a route to request deletion.

## Redaction

`SupportRedactor` runs before a prepared report is queued. The default rules detect common credential formats, bearer
headers, JWT-like strings, credentialed URLs, common secret assignments, email addresses, IP addresses, URL query
values, and common Apple user-container paths. Sensitive breadcrumb metadata keys are replaced wholesale.

Pattern-based redaction is conservative by design and imperfect. It can remove useful values (for example, an email
address intentionally entered as contact information), and it cannot recognize every application-specific secret. Add
focused `SupportRedactionRule` values for your domain, test them with representative data, and minimize collection at
the source.

If your support flow must preserve an intentional contact address, design an explicit, consented server-side field and
review your disclosure rather than weakening redaction across logs and free-form text.

## Apple privacy manifest

The package bundles `PrivacyInfo.xcprivacy` declaring:

- Customer Support data, used for App Functionality;
- Other Diagnostic Data, used for App Functionality;
- Email Address, because an explicitly configured email field can preserve a reply address for App Functionality;
- all three categories conservatively marked as linked to the user, because an optional email address can associate the
  support message and included diagnostics with a person;
- no tracking and no tracking domains.

This declaration describes SupportKit's behavior, not the complete host app. Authentication added through a custom
authorizer, custom diagnostic providers, server-side enrichment, linking reports to an account, analytics, retention,
or other SDKs can change the host app's required privacy answers. Generate an Xcode privacy report for the final app and
keep App Store privacy details and the public privacy policy consistent with the deployed configuration.

## Storage and transport

The client seals redacted reports with AES-GCM before atomically writing them under Application Support. Its random
256-bit install key is stored as an `AfterFirstUnlockThisDeviceOnly` Keychain item; authenticated additional data binds
each ciphertext to its queue and file identity. The queue is excluded from backup and also applies
`completeUntilFirstUserAuthentication` file protection on supported Apple platforms. Encryption and file protection do
not protect data while the running app is legitimately reading it, so the host app's sandbox, device passcode, and
runtime integrity remain part of the boundary.

On macOS, packaged apps and extensions use the data-protection Keychain and fail closed if it is unavailable. The
classic macOS Keychain compatibility path is limited to unbundled command-line tools and SwiftPM test hosts, which do
not have an application entitlement context. SupportKit never replaces a failed Keychain operation with a key stored
in preferences, a file, or source code.

The server boundary must accept HTTPS only from production clients and encrypt retained report payloads before durable
storage. Avoid logging request bodies. Destination tickets are durable copies outside the server retention job, so
their access and deletion policy must be managed separately. The included Cloudflare and GitHub adapters implement
these boundaries, but hosts and destinations remain replaceable.

## User-facing disclosure starter

Adapt this to the actual app and legal requirements:

> When you contact support, we receive the message and fields you submit. If you choose to include diagnostics, you can
> review the exact technical details before sending. We use this information only to respond to and troubleshoot your
> request, restrict access to support staff, and retain it according to our support-data policy.

This is product guidance, not legal advice.
