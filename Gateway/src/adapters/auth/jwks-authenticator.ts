import type {
  AuthenticationResult,
  RequestAuthenticationInput,
  RequestAuthenticator,
} from "../../ServerCore/ports";
import { isProjectID } from "../../ServerCore/validation";
import { decodeBase64Url } from "../crypto/web-crypto";
import { readBoundedJsonResponse } from "../web/bounded-json";

export type JWKSAuthenticationConfig = {
  /** Null represents invalid host configuration and always fails closed. */
  required: boolean | null;
  issuer: string;
  audience: string;
  jwksURL: string;
};

export type FirstPartyAssertionVerifier = (
  assertion: string,
  input: Readonly<RequestAuthenticationInput>,
) => Promise<AuthenticationResult>;

type FetchFunction = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;
type CachedKeys = {
  fetchedAt: number;
  expiresAt: number;
  keys: ReadonlyMap<string, JsonWebKey>;
};

const MAX_AUTHORIZATION_BYTES = 8_192;
const MAX_JWT_BYTES = 8_000;
const MAX_JWKS_BYTES = 64 * 1024;
const MAX_JWKS_KEYS = 20;
const MAX_TOKEN_LIFETIME_SECONDS = 10 * 60;
const CLOCK_SKEW_SECONDS = 60;
const DEFAULT_JWKS_CACHE_SECONDS = 60;
const MAX_JWKS_CACHE_SECONDS = 5 * 60;
const MIN_KID_MISS_REFRESH_INTERVAL_MILLISECONDS = 30_000;
const MAX_PROJECT_SCOPE_SIZE = 16;
const AUTHENTICATION_CODE_PATTERN = /^[a-z][a-z0-9_]{0,63}$/u;

/**
 * Portable RequestAuthenticator adapter for short-lived, project-scoped RS256
 * assertions. Instances cache bounded validated JWKS data and refresh on a kid
 * miss. Cache state contains public keys only, never request or credential data.
 */
export class JWKSRequestAuthenticator implements RequestAuthenticator {
  readonly #config: JWKSAuthenticationConfig;
  readonly #fetch: FetchFunction;
  readonly #now: () => number;
  readonly #customVerifier: FirstPartyAssertionVerifier | null;
  #cachedKeys: CachedKeys | null = null;
  #refreshInFlight: Promise<CachedKeys> | null = null;

  constructor(
    config: JWKSAuthenticationConfig,
    options: {
      fetch?: FetchFunction;
      now?: () => number;
      verifier?: FirstPartyAssertionVerifier;
    } = {},
  ) {
    this.#config = config;
    this.#fetch = options.fetch ?? fetch;
    this.#now = options.now ?? Date.now;
    this.#customVerifier = options.verifier ?? null;
  }

