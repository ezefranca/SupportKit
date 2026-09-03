import type {
  EncryptedPayload,
  StoredPayload,
  VersionedEncryptedPayload,
} from "../../ServerCore/domain";
import type { MarkerFactory, PayloadCipher } from "../../ServerCore/ports";

export async function encryptPayload(
  payload: StoredPayload,
  encodedKey: string,
  keyVersion: number,
  projectID: string,
  reportID: string,
): Promise<EncryptedPayload> {
  if (!isKeyVersion(keyVersion)) {
    throw new Error("invalid_report_encryption_key_version");
  }
  const rawKey = decodeEncryptionKey(encodedKey);
  const key = await crypto.subtle.importKey("raw", rawKey, { name: "AES-GCM" }, false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const plaintext = new TextEncoder().encode(JSON.stringify(payload));
  const ciphertext = await crypto.subtle.encrypt(
    {
      name: "AES-GCM",
      iv,
      additionalData: additionalData(keyVersion, projectID, reportID),
      tagLength: 128,
    },
    key,
    plaintext,
  );
  return {
    ciphertext: encodeBase64Url(new Uint8Array(ciphertext)),
    iv: encodeBase64Url(iv),
  };
}

export async function decryptPayload(
  encrypted: EncryptedPayload,
  encodedKey: string,
  keyVersion: number,
  projectID: string,
  reportID: string,
): Promise<unknown> {
  if (!isKeyVersion(keyVersion)) {
    throw new Error("invalid_report_encryption_key_version");
  }
  const rawKey = decodeEncryptionKey(encodedKey);
  const key = await crypto.subtle.importKey("raw", rawKey, { name: "AES-GCM" }, false, ["decrypt"]);
  const plaintext = await crypto.subtle.decrypt(
    {
      name: "AES-GCM",
      iv: decodeBase64Url(encrypted.iv),
      additionalData: additionalData(keyVersion, projectID, reportID),
      tagLength: 128,
    },
    key,
    decodeBase64Url(encrypted.ciphertext),
  );
  const text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(plaintext);
  const parsed: unknown = JSON.parse(text);
  return parsed;
}

export async function destinationMarker(
  encodedKey: string,
  keyVersion: number,
  projectID: string,
  reportID: string,
): Promise<string> {
  if (!isKeyVersion(keyVersion)) {
    throw new Error("invalid_issue_marker_key_version");
  }
  const key = await crypto.subtle.importKey(
    "raw",
    decodeIssueMarkerKey(encodedKey),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(
      `supportkit-destination-marker-v1\u0000${String(keyVersion)}\u0000${projectID}\u0000${reportID}`,
    ),
  );
  const tag = encodeBase64Url(new Uint8Array(signature)).slice(0, 32);
  return `supportkit-report-${reportID}-${tag}`;
}

export function encodeBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}

