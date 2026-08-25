import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

import worker from "../src/index";
import type { Env } from "../src/types";

const encoder = new TextEncoder();

function rateLimiter(success: boolean, keys: string[]): RateLimit {
  return {
    async limit({ key }) {
      keys.push(key);
      return { success };
    },
  };
}

function workerEnv(overrides: Partial<Env> = {}): Env {
  const allow = () => rateLimiter(true, []);
  return {
    ...env,
    LIBRARY_BOOTSTRAP_CLIENT_RATE_LIMITER: allow(),
    LIBRARY_BOOTSTRAP_GLOBAL_RATE_LIMITER: allow(),
    SHARE_CREATE_RATE_LIMITER: allow(),
    SHARE_PREVIEW_RATE_LIMITER: allow(),
    SHARE_LANDING_RATE_LIMITER: allow(),
    SHARE_CLAIM_RATE_LIMITER: allow(),
    LINK_CODE_CREATE_RATE_LIMITER: allow(),
    LINK_CODE_CLAIM_RATE_LIMITER: allow(),
    PROMOTION_RATE_LIMITER: allow(),
    PUBLIC_MUTATION_GLOBAL_RATE_LIMITER: allow(),
    LIBRARY_MUTATION_RATE_LIMITER: allow(),
    SERVICE_MUTATION_RATE_LIMITER: allow(),
    ...overrides,
  } as Env;
}