  async authenticate(input: Readonly<RequestAuthenticationInput>): Promise<AuthenticationResult> {
    if (input.authorization !== null && byteLength(input.authorization) > MAX_AUTHORIZATION_BYTES) {
      return { status: "denied", code: "authorization_too_large" };
    }
    if (this.#config.required === false) {
      return {
        status: "allowed",
        principal: { actorID: null, allowedProjectIDs: null },
      };
    }
    if (this.#config.required !== true) {
      return { status: "unavailable", code: "auth_mode_misconfigured" };
    }
    if (input.authorization === null) {
      return { status: "denied", code: "authorization_required" };
    }
    const match = /^Bearer ([A-Za-z0-9._~+/-]+=*)$/u.exec(
      input.authorization,
    );
    const assertion = match?.[1];
    if (assertion === undefined || byteLength(assertion) > MAX_JWT_BYTES) {
      return { status: "denied", code: "invalid_authorization" };
    }
    if (this.#customVerifier === null) {
      if (!/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/u.test(assertion)) {
        return { status: "denied", code: "invalid_authorization" };
      }
      return this.#verifyJWT(assertion);
    }
    try {
      return validateCustomResult(await this.#customVerifier(assertion, input));
    } catch {
      return { status: "unavailable", code: "assertion_verifier_unavailable" };
    }
  }

  async #verifyJWT(assertion: string): Promise<AuthenticationResult> {
    if (
      typeof this.#config.issuer !== "string"
      || typeof this.#config.jwksURL !== "string"
      || typeof this.#config.audience !== "string"
      || parseHttpsURL(this.#config.issuer) === null
      || parseHttpsURL(this.#config.jwksURL) === null
      || this.#config.audience.length < 1
      || this.#config.audience.length > 256
    ) {
      return { status: "unavailable", code: "auth_configuration_invalid" };
    }

    const segments = assertion.split(".");
    const encodedHeader = segments[0];
    const encodedClaims = segments[1];
    const encodedSignature = segments[2];
    if (
      segments.length !== 3
      || encodedHeader === undefined
      || encodedClaims === undefined
      || encodedSignature === undefined
    ) {
      return { status: "denied", code: "jwt_malformed" };
    }

    const header = parseJWTPart(encodedHeader);
    const claims = parseJWTPart(encodedClaims);
    if (header === null || claims === null) {
      return { status: "denied", code: "jwt_malformed" };
    }
    const keyID = header["kid"];
    if (
      header["alg"] !== "RS256"
      || (header["typ"] !== undefined && header["typ"] !== "JWT")
      || typeof keyID !== "string"
      || keyID.length < 1
      || keyID.length > 256
    ) {
      return { status: "denied", code: "jwt_header_invalid" };
    }

    const now = Math.floor(this.#now() / 1_000);
    const issuedAt = claims["iat"];
    const expiresAt = claims["exp"];
    const notBefore = claims["nbf"];
    const subject = claims["sub"];
    const projectScope = parseProjectScope(claims["supportkit_project"]);
    if (
      claims["iss"] !== this.#config.issuer
      || !audienceIncludes(claims["aud"], this.#config.audience)
      || typeof subject !== "string"
      || subject.length < 1
      || subject.length > 256
      || projectScope === null
      || !isNumericDate(issuedAt)
      || !isNumericDate(expiresAt)
      || expiresAt <= issuedAt
      || expiresAt - issuedAt > MAX_TOKEN_LIFETIME_SECONDS
      || issuedAt > now + CLOCK_SKEW_SECONDS
      || expiresAt <= now - CLOCK_SKEW_SECONDS
      || (notBefore !== undefined && (!isNumericDate(notBefore) || notBefore > now + CLOCK_SKEW_SECONDS))
    ) {
      return { status: "denied", code: "jwt_claims_invalid" };
    }

    let key: JsonWebKey | null;
    try {
      key = await this.#verificationKey(keyID);
    } catch {
      return { status: "unavailable", code: "jwks_unavailable" };
    }
    if (key === null) {
      return { status: "denied", code: "jwt_key_not_found" };
    }

    let signature: Uint8Array;
    try {
      signature = decodeBase64Url(encodedSignature);
    } catch {
      return { status: "denied", code: "jwt_signature_invalid" };
    }
    let verified: boolean;
    try {
      const cryptoKey = await crypto.subtle.importKey(
        "jwk",
        key,
        { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
        false,
        ["verify"],
      );
      verified = await crypto.subtle.verify(
        "RSASSA-PKCS1-v1_5",
        cryptoKey,
        signature,
        new TextEncoder().encode(`${encodedHeader}.${encodedClaims}`),
      );
    } catch {
      return { status: "unavailable", code: "jwks_key_invalid" };
    }
    if (!verified) {
      return { status: "denied", code: "jwt_signature_invalid" };
    }
    return {
      status: "allowed",
      principal: {
        actorID: `${this.#config.issuer}\u0000${subject}`,
        allowedProjectIDs: projectScope,
      },
    };
  }

  async #verificationKey(keyID: string): Promise<JsonWebKey | null> {
    const now = this.#now();
    if (this.#cachedKeys !== null && this.#cachedKeys.expiresAt > now) {
      const cached = this.#cachedKeys.keys.get(keyID);
      if (cached !== undefined) {
        return cached;
      }
      if (now - this.#cachedKeys.fetchedAt < MIN_KID_MISS_REFRESH_INTERVAL_MILLISECONDS) {
        return null;
      }
      // Refresh a bounded valid cache on a kid miss, but not often enough for
      // attacker-controlled kid values to force one network request per token.
    }
    const refreshed = await this.#refreshKeys();
    return refreshed.keys.get(keyID) ?? null;
  }

  async #refreshKeys(): Promise<CachedKeys> {
    if (this.#refreshInFlight !== null) {
      return this.#refreshInFlight;
    }
    const refresh = this.#fetchKeys();
    this.#refreshInFlight = refresh;
    try {
      const cached = await refresh;
      this.#cachedKeys = cached;
      return cached;
    } finally {
      this.#refreshInFlight = null;
    }
  }

  async #fetchKeys(): Promise<CachedKeys> {
    let response: Response;
    try {
      response = await this.#fetch(this.#config.jwksURL, {
        method: "GET",
        headers: { Accept: "application/json" },
        redirect: "error",
        signal: AbortSignal.timeout(10_000),
      });
    } catch {
      throw new Error("jwks_transport");
    }
    if (response.status !== 200) {
      try {
        await response.body?.cancel();
      } catch {
        // Ignore body cancellation failure; the status is already unusable.
      }
      throw new Error("jwks_status");
    }
    let value: unknown;
    try {
      value = await readBoundedJsonResponse(response, MAX_JWKS_BYTES);
    } catch {
      throw new Error("jwks_invalid");
    }
    const keys = parseKeySet(value);
    if (keys === null) {
      throw new Error("jwks_invalid");
    }
    const ttlSeconds = jwksTTLSeconds(response.headers.get("cache-control"));
    const fetchedAt = this.#now();
    return { keys, fetchedAt, expiresAt: fetchedAt + ttlSeconds * 1_000 };
  }
}

