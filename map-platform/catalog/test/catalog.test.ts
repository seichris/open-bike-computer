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
});
