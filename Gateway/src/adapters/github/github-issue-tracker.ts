import { encodeBase64Url } from "../crypto/web-crypto";
import type {
  DestinationDocument,
  DestinationItem,
  IssueTracker,
  IssueTrackerSession,
} from "../../ServerCore/ports";
import { IssueTrackerError, ProjectConfigurationError } from "../../ServerCore/ports";
import { readBoundedJsonResponse } from "../web/bounded-json";

const MAX_GITHUB_RESPONSE_BYTES = 2 * 1024 * 1024;

export type GitHubRepositoryVisibility = "private" | "public";

export type GitHubTarget = {
  owner: string;
  repository: string;
  installationID: string;
  repositoryVisibility: GitHubRepositoryVisibility;
};

export type GitHubAdapterConfig = {
  apiBaseURL: string;
  apiVersion: string;
  appClientID: string;
  appPrivateKey: string;
};

export type GitHubIssue = {
  number: number;
  url: string;
};

export type GitHubFailureKind = "retryable" | "permanent" | "ambiguous";

export class GitHubOperationError extends IssueTrackerError {
  constructor(
    kind: GitHubFailureKind,
    code: string,
    retryAfterSeconds: number | null = null,
  ) {
    super(kind, code, retryAfterSeconds);
    this.name = "GitHubOperationError";
  }
}

type FetchFunction = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;

const REPOSITORY_COMPONENT_PATTERN =
  /^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,98}[A-Za-z0-9])?$/u;
const INSTALLATION_ID_PATTERN = /^[1-9][0-9]{0,19}$/u;

export class GitHubIssueTracker implements IssueTracker<GitHubTarget> {
  readonly #config: GitHubAdapterConfig;
  readonly #fetch: FetchFunction;

  constructor(config: GitHubAdapterConfig, fetchFunction: FetchFunction = fetch) {
    this.#config = config;
    this.#fetch = fetchFunction;
  }