function parseJWTPart(value: string): Record<string, unknown> | null {
  try {
    const decoded = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(
      decodeBase64Url(value),
    );
    const parsed: unknown = JSON.parse(decoded);
    return isRecord(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

function parseKeySet(jwks: unknown): ReadonlyMap<string, JsonWebKey> | null {
  if (
    !isRecord(jwks)
    || !Array.isArray(jwks["keys"])
    || jwks["keys"].length < 1
    || jwks["keys"].length > MAX_JWKS_KEYS
  ) {
    return null;
  }
  const keys = new Map<string, JsonWebKey>();
  for (const candidate of jwks["keys"]) {
    if (!isRecord(candidate)) {
      continue;
    }
    const keyID = candidate["kid"];
    const keyOperations = candidate["key_ops"];
    if (
      typeof keyID !== "string"
      || keyID.length < 1
      || keyID.length > 256
      || candidate["kty"] !== "RSA"
      || (candidate["use"] !== undefined && candidate["use"] !== "sig")
      || (candidate["alg"] !== undefined && candidate["alg"] !== "RS256")
      || (keyOperations !== undefined
        && (!Array.isArray(keyOperations) || !keyOperations.includes("verify")))
      || typeof candidate["n"] !== "string"
      || candidate["n"].length > 2_048
      || typeof candidate["e"] !== "string"
      || candidate["e"].length > 16
      || !hasSecureRSAParameters(candidate["n"], candidate["e"])
      || keys.has(keyID)
    ) {
      continue;
    }
    keys.set(keyID, {
      alg: "RS256",
      e: candidate["e"],
      ext: true,
      key_ops: ["verify"],
      kty: "RSA",
      n: candidate["n"],
      use: "sig",
    });
  }
  return keys.size > 0 ? keys : null;
}

function hasSecureRSAParameters(encodedModulus: string, encodedExponent: string): boolean {
  let modulus: Uint8Array;
  let exponentBytes: Uint8Array;
  try {
    modulus = withoutLeadingZeroBytes(decodeBase64Url(encodedModulus));
    exponentBytes = withoutLeadingZeroBytes(decodeBase64Url(encodedExponent));
  } catch {
    return false;
  }
  const firstModulusByte = modulus[0];
  const lastModulusByte = modulus[modulus.byteLength - 1];
  if (
    modulus.byteLength < 256
    || modulus.byteLength > 1_024
    || firstModulusByte === undefined
    || lastModulusByte === undefined
    || (modulus.byteLength === 256 && firstModulusByte < 0x80)
    || (lastModulusByte & 1) === 0
    || exponentBytes.byteLength < 1
    || exponentBytes.byteLength > 4
  ) {
    return false;
  }
  let exponent = 0;
  for (const byte of exponentBytes) {
    exponent = exponent * 256 + byte;
  }
  return exponent >= 3 && exponent <= 0x7fff_ffff && exponent % 2 === 1;
}

function withoutLeadingZeroBytes(value: Uint8Array): Uint8Array {
  let offset = 0;
  while (offset < value.byteLength - 1 && value[offset] === 0) {
    offset += 1;
  }
  return value.subarray(offset);
}

function parseProjectScope(value: unknown): ReadonlySet<string> | null {
  const projects = typeof value === "string" ? [value] : value;
  if (
    !Array.isArray(projects)
    || projects.length < 1
    || projects.length > MAX_PROJECT_SCOPE_SIZE
    || projects.some((project) => typeof project !== "string" || !isProjectID(project))
  ) {
    return null;
  }
  const typedProjects = projects.filter((project): project is string => typeof project === "string");
  return new Set(typedProjects).size === typedProjects.length ? new Set(typedProjects) : null;
}

function audienceIncludes(value: unknown, expected: string): boolean {
  if (typeof value === "string") {
    return value === expected;
  }
  return Array.isArray(value)
    && value.length >= 1
    && value.length <= 8
    && value.every((audience) => typeof audience === "string")
    && value.includes(expected);
}

function jwksTTLSeconds(cacheControl: string | null): number {
  if (cacheControl?.toLowerCase().includes("no-store") === true) {
    return 0;
  }
  const match = /(?:^|,)\s*max-age=(\d+)/iu.exec(cacheControl ?? "");
  const advertised = match?.[1] === undefined ? DEFAULT_JWKS_CACHE_SECONDS : Number(match[1]);
  if (!Number.isSafeInteger(advertised) || advertised < 0) {
    return DEFAULT_JWKS_CACHE_SECONDS;
  }
  return Math.min(advertised, MAX_JWKS_CACHE_SECONDS);
}

function isNumericDate(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

function parseHttpsURL(value: string): URL | null {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return null;
  }
  return url.protocol === "https:"
    && url.username === ""
    && url.password === ""
    && url.hash === ""
    ? url
    : null;
}

function byteLength(value: string): number {
  return new TextEncoder().encode(value).byteLength;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function validateCustomResult(result: AuthenticationResult): AuthenticationResult {
  if (result.status !== "allowed") {
    return AUTHENTICATION_CODE_PATTERN.test(result.code)
      ? result
      : { status: "denied", code: "assertion_result_invalid" };
  }
  const actorID = result.principal.actorID;
  const projects = result.principal.allowedProjectIDs;
  if (
    actorID === null
    || actorID.length < 1
    || actorID.length > 512
    || projects === null
    || projects.size < 1
    || projects.size > MAX_PROJECT_SCOPE_SIZE
    || Array.from(projects).some((projectID) => !isProjectID(projectID))
  ) {
    return { status: "denied", code: "assertion_scope_invalid" };
  }
  return result;
}
