import { describe, expect, it } from "vitest";
import { JWKSRequestAuthenticator } from "../src/adapters/auth/jwks-authenticator";
import { encodeBase64Url } from "../src/adapters/crypto/web-crypto";
import { projectIsAllowed } from "../src/ServerCore/ingestion";

const authenticationConfiguration = {
  required: true,
  issuer: "https://identity.example.test/",
  audience: "supportkit-gateway",
  jwksURL: "https://identity.example.test/.well-known/jwks.json",
};

const authenticationInput = {
  authorization: null,
  method: "POST",
  path: "/v1/reports",
};

describe("first-party authentication adapter", () => {
  it("allows explicitly anonymous evaluation mode without interpreting a credential", async () => {
    const authenticator = new JWKSRequestAuthenticator({
      ...authenticationConfiguration,
      required: false,
    });
    const decision = await authenticator.authenticate({
      ...authenticationInput,
      authorization: "Bearer invalid.invalid.invalid",
    });
    expect(decision).toEqual({
      status: "allowed",
      principal: { actorID: null, allowedProjectIDs: null },
    });
  });

  it("fails closed when production authentication is missing or misconfigured", async () => {
    await expect(
      new JWKSRequestAuthenticator(authenticationConfiguration).authenticate(authenticationInput),
    ).resolves.toMatchObject({ status: "denied", code: "authorization_required" });
    await expect(
      new JWKSRequestAuthenticator({
        ...authenticationConfiguration,
        required: null,
      }).authenticate(authenticationInput),
    ).resolves.toMatchObject({ status: "unavailable", code: "auth_mode_misconfigured" });
  });

  it("supports an injected first-party verifier without shared app secrets", async () => {
    const authenticator = new JWKSRequestAuthenticator(authenticationConfiguration, {
      verifier: (assertion, input) => {
        expect(assertion).toBe("header.claims.signature");
        expect(input.path).toBe("/v1/reports");
        return Promise.resolve({
          status: "allowed" as const,
          principal: {
            actorID: "app-attest:device-subject",
            allowedProjectIDs: new Set(["test.project"]),
          },
        });
      },
    });
    const decision = await authenticator.authenticate({
      ...authenticationInput,
      authorization: "Bearer header.claims.signature",
    });
    expect(decision).toMatchObject({
      status: "allowed",
      principal: { actorID: "app-attest:device-subject" },
    });
  });

  it("fails closed when an injected verifier is unavailable", async () => {
    const authenticator = new JWKSRequestAuthenticator(authenticationConfiguration, {
      verifier: () => Promise.reject(new Error("identity service unavailable")),
    });
    await expect(authenticator.authenticate({
      ...authenticationInput,
      authorization: "Bearer opaque-first-party-assertion",
    })).resolves.toEqual({
      status: "unavailable",
      code: "assertion_verifier_unavailable",
    });
  });

  it("verifies, caches, and enforces a project-scoped RS256 token", async () => {
    const keyPair = await crypto.subtle.generateKey(
      {
        name: "RSASSA-PKCS1-v1_5",
        modulusLength: 2_048,
        publicExponent: new Uint8Array([1, 0, 1]),
        hash: "SHA-256",
      },
      true,
      ["sign", "verify"],
    );
    if (!("publicKey" in keyPair)) {
      throw new Error("Expected an RSA key pair.");
    }
    const publicKey = await crypto.subtle.exportKey("jwk", keyPair.publicKey);
    if (publicKey instanceof ArrayBuffer) {
      throw new Error("Expected a JSON Web Key.");
    }
    const now = 1_788_436_800;
    const jwt = await signedJWT(keyPair.privateKey, {
      iss: authenticationConfiguration.issuer,
      aud: authenticationConfiguration.audience,
      sub: "installation:42",
      supportkit_project: "test.project",
      iat: now - 30,
      exp: now + 300,
    });
    let fetchCount = 0;
    const fetchJWKS = (): Promise<Response> => {
      fetchCount += 1;
      return Promise.resolve(Response.json({
        keys: [{
          kty: publicKey.kty,
          n: publicKey.n,
          e: publicKey.e,
          kid: "test-key",
          alg: "RS256",
          use: "sig",
        }],
      }, { headers: { "Cache-Control": "public, max-age=600" } }));
    };
    const authenticator = new JWKSRequestAuthenticator(authenticationConfiguration, {
      fetch: fetchJWKS,
      now: () => now * 1_000,
    });
    const request = {
      ...authenticationInput,
      authorization: `Bearer ${jwt}`,
    };

    const first = await authenticator.authenticate(request);
    const second = await authenticator.authenticate(request);
    expect(first.status).toBe("allowed");
    expect(second.status).toBe("allowed");
    expect(fetchCount).toBe(1);
    if (first.status !== "allowed") {
      throw new Error("Expected successful authentication.");
    }
    expect(projectIsAllowed(first.principal, "test.project")).toBe(true);
    expect(projectIsAllowed(first.principal, "another.project")).toBe(false);
  });

  it("rejects a JWKS RSA key weaker than 2048 bits", async () => {
    const keyPair = await crypto.subtle.generateKey(
      {
        name: "RSASSA-PKCS1-v1_5",
        modulusLength: 1_024,
        publicExponent: new Uint8Array([1, 0, 1]),
        hash: "SHA-256",
      },
      true,
      ["sign", "verify"],
    );
    if (!("publicKey" in keyPair)) {
      throw new Error("Expected an RSA key pair.");
    }
    const publicKey = await crypto.subtle.exportKey("jwk", keyPair.publicKey);
    if (publicKey instanceof ArrayBuffer) {
      throw new Error("Expected a JSON Web Key.");
    }
    const now = 1_788_436_800;
    const jwt = await signedJWT(keyPair.privateKey, {
      iss: authenticationConfiguration.issuer,
      aud: authenticationConfiguration.audience,
      sub: "installation:weak-key",
      supportkit_project: "test.project",
      iat: now - 30,
      exp: now + 300,
    });
    const authenticator = new JWKSRequestAuthenticator(authenticationConfiguration, {
      fetch: () => Promise.resolve(Response.json({
        keys: [{
          kty: publicKey.kty,
          n: publicKey.n,
          e: publicKey.e,
          kid: "test-key",
          alg: "RS256",
          use: "sig",
        }],
      })),
      now: () => now * 1_000,
    });

    await expect(authenticator.authenticate({
      ...authenticationInput,
      authorization: `Bearer ${jwt}`,
    })).resolves.toEqual({ status: "unavailable", code: "jwks_unavailable" });
  });
});

async function signedJWT(privateKey: CryptoKey, claims: Record<string, unknown>): Promise<string> {
  const header = encodeBase64Url(
    new TextEncoder().encode(JSON.stringify({ alg: "RS256", typ: "JWT", kid: "test-key" })),
  );
  const payload = encodeBase64Url(new TextEncoder().encode(JSON.stringify(claims)));
  const signingInput = `${header}.${payload}`;
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    privateKey,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${encodeBase64Url(new Uint8Array(signature))}`;
}