  async open(target: Readonly<GitHubTarget>): Promise<IssueTrackerSession> {
    const installationToken = await createInstallationToken(this.#config, target, this.#fetch);
    let validationPromise: Promise<void> | null = null;
    const validateTarget = (): Promise<void> => {
      validationPromise ??= verifyRepository(
        this.#config,
        target,
        installationToken,
        this.#fetch,
      );
      return validationPromise;
    };
    return {
      validateTarget,
      create: async (document: Readonly<DestinationDocument>, labels: readonly string[]) => {
        await validateTarget();
        const issue = await createIssue(
          this.#config,
          target,
          installationToken,
          document,
          labels,
          this.#fetch,
        );
        return { reference: String(issue.number), url: issue.url };
      },
      findByMarker: async (marker: string): Promise<DestinationItem | null> => {
        await validateTarget();
        const issue = await findIssueByMarker(
          this.#config,
          target,
          installationToken,
          marker,
          this.#fetch,
        );
        return issue === null ? null : { reference: String(issue.number), url: issue.url };
      },
    };
  }
}

/** Strict decoder injected into a host's project registry. */
export function decodeGitHubTarget(adapter: string, value: unknown): GitHubTarget {
  if (adapter !== "github" || !isRecord(value)) {
    throw new ProjectConfigurationError("unsupported_destination_adapter");
  }
  const keys = Object.keys(value);
  if (
    keys.length !== 4
    || !keys.includes("owner")
    || !keys.includes("repository")
    || !keys.includes("installationID")
    || !keys.includes("repositoryVisibility")
    || typeof value["owner"] !== "string"
    || !REPOSITORY_COMPONENT_PATTERN.test(value["owner"])
    || typeof value["repository"] !== "string"
    || !REPOSITORY_COMPONENT_PATTERN.test(value["repository"])
    || typeof value["installationID"] !== "string"
    || !INSTALLATION_ID_PATTERN.test(value["installationID"])
    || (value["repositoryVisibility"] !== "private"
      && value["repositoryVisibility"] !== "public")
  ) {
    throw new ProjectConfigurationError("invalid_destination_configuration");
  }
  return {
    owner: value["owner"],
    repository: value["repository"],
    installationID: value["installationID"],
    repositoryVisibility: value["repositoryVisibility"],
  };
}

export async function createInstallationToken(
  config: GitHubAdapterConfig,
  target: GitHubTarget,
  fetchFunction: FetchFunction = fetch,
): Promise<string> {
  const jwt = await createGitHubAppJWT(config.appClientID, config.appPrivateKey);
  const url = githubAPIURL(config, `/app/installations/${target.installationID}/access_tokens`);
  let response: Response;
  try {
    response = await fetchFunction(
      url,
      {
        method: "POST",
        headers: githubHeaders(config.apiVersion, jwt),
        body: JSON.stringify({
          repositories: [target.repository],
          permissions: { issues: "write" },
        }),
        redirect: "manual",
        signal: AbortSignal.timeout(20_000),
      },
    );
  } catch {
    throw new GitHubOperationError("retryable", "github_token_transport");
  }

  if (response.status !== 201) {
    throw await classifyDefinitiveResponse("token", response);
  }
  let payload: unknown;
  try {
    payload = await readBoundedJsonResponse(response, 64 * 1024);
  } catch {
    throw new GitHubOperationError("retryable", "github_token_invalid_response");
  }
  if (!isRecord(payload) || typeof payload["token"] !== "string" || payload["token"].length > 5_000) {
    throw new GitHubOperationError("retryable", "github_token_invalid_response");
  }
  const token = payload["token"];
  if (token.length < 16) {
    throw new GitHubOperationError("retryable", "github_token_invalid_response");
  }
  return token;
}

export async function createIssue(
  config: GitHubAdapterConfig,
  target: GitHubTarget,
  installationToken: string,
  document: { title: string; body: string },
  labels: readonly string[],
  fetchFunction: FetchFunction = fetch,
): Promise<GitHubIssue> {
  const url = githubAPIURL(
    config,
    `/repos/${encodeURIComponent(target.owner)}/${encodeURIComponent(target.repository)}/issues`,
  );
  let response: Response;
  try {
    response = await fetchFunction(
      url,
      {
        method: "POST",
        headers: githubHeaders(config.apiVersion, installationToken),
        body: JSON.stringify({ title: document.title, body: document.body, labels }),
        redirect: "manual",
        signal: AbortSignal.timeout(25_000),
      },
    );
  } catch {
    // A transport failure does not reveal whether GitHub committed the POST.
    // The caller must enter marker reconciliation and must not repeat the POST.
    throw new GitHubOperationError("ambiguous", "github_create_ambiguous_transport");
  }

  if (response.status !== 201) {
    throw await classifyDefinitiveResponse("create", response);
  }
  let payload: unknown;
  try {
    payload = await readBoundedJsonResponse(response, 256 * 1024);
  } catch {
    throw new GitHubOperationError("ambiguous", "github_create_ambiguous_response");
  }
  const issue = parseIssue(payload, target);
  if (issue === null) {
    throw new GitHubOperationError("ambiguous", "github_create_ambiguous_response");
  }
  return issue;
}

export async function verifyRepository(
  config: GitHubAdapterConfig,
  target: GitHubTarget,
  installationToken: string,
  fetchFunction: FetchFunction = fetch,
): Promise<void> {
  const url = githubAPIURL(
    config,
    `/repos/${encodeURIComponent(target.owner)}/${encodeURIComponent(target.repository)}`,
  );
  let response: Response;
  try {
    response = await fetchFunction(
      url,
      {
        method: "GET",
        headers: githubHeaders(config.apiVersion, installationToken),
        redirect: "manual",
        signal: AbortSignal.timeout(20_000),
      },
    );
  } catch {
    throw new GitHubOperationError("retryable", "github_repository_transport");
  }
  if (response.status !== 200) {
    throw await classifyDefinitiveResponse("repository", response);
  }
  let payload: unknown;
  try {
    payload = await readBoundedJsonResponse(response, 256 * 1024);
  } catch {
    throw new GitHubOperationError("retryable", "github_repository_invalid_response");
  }
  const expectedName = `${target.owner}/${target.repository}`.toLowerCase();
  if (
    !isRecord(payload)
    || typeof payload["full_name"] !== "string"
    || typeof payload["private"] !== "boolean"
    || (payload["visibility"] !== "private"
      && payload["visibility"] !== "public"
      && payload["visibility"] !== "internal")
  ) {
    throw new GitHubOperationError("retryable", "github_repository_invalid_response");
  }
  const actualVisibility = payload["visibility"];
  if (payload["private"] !== (actualVisibility !== "public")) {
    throw new GitHubOperationError("retryable", "github_repository_invalid_response");
  }
  if (payload["full_name"].toLowerCase() !== expectedName) {
    throw new GitHubOperationError("permanent", "github_repository_identity_mismatch");
  }
  if (actualVisibility !== target.repositoryVisibility) {
    throw new GitHubOperationError("permanent", "github_repository_visibility_mismatch");
  }
}

export async function findIssueByMarker(
  config: GitHubAdapterConfig,
  target: GitHubTarget,
  installationToken: string,
  marker: string,
  fetchFunction: FetchFunction = fetch,
): Promise<GitHubIssue | null> {
  const query = `repo:${target.owner}/${target.repository} is:issue in:body "${marker}"`;
  const url = new URL(githubAPIURL(config, "/search/issues"));
  url.searchParams.set("q", query);
  url.searchParams.set("per_page", "20");

  let response: Response;
  try {
    response = await fetchFunction(url, {
      method: "GET",
      headers: githubHeaders(config.apiVersion, installationToken),
      redirect: "manual",
      signal: AbortSignal.timeout(20_000),
    });
  } catch {
    throw new GitHubOperationError("retryable", "github_reconcile_transport");
  }
  if (response.status !== 200) {
    throw await classifyDefinitiveResponse("reconcile", response);
  }

  let payload: unknown;
  try {
    payload = await readBoundedJsonResponse(response, MAX_GITHUB_RESPONSE_BYTES);
  } catch {
    throw new GitHubOperationError("retryable", "github_reconcile_invalid_response");
  }
  if (
    !isRecord(payload)
    || payload["incomplete_results"] === true
    || !Array.isArray(payload["items"])
  ) {
    throw new GitHubOperationError("retryable", "github_reconcile_incomplete");
  }
  for (const item of payload["items"]) {
    if (!isRecord(item) || typeof item["body"] !== "string" || !item["body"].includes(marker)) {
      continue;
    }
    const issue = parseIssue(item, target);
    if (issue !== null) {
      return issue;
    }
  }
  return null;
}

export async function createGitHubAppJWT(
  clientID: string,
  privateKeyPEM: string,
  nowMilliseconds: number = Date.now(),
): Promise<string> {
  if (!/^[A-Za-z0-9_-]{1,200}$/u.test(clientID)) {
    throw new GitHubOperationError("permanent", "github_client_id_invalid");
  }
  let key: CryptoKey;
  try {
    key = await crypto.subtle.importKey(
      "pkcs8",
      pemToPkcs8(privateKeyPEM),
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["sign"],
    );
  } catch {
    throw new GitHubOperationError("permanent", "github_private_key_invalid");
  }
  const nowSeconds = Math.floor(nowMilliseconds / 1_000);
  const header = encodeBase64Url(new TextEncoder().encode(JSON.stringify({ alg: "RS256", typ: "JWT" })));
  const claims = encodeBase64Url(
    new TextEncoder().encode(
      JSON.stringify({ iat: nowSeconds - 60, exp: nowSeconds + 540, iss: clientID }),
    ),
  );
  const signingInput = `${header}.${claims}`;
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${encodeBase64Url(new Uint8Array(signature))}`;
}

async function classifyDefinitiveResponse(
  operation: "token" | "repository" | "create" | "reconcile",
  response: Response,
): Promise<GitHubOperationError> {
  const status = response.status;
  const retryAfter = parseRetryAfter(response.headers);
  const rateLimited = status === 429
    || (status === 403 && response.headers.get("x-ratelimit-remaining") === "0")
    || retryAfter !== null;
  try {
    await response.body?.cancel();
  } catch {
    // The status and headers are already sufficient to classify this response.
  }
  if (operation === "create" && (status === 408 || status === 425 || status >= 500)) {
    return new GitHubOperationError("ambiguous", `github_${operation}_${String(status)}`);
  }
  if (rateLimited || status === 408 || status === 425 || status >= 500) {
    return new GitHubOperationError("retryable", `github_${operation}_${String(status)}`, retryAfter);
  }
  return new GitHubOperationError("permanent", `github_${operation}_${String(status)}`);
}

function githubAPIURL(config: GitHubAdapterConfig, path: string): string {
  let baseURL: URL;
  try {
    baseURL = new URL(config.apiBaseURL);
  } catch {
    throw new GitHubOperationError("permanent", "github_api_base_invalid");
  }
  if (
    baseURL.protocol !== "https:"
    || baseURL.hostname !== "api.github.com"
    || baseURL.port !== ""
    || baseURL.username !== ""
    || baseURL.password !== ""
    || (baseURL.pathname !== "/" && baseURL.pathname !== "")
    || baseURL.search !== ""
    || baseURL.hash !== ""
    || !/^\d{4}-\d{2}-\d{2}$/u.test(config.apiVersion)
  ) {
    throw new GitHubOperationError("permanent", "github_api_base_invalid");
  }
  return new URL(path, baseURL).toString();
}

function parseRetryAfter(headers: Headers): number | null {
  const retryAfter = headers.get("retry-after");
  if (retryAfter !== null) {
    const seconds = Number(retryAfter);
    if (Number.isSafeInteger(seconds) && seconds >= 1) {
      return Math.min(seconds, 86_400);
    }
    const date = Date.parse(retryAfter);
    if (Number.isFinite(date)) {
      return Math.min(86_400, Math.max(1, Math.ceil((date - Date.now()) / 1_000)));
    }
  }
  const reset = Number(headers.get("x-ratelimit-reset"));
  if (Number.isSafeInteger(reset) && reset > 0) {
    return Math.min(86_400, Math.max(1, reset - Math.floor(Date.now() / 1_000)));
  }
  return null;
}

function githubHeaders(apiVersion: string, credential: string): Headers {
  return new Headers({
    Accept: "application/vnd.github+json",
    Authorization: `Bearer ${credential}`,
    "Content-Type": "application/json",
    "User-Agent": "SupportKit-Server/1.0",
    "X-GitHub-Api-Version": apiVersion,
  });
}

function parseIssue(value: unknown, target: GitHubTarget): GitHubIssue | null {
  if (!isRecord(value)) {
    return null;
  }
  const number = value["number"];
  const rawURL = value["html_url"];
  if (typeof number !== "number" || !Number.isSafeInteger(number) || number < 1 || typeof rawURL !== "string") {
    return null;
  }
  let url: URL;
  try {
    url = new URL(rawURL);
  } catch {
    return null;
  }
  const expectedPath = `/${target.owner}/${target.repository}/issues/${String(number)}`.toLowerCase();
  if (
    url.protocol !== "https:"
    || url.hostname !== "github.com"
    || url.port !== ""
    || url.username !== ""
    || url.password !== ""
    || url.pathname.toLowerCase() !== expectedPath
    || url.search !== ""
    || url.hash !== ""
  ) {
    return null;
  }
  return { number, url: url.toString() };
}

function pemToPkcs8(pem: string): Uint8Array {
  const normalized = pem.replaceAll("\\n", "\n").trim();
  const pkcs8 = extractPEM(normalized, "PRIVATE KEY");
  if (pkcs8 !== null) {
    return pkcs8;
  }
  const pkcs1 = extractPEM(normalized, "RSA PRIVATE KEY");
  if (pkcs1 === null) {
    throw new Error("unsupported_private_key_pem");
  }
  const version = new Uint8Array([0x02, 0x01, 0x00]);
  const rsaAlgorithmIdentifier = new Uint8Array([
    0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00,
  ]);
  return derElement(0x30, concatenate(version, rsaAlgorithmIdentifier, derElement(0x04, pkcs1)));
}

function extractPEM(pem: string, label: string): Uint8Array | null {
  const begin = `-----BEGIN ${label}-----`;
  const end = `-----END ${label}-----`;
  if (!pem.startsWith(begin) || !pem.endsWith(end)) {
    return null;
  }
  const base64 = pem.slice(begin.length, -end.length).replace(/\s/gu, "");
  if (base64.length < 64 || base64.length > 32_768 || !/^[A-Za-z0-9+/]+={0,2}$/u.test(base64)) {
    throw new Error("invalid_private_key_pem");
  }
  return Uint8Array.from(atob(base64), (character) => character.charCodeAt(0));
}

function derElement(tag: number, value: Uint8Array): Uint8Array {
  return concatenate(new Uint8Array([tag]), derLength(value.byteLength), value);
}

function derLength(length: number): Uint8Array {
  if (length < 0x80) {
    return new Uint8Array([length]);
  }
  const bytes: number[] = [];
  let remaining = length;
  while (remaining > 0) {
    bytes.unshift(remaining & 0xff);
    remaining >>>= 8;
  }
  return new Uint8Array([0x80 | bytes.length, ...bytes]);
}

function concatenate(...arrays: readonly Uint8Array[]): Uint8Array {
  const totalLength = arrays.reduce((total, array) => total + array.byteLength, 0);
  const result = new Uint8Array(totalLength);
  let offset = 0;
  for (const array of arrays) {
    result.set(array, offset);
    offset += array.byteLength;
  }
  return result;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
