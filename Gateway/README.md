# SupportKit Server Reference

A portable server core plus optional adapters for accepting SupportKit reports without shipping service credentials in an app. The included deployment uses Cloudflare Workers, D1, and Queues; the included destination adapter creates issues in allowlisted GitHub repositories with an explicit private-or-public visibility expectation and a GitHub App.

Cloudflare and GitHub are adapters, not core dependencies. This repository currently ships and integration-tests the Cloudflare + GitHub composition. It does **not** claim that a runnable self-hosted adapter is included.

## Architecture and portability boundary

```text
SupportKit client
  -> host HTTP/auth/rate-limit adapter
  -> ServerCore ingestion service
  -> ReportStore.acceptWithOutbox (atomic durability boundary)
  -> OutboxStore + DeliveryPublisher adapters
  -> ServerCore delivery state machine
  -> IssueTracker adapter
```

`src/ServerCore/index.ts` is the public barrel for the host-neutral domain, ports, errors, and services. It contains no `Env`, D1, Cloudflare Queue, or GitHub configuration types. Its explicit ports are:

- `RequestAuthenticator`
- `ProjectRegistry<TTarget>` and `ProjectAdmissionControl`
- `ReportStore` and `OutboxStore`
- `DeliveryPublisher`
- `PayloadCipher` and `MarkerFactory`
- `IssueTracker<TTarget>` / `IssueTrackerSession`
- `Clock` and `IdentifierGenerator`

Included adapters live under `src/adapters/`:

- `cloudflare/`: D1 persistence, Queue publishing/consumption, bounded HTTP handling, and edge rate-limit helpers.
- `github/`: a strict `IssueTracker<GitHubTarget>` implementation using GitHub App installation authentication.
- `auth/`: a project-scoped short-lived RS256/JWKS `RequestAuthenticator`.
- `crypto/`: Web Crypto AES-GCM payload protection and an independent HMAC marker factory.
- `web/`: bounded Fetch response helpers shared by provider adapters.

`src/index.ts` is only the Cloudflare composition root. Run `npm run typecheck:core` and `npm run test:core` to verify the ServerCore with no Cloudflare globals; the core test uses a fake IssueTracker and proves ambiguous delivery can reconcile without calling create twice.

### Building another host adapter

A Node 22 + PostgreSQL deployment would implement `ReportStore.acceptWithOutbox` as one SQL transaction, implement the remaining store transitions with conditional updates, poll the outbox into a durable at-least-once transport, and invoke `processDelivery`. BullMQ, RabbitMQ, SQS, or a PostgreSQL job table can implement `DeliveryPublisher`; another ticket system implements `IssueTracker`.

Those choices have materially different lease, transaction, and retry behavior. They are intentionally documented as an adapter map—not represented as a working Docker/self-host distribution. Preserve these invariants in any adapter:

1. A report and outbox row commit atomically before returning accepted.
2. Idempotency is unique per project and resolves the existing record by idempotency key, even when the submitted report ID differs.
3. Acceptance pins an immutable destination/label routing revision, encryption-key version, marker-key version, and payload purge deadline.
4. State becomes `creating` durably immediately before the non-idempotent destination call.
5. A lost/timeout/5xx create outcome goes to marker reconciliation and never to a blind second create.
6. Authorization and reconciliation leases and every reconciliation transition are conditional and concurrency-safe.
7. Reconciliation has a durable not-before time; duplicate queue messages cannot consume the search budget during provider indexing delay.

## Why a server is required

A GitHub token, API key, or shared bearer secret embedded in an iOS/macOS application can be extracted. SupportKit clients send only a logical `projectID`; destination routing and provider credentials remain server-side.

Production client authentication is not an app-wide secret either. The included adapter verifies a short-lived assertion issued by your first-party identity/App Attest service. The checked-in Cloudflare configuration fails closed until a real issuer is configured.

## Delivery and duplicate safety

The included Worker returns `202` only after the encrypted report and outbox row are durable in one atomic D1 batch. A scheduled handler republishes stranded outbox rows and purges retained payloads at the deadline calculated from the project retention policy when each report was first accepted. The deadline is a hard ceiling even for a nonterminal report; a later create that still needs a purged body fails to manual review instead of retaining customer data longer. Later configuration or duplicate replays cannot extend that deadline; an operator may explicitly shorten it.

Cloudflare Queues are at-least-once and GitHub's create-issue API has no idempotency key. The provider-neutral state machine therefore:

