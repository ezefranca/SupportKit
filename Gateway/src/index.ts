import { JWKSRequestAuthenticator } from "./adapters/auth/jwks-authenticator";
import { D1Persistence } from "./adapters/cloudflare/d1";
import {
  errorResponse,
  HttpError,
  jsonResponse,
  readBoundedBody,
  requireJsonContentType,
} from "./adapters/cloudflare/http";
import {
  CloudflareDeliveryQueue,
  consumeCloudflareBatch,
} from "./adapters/cloudflare/queue";
import { edgeActorKey, verifiedActorKey } from "./adapters/cloudflare/rate-limit";
import { HMACMarkerFactory, WebCryptoPayloadCipher } from "./adapters/crypto/web-crypto";
import {
  decodeGitHubTarget,
  GitHubIssueTracker,
} from "./adapters/github/github-issue-tracker";
import type { GitHubAdapterConfig, GitHubTarget } from "./adapters/github/github-issue-tracker";
import { MAX_REQUEST_BYTES } from "./ServerCore/domain";
import type { DeliveryMessage } from "./ServerCore/domain";
import type { DeliveryDependencies } from "./ServerCore/delivery";
import { ingestSubmission, IngestionError, projectIsAllowed } from "./ServerCore/ingestion";
import { dispatchOutbox, runScheduledMaintenance } from "./ServerCore/outbox";
import type { AuthenticatedRequest, RequestAuthenticator } from "./ServerCore/ports";
import { ProjectConfigurationError } from "./ServerCore/ports";
import { publicStatusFromReport, receiptFromReport } from "./ServerCore/status";
import {
  isLowercaseSha256,
  isLowercaseUUID,
  isProjectID,
  ValidationError,
} from "./ServerCore/validation";

const REPORT_PATH_PATTERN = /^\/v1\/reports\/([0-9a-f-]{36})$/u;
const systemClock = { now: (): Date => new Date() };
const systemIdentifiers = { randomUUID: (): string => crypto.randomUUID() };

let cachedAuthenticator:
  | { configurationKey: string; authenticator: RequestAuthenticator }
  | null = null;

export default {
  async fetch(request, env, ctx): Promise<Response> {
    const requestID = crypto.randomUUID();
    try {
      return await routeRequest(request, env, ctx, requestID);
    } catch (error) {
      if (error instanceof HttpError) {
        return errorResponse(error, requestID);
      }
      if (error instanceof ValidationError) {
        return errorResponse(new HttpError(422, error.code, error.message), requestID);
      }
      if (error instanceof IngestionError) {
        return errorResponse(ingestionHttpError(error), requestID);
      }
      if (error instanceof ProjectConfigurationError) {
        logError("project_configuration_error", { requestID, code: error.code });
        return errorResponse(
          new HttpError(500, "project_configuration_error", "The project is not configured correctly."),
          requestID,
        );
      }
      logError("unhandled_request_error", { requestID, code: safeErrorCode(error) });
      return errorResponse(
        new HttpError(500, "internal_error", "The receiver could not process the request."),
        requestID,
      );
    }
  },

  async queue(batch, env): Promise<void> {
    await consumeCloudflareBatch(batch, deliveryDependencies(env));
  },

  scheduled(controller, env, ctx): void {
    log("scheduled_maintenance_started", { cron: controller.cron });
    ctx.waitUntil(
      runScheduledMaintenance(outboxDependencies(env))
        .then((result) => {
          log("scheduled_maintenance_finished", {
            published: result.published,
            outboxFailed: result.failed,
          });
        })
        .catch((error: unknown) => {
          logError("scheduled_maintenance_failed", { code: safeErrorCode(error) });
        }),
    );
  },
} satisfies ExportedHandler<Env, DeliveryMessage>;

async function routeRequest(
  request: Request,
  env: Env,
  ctx: ExecutionContext,
  requestID: string,
): Promise<Response> {
  const url = new URL(request.url);
  if (url.pathname === "/healthz") {
    if (request.method !== "GET" && request.method !== "HEAD") {
      throw methodNotAllowed("GET, HEAD");
    }
    const response = jsonResponse({ status: "ok" }, 200, requestID);
    return request.method === "HEAD" ? new Response(null, response) : response;
  }

  if (url.pathname === "/v1/reports") {
    if (request.method !== "POST") {
      throw methodNotAllowed("POST");
    }
    return acceptSubmission(request, url, env, ctx, requestID);
  }

  const reportMatch = REPORT_PATH_PATTERN.exec(url.pathname);
  if (reportMatch !== null) {
    if (request.method !== "GET") {
      throw methodNotAllowed("GET");
    }
    const reportID = reportMatch[1];
    if (reportID === undefined || !isLowercaseUUID(reportID)) {
      throw new HttpError(404, "not_found", "The requested resource was not found.");
    }
    return reportStatus(request, url, reportID, env, requestID);
  }
  throw new HttpError(404, "not_found", "The requested resource was not found.");
}