function hex(bytes: ArrayBuffer): string {
  return Array.from(new Uint8Array(bytes), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
}

async function serviceRequest(
  path: string,
  keyID: string,
  secret: string,
): Promise<Request> {
  const body = "{}";
  const timestamp = String(Math.floor(Date.now() / 1000));
  const idempotencyKey = `test-request:${keyID}`;
  const bodySha256 = hex(
    await crypto.subtle.digest("SHA-256", encoder.encode(body)),
  );
  const canonical = ["POST", path, timestamp, idempotencyKey, bodySha256].join(
    "\n",
  );
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = hex(
    await crypto.subtle.sign("HMAC", key, encoder.encode(canonical)),
  );
  return new Request(`https://maps-share-staging.8o.vc${path}`, {
    method: "POST",
    body,
    headers: {
      "content-type": "application/json",
      "x-catalog-key-id": keyID,
      "x-catalog-timestamp": timestamp,
      "x-catalog-idempotency-key": idempotencyKey,
      "x-catalog-signature": signature,
    },
  });
}

async function bootstrapCredential(): Promise<{
  credential: string;
  libraryId: string;
}> {
  const response = await worker.fetch(
    new Request("https://maps-share-staging.8o.vc/v1/libraries/bootstrap", {
      method: "POST",
    }),
    workerEnv(),
  );
  expect(response.status).toBe(201);
  return response.json();
}

describe("worker public surfaces", () => {
  it("bootstraps a bearer credential but never caches it", async () => {
    const response = await worker.fetch(
      new Request("https://maps-share-staging.8o.vc/v1/libraries/bootstrap", {
        method: "POST",
      }),
      workerEnv(),
    );
    expect(response.status).toBe(201);
    expect(response.headers.get("cache-control")).toBe("no-store");
    const body = (await response.json()) as {
      credential: string;
      libraryId: string;
    };
    expect(body.credential).toMatch(/^[A-Za-z0-9_-]{43}$/);

    const refreshed = await worker.fetch(
      new Request("https://maps-share-staging.8o.vc/v1/libraries/bootstrap", {
        method: "POST",
        headers: { authorization: `Bearer ${body.credential}` },
      }),
      workerEnv(),
    );
    expect(refreshed.status).toBe(200);
    expect(await refreshed.json()).toMatchObject({
      libraryId: body.libraryId,
      created: false,
    });
  });

  it("keeps the accepting bearer usable when a link claim response is lost", async () => {
    async function bootstrap(): Promise<{
      credential: string;
      libraryId: string;
    }> {
      const response = await worker.fetch(
        new Request("https://maps-share-staging.8o.vc/v1/libraries/bootstrap", {
          method: "POST",
        }),
        workerEnv(),
      );
      expect(response.status).toBe(201);
      return response.json();
    }

    const source = await bootstrap();
    const target = await bootstrap();
    const linkResponse = await worker.fetch(
      new Request("https://maps-share-staging.8o.vc/v1/libraries/link-codes", {
        method: "POST",
        headers: { authorization: `Bearer ${source.credential}` },
      }),
      workerEnv(),
    );
    expect(linkResponse.status).toBe(201);
    const link = (await linkResponse.json()) as { code: string };
    const claimURL = `https://maps-share-staging.8o.vc/v1/libraries/link-codes/${link.code}/claim`;
    const claim = await worker.fetch(
      new Request(claimURL, {
        method: "POST",
        headers: { authorization: `Bearer ${target.credential}` },
      }),
      workerEnv(),
    );
    expect(claim.status).toBe(200);
    expect(await claim.json()).toEqual({ libraryId: source.libraryId });

    const retry = await worker.fetch(
      new Request(claimURL, {
        method: "POST",
        headers: { authorization: `Bearer ${target.credential}` },
      }),
      workerEnv(),
    );
    expect(retry.status).toBe(200);
    expect(await retry.json()).toEqual({ libraryId: source.libraryId });
    const refresh = await worker.fetch(
      new Request("https://maps-share-staging.8o.vc/v1/libraries/bootstrap", {
        method: "POST",
        headers: { authorization: `Bearer ${target.credential}` },
      }),
      workerEnv(),
    );
    expect(await refresh.json()).toMatchObject({
      libraryId: source.libraryId,
      created: false,
    });
  });

  it("rate limits unauthenticated bootstrap before writing to D1", async () => {
    const clientKeys: string[] = [];
    const globalKeys: string[] = [];
    const before = await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM libraries",
    ).first<{ count: number }>();
    const response = await worker.fetch(
      new Request("https://maps-share-staging.8o.vc/v1/libraries/bootstrap", {
        method: "POST",
        headers: { "cf-connecting-ip": "203.0.113.7" },
      }),
      workerEnv({
        LIBRARY_BOOTSTRAP_CLIENT_RATE_LIMITER: rateLimiter(false, clientKeys),
        LIBRARY_BOOTSTRAP_GLOBAL_RATE_LIMITER: rateLimiter(true, globalKeys),
      }),
    );

    expect(response.status).toBe(429);
    expect(await response.json()).toEqual({
      error: "library bootstrap rate limit exceeded",
    });
    expect(clientKeys).toEqual(["library-bootstrap:203.0.113.7"]);
    expect(globalKeys).toEqual(["library-bootstrap"]);
    const libraries = await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM libraries",
    ).first<{ count: number }>();
    expect(libraries?.count).toBe(before?.count);
  });

  it("fails closed when the bootstrap rate limiter is unavailable", async () => {
    const before = await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM libraries",
    ).first<{ count: number }>();
    const response = await worker.fetch(
      new Request("https://maps-share-staging.8o.vc/v1/libraries/bootstrap", {
        method: "POST",
      }),
      workerEnv({
        LIBRARY_BOOTSTRAP_CLIENT_RATE_LIMITER: {
          async limit() {
            throw new Error("rate limiter unavailable");
          },
        },
        LIBRARY_BOOTSTRAP_GLOBAL_RATE_LIMITER: rateLimiter(true, []),
      }),
    );

    expect(response.status).toBe(503);
    const libraries = await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM libraries",
    ).first<{ count: number }>();
    expect(libraries?.count).toBe(before?.count);
  });

  it("applies endpoint-specific public limits with library and client keys", async () => {
    const library = await bootstrapCredential();
    const authorization = { authorization: `Bearer ${library.credential}` };
    const credentialHash = hex(
      await crypto.subtle.digest("SHA-256", encoder.encode(library.credential)),
    );
    const mapID = `map_v1_${"m".repeat(43)}`;
    const endpointCases: Array<{
      request: Request;
      binding: keyof Env;
      expectedKey: string;
    }> = [
      {
        request: new Request(
          `https://maps-share-staging.8o.vc/v1/library/maps/${mapID}/shares`,
          { method: "POST", headers: authorization },
        ),
        binding: "SHARE_CREATE_RATE_LIMITER",
        expectedKey: `share-create:${library.libraryId}`,
      },
      {
        request: new Request(
          `https://maps-share-staging.8o.vc/v1/shares/${"A".repeat(43)}/claim`,
          { method: "POST", headers: authorization },
        ),
        binding: "SHARE_CLAIM_RATE_LIMITER",
        expectedKey: `share-claim:${library.libraryId}`,
      },
      {
        request: new Request(
          "https://maps-share-staging.8o.vc/v1/libraries/link-codes",
          { method: "POST", headers: authorization },
        ),
        binding: "LINK_CODE_CREATE_RATE_LIMITER",
        expectedKey: `link-code-create:${library.libraryId}`,
      },
      {
        request: new Request(
          "https://maps-share-staging.8o.vc/v1/libraries/link-codes/AAAA-BBBB/claim",
          { method: "POST", headers: authorization },
        ),
        binding: "LINK_CODE_CLAIM_RATE_LIMITER",
        expectedKey: `link-code-claim:${credentialHash}`,
      },
      {
        request: new Request(
          `https://maps-share-staging.8o.vc/v1/shares/${"A".repeat(43)}`,
          { headers: { "cf-connecting-ip": "203.0.113.9" } },
        ),
        binding: "SHARE_PREVIEW_RATE_LIMITER",
        expectedKey: "share-preview:203.0.113.9",
      },
      {
        request: new Request(
          `https://maps-share-staging.8o.vc/s/${"A".repeat(43)}`,
          { headers: { "cf-connecting-ip": "203.0.113.9" } },
        ),
        binding: "SHARE_LANDING_RATE_LIMITER",
        expectedKey: "share-landing:203.0.113.9",
      },
    ];

    for (const endpoint of endpointCases) {
      const keys: string[] = [];
      const response = await worker.fetch(
        endpoint.request,
        workerEnv({
          [endpoint.binding]: rateLimiter(false, keys),
        }),
      );
      expect(response.status, endpoint.binding).toBe(429);
      expect(keys, endpoint.binding).toEqual([endpoint.expectedKey]);
    }
  });

  it("fails closed when an endpoint limiter is unavailable", async () => {
    const response = await worker.fetch(
      new Request(
        `https://maps-share-staging.8o.vc/v1/shares/${"A".repeat(43)}`,
      ),
      workerEnv({
        SHARE_PREVIEW_RATE_LIMITER: {
          async limit() {
            throw new Error("unavailable");
          },
        },
      }),
    );
    expect(response.status).toBe(503);
  });

  it("keeps read-only pagination outside mutation counters", async () => {
    const library = await bootstrapCredential();
    const response = await worker.fetch(
      new Request("https://maps-share-staging.8o.vc/v1/library/maps", {
        headers: { authorization: `Bearer ${library.credential}` },
      }),
      workerEnv({
        PUBLIC_MUTATION_GLOBAL_RATE_LIMITER: rateLimiter(false, []),
        LIBRARY_MUTATION_RATE_LIMITER: rateLimiter(false, []),
      }),
    );
    expect(response.status).toBe(200);
  });

  it("refreshes stale credential activity once without writing on every read", async () => {
    const library = await bootstrapCredential();
    const credentialHash = hex(
      await crypto.subtle.digest("SHA-256", encoder.encode(library.credential)),
    );
    await env.DB.prepare(
      "UPDATE library_credentials SET last_used_at = ? WHERE credential_hash = ?",
    )
      .bind("2020-01-01T00:00:00.000Z", credentialHash)
      .run();
    const request = () =>
      new Request("https://maps-share-staging.8o.vc/v1/library/maps", {
        headers: { authorization: `Bearer ${library.credential}` },
      });
    expect((await worker.fetch(request(), workerEnv())).status).toBe(200);
    const first = await env.DB.prepare(
      "SELECT last_used_at FROM library_credentials WHERE credential_hash = ?",
    )
      .bind(credentialHash)
      .first<{ last_used_at: string }>();
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect((await worker.fetch(request(), workerEnv())).status).toBe(200);
    const second = await env.DB.prepare(
      "SELECT last_used_at FROM library_credentials WHERE credential_hash = ?",
    )
      .bind(credentialHash)
      .first<{ last_used_at: string }>();
    expect(first?.last_used_at).not.toBe("2020-01-01T00:00:00.000Z");
    expect(second?.last_used_at).toBe(first?.last_used_at);
  });

  it("authenticates map detach and keeps repeated valid IDs idempotent", async () => {
    const library = await bootstrapCredential();
    const validURL = `https://maps-share-staging.8o.vc/v1/library/maps/map_v1_${"d".repeat(43)}`;
    const unauthorized = await worker.fetch(
      new Request(validURL, { method: "DELETE" }),
      workerEnv(),
    );
    expect(unauthorized.status).toBe(401);
    for (let attempt = 0; attempt < 2; attempt += 1) {
      const response = await worker.fetch(
        new Request(validURL, {
          method: "DELETE",
          headers: { authorization: `Bearer ${library.credential}` },
        }),
        workerEnv(),
      );
      expect(response.status).toBe(204);
    }
    const malformed = await worker.fetch(
      new Request(
        "https://maps-share-staging.8o.vc/v1/library/maps/not-a-map",
        {
          method: "DELETE",
          headers: { authorization: `Bearer ${library.credential}` },
        },
      ),
      workerEnv(),
    );
    expect(malformed.status).toBe(404);
  });

  it("serves path-scoped associated domains without a redirect", async () => {
    const response = await worker.fetch(
      new Request(
        "https://maps-share-staging.8o.vc/.well-known/apple-app-site-association",
      ),
      workerEnv({
        APPLE_TEAM_ID: "ABCDEFGHIJ",
      }),
    );
    expect(response.status).toBe(200);
    const body = (await response.json()) as {
      applinks: {
        details: Array<{ appID: string; components: Array<{ "/": string }> }>;
      };
    };
    expect(body.applinks.details[0].components[0]["/"]).toBe("/s/*");
    expect(body.applinks.details[1].components[0]["/"]).toBe("/dev/s/*");
  });

  it("prevents a development service principal from invoking promotion", async () => {
    const path = `/v1/internal/promotions/map_v1_${"m".repeat(43)}/grant`;
    const promotionKeys: string[] = [];
    const denied = await worker.fetch(
      await serviceRequest(path, "test-development", "s".repeat(48)),
      workerEnv(),
    );
    expect(denied.status).toBe(403);

    const production = await worker.fetch(
      await serviceRequest(path, "test-production", "p".repeat(48)),
      workerEnv({
        PROMOTION_RATE_LIMITER: rateLimiter(true, promotionKeys),
      }),
    );
    expect(production.status).toBe(404);
    expect(promotionKeys).toEqual([`promotion:map_v1_${"m".repeat(43)}`]);
  });

  it("isolates trusted service mutations from exhausted public counters", async () => {
    const path = `/v1/internal/promotions/map_v1_${"m".repeat(43)}/grant`;
    const serviceKeys: string[] = [];
    const response = await worker.fetch(
      await serviceRequest(path, "test-production", "p".repeat(48)),
      workerEnv({
        PUBLIC_MUTATION_GLOBAL_RATE_LIMITER: rateLimiter(false, []),
        SERVICE_MUTATION_RATE_LIMITER: rateLimiter(true, serviceKeys),
      }),
    );
    expect(response.status).toBe(404);
    expect(serviceKeys).toEqual(["service-mutation:production"]);
  });
});
