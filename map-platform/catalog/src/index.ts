import {
  attachLibrary,
  bootstrapLibrary,
  claimLinkCode,
  claimShare,
  createLibraryDownloadGrant,
  createLinkCode,
  createPromotionGrant,
  createShare,
  finalizePublication,
  getLibraryMap,
  listLibraryMaps,
  listShares,
  quarantinePublication,
  refreshLibrary,
  resolveDownloadGrant,
  revokeShare,
  sharePreview,
  updateAlias,
} from "./catalog";
import { presignedDownloadURL } from "./r2";
import {
  HttpError,
  authenticatedLibraryID,
  jsonBody,
  libraryIDForCredential,
  parseObject,
  requireExactKeys,
  requireToken,
  verifyServiceRequest,
} from "./security";
import type { Channel, Env } from "./types";
import { validatePublication } from "./validation";

function json(
  value: unknown,
  status = 200,
  headers: HeadersInit = {},
): Response {
  return Response.json(value, {
    status,
    headers: { "cache-control": "no-store", ...headers },
  });
}

function securityHeaders(response: Response): Response {
  const result = new Response(response.body, response);
  result.headers.set("x-content-type-options", "nosniff");
  result.headers.set("referrer-policy", "no-referrer");
  result.headers.set(
    "permissions-policy",
    "camera=(), microphone=(), geolocation=()",
  );
  result.headers.set(
    "content-security-policy",
    "default-src 'none'; style-src 'unsafe-inline'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  );
  return result;
}

function match(pathname: string, expression: RegExp): string[] | null {
  const result = pathname.match(expression);
  return result ? result.slice(1).map(decodeURIComponent) : null;
}

function parseChannel(value: unknown): Channel {
  if (value !== "development" && value !== "production") {
    throw new HttpError(400, "channel is invalid");
  }
  return value;
}

function bootstrapClientRateLimitKey(request: Request): string {
  const address = request.headers.get("cf-connecting-ip")?.trim().toLowerCase();
  if (!address || !/^[0-9a-f:.]{2,64}$/.test(address)) {
    return "library-bootstrap:unknown-client";
  }
  return `library-bootstrap:${address}`;
}

async function enforceLibraryBootstrapRateLimit(
  request: Request,
  env: Env,
): Promise<void> {
  let client: RateLimitOutcome;
  let global: RateLimitOutcome;
  try {
    [client, global] = await Promise.all([
      env.LIBRARY_BOOTSTRAP_CLIENT_RATE_LIMITER.limit({
        key: bootstrapClientRateLimitKey(request),
      }),
      env.LIBRARY_BOOTSTRAP_GLOBAL_RATE_LIMITER.limit({
        key: "library-bootstrap",
      }),
    ]);
  } catch {
    throw new HttpError(503, "library bootstrap is temporarily unavailable");
  }
  if (!client.success || !global.success) {
    throw new HttpError(429, "library bootstrap rate limit exceeded");
  }
}

function appleAppSiteAssociation(env: Env): Response {
  const teamID = env.APPLE_TEAM_ID;
  if (!/^[A-Z0-9]{10}$/.test(teamID)) {
    throw new HttpError(503, "associated domains are not configured");
  }
  return json(
    {
      applinks: {
        apps: [],
        details: [
          {
            appID: `${teamID}.${env.PRODUCTION_BUNDLE_ID}`,
            components: [
              { "/": "/s/*", comment: "Production Bicino map shares" },
            ],
          },
          {
            appID: `${teamID}.${env.DEVELOPMENT_BUNDLE_ID}`,
            components: [{ "/": "/dev/s/*", comment: "Bicino Dev map shares" }],
          },
        ],
      },
    },
    200,
    { "content-type": "application/json" },
  );
}

function escapeHTML(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

async function shareLanding(env: Env, token: string): Promise<Response> {
  const preview = await sharePreview(env, token);
  const features = preview.features.map(escapeHTML).join(", ") || "offline map";
  const size = preview.approximateBytes
    ? `${Math.max(1, Math.round(preview.approximateBytes / (1024 * 1024)))} MB`
    : "size calculated in the app";
  const devURL = `${env.PUBLIC_BASE_URL.replace(/\/$/, "")}/dev/s/${encodeURIComponent(token)}`;
  const appStoreURL = escapeHTML(env.APP_STORE_URL);
  const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapeHTML(preview.title)} — Bicino offline map</title>
<style>body{font:17px system-ui,sans-serif;max-width:42rem;margin:4rem auto;padding:0 1.25rem;color:#161616}main{border:1px solid #ddd;border-radius:18px;padding:1.5rem}h1{margin-top:0}a{display:inline-block;margin:.6rem .8rem .2rem 0;padding:.7rem 1rem;border-radius:999px;background:#111;color:#fff;text-decoration:none}.secondary{background:#eee;color:#111}small{color:#666}</style></head>
<body><main><small>Shared Bicino map</small><h1>${escapeHTML(preview.title)}</h1>
<p>${escapeHTML(features)} · approximately ${escapeHTML(size)}</p>
<p>Open this link in Bicino to preview the map. Adding it is always an explicit step; opening this page does not download or install anything.</p>
<a href="${appStoreURL}">Get Bicino</a><a class="secondary" href="${escapeHTML(devURL)}">Open in Bicino Dev</a>
<p><small>Map data attribution is included with the downloaded map.</small></p></main></body></html>`;
  return new Response(html, {
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "private, max-age=60",
    },
  });
}

async function handle(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const path = url.pathname;

  if (request.method === "GET" && path === "/healthz") {
    return json({
      status: "ok",
      environment: env.ENVIRONMENT,
      schemaVersion: 1,
    });
  }
  if (
    request.method === "GET" &&
    (path === "/.well-known/apple-app-site-association" ||
      path === "/apple-app-site-association")
  ) {
    return appleAppSiteAssociation(env);
  }

  if (request.method === "POST" && path === "/v1/libraries/bootstrap") {
    const authorization = request.headers.get("authorization");
    if (authorization?.startsWith("Bearer ")) {
      return json(
        await refreshLibrary(await authenticatedLibraryID(request, env)),
      );
    }
    if (authorization)
      throw new HttpError(401, "invalid library authorization");
    await enforceLibraryBootstrapRateLimit(request, env);
    return json(await bootstrapLibrary(env), 201);
  }

  if (request.method === "POST" && path === "/v1/libraries/link-codes") {
    return json(
      await createLinkCode(env, await authenticatedLibraryID(request, env)),
      201,
    );
  }
  const linkCodeClaim = match(
    path,
    /^\/v1\/libraries\/link-codes\/([^/]+)\/claim$/,
  );
  if (request.method === "POST" && linkCodeClaim) {
    return json(
      await claimLinkCode(
        env,
        await authenticatedLibraryID(request, env),
        linkCodeClaim[0],
      ),
    );
  }

  if (request.method === "GET" && path === "/v1/library/maps") {
    return json(
      await listLibraryMaps(
        env,
        await authenticatedLibraryID(request, env),
        url.searchParams.get("cursor"),
        url.searchParams.get("limit"),
      ),
    );
  }
  const libraryMap = match(path, /^\/v1\/library\/maps\/([^/]+)$/);
  if (request.method === "GET" && libraryMap) {
    return json(
      await getLibraryMap(
        env,
        await authenticatedLibraryID(request, env),
        libraryMap[0],
      ),
    );
  }
  if (request.method === "PATCH" && libraryMap) {
    const body = await jsonBody<Record<string, unknown>>(request);
    requireExactKeys(body, ["alias"], ["expectedRevision"]);
    return json(
      await updateAlias(
        env,
        await authenticatedLibraryID(request, env),
        libraryMap[0],
        body.alias,
        body.expectedRevision,
      ),
    );
  }

  const createMapShare = match(path, /^\/v1\/library\/maps\/([^/]+)\/shares$/);
  if (request.method === "POST" && createMapShare) {
    const body = await jsonBody<Record<string, unknown>>(request);
    requireExactKeys(body, [], ["expiresAt"]);
    return json(
      await createShare(
        env,
        await authenticatedLibraryID(request, env),
        createMapShare[0],
        body.expiresAt,
      ),
      201,
    );
  }
  if (request.method === "GET" && path === "/v1/library/shares") {
    return json(
      await listShares(env, await authenticatedLibraryID(request, env)),
    );
  }
  const deleteShare = match(path, /^\/v1\/library\/shares\/([^/]+)$/);
  if (request.method === "DELETE" && deleteShare) {
    await revokeShare(
      env,
      await authenticatedLibraryID(request, env),
      deleteShare[0],
    );
    return new Response(null, { status: 204 });
  }

  const previewShare = match(path, /^\/v1\/shares\/([^/]+)$/);
  if (request.method === "GET" && previewShare) {
    return json(await sharePreview(env, requireToken(previewShare[0])));
  }
  const claimMapShare = match(path, /^\/v1\/shares\/([^/]+)\/claim$/);
  if (request.method === "POST" && claimMapShare) {
    return json(
      await claimShare(
        env,
        await authenticatedLibraryID(request, env),
        requireToken(claimMapShare[0]),
      ),
    );
  }

  const createDownload = match(
    path,
    /^\/v1\/library\/maps\/([^/]+)\/download-grants$/,
  );
  if (request.method === "POST" && createDownload) {
    const body = await jsonBody<Record<string, unknown>>(request);
    requireExactKeys(body, ["channel", "acceptedSigners", "appIdentity"]);
    return json(
      await createLibraryDownloadGrant(
        env,
        await authenticatedLibraryID(request, env),
        createDownload[0],
        parseChannel(body.channel),
        body.acceptedSigners,
        body.appIdentity,
      ),
      201,
    );
  }
  const download = match(path, /^\/v1\/downloads\/([^/]+)$/);
  if (request.method === "GET" && download) {
    const artifact = await resolveDownloadGrant(
      env,
      requireToken(download[0]),
      "library",
    );
    return Response.redirect(await presignedDownloadURL(artifact, env), 307);
  }

  if (
    request.method === "POST" &&
    path === "/v1/internal/publications/finalize"
  ) {
    const verified = await verifyServiceRequest(request, env);
    const publication = validatePublication(parseObject(verified.bodyText));
    if (
      verified.channel !== publication.deliveryState ||
      publication.originChannel !== publication.deliveryState
    ) {
      throw new HttpError(403, "service channel is not authorized");
    }
    return json(
      await finalizePublication(
        env,
        publication,
        verified.idempotencyKey,
        verified.bodySha256,
      ),
      201,
    );
  }
  const attach = match(
    path,
    /^\/v1\/internal\/publications\/([^/]+)\/attach-library$/,
  );
  if (request.method === "POST" && attach) {
    const verified = await verifyServiceRequest(request, env);
    const body = parseObject<Record<string, unknown>>(verified.bodyText);
    requireExactKeys(body, ["libraryCredential"], ["alias"]);
    if (typeof body.libraryCredential !== "string") {
      throw new HttpError(400, "libraryCredential is invalid");
    }
    const libraryID = await libraryIDForCredential(body.libraryCredential, env);
    return json(
      await attachLibrary(
        env,
        attach[0],
        libraryID,
        body.alias,
        verified.channel,
      ),
    );
  }
  const quarantine = match(
    path,
    /^\/v1\/internal\/publications\/([^/]+)\/quarantine$/,
  );
  if (request.method === "POST" && quarantine) {
    const verified = await verifyServiceRequest(request, env);
    await quarantinePublication(env, quarantine[0], verified.channel);
    return json({ publicationId: quarantine[0], state: "quarantined" });
  }
  const promotionGrant = match(
    path,
    /^\/v1\/internal\/promotions\/([^/]+)\/grant$/,
  );
  if (request.method === "POST" && promotionGrant) {
    const verified = await verifyServiceRequest(request, env);
    if (verified.channel !== "production") {
      throw new HttpError(403, "production service authorization required");
    }
    return json(await createPromotionGrant(env, promotionGrant[0]), 201);
  }
  const promotionFinalize = match(
    path,
    /^\/v1\/internal\/promotions\/([^/]+)\/finalize$/,
  );
  if (request.method === "POST" && promotionFinalize) {
    const verified = await verifyServiceRequest(request, env);
    const publication = validatePublication(parseObject(verified.bodyText));
    if (
      verified.channel !== "production" ||
      publication.mapEntryId !== promotionFinalize[0] ||
      publication.deliveryState !== "production" ||
      publication.originChannel !== "development"
    ) {
      throw new HttpError(400, "promotion publication is invalid");
    }
    return json(
      await finalizePublication(
        env,
        publication,
        verified.idempotencyKey,
        verified.bodySha256,
      ),
      201,
    );
  }
  const promotionDownload = match(
    path,
    /^\/v1\/internal\/promotions\/downloads\/([^/]+)$/,
  );
  if (request.method === "GET" && promotionDownload) {
    const artifact = await resolveDownloadGrant(
      env,
      requireToken(promotionDownload[0]),
      "promotion",
    );
    return Response.redirect(await presignedDownloadURL(artifact, env), 307);
  }

  const landing = match(path, /^\/(?:dev\/)?s\/([^/]+)$/);
  if (request.method === "GET" && landing) {
    return shareLanding(env, requireToken(landing[0]));
  }

  throw new HttpError(404, "not found");
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      return securityHeaders(await handle(request, env));
    } catch (error) {
      if (error instanceof HttpError) {
        return securityHeaders(json({ error: error.message }, error.status));
      }
      console.error("catalog_request_failed", {
        method: request.method,
        path: new URL(request.url).pathname,
        error: error instanceof Error ? error.name : "unknown",
      });
      return securityHeaders(json({ error: "internal server error" }, 500));
    }
  },
};
