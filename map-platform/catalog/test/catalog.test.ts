import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

import {
  attachLibrary,
  bootstrapLibrary,
  claimShare,
  claimLinkCode,
  createLinkCode,
  createLibraryDownloadGrant,
  createShare,
  finalizePublication,
  getLibraryMap,
  listLibraryMaps,
  revokeShare,
  sharePreview,
  updateAlias,
} from "../src/catalog";
import { HttpError, normalizeAlias, sha256Hex } from "../src/security";
import { libraryIDForCredential } from "../src/security";
import { validatePublication } from "../src/validation";

const receipt = "a".repeat(64);
const streamSha = "b".repeat(64);
const signerSha = "c".repeat(64);
const producerSha = "d".repeat(64);
const imageSha = "e".repeat(64);
const mapEntryID = `map_v1_${"m".repeat(43)}`;
const artifactID = `artifact_v1_${"r".repeat(43)}`;
const appIdentity = {
  build: "202608250001",
  gitSha: "f".repeat(40),
  buildSha256: "9".repeat(64),
};

function publication() {
  return validatePublication({
    publicationId: "job-test-publication",
    mapEntryId: mapEntryID,
    legacyMapId: "test-map",
    contentReceipt: receipt,
    originChannel: "production",
    canonicalName: "Generated Test Map",
    sourceRegionName: "Test Region",
    bounds: [120, 30, 121, 31],
    renderer: "esp32-fmb",
    rendererFormatVersion: 3,
    features: ["3d-buildings", "street-labels"],
    attribution: { source: "OpenStreetMap contributors" },
    generatedAt: "2026-08-25T00:00:00Z",
    deliveryState: "production",
    artifacts: [
      {
        artifactId: artifactID,
        bucketSlot: "production",
        objectKey: `maps/test-map/bike-map-stream-v1/prod/${signerSha}/${producerSha}/${imageSha}/${receipt}.bmap`,
        format: "bike-map-stream-v1",
        mediaType: "application/vnd.openbikecomputer.map-stream",
        filename: "test-map.bmap",
        bytes: 12345,
        sha256: streamSha,
        manifestReceipt: receipt,
        signedManifestReceipt: receipt,
        signatureKeyId: "prod",
        signatureKeySha256: signerSha,
        producerBuildSha256: producerSha,
        producerImageDigest: `sha256:${imageSha}`,
        requiredIosBuild: appIdentity.build,
        requiredIosGitSha: appIdentity.gitSha,
        requiredIosBuildSha256: appIdentity.buildSha256,
        deliveryTier: "production",
      },
    ],
  });
}

async function seededLibrary(): Promise<{
  libraryId: string;
  credential: string;
}> {
  const library = await bootstrapLibrary(env);
  const bodyHash = await sha256Hex(JSON.stringify(publication()));
  await finalizePublication(
    env,
    publication(),
    "test-publication-key",
    bodyHash,
  );
  await attachLibrary(
    env,
    "job-test-publication",
    library.libraryId,
    "My Sunday Route",
    "production",
  );
  return { libraryId: library.libraryId, credential: library.credential! };
}

