# Security policy

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability or include real customer data, credentials, or exploit
details in a GitHub discussion. Use GitHub's **Report a vulnerability** private reporting form for this repository.

Include the affected version, platform, impact, minimal reproduction, and whether you believe a credential or customer
report was exposed. You should receive an acknowledgment within five business days. Coordinated disclosure is
appreciated.

## Supported versions

Security fixes are provided for the latest tagged release. Confirm the issue against that version before reporting a
problem that may already be fixed.

## Deployment invariants

- Never embed a destination API token, GitHub App private key, installation token, shared server secret, or long-lived
  bearer credential in an app binary.
- Keep destination credentials behind a server-side adapter with the narrowest possible scope. For the included GitHub
  adapter, use a GitHub App installed only on intended repositories with **Issues: write**.
- Map `projectID` to an adapter and fixed destination exclusively in the server-side allowlist.
- With the included GitHub adapter, declare `repositoryVisibility` as `private` or `public` in every immutable route;
  the adapter rejects a metadata mismatch. Prefer a private support destination and protect its issue, audit, and
  collaborator access. A public destination exposes report content and included diagnostics to everyone. The app's
  source repository may be public or private independently.
- Store secrets with the host's secret manager. The optional Cloudflare adapter uses `wrangler secret put`. Do not
  commit `.dev.vars`, PEM files, database exports, or support payloads.
- Require HTTPS, validate payload digests, bound every request and string, intersect labels with server policy, and treat
  client timestamps and content as untrusted.
- Add platform attestation or a short-lived first-party assertion for higher-risk public apps. A static app-wide API key
  does not authenticate an installation.
- Monitor rate limits, dead letters, manual-review reports, credential use, and unusual project traffic.
- Rotate destination credentials and report-encryption keys through a rehearsed process. Preserve prior data-encryption
  keys until records written with them have been delivered or purged.

## Threat model

The reference design addresses credential extraction from app bundles, casual spam, cross-project authorization,
replay with altered payloads, duplicate client requests, common accidental secret leakage in text, transient network
loss, corrupted queue files, open redirects, oversized responses, and overbroad repository routing.

It does not claim to prevent a determined attacker from modifying a public client, to make regex redaction complete, to
guarantee exactly-once behavior from an upstream API without native idempotency, or to keep data private after an
authorized repository collaborator copies it. Operational access control, retention, monitoring, dependency updates,
and incident response remain required.

## Security review checklist

Before production:

1. Review `Documentation/Privacy.md` against the actual form and providers.
2. Run `scripts/quality.sh` and the server reference's `npm run check`.
3. Verify no secret appears in git history, build settings, Info.plist, entitlements, sample code, or remote config.
4. Verify server-side project/destination mappings, expected repository visibility, and allowed labels independently
   of the client configuration.
5. Exercise offline recovery, server replay, altered-payload conflict, cross-project denial, rate limits, ambiguous
   destination responses, reconciliation, and dead-letter paths.
6. Confirm logs contain request IDs and safe error codes, never report bodies or authorization headers.
7. Enable GitHub private vulnerability reporting, secret scanning, dependency alerts, and branch protection.
8. Document incident contacts, key rotation, customer notification, deletion, and recovery procedures.

The Swift API intentionally makes secure deployment the shortest path: the production transport takes an HTTPS server
URL and non-secret project ID, not a destination credential. The portable server core depends on interfaces; the
included Cloudflare host and GitHub issue tracker are independently replaceable adapters.