async function acceptSubmission(
  request: Request,
  url: URL,
  env: Env,
  ctx: ExecutionContext,
  requestID: string,
): Promise<Response> {
  if (url.search !== "") {
    throw new HttpError(400, "unexpected_query", "This endpoint does not accept query parameters.");
  }
  requireJsonContentType(request);
  const principal = await authorizeAndRateLimit(request, env, requestID);
  const idempotencyKey = request.headers.get("idempotency-key");
  if (idempotencyKey === null || !isLowercaseUUID(idempotencyKey)) {
    throw new HttpError(
      400,
      "invalid_idempotency_key",
      "Idempotency-Key must be a lowercase canonical UUID.",
    );
  }
  const claimedDigest = request.headers.get("x-supportkit-payload-sha256");
  if (claimedDigest === null || !isLowercaseSha256(claimedDigest)) {
    throw new HttpError(
      400,
      "invalid_payload_digest",
      "X-SupportKit-Payload-SHA256 must be a lowercase SHA-256 hex digest.",
    );
  }

  const persistence = persistenceAdapter(env);
  const markerFactory = new HMACMarkerFactory(env.ISSUE_MARKER_KEY_RING);
  const accepted = await ingestSubmission(
    {
      rawBody: await readBoundedBody(request, MAX_REQUEST_BYTES),
      claimedRawPayloadSha256: claimedDigest,
      idempotencyKey,
      principal,
    },
    {
      projects: persistence,
      reports: persistence,
      payloadCipher: new WebCryptoPayloadCipher(env.REPORT_ENCRYPTION_KEY_RING),
      markerFactory,
      admission: {
        allow: async (projectID: string) => {
          const result = await env.PROJECT_RATE_LIMITER.limit({ key: projectID });
          return result.success;
        },
      },
      now: systemClock.now,
    },
  );

  if (accepted.inserted) {
    ctx.waitUntil(
      dispatchOutbox(outboxDependencies(env)).catch((error: unknown) => {
        logError("request_outbox_dispatch_failed", {
          requestID,
          projectID: accepted.report.projectID,
          reportID: accepted.report.reportID,
          code: safeErrorCode(error),
        });
      }),
    );
  }
  log("report_accepted", {
    requestID,
    projectID: accepted.report.projectID,
    reportID: accepted.report.reportID,
    duplicate: !accepted.inserted,
    actor: principal.actorID === null ? "anonymous" : "verified",
  });
  return jsonResponse(
    receiptFromReport(accepted.report, !accepted.inserted),
    accepted.inserted ? 202 : 200,
    requestID,
    {
      Location: `/v1/reports/${accepted.report.reportID}?projectID=${encodeURIComponent(accepted.report.projectID)}`,
    },
  );
}

async function reportStatus(
  request: Request,
  url: URL,
  reportID: string,
  env: Env,
  requestID: string,
): Promise<Response> {
  const principal = await authorizeAndRateLimit(request, env, requestID);
  if (Array.from(url.searchParams.keys()).some((key) => key !== "projectID")) {
    throw new HttpError(400, "unexpected_query", "Only projectID is accepted.");
  }
  const projectIDs = url.searchParams.getAll("projectID");
  if (projectIDs.length !== 1) {
    throw new HttpError(400, "invalid_project", "projectID is required exactly once.");
  }
  const projectID = projectIDs[0];
  if (projectID === undefined || !isProjectID(projectID)) {
    throw new HttpError(400, "invalid_project", "projectID has an invalid format.");
  }
  if (!projectIsAllowed(principal, projectID)) {
    throw new HttpError(
      403,
      "project_not_authorized",
      "The authenticated assertion is not valid for this project.",
    );
  }
  const projectLimit = await env.PROJECT_RATE_LIMITER.limit({ key: projectID });
  if (!projectLimit.success) {
    throw new HttpError(429, "rate_limited", "Too many status requests were made.", 60);
  }
  const persistence = persistenceAdapter(env);
  if (await persistence.findEnabledProject(projectID) === null) {
    throw new HttpError(404, "report_not_found", "The support report was not found.");
  }
  const report = await persistence.find(projectID, reportID);
  if (report === null) {
    throw new HttpError(404, "report_not_found", "The support report was not found.");
  }
  return jsonResponse(publicStatusFromReport(report), 200, requestID);
}

