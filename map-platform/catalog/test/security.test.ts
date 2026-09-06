import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

import worker from "../src/index";
import { sha256Hex, verifyServiceRequest } from "../src/security";
import type { Channel, Env } from "../src/types";

const encoder = new TextEncoder();

function attachment(channel: Channel) {
  const publicationID = `publication:${channel}:${"a".repeat(64)}`;
  return {
    path: `/v1/internal/publications/${encodeURIComponent(publicationID)}/attach-library`,
    key: `attach:${publicationID}:${"b".repeat(64)}`,
  };
}

async function signedRequest(
  channel: Channel,
  path: string,
  idempotencyKey: string,
  options: { method?: string; timestamp?: string; badSignature?: boolean } = {},
): Promise<Request> {
  const method = options.method ?? "POST";
  const body = JSON.stringify({
    libraryCredential: "not-a-library-credential",
  });
  const timestamp = options.timestamp ?? String(Math.floor(Date.now() / 1000));
  const canonical = [
    method,
    path,
    timestamp,
    idempotencyKey,
    await sha256Hex(body),
  ].join("\n");
  const secret = (channel === "development" ? "s" : "p").repeat(48);
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = Array.from(
    new Uint8Array(
      await crypto.subtle.sign("HMAC", key, encoder.encode(canonical)),
    ),
    (byte) => byte.toString(16).padStart(2, "0"),
  ).join("");
  return new Request(`https://maps-share.8o.vc${path}`, {
    method,
    body,
    headers: {
      "content-type": "application/json",
      "x-catalog-key-id": `test-${channel}`,
      "x-catalog-timestamp": timestamp,
      "x-catalog-idempotency-key": idempotencyKey,
      "x-catalog-signature": options.badSignature ? "0".repeat(64) : signature,
    },
  });
}

describe("legacy backend attachment authorization", () => {
  it.each(["development", "production"] as const)(
    "accepts signed legacy %s attachment keys without bypassing library authorization",
    async (channel) => {
      const { path, key } = attachment(channel);
      const request = await signedRequest(channel, path, key);
      expect(key.length).toBeGreaterThan(128);
      await expect(
        verifyServiceRequest(
          await signedRequest(channel, path, key),
          env as Env,
        ),
      ).resolves.toMatchObject({
        channel,
        idempotencyKey: key,
      });
      const response = await worker.fetch(request, {
        ...env,
        SERVICE_MUTATION_RATE_LIMITER: {
          async limit() {
            return { success: true };
          },
        },
      } as Env);
      expect(response.status).toBe(401);
      expect(await response.json()).toEqual({
        error: "invalid library authorization",
      });
    },
  );

  it("still accepts compact attachment keys", async () => {
    const { path } = attachment("production");
    const key = `attach:${"c".repeat(64)}`;
    await expect(
      verifyServiceRequest(
        await signedRequest("production", path, key),
        env as Env,
      ),
    ).resolves.toMatchObject({ idempotencyKey: key, channel: "production" });
  });

  it.each([
    [
      "other operation",
      "/v1/internal/publications",
      attachment("production").key,
      "POST",
    ],
    [
      "other publication",
      attachment("development").path,
      attachment("production").key,
      "POST",
    ],
    [
      "other method",
      attachment("production").path,
      attachment("production").key,
      "PUT",
    ],
    [
      "arbitrary long key",
      attachment("production").path,
      "x".repeat(159),
      "POST",
    ],
    [
      "malformed digest",
      attachment("production").path,
      attachment("production").key + "b",
      "POST",
    ],
  ])(
    "rejects %s even with a valid signature",
    async (_label, path, key, method) => {
      await expect(
        verifyServiceRequest(
          await signedRequest("production", path, key, { method }),
          env as Env,
        ),
      ).rejects.toMatchObject({
        status: 401,
        message: "invalid service authorization",
      });
    },
  );

  it("still rejects a bad signature", async () => {
    const { path, key } = attachment("production");
    await expect(
      verifyServiceRequest(
        await signedRequest("production", path, key, { badSignature: true }),
        env as Env,
      ),
    ).rejects.toMatchObject({
      status: 401,
      message: "invalid service authorization",
    });
  });

  it("still rejects expired signatures", async () => {
    const { path, key } = attachment("production");
    const timestamp = String(Math.floor(Date.now() / 1000) - 3600);
    await expect(
      verifyServiceRequest(
        await signedRequest("production", path, key, { timestamp }),
        env as Env,
      ),
    ).rejects.toMatchObject({
      status: 401,
      message: "stale service authorization",
    });
  });
});