describe("catalog library", () => {
  it("keeps a private alias separate from immutable map identity", async () => {
    const library = await seededLibrary();
    const original = await getLibraryMap(env, library.libraryId, mapEntryID);
    expect(original.alias).toBe("My Sunday Route");
    expect(original.mapId).toBe("test-map");
    expect(original.artifacts[0].artifactId).toBe(artifactID);

    const renamed = await updateAlias(
      env,
      library.libraryId,
      mapEntryID,
      "  Evening Ride  ",
      original.aliasRevision,
    );
    expect(renamed.alias).toBe("Evening Ride");
    expect(renamed.aliasRevision).toBe(original.aliasRevision + 1);
    expect(renamed.artifacts[0].sha256).toBe(streamSha);

    const list = await listLibraryMaps(env, library.libraryId, null, "50");
    expect(list.maps).toHaveLength(1);
    expect(list.maps[0].alias).toBe("Evening Ride");
  });

  it("creates, claims, and revokes stable shares without exposing object keys", async () => {
    const owner = await seededLibrary();
    const recipient = await bootstrapLibrary(env);
    const share = await createShare(
      env,
      owner.libraryId,
      mapEntryID,
      undefined,
    );
    const token = share.url.split("/").at(-1)!;
    const preview = await sharePreview(env, token);
    expect(preview.title).toBe("My Sunday Route");
    expect(JSON.stringify(preview)).not.toContain("object_key");

    const claimed = await claimShare(env, recipient.libraryId, token);
    expect(claimed.alias).toBe("My Sunday Route");
    await updateAlias(
      env,
      recipient.libraryId,
      mapEntryID,
      "Recipient Name",
      claimed.aliasRevision,
    );
    expect((await getLibraryMap(env, owner.libraryId, mapEntryID)).alias).toBe(
      "My Sunday Route",
    );

    await revokeShare(env, owner.libraryId, share.shareId);
    await expect(sharePreview(env, token)).rejects.toMatchObject({
      status: 404,
    });
    expect(
      (await getLibraryMap(env, recipient.libraryId, mapEntryID)).alias,
    ).toBe("Recipient Name");
  });

  it("never gives production a development-tier artifact", async () => {
    const library = await seededLibrary();
    const grant = await createLibraryDownloadGrant(
      env,
      library.libraryId,
      mapEntryID,
      "production",
      [{ keyId: "prod", keySha256: signerSha }],
      appIdentity,
    );
    expect(grant.artifact.deliveryTier).toBe("production");
    expect(grant.downloadURL).not.toContain("map-artifacts");
  });

  it("rejects a production download from a different app build", async () => {
    const library = await seededLibrary();
    await expect(
      createLibraryDownloadGrant(
        env,
        library.libraryId,
        mapEntryID,
        "production",
        [{ keyId: "prod", keySha256: signerSha }],
        { ...appIdentity, build: "202608250002" },
      ),
    ).rejects.toMatchObject({ status: 409 });
  });

  it("links only an empty fallback library and revokes its old credential", async () => {
    const source = await bootstrapLibrary(env);
    const target = await bootstrapLibrary(env);
    const link = await createLinkCode(env, source.libraryId);
    const claimed = await claimLinkCode(env, target.libraryId, link.code);
    expect(claimed.libraryId).toBe(source.libraryId);
    expect(await libraryIDForCredential(claimed.credential, env)).toBe(
      source.libraryId,
    );
    await expect(
      libraryIDForCredential(target.credential!, env),
    ).rejects.toMatchObject({ status: 401 });
  });

  it("allows only one concurrent claim for a one-time link code", async () => {
    const source = await bootstrapLibrary(env);
    const targets = await Promise.all([
      bootstrapLibrary(env),
      bootstrapLibrary(env),
    ]);
    const link = await createLinkCode(env, source.libraryId);
    const claims = await Promise.allSettled(
      targets.map((target) => claimLinkCode(env, target.libraryId, link.code)),
    );

    const winnerIndex = claims.findIndex(
      (claim) => claim.status === "fulfilled",
    );
    const loserIndex = claims.findIndex((claim) => claim.status === "rejected");
    expect(winnerIndex).toBeGreaterThanOrEqual(0);
    expect(loserIndex).toBeGreaterThanOrEqual(0);
    expect(claims.filter((claim) => claim.status === "fulfilled")).toHaveLength(
      1,
    );
    expect(claims.filter((claim) => claim.status === "rejected")).toHaveLength(
      1,
    );

    const winner = claims[winnerIndex];
    const loser = claims[loserIndex];
    if (winner.status !== "fulfilled" || loser.status !== "rejected") {
      throw new Error("link-code claim result shape is invalid");
    }
    expect(winner.value.libraryId).toBe(source.libraryId);
    expect(await libraryIDForCredential(winner.value.credential, env)).toBe(
      source.libraryId,
    );
    expect(loser.reason).toMatchObject({ status: 404 });
    await expect(
      libraryIDForCredential(targets[winnerIndex].credential!, env),
    ).rejects.toMatchObject({ status: 401 });
    expect(
      await libraryIDForCredential(targets[loserIndex].credential!, env),
    ).toBe(targets[loserIndex].libraryId);
  });
});