export function decodeBase64Url(value: string): Uint8Array {
  if (!/^[A-Za-z0-9_-]+={0,2}$/u.test(value)) {
    throw new Error("invalid_base64url");
  }
  const unpadded = value.replace(/=+$/u, "");
  const paddingLength = (4 - (unpadded.length % 4)) % 4;
  const base64 = unpadded.replaceAll("-", "+").replaceAll("_", "/") + "=".repeat(paddingLength);
  let binary: string;
  try {
    binary = atob(base64);
  } catch {
    throw new Error("invalid_base64url");
  }
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

export function decodeEncryptionKey(value: string): Uint8Array {
  const key = decodeBase64Url(value);
  if (key.byteLength !== 32) {
    throw new Error("invalid_report_encryption_key");
  }
  return key;
}

function decodeIssueMarkerKey(value: string): Uint8Array {
  const key = decodeBase64Url(value);
  if (key.byteLength !== 32) {
    throw new Error("invalid_issue_marker_key");
  }
  return key;
}

function additionalData(keyVersion: number, projectID: string, reportID: string): Uint8Array {
  return new TextEncoder().encode(
    `supportkit-encrypted-report-v1\u0000${String(keyVersion)}\u0000${projectID}\u0000${reportID}`,
  );
}

export class WebCryptoPayloadCipher implements PayloadCipher {
  readonly #keyRing: VersionedKeyRing;

  constructor(encodedKeyRing: string) {
    this.#keyRing = parseVersionedKeyRing(encodedKeyRing, decodeEncryptionKey);
  }

  async encrypt(
    payload: StoredPayload,
    projectID: string,
    reportID: string,
  ): Promise<VersionedEncryptedPayload> {
    const keyVersion = this.#keyRing.activeVersion;
    const encrypted = await encryptPayload(
      payload,
      requireKeyVersion(this.#keyRing, keyVersion, "missing_report_encryption_key_version"),
      keyVersion,
      projectID,
      reportID,
    );
    return { ...encrypted, keyVersion };
  }

  async decrypt(
    payload: EncryptedPayload,
    keyVersion: number,
    projectID: string,
    reportID: string,
  ): Promise<unknown> {
    return decryptPayload(
      payload,
      requireKeyVersion(this.#keyRing, keyVersion, "missing_report_encryption_key_version"),
      keyVersion,
      projectID,
      reportID,
    );
  }
}

export class HMACMarkerFactory implements MarkerFactory {
  readonly #keyRing: VersionedKeyRing;

  constructor(encodedKeyRing: string) {
    this.#keyRing = parseVersionedKeyRing(encodedKeyRing, decodeIssueMarkerKey);
  }

  get activeVersion(): number {
    return this.#keyRing.activeVersion;
  }

  async make(projectID: string, reportID: string, keyVersion: number): Promise<string> {
    return destinationMarker(
      requireKeyVersion(this.#keyRing, keyVersion, "missing_issue_marker_key_version"),
      keyVersion,
      projectID,
      reportID,
    );
  }
}

type VersionedKeyRing = {
  activeVersion: number;
  encodedKeys: ReadonlyMap<number, string>;
};

function parseVersionedKeyRing(
  encodedKeyRing: string,
  validateKey: (encodedKey: string) => Uint8Array,
): VersionedKeyRing {
  if (encodedKeyRing.length < 1 || encodedKeyRing.length > 16_384) {
    throw new Error("invalid_key_ring");
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(encodedKeyRing);
  } catch {
    throw new Error("invalid_key_ring");
  }
  if (!isRecord(parsed) || !hasExactKeys(parsed, ["activeVersion", "keys"])) {
    throw new Error("invalid_key_ring");
  }
  const activeVersion = parsed["activeVersion"];
  const encodedKeys = parsed["keys"];
  if (!isKeyVersion(activeVersion) || !isRecord(encodedKeys)) {
    throw new Error("invalid_key_ring");
  }
  const entries = Object.entries(encodedKeys);
  if (entries.length < 1 || entries.length > 16) {
    throw new Error("invalid_key_ring");
  }
  const keys = new Map<number, string>();
  for (const [rawVersion, encodedKey] of entries) {
    if (!/^[1-9][0-9]{0,8}$/u.test(rawVersion) || typeof encodedKey !== "string") {
      throw new Error("invalid_key_ring");
    }
    const version = Number(rawVersion);
    if (!isKeyVersion(version)) {
      throw new Error("invalid_key_ring");
    }
    validateKey(encodedKey);
    keys.set(version, encodedKey);
  }
  if (!keys.has(activeVersion)) {
    throw new Error("active_key_version_missing");
  }
  return { activeVersion, encodedKeys: keys };
}

function requireKeyVersion(
  keyRing: VersionedKeyRing,
  keyVersion: number,
  errorCode: string,
): string {
  if (!isKeyVersion(keyVersion)) {
    throw new Error(errorCode);
  }
  const key = keyRing.encodedKeys.get(keyVersion);
  if (key === undefined) {
    throw new Error(errorCode);
  }
  return key;
}

function isKeyVersion(value: unknown): value is number {
  return Number.isSafeInteger(value) && typeof value === "number" && value >= 1 && value <= 999_999_999;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasExactKeys(value: Record<string, unknown>, expected: readonly string[]): boolean {
  const actual = Object.keys(value).sort();
  const sortedExpected = [...expected].sort();
  return actual.length === expected.length
    && actual.every((key, index) => key === sortedExpected[index]);
}