1. Leases the stored report.
2. Opens and validates the configured IssueTracker target.
3. Stores `creating` immediately before calling `IssueTrackerSession.create`.
4. Includes a deterministic HMAC-authenticated marker in the destination body.
5. Retries only outcomes known not to have created an item.
6. Reconciles transport loss, malformed success responses, timeouts, and 5xx responses by marker; it never blindly calls create again.
7. Atomically leases one due marker search at a time and spaces misses by ten minutes, regardless of duplicate Queue messages.
8. Moves unresolved ambiguous outcomes to `manual_review` after eight completed, spaced searches.

Every result of a reconciliation search—including delivered, retry, miss count, and manual review—must present the same current lease token. A worker whose lease expired cannot overwrite a newer worker's result. `delivered` is monotonic and authoritative.

Third-party operations can still fail. The server provides durable acceptance, retryable delivery, idempotent client replay, and duplicate-safe handling of ambiguous outcomes. It sends uncertain cases to manual review instead of risking a duplicate.

## HTTP API

### `POST /v1/reports`

Required headers:

- `Content-Type: application/json`
- `Idempotency-Key: <lowercase canonical report UUID>`
- `X-SupportKit-Payload-SHA256: <lowercase SHA-256 of the exact raw JSON bytes>`
- `Authorization: Bearer <short-lived first-party assertion>` when production authentication is required

The payload is limited to 256 KiB and must contain exactly this camel-case Swift `SupportSubmission` shape:

```json
{
  "schemaVersion": 1,
  "id": "00000000-0000-4000-8000-000000000001",
  "idempotencyKey": "00000000-0000-4000-8000-000000000001",
  "projectID": "example.app",
  "createdAt": "2026-09-03T12:00:00Z",
  "title": "Cannot sign in",
  "message": "The sign-in button does not respond.",
  "responses": [
    { "id": "contact", "label": "Contact", "value": "user supplied value" }
  ],
  "diagnostics": [
    { "key": "OS", "value": "iOS 27.0", "sensitivity": "standard" }
  ],
  "labels": ["bug"],
  "contentFingerprint": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
```

`id` may contain uppercase UUID hexadecimal because Swift's encoder does; the server normalizes it. `idempotencyKey` and its header must be lowercase and identify the same report. `contentFingerprint` is a semantic duplicate fingerprint and is distinct from the header digest of exact raw request bytes.

The core hashes raw bytes before JSON parsing. Unknown fields, malformed dates, forbidden controls, oversized values, duplicate response IDs/labels, and unsupported diagnostic sensitivities are rejected. A client never supplies a repository/provider route. Requested labels are intersected with the server allowlist, so unapproved labels are ignored.

```json
{
  "reportID": "00000000-0000-4000-8000-000000000001",
  "status": "accepted",
  "acceptedAt": "2026-09-03T12:01:00.000Z",
  "destinationReference": null,
  "destinationURL": null
}
```

- New durable report: `202`, status `accepted`.
- Byte-identical replay: `200`, status `duplicate`.
- Reused idempotency key with changed report identity/raw bytes: `409 idempotency_conflict`.

Destination references and URLs are stored for operators but intentionally remain `null` in untrusted client receipts, regardless of repository visibility. Exposing them would reveal server-side routing coordinates. A future customer-facing status link should be a separately configured, explicitly public project policy—not the adapter's internal destination URL.

### `GET /v1/reports/{reportID}?projectID={projectID}`

Returns `accepted`, `delivered`, or `needsAttention`, with the same null destination fields in the public response. It never returns message or diagnostic content. Authentication, project scope, and edge/actor/project rate limits apply. The opaque UUID is defense-in-depth, not authorization.

### `GET /healthz`

Unauthenticated liveness only. It intentionally does not probe storage, a destination provider, or the identity service.

## First-party authentication boundary

The included Cloudflare config has `AUTH_REQUIRED=true`. Replace:

- `AUTH_JWT_ISSUER`: exact `iss`, including any trailing slash.
- `AUTH_JWT_AUDIENCE`: required `aud`.
- `AUTH_JWKS_URL`: HTTPS JSON Web Key Set URL.

Accepted JWTs must use `RS256`, carry non-empty `kid` and `sub`, match issuer/audience, contain integer `iat`/`exp`, and live for at most ten minutes. They must include `supportkit_project` as one project ID or an array of at most 16 unique project IDs. Both report submission and status lookup enforce that scope; a token for one app cannot access another configured app.

The verifier permits 60 seconds of clock skew, bounds JWKS responses, rejects redirects, caches validated public keys according to `Cache-Control: max-age` capped at five minutes, coalesces concurrent refreshes, and rate-bounds refresh on an unknown `kid`. Invalid assertions return `401`; unavailable/misconfigured verification returns retryable `503`.