describe("validation", () => {
  it("normalizes names and rejects control characters", () => {
    expect(normalizeAlias("  Cafe\u0301 route  ")).toBe("Café route");
    expect(() => normalizeAlias("bad\nname")).toThrow(HttpError);
  });

  it("rejects an idempotency replay with different bytes", async () => {
    await seededLibrary();
    await expect(
      finalizePublication(
        env,
        publication(),
        "test-publication-key",
        "f".repeat(64),
      ),
    ).rejects.toMatchObject({ status: 409 });
  });

  it("rejects changes to every immutable artifact field", async () => {
    await seededLibrary();
    const mutations: Array<
      [
        string,
        (artifact: ReturnType<typeof publication>["artifacts"][number]) => void,
      ]
    > = [
      [
        "artifactId",
        (artifact) => (artifact.artifactId = `artifact_v1_${"s".repeat(43)}`),
      ],
      ["bucketSlot", (artifact) => (artifact.bucketSlot = "development")],
      ["objectKey", (artifact) => (artifact.objectKey += ".other")],
      ["format", (artifact) => (artifact.format = "other-v1")],
      [
        "mediaType",
        (artifact) => (artifact.mediaType = "application/octet-stream"),
      ],
      ["filename", (artifact) => (artifact.filename = "other.bmap")],
      ["bytes", (artifact) => (artifact.bytes += 1)],
      ["sha256", (artifact) => (artifact.sha256 = "0".repeat(64))],
      [
        "manifestReceipt",
        (artifact) => (artifact.manifestReceipt = "1".repeat(64)),
      ],
      [
        "signedManifestReceipt",
        (artifact) => (artifact.signedManifestReceipt = "2".repeat(64)),
      ],
      ["signatureKeyId", (artifact) => (artifact.signatureKeyId = "other")],
      [
        "signatureKeySha256",
        (artifact) => (artifact.signatureKeySha256 = "3".repeat(64)),
      ],
      [
        "producerBuildSha256",
        (artifact) => (artifact.producerBuildSha256 = "4".repeat(64)),
      ],
      [
        "producerImageDigest",
        (artifact) =>
          (artifact.producerImageDigest = `sha256:${"5".repeat(64)}`),
      ],
      [
        "requiredIosBuild",
        (artifact) => (artifact.requiredIosBuild = "202608250002"),
      ],
      [
        "requiredIosGitSha",
        (artifact) => (artifact.requiredIosGitSha = "a".repeat(40)),
      ],
      [
        "requiredIosBuildSha256",
        (artifact) => (artifact.requiredIosBuildSha256 = "6".repeat(64)),
      ],
      [
        "requiredFirmwareVersion",
        (artifact) => (artifact.requiredFirmwareVersion = "1.0.0"),
      ],
      [
        "requiredFirmwareBuild",
        (artifact) => (artifact.requiredFirmwareBuild = 1),
      ],
      [
        "requiredFirmwareGitSha",
        (artifact) => (artifact.requiredFirmwareGitSha = "b".repeat(40)),
      ],
      ["deliveryTier", (artifact) => (artifact.deliveryTier = "development")],
    ];

    for (const [field, mutate] of mutations) {
      const candidate = publication();
      candidate.publicationId = `job-conflict-${field}`;
      mutate(candidate.artifacts[0]);
      await expect(
        finalizePublication(
          env,
          candidate,
          `conflict:${field}`,
          await sha256Hex(JSON.stringify(candidate)),
        ),
      ).rejects.toMatchObject({ status: 409 });
    }

    const eventCount = await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM publication_events",
    ).first<{ count: number }>();
    expect(eventCount?.count).toBe(1);
  });
});
