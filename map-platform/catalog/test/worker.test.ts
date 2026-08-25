import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

import worker from "../src/index";

const encoder = new TextEncoder();

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

describe("worker public surfaces", () => {
  it("bootstraps a bearer credential but never caches it", async () => {
    const response = await worker.fetch(
      new Request("https://maps-share-staging.8o.vc/v1/libraries/bootstrap", {
        method: "POST",
      }),
      env,
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
      env,
    );
    expect(refreshed.status).toBe(200);
    expect(await refreshed.json()).toMatchObject({
      libraryId: body.libraryId,
      created: false,
    });
  });

  it("serves path-scoped associated domains without a redirect", async () => {
    const response = await worker.fetch(
      new Request(
        "https://maps-share-staging.8o.vc/.well-known/apple-app-site-association",
      ),
      {
        ...env,
        APPLE_TEAM_ID: "ABCDEFGHIJ",
      },
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
    const denied = await worker.fetch(
      await serviceRequest(path, "test-development", "s".repeat(48)),
      env,
    );
    expect(denied.status).toBe(403);

    const production = await worker.fetch(
      await serviceRequest(path, "test-production", "p".repeat(48)),
      env,
    );
    expect(production.status).toBe(404);
  });
});