A recommended Apple flow is:

1. The app obtains an App Attest assertion for a server challenge.
2. Your first-party service verifies it and issues a short-lived project-scoped JWT for this audience.
3. The app supplies that JWT for report and status calls.

For another assertion format, inject a verifier into `JWKSRequestAuthenticator` or implement the `RequestAuthenticator` port. Keep failure closed in production. Never replace it with a static secret shipped in the app.

For local evaluation only, use `AUTH_REQUIRED=false`. The adapter then ignores `Authorization`, returns an explicitly unscoped anonymous principal, and relies on pre-authentication IP, actor, and project rate limits. Never expose that mode as the production boundary; add Cloudflare WAF/abuse rules appropriate to your threat model.

## Included GitHub IssueTracker adapter

1. Create a GitHub App owned by the organization that owns the support repositories.
2. Grant repository **Issues: Read and write** plus default metadata access. No webhook is required.
3. Install it only on repositories that may receive reports.
4. Generate an App private key and record the App client ID and each installation ID.

The adapter mints installation tokens server-side, restricts them to the configured repository, and requests only issue access. Every immutable route must set `repositoryVisibility` to exactly `private` or `public`; there is no implicit `any` mode. Before issue creation and before every reconciliation search, the adapter verifies the exact repository identity and GitHub's coherent `private`/`visibility` metadata. A mismatch fails closed. API base configuration is pinned to `https://api.github.com` to prevent credential exfiltration through a misconfigured endpoint.

> [!WARNING]
> GitHub cannot make an individual issue private inside a public repository. With `repositoryVisibility: "public"`,
> every support message, submitted field, and included diagnostic placed in the issue is publicly readable. The checked-in
> examples intentionally use `private`; choose `public` only with an explicit disclosure, consent, and retention policy.
> The app source repository may independently be public or private and does not determine this destination setting.

Projects point at append-only routing revisions. Each revision pins the generic adapter/config envelope and both label sets:

```json
{
  "routing_revision": 1,
  "destination_adapter": "github",
  "destination_config_json": {
    "owner": "example",
    "repository": "private-support",
    "installationID": "1234",
    "repositoryVisibility": "private"
  }
}
```

`projects.current_routing_revision` selects the revision for new reports. `reports.routing_revision` pins the accepted revision, and delivery resolves that exact row—it never falls forward to the current route. Repository visibility is delivery-affecting policy, so changing it also requires a new route revision. Insert and verify a new `project_routes` row first, then update `current_routing_revision`. Existing reports continue on their accepted route. If that immutable route cannot be resolved or its expected visibility no longer matches, delivery fails closed rather than silently rerouting. `examples/register-project.sql` shows initial registration; `examples/add-routing-revision.sql` shows the safe ordered update and guards against racing operator edits. Migration `0003_explicit_github_visibility.sql` records legacy routes as `private`, matching the earlier adapter's only permitted behavior; it does not create a fallback for new configuration.

## Included Cloudflare host setup

Prerequisites: Node.js 22+, a Cloudflare account with Workers, D1, and Queues, and Wrangler authentication.

```sh
npm ci
npx wrangler d1 create supportkit-gateway
npx wrangler queues create supportkit-reports
npx wrangler queues create supportkit-reports-dlq
```

Copy the D1 UUID into `wrangler.jsonc`. Keep producer/consumer/dead-letter names consistent. Choose three stable rate-limit `namespace_id` values that do not collide with another limiter in your account.

Create two independent random 32-byte base64url values by running this twice:

```sh
openssl rand -base64 32 | tr '+/' '-_' | tr -d '='
```

Upload secrets interactively. Piping a local key file keeps its content out of shell history:

```sh
npx wrangler secret put GITHUB_APP_CLIENT_ID
npx wrangler secret put GITHUB_APP_PRIVATE_KEY < /absolute/path/to/github-app-private-key.pem
npx wrangler secret put REPORT_ENCRYPTION_KEY_RING
npx wrangler secret put ISSUE_MARKER_KEY_RING
```

Each key-ring secret is bounded JSON containing at most 16 retained versions. Keys are 32-byte base64url values and versions are positive integers:

```json
{"activeVersion":2,"keys":{"1":"OLD_BASE64URL_KEY","2":"NEW_BASE64URL_KEY"}}
```

`REPORT_ENCRYPTION_KEY_RING` protects retained reports with AES-256-GCM and version-bound, record-bound associated data. `ISSUE_MARKER_KEY_RING` authenticates reconciliation markers with HMAC-SHA-256. Use unrelated key material for the two rings. New reports persist both active versions; decrypt and marker lookup select the persisted version. A duplicate replay never changes those versions. Missing referenced versions fail closed to manual review. The GitHub parser accepts GitHub's PKCS#1 and PKCS#8 PEM encodings.