async function authorizeAndRateLimit(
  request: Request,
  env: Env,
  requestID: string,
): Promise<AuthenticatedRequest> {
  const url = new URL(request.url);
  const rateLimitScope = request.method === "GET" && REPORT_PATH_PATTERN.test(url.pathname)
    ? "GET:/v1/reports/:reportID"
    : `${request.method}:${url.pathname}`;
  const anonymousKey = await edgeActorKey(request);
  const edgeResult = await env.EDGE_RATE_LIMITER.limit({ key: `${rateLimitScope}:${anonymousKey}` });
  if (!edgeResult.success) {
    log("request_rate_limited", { requestID, scope: "edge" });
    throw new HttpError(429, "rate_limited", "Too many requests were made.", 60);
  }
  const authentication = await authenticator(env).authenticate({
    authorization: request.headers.get("authorization"),
    method: request.method,
    path: url.pathname,
  });
  if (authentication.status === "unavailable") {
    logError("request_authentication_unavailable", { requestID, code: authentication.code });
    throw new HttpError(
      503,
      "authentication_unavailable",
      "Request authentication is temporarily unavailable.",
      30,
    );
  }
  if (authentication.status === "denied") {
    throw new HttpError(401, "unauthorized", "The request could not be authorized.");
  }
  const actorKey = authentication.principal.actorID === null
    ? anonymousKey
    : await verifiedActorKey(authentication.principal.actorID);
  const actorResult = await env.ACTOR_RATE_LIMITER.limit({ key: `${rateLimitScope}:${actorKey}` });
  if (!actorResult.success) {
    log("request_rate_limited", { requestID, scope: "actor" });
    throw new HttpError(429, "rate_limited", "Too many requests were made.", 60);
  }
  return authentication.principal;
}

function persistenceAdapter(env: Env): D1Persistence<GitHubTarget> {
  return new D1Persistence(env.SUPPORTKIT_DB, decodeGitHubTarget);
}

function githubConfig(env: Env): GitHubAdapterConfig {
  return {
    apiBaseURL: env.GITHUB_API_BASE_URL,
    apiVersion: env.GITHUB_API_VERSION,
    appClientID: env.GITHUB_APP_CLIENT_ID,
    appPrivateKey: env.GITHUB_APP_PRIVATE_KEY,
  };
}

function deliveryDependencies(env: Env): DeliveryDependencies<GitHubTarget> {
  const persistence = persistenceAdapter(env);
  return {
    reports: persistence,
    projects: persistence,
    issueTracker: new GitHubIssueTracker(githubConfig(env)),
    payloadCipher: new WebCryptoPayloadCipher(env.REPORT_ENCRYPTION_KEY_RING),
    markerFactory: new HMACMarkerFactory(env.ISSUE_MARKER_KEY_RING),
    clock: systemClock,
    identifiers: systemIdentifiers,
  };
}

function outboxDependencies(env: Env) {
  return {
    outbox: persistenceAdapter(env),
    publisher: new CloudflareDeliveryQueue(env.REPORT_QUEUE),
    clock: systemClock,
  };
}

function authenticator(env: Env): RequestAuthenticator {
  const required = env.AUTH_REQUIRED === "true"
    ? true
    : env.AUTH_REQUIRED === "false"
      ? false
      : null;
  const configurationKey = JSON.stringify([
    required,
    env.AUTH_JWT_ISSUER,
    env.AUTH_JWT_AUDIENCE,
    env.AUTH_JWKS_URL,
  ]);
  if (cachedAuthenticator?.configurationKey === configurationKey) {
    return cachedAuthenticator.authenticator;
  }
  const value = new JWKSRequestAuthenticator({
    required,
    issuer: env.AUTH_JWT_ISSUER,
    audience: env.AUTH_JWT_AUDIENCE,
    jwksURL: env.AUTH_JWKS_URL,
  });
  cachedAuthenticator = { configurationKey, authenticator: value };
  return value;
}

function ingestionHttpError(error: IngestionError): HttpError {
  if (error.kind === "conflict") {
    return new HttpError(409, error.code, error.message);
  }
  if (error.kind === "forbidden") {
    return new HttpError(403, error.code, error.message);
  }
  if (error.kind === "not_found") {
    return new HttpError(404, error.code, error.message);
  }
  if (error.kind === "rate_limited") {
    return new HttpError(429, error.code, error.message, 60);
  }
  return new HttpError(400, error.code, error.message);
}

function methodNotAllowed(allow: string): HttpError {
  return new HttpError(405, "method_not_allowed", "The HTTP method is not allowed.", null, allow);
}

function safeErrorCode(error: unknown): string {
  return error instanceof Error ? error.name.slice(0, 80) : "unknown_error";
}

function log(event: string, fields: Record<string, string | number | boolean>): void {
  console.log(JSON.stringify({ event, ...fields }));
}

function logError(event: string, fields: Record<string, string | number | boolean>): void {
  console.error(JSON.stringify({ event, ...fields }));
}
