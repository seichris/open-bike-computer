import type { Channel, Env } from "./types";

const encoder = new TextEncoder();
const HEX_64 = /^[0-9a-f]{64}$/;
const TOKEN = /^[A-Za-z0-9_-]{32,128}$/;
const SERVICE_KEY_ID = /^[A-Za-z0-9._-]{1,64}$/;

export class HttpError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

export function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
}

export function randomToken(byteCount = 32): string {
  const bytes = new Uint8Array(byteCount);
  crypto.getRandomValues(bytes);
  return base64Url(bytes);
}

export async function sha256Hex(value: string | ArrayBuffer): Promise<string> {
  const input = typeof value === "string" ? encoder.encode(value) : value;
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", input));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join(
    "",
  );
}

export function timingSafeEqual(left: string, right: string): boolean {
  const leftBytes = encoder.encode(left);
  const rightBytes = encoder.encode(right);
  if (leftBytes.length !== rightBytes.length) return false;
  let difference = 0;
  for (let index = 0; index < leftBytes.length; index += 1) {
    difference |= leftBytes[index] ^ rightBytes[index];
  }
  return difference === 0;
}

async function hmacHex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(message),
  );
  return Array.from(new Uint8Array(signature), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
}

export interface VerifiedServiceRequest {
  bodyText: string;
  bodySha256: string;
  idempotencyKey: string;
  keyID: string;
  channel: Channel;
}

export async function verifyServiceRequest(
  request: Request,
  env: Env,
): Promise<VerifiedServiceRequest> {
  const keyID = request.headers.get("x-catalog-key-id") ?? "";
  const timestamp = request.headers.get("x-catalog-timestamp") ?? "";
  const idempotencyKey = request.headers.get("x-catalog-idempotency-key") ?? "";
  const suppliedSignature = request.headers.get("x-catalog-signature") ?? "";
  if (
    !SERVICE_KEY_ID.test(keyID) ||
    !/^[0-9]{10,13}$/.test(timestamp) ||
    !/^[A-Za-z0-9._:-]{8,128}$/.test(idempotencyKey) ||
    !HEX_64.test(suppliedSignature)
  ) {
    throw new HttpError(401, "invalid service authorization");
  }

  const timestampMilliseconds =
    timestamp.length === 10 ? Number(timestamp) * 1000 : Number(timestamp);
  if (
    !Number.isSafeInteger(timestampMilliseconds) ||
    Math.abs(Date.now() - timestampMilliseconds) > 5 * 60 * 1000
  ) {
    throw new HttpError(401, "stale service authorization");
  }

  let keys: Record<string, unknown>;
  try {
    keys = JSON.parse(env.SERVICE_KEYS_JSON) as Record<string, unknown>;
  } catch {
    throw new HttpError(503, "service authorization is unavailable");
  }
  const configured = keys[keyID];
  if (
    configured === null ||
    Array.isArray(configured) ||
    typeof configured !== "object"
  ) {
    throw new HttpError(401, "unknown service authorization");
  }
  const principal = configured as Record<string, unknown>;
  if (
    Object.keys(principal).sort().join(",") !== "channel,secret" ||
    typeof principal.secret !== "string" ||
    principal.secret.length < 32 ||
    (principal.channel !== "development" && principal.channel !== "production")
  ) {
    throw new HttpError(503, "service authorization is unavailable");
  }
  const secret = principal.secret;
  const channel = principal.channel;

  const bodyText = await request.text();
  if (bodyText.length > 256 * 1024)
    throw new HttpError(413, "request body is too large");
  const bodySha256 = await sha256Hex(bodyText);
  const canonical = [
    request.method.toUpperCase(),
    new URL(request.url).pathname,
    timestamp,
    idempotencyKey,
    bodySha256,
  ].join("\n");
  const expected = await hmacHex(secret, canonical);
  if (!timingSafeEqual(expected, suppliedSignature)) {
    throw new HttpError(401, "invalid service authorization");
  }
  return { bodyText, bodySha256, idempotencyKey, keyID, channel };
}

export async function authenticatedLibraryID(
  request: Request,
  env: Env,
): Promise<string> {
  return (await authenticatedLibraryPrincipal(request, env)).libraryID;
}

export interface AuthenticatedLibraryPrincipal {
  libraryID: string;
  credentialHash: string;
}

export async function authenticatedLibraryPrincipal(
  request: Request,
  env: Env,
): Promise<AuthenticatedLibraryPrincipal> {
  const authorization = request.headers.get("authorization") ?? "";
  if (!authorization.startsWith("Bearer "))
    throw new HttpError(401, "library authorization required");
  const credential = authorization.slice("Bearer ".length);
  return libraryPrincipalForCredential(credential, env);
}

export async function libraryIDForCredential(
  credential: string,
  env: Env,
): Promise<string> {
  return (await libraryPrincipalForCredential(credential, env)).libraryID;
}

async function libraryPrincipalForCredential(
  credential: string,
  env: Env,
): Promise<AuthenticatedLibraryPrincipal> {
  if (!TOKEN.test(credential))
    throw new HttpError(401, "invalid library authorization");
  const credentialHash = await sha256Hex(credential);
  const row = await env.DB.prepare(
    `SELECT lc.library_id
       FROM library_credentials lc
       JOIN libraries l ON l.id = lc.library_id
      WHERE lc.credential_hash = ?
        AND lc.revoked_at IS NULL
        AND l.revoked_at IS NULL`,
  )
    .bind(credentialHash)
    .first<{ library_id: string }>();
  if (!row) throw new HttpError(401, "invalid library authorization");
  const clock = new Date();
  const now = clock.toISOString();
  const staleBefore = new Date(
    clock.getTime() - 24 * 60 * 60 * 1000,
  ).toISOString();
  await env.DB.prepare(
    `UPDATE library_credentials SET last_used_at = ?
      WHERE credential_hash = ? AND last_used_at <= ?`,
  )
    .bind(now, credentialHash, staleBefore)
    .run();
  return { libraryID: row.library_id, credentialHash };
}

export function requireToken(value: string): string {
  if (!TOKEN.test(value)) throw new HttpError(404, "share not found");
  return value;
}

export function normalizeAlias(value: unknown): string {
  if (typeof value !== "string")
    throw new HttpError(400, "alias must be a string");
  if (/\p{Cc}/u.test(value)) {
    throw new HttpError(400, "alias is invalid");
  }
  const normalized = value.normalize("NFC").trim();
  if (
    Array.from(normalized).length === 0 ||
    Array.from(normalized).length > 80 ||
    encoder.encode(normalized).length > 240
  ) {
    throw new HttpError(400, "alias is invalid");
  }
  return normalized;
}

export function parseObject<T>(bodyText: string): T {
  let value: unknown;
  try {
    value = JSON.parse(bodyText);
  } catch {
    throw new HttpError(400, "request body must be JSON");
  }
  if (value === null || Array.isArray(value) || typeof value !== "object") {
    throw new HttpError(400, "request body must be an object");
  }
  return value as T;
}

export async function jsonBody<T>(request: Request): Promise<T> {
  const bodyText = await request.text();
  if (bodyText.length > 64 * 1024)
    throw new HttpError(413, "request body is too large");
  return parseObject<T>(bodyText);
}

export function requireExactKeys(
  value: Record<string, unknown>,
  required: readonly string[],
  optional: readonly string[] = [],
): void {
  const allowed = new Set([...required, ...optional]);
  if (
    required.some((key) => !(key in value)) ||
    Object.keys(value).some((key) => !allowed.has(key))
  ) {
    throw new HttpError(400, "request body has invalid fields");
  }
}