To rotate either ring, first upload an expanded ring that retains the old `activeVersion` and includes the new key, exercise an authenticated canary report, and inspect Worker logs. Then upload the same ring with the new version active. Before removing an old encryption key, this query must return zero for that version:

```sql
SELECT COUNT(*) FROM reports
WHERE encryption_version = 1 AND payload_ciphertext IS NOT NULL;
```

Before removing an old marker key, this query must return zero for nonterminal create outcomes:

```sql
SELECT COUNT(*) FROM reports
WHERE marker_version = 1
  AND status NOT IN ('delivered', 'permanent_failure', 'manual_review');
```

Keep an old marker key longer if operators may still need to investigate its hidden marker. Removing an in-use version does not fall back to another key.

Apply the migration, edit a copy of the example for each project, and register it:

```sh
npm run migrate:remote
npx wrangler d1 execute supportkit-gateway --remote --file ./path/to/register-project.sql
```

Configure the real JWT issuer/audience/JWKS, keep `AUTH_REQUIRED=true`, and deploy:

```sh
npm run check
npm run deploy
```

## Development and verification

Copy `.env.example` to `.dev.vars` and replace every placeholder. It is ignored by Git. Local anonymous evaluation can use:

```sh
npx wrangler dev --var AUTH_REQUIRED:false
```

Verification commands:

```sh
npm run typecheck:core
npm run test:core
npm run typecheck
npm run lint
npm test
npm run deploy:dry-run
```

`npm run check` performs generated binding drift detection, the isolated core check/test, full checking/lint/tests, and a Wrangler deployment dry-run.

## Privacy and security properties

- Exact raw bytes are hashed before parsing and are never logged or stored.
- The strict payload is redacted and then encrypted before durable storage.
- Destination/label routing, encryption-key version, marker-key version, and purge deadline are immutable acceptance-time snapshots.
- Known provider credentials (including current GitHub token families), credentialed URLs, JWTs, authorization values, private keys, common secret assignments, diagnostic emails, and diagnostic IPv4 addresses receive defense-in-depth redaction.
- User text is emitted as indented Markdown, headings are escaped, `@` mentions are neutralized, and a trusted marker survives bounded truncation.
- Logs contain only event names, validated project/report/request IDs, safe codes, counts, and boolean state. Bodies, diagnostics, credentials, authorization headers, IP addresses, and destination URLs/references are never logged.
- Request/JWKS/provider responses have hard size limits; outbound calls have deadlines and reject redirects.
- Storage keeps a SHA-256 idempotency-key hash, not the header value.
- GitHub responses are accepted only for the exact allowlisted target and its explicitly expected visibility.
- Public responses are `no-store`, include defensive headers, and hide internal destination coordinates.

Redaction is a safety net, not proof arbitrary logs contain no personal information. Collect only needed diagnostics, disclose collection, obtain appropriate consent, and choose a short payload-retention period. Destination retention is governed separately.

## Operations

Internal states are `pending`, `authorizing`, `creating`, `retrying`, `reconciling`, `delivered`, `permanent_failure`, and `manual_review`; public responses intentionally collapse them.

- Monitor Queue failure and `supportkit-reports-dlq`.
- Alert on `manual_review`, `permanent_failure`, outbox failure, and authentication-unavailable events.
- For ambiguous `manual_review`, search the target by its hidden marker before any operator create. Never just reset it to `pending`.
- Monitor reconciliation lease contention and due-search counts; eight rapid duplicate deliveries should consume one attempt, not eight.
- Follow the key-ring drain queries above before removing old versions. Existing ciphertext and ambiguous markers deliberately have no version fallback.
- Disabling a project prevents queued delivery; reports whose accepted route is unavailable move to manual review rather than another destination.

## Primary references

- [Cloudflare D1 batch atomicity](https://developers.cloudflare.com/d1/worker-api/d1-database/#batch)
- [Cloudflare Queues JavaScript APIs](https://developers.cloudflare.com/queues/configuration/javascript-apis/)
- [Cloudflare Workers rate-limit bindings](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/)
- [Cloudflare Workers Vitest integration](https://developers.cloudflare.com/workers/testing/vitest-integration/)
- [GitHub App authentication](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app)
- [GitHub installation access tokens](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app)
- [GitHub create issue API](https://docs.github.com/en/rest/issues/issues#create-an-issue)
