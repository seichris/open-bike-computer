import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

import {
  attachLibrary,
  bootstrapLibrary,
  claimRetentionDeletion,
  claimShare,
  claimLinkCode,
  createLinkCode,
  createLibraryDownloadGrant,
  createPromotionGrant,
  createShare,
  confirmRetentionDeletion,
  detachLibraryMap,
  finalizePublication,
  getLibraryMap,
  listLibraryMaps,
  listShares,
  prepareRetentionAuthorizations,
  quarantinePublication,
  renewPromotionLease,
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
const verifyTestArtifact = async () => true;
let fixtureSequence = 0;

function fixtureID(kind: "map" | "artifact"): string {
  const suffix = (fixtureSequence++).toString(36).padStart(8, "0");
  return `${kind}_v1_${"Q".repeat(35)}${suffix}`;
}

async function seedLibraryMapCount(
  libraryID: string,
  desiredCount: number,
): Promise<string[]> {
  const existing = await env.DB.prepare(
    "SELECT COUNT(*) AS count FROM library_maps WHERE library_id = ?",
  )
    .bind(libraryID)
    .first<{ count: number }>();
  const mapIDs = Array.from(
    { length: Math.max(0, desiredCount - (existing?.count ?? 0)) },
    () => fixtureID("map"),
  );
  const now = new Date().toISOString();
  const statements = mapIDs.flatMap((id) => [
    env.DB.prepare(
      `INSERT INTO map_entries(
         id, legacy_map_id, content_receipt, origin_channel, canonical_name,
         source_region_name, bounds_json, renderer, renderer_format_version,
         features_json, attribution_json, generated_at, delivery_state,
         created_at, updated_at
       ) SELECT ?, ?, content_receipt, origin_channel, ?, source_region_name,
                bounds_json, renderer, renderer_format_version, features_json,
                attribution_json, generated_at, delivery_state, ?, ?
           FROM map_entries WHERE id = ?`,
    ).bind(
      id,
      `quota-${id.slice(-8)}`,
      `Quota ${id.slice(-8)}`,
      now,
      now,
      mapEntryID,
    ),
    env.DB.prepare(
      `INSERT INTO library_maps(
         library_id, map_entry_id, alias, alias_source, added_at, updated_at
       ) VALUES (?, ?, ?, 'generated', ?, ?)`,
    ).bind(libraryID, id, `Quota ${id.slice(-8)}`, now, now),
  ]);
  for (let index = 0; index < statements.length; index += 50) {
    await env.DB.batch(statements.slice(index, index + 50));
  }
  return mapIDs;
}

function uniquePublication(label: string) {
  const candidate = publication();
  const uniqueMapID = fixtureID("map");
  const uniqueArtifactID = fixtureID("artifact");
  const identity = fixtureSequence.toString(16).padStart(64, "0").slice(-64);
  candidate.publicationId = `job-${label}-${uniqueMapID.slice(-8)}`;
  candidate.mapEntryId = uniqueMapID;
  candidate.legacyMapId = `${label}-${uniqueMapID.slice(-8)}`;
  candidate.contentReceipt = identity;
  candidate.artifacts[0].artifactId = uniqueArtifactID;
  candidate.artifacts[0].objectKey = `${candidate.artifacts[0].objectKey}.${uniqueMapID.slice(-8)}`;
  candidate.artifacts[0].manifestReceipt = identity;
  candidate.artifacts[0].signedManifestReceipt = identity;
  return candidate;
}

function developmentPublication(label: string) {
  const candidate = uniquePublication(label);
  candidate.originChannel = "development";
  candidate.deliveryState = "development";
  const artifact = candidate.artifacts[0];
  artifact.bucketSlot = "development";
  artifact.deliveryTier = "development";
  artifact.format = "zip-stored-v1";
  artifact.mediaType = "application/zip";
  artifact.filename = `${candidate.legacyMapId}.zip`;
  artifact.objectKey = `maps/${candidate.legacyMapId}/zip-stored-v1/${artifact.sha256}.zip`;
  artifact.signedManifestReceipt = null;
  artifact.signatureKeyId = null;
  artifact.signatureKeySha256 = null;
  artifact.producerBuildSha256 = null;
  artifact.producerImageDigest = null;
  artifact.requiredIosBuild = null;
  artifact.requiredIosGitSha = null;
  artifact.requiredIosBuildSha256 = null;
  return candidate;
}

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
    null,
    verifyTestArtifact,
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

  it("loads artifacts for a library page with one batched D1 query", async () => {
    const library = await seededLibrary();
    const second = publication();
    second.publicationId = "job-second-library-map";
    second.mapEntryId = `map_v1_${"z".repeat(43)}`;
    second.legacyMapId = "second-library-map";
    second.contentReceipt = "1".repeat(64);
    second.artifacts[0].artifactId = `artifact_v1_${"z".repeat(43)}`;
    second.artifacts[0].objectKey = second.artifacts[0].objectKey.replace(
      "test-map",
      "second-library-map",
    );
    await finalizePublication(
      env,
      second,
      "second-library-map",
      await sha256Hex(JSON.stringify(second)),
      null,
      verifyTestArtifact,
    );
    await attachLibrary(
      env,
      second.publicationId,
      library.libraryId,
      undefined,
      "production",
    );

    let artifactQueries = 0;
    const countedEnv = {
      ...env,
      DB: new Proxy(env.DB, {
        get(target, property, receiver) {
          if (property === "prepare") {
            return (query: string) => {
              if (query.includes("FROM artifacts")) artifactQueries += 1;
              return target.prepare(query);
            };
          }
          const value = Reflect.get(target, property, receiver) as unknown;
          return typeof value === "function" ? value.bind(target) : value;
        },
      }),
    } as typeof env;
    const page = await listLibraryMaps(
      countedEnv,
      library.libraryId,
      null,
      "50",
    );

    expect(page.maps.map((map) => map.mapEntryId)).toContain(second.mapEntryId);
    expect(artifactQueries).toBe(1);
  });

  it("atomically enforces the map quota and recovers capacity after detach", async () => {
    const library = await seededLibrary();
    await seedLibraryMapCount(library.libraryId, 99);
    const candidates = [
      uniquePublication("quota-a"),
      uniquePublication("quota-b"),
    ];
    for (const candidate of candidates) {
      await finalizePublication(
        env,
        candidate,
        candidate.publicationId,
        await sha256Hex(JSON.stringify(candidate)),
        null,
        verifyTestArtifact,
      );
    }

    const boundary = await Promise.allSettled(
      candidates.map((candidate) =>
        attachLibrary(
          env,
          candidate.publicationId,
          library.libraryId,
          undefined,
          "production",
        ),
      ),
    );
    expect(
      boundary.filter((result) => result.status === "fulfilled"),
    ).toHaveLength(1);
    expect(
      boundary.filter((result) => result.status === "rejected"),
    ).toHaveLength(1);
    const winnerIndex = boundary.findIndex(
      (result) => result.status === "fulfilled",
    );
    const loserIndex = boundary.findIndex(
      (result) => result.status === "rejected",
    );
    if (winnerIndex < 0 || loserIndex < 0) {
      throw new Error("map quota result shape is invalid");
    }
    await detachLibraryMap(
      env,
      library.libraryId,
      candidates[winnerIndex].mapEntryId,
    );
    await expect(
      attachLibrary(
        env,
        candidates[loserIndex].publicationId,
        library.libraryId,
        undefined,
        "production",
      ),
    ).resolves.toMatchObject({ mapEntryId: candidates[loserIndex].mapEntryId });
    expect(
      await env.DB.prepare(
        "SELECT COUNT(*) AS count FROM library_maps WHERE library_id = ?",
      )
        .bind(library.libraryId)
        .first<{ count: number }>(),
    ).toMatchObject({ count: 100 });
  });

  it("atomically enforces share quotas and purges only inactive rows beyond grace", async () => {
    const owner = await seededLibrary();
    const now = new Date().toISOString();
    const recentRevoked = "share_recent_revoked_keep";
    const rows = Array.from({ length: 499 }, (_, index) => ({
      id:
        index === 100
          ? recentRevoked
          : `share_quota_${index.toString().padStart(4, "0")}`,
      tokenHash: `${index + 1000}`.padStart(64, "0"),
      revokedAt: index < 99 ? null : now,
    }));
    const statements = rows.map((row) =>
      env.DB.prepare(
        `INSERT INTO shares(
           id, token_hash, owner_library_id, map_entry_id, title_snapshot,
           created_at, revoked_at
         ) VALUES (?, ?, ?, ?, 'Quota map', ?, ?)`,
      ).bind(
        row.id,
        row.tokenHash,
        owner.libraryId,
        mapEntryID,
        now,
        row.revokedAt,
      ),
    );
    for (let index = 0; index < statements.length; index += 50) {
      await env.DB.batch(statements.slice(index, index + 50));
    }

    const boundary = await Promise.allSettled([
      createShare(env, owner.libraryId, mapEntryID, undefined),
      createShare(env, owner.libraryId, mapEntryID, undefined),
    ]);
    expect(
      boundary.filter((result) => result.status === "fulfilled"),
    ).toHaveLength(1);
    expect(
      boundary.filter((result) => result.status === "rejected"),
    ).toHaveLength(1);
    const liveShare = boundary.find((result) => result.status === "fulfilled");
    if (liveShare?.status !== "fulfilled") {
      throw new Error("share quota result shape is invalid");
    }
    await revokeShare(env, owner.libraryId, liveShare.value.shareId);
    await env.DB.prepare(
      "UPDATE shares SET revoked_at = ? WHERE id = 'share_quota_0101'",
    )
      .bind("2020-01-01T00:00:00.000Z")
      .run();
    await expect(
      createShare(env, owner.libraryId, mapEntryID, undefined),
    ).resolves.toMatchObject({ shareId: expect.any(String) });
    expect(
      await env.DB.prepare(
        "SELECT COUNT(*) AS count FROM shares WHERE owner_library_id = ?",
      )
        .bind(owner.libraryId)
        .first<{ count: number }>(),
    ).toMatchObject({ count: 500 });
    expect(
      await env.DB.prepare("SELECT COUNT(*) AS count FROM shares WHERE id = ?")
        .bind(recentRevoked)
        .first<{ count: number }>(),
    ).toMatchObject({ count: 1 });
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

  it("does not claim a share revoked after preview but before the D1 batch", async () => {
    const owner = await seededLibrary();
    const recipient = await bootstrapLibrary(env);
    const share = await createShare(
      env,
      owner.libraryId,
      mapEntryID,
      undefined,
    );
    const token = share.url.split("/").at(-1)!;
    let revoked = false;
    const raceEnv = {
      ...env,
      DB: new Proxy(env.DB, {
        get(target, property, receiver) {
          if (property === "batch") {
            return async (statements: D1PreparedStatement[]) => {
              if (!revoked) {
                revoked = true;
                await revokeShare(env, owner.libraryId, share.shareId);
              }
              return target.batch(statements);
            };
          }
          const value = Reflect.get(target, property, receiver) as unknown;
          return typeof value === "function" ? value.bind(target) : value;
        },
      }),
    } as typeof env;

    await expect(
      claimShare(raceEnv, recipient.libraryId, token),
    ).rejects.toMatchObject({ status: 404 });
    expect(
      await env.DB.prepare(
        `SELECT COUNT(*) AS count FROM library_maps
          WHERE library_id = ? AND map_entry_id = ?`,
      )
        .bind(recipient.libraryId, mapEntryID)
        .first<{ count: number }>(),
    ).toMatchObject({ count: 0 });
    expect(
      await env.DB.prepare(
        "SELECT COUNT(*) AS count FROM share_claims WHERE share_id = ?",
      )
        .bind(share.shareId)
        .first<{ count: number }>(),
    ).toMatchObject({ count: 0 });
  });

  it("enforces claimed-map quota atomically and preserves idempotent retries", async () => {
    const owner = await seededLibrary();
    const shared = uniquePublication("claimed-quota");
    await finalizePublication(
      env,
      shared,
      shared.publicationId,
      await sha256Hex(JSON.stringify(shared)),
      null,
      verifyTestArtifact,
    );
    await attachLibrary(
      env,
      shared.publicationId,
      owner.libraryId,
      undefined,
      "production",
    );
    const share = await createShare(
      env,
      owner.libraryId,
      shared.mapEntryId,
      undefined,
    );
    const token = share.url.split("/").at(-1)!;
    const recipient = await seededLibrary();
    const quotaMaps = await seedLibraryMapCount(recipient.libraryId, 100);

    await expect(
      claimShare(env, recipient.libraryId, token),
    ).rejects.toMatchObject({ status: 409 });
    expect(
      await env.DB.prepare(
        "SELECT COUNT(*) AS count FROM share_claims WHERE share_id = ?",
      )
        .bind(share.shareId)
        .first<{ count: number }>(),
    ).toMatchObject({ count: 0 });

    await detachLibraryMap(env, recipient.libraryId, quotaMaps[0]);
    await claimShare(env, recipient.libraryId, token);
    await claimShare(env, recipient.libraryId, token);
    expect(
      await env.DB.prepare("SELECT claim_count FROM shares WHERE id = ?")
        .bind(share.shareId)
        .first<{ claim_count: number }>(),
    ).toMatchObject({ claim_count: 1 });
    expect(
      await env.DB.prepare(
        "SELECT COUNT(*) AS count FROM library_maps WHERE library_id = ?",
      )
        .bind(recipient.libraryId)
        .first<{ count: number }>(),
    ).toMatchObject({ count: 100 });
  });

  it("caps same-map share claims and detach recovers claim capacity and counts", async () => {
    const owner = await seededLibrary();
    const recipient = await seededLibrary();
    const tokens = Array.from({ length: 501 }, (_, index) =>
      index.toString(36).padStart(43, "A"),
    );
    const tokenHashes = await Promise.all(
      tokens.map((token) => sha256Hex(token)),
    );
    const now = new Date().toISOString();
    const statements: D1PreparedStatement[] = [];
    for (let index = 0; index < tokens.length; index += 1) {
      const shareID = `share_claim_quota_${index.toString().padStart(3, "0")}`;
      statements.push(
        env.DB.prepare(
          `INSERT INTO shares(
             id, token_hash, owner_library_id, map_entry_id, title_snapshot,
             created_at, claim_count
           ) VALUES (?, ?, ?, ?, 'Claim quota map', ?, ?)`,
        ).bind(
          shareID,
          tokenHashes[index],
          owner.libraryId,
          mapEntryID,
          now,
          index < 500 ? 1 : 0,
        ),
      );
      if (index < 500) {
        statements.push(
          env.DB.prepare(
            `INSERT INTO share_claims(share_id, recipient_library_id, claimed_at)
             VALUES (?, ?, ?)`,
          ).bind(shareID, recipient.libraryId, now),
        );
      }
    }
    for (let index = 0; index < statements.length; index += 50) {
      await env.DB.batch(statements.slice(index, index + 50));
    }

    await expect(
      claimShare(env, recipient.libraryId, tokens[0]),
    ).resolves.toMatchObject({ mapEntryId: mapEntryID });
    await expect(
      claimShare(env, recipient.libraryId, tokens[500]),
    ).rejects.toMatchObject({ status: 409 });

    await detachLibraryMap(env, recipient.libraryId, mapEntryID);
    expect(
      await env.DB.prepare(
        "SELECT COUNT(*) AS count FROM share_claims WHERE recipient_library_id = ?",
      )
        .bind(recipient.libraryId)
        .first<{ count: number }>(),
    ).toMatchObject({ count: 0 });
    expect(
      await env.DB.prepare(
        `SELECT COUNT(*) AS count FROM shares
          WHERE id LIKE 'share_claim_quota_%' AND claim_count <> 0`,
      ).first<{ count: number }>(),
    ).toMatchObject({ count: 0 });

    await attachLibrary(
      env,
      "job-test-publication",
      recipient.libraryId,
      undefined,
      "production",
    );
    await claimShare(env, recipient.libraryId, tokens[500]);
    expect(
      await env.DB.prepare(
        "SELECT claim_count FROM shares WHERE id = 'share_claim_quota_500'",
      ).first<{ claim_count: number }>(),
    ).toMatchObject({ claim_count: 1 });
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

  it("boundedly purges expired download grants while creating a new grant", async () => {
    const library = await seededLibrary();
    const statements = Array.from({ length: 30 }, (_, index) =>
      env.DB.prepare(
        `INSERT INTO download_grants(
           token_hash, library_id, artifact_id, purpose, created_at, expires_at
         ) VALUES (?, ?, ?, 'library', ?, ?)`,
      ).bind(
        `expired-download-${index.toString().padStart(3, "0")}`,
        library.libraryId,
        artifactID,
        "2019-01-01T00:00:00.000Z",
        "2020-01-01T00:00:00.000Z",
      ),
    );
    await env.DB.batch(statements);

    await createLibraryDownloadGrant(
      env,
      library.libraryId,
      mapEntryID,
      "production",
      [{ keyId: "prod", keySha256: signerSha }],
      appIdentity,
    );
    expect(
      await env.DB.prepare(
        `SELECT COUNT(*) AS count FROM download_grants
          WHERE token_hash LIKE 'expired-download-%'`,
      ).first<{ count: number }>(),
    ).toMatchObject({ count: 5 });
  });

  it("atomically merges a populated library and survives a lost claim response", async () => {
    const source = await seededLibrary();
    const target = await seededLibrary();
    const additionalTargetCredential = await bootstrapLibrary(env);
    const addCredentialCode = await createLinkCode(env, target.libraryId);
    await claimLinkCode(
      env,
      additionalTargetCredential.libraryId,
      await sha256Hex(additionalTargetCredential.credential!),
      addCredentialCode.code,
    );
    const targetDuplicate = await getLibraryMap(
      env,
      target.libraryId,
      mapEntryID,
    );
    await updateAlias(
      env,
      target.libraryId,
      mapEntryID,
      "Target duplicate alias",
      targetDuplicate.aliasRevision,
    );

    const unique = publication();
    unique.publicationId = "job-link-merge-unique-map";
    unique.mapEntryId = `map_v1_${"l".repeat(43)}`;
    unique.legacyMapId = "link-merge-map";
    unique.contentReceipt = "7".repeat(64);
    unique.artifacts[0].artifactId = `artifact_v1_${"l".repeat(43)}`;
    unique.artifacts[0].objectKey = unique.artifacts[0].objectKey.replace(
      "test-map",
      "link-merge-map",
    );
    unique.artifacts[0].manifestReceipt = unique.contentReceipt;
    unique.artifacts[0].signedManifestReceipt = unique.contentReceipt;
    await finalizePublication(
      env,
      unique,
      "link-merge-unique-map",
      await sha256Hex(JSON.stringify(unique)),
      null,
      verifyTestArtifact,
    );
    await attachLibrary(
      env,
      unique.publicationId,
      target.libraryId,
      "Target-only map",
      "production",
    );

    const targetShare = await createShare(
      env,
      target.libraryId,
      unique.mapEntryId,
      undefined,
    );
    const sourceShare = await createShare(
      env,
      source.libraryId,
      mapEntryID,
      undefined,
    );
    const sourceShareToken = sourceShare.url.split("/s/")[1];
    await claimShare(env, target.libraryId, sourceShareToken);
    await createLibraryDownloadGrant(
      env,
      target.libraryId,
      unique.mapEntryId,
      "production",
      [{ keyId: "prod", keySha256: signerSha }],
      appIdentity,
    );
    const targetOwnedCode = await createLinkCode(env, target.libraryId);
    const credentialsBefore = await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM library_credentials",
    ).first<{ count: number }>();

    const link = await createLinkCode(env, source.libraryId);
    const targetCredentialHash = await sha256Hex(target.credential);
    const claimed = await claimLinkCode(
      env,
      target.libraryId,
      targetCredentialHash,
      link.code,
    );
    expect(claimed).toEqual({ libraryId: source.libraryId });

    expect(await libraryIDForCredential(target.credential, env)).toBe(
      source.libraryId,
    );
    expect(
      await libraryIDForCredential(additionalTargetCredential.credential!, env),
    ).toBe(source.libraryId);
    const retry = await claimLinkCode(
      env,
      await libraryIDForCredential(target.credential, env),
      targetCredentialHash,
      link.code,
    );
    expect(retry).toEqual({ libraryId: source.libraryId });
    const otherCredentialRetry = await claimLinkCode(
      env,
      await libraryIDForCredential(additionalTargetCredential.credential!, env),
      await sha256Hex(additionalTargetCredential.credential!),
      link.code,
    );
    expect(otherCredentialRetry).toEqual({ libraryId: source.libraryId });

    expect((await getLibraryMap(env, source.libraryId, mapEntryID)).alias).toBe(
      "My Sunday Route",
    );
    expect(
      (await getLibraryMap(env, source.libraryId, unique.mapEntryId)).alias,
    ).toBe("Target-only map");
    const movedShare = await env.DB.prepare(
      "SELECT owner_library_id FROM shares WHERE id = ?",
    )
      .bind(targetShare.shareId)
      .first<{ owner_library_id: string }>();
    expect(movedShare?.owner_library_id).toBe(source.libraryId);
    const movedClaim = await env.DB.prepare(
      "SELECT recipient_library_id FROM share_claims WHERE share_id = ?",
    )
      .bind(sourceShare.shareId)
      .first<{ recipient_library_id: string }>();
    expect(movedClaim?.recipient_library_id).toBe(source.libraryId);
    const movedGrant = await env.DB.prepare(
      "SELECT library_id FROM download_grants WHERE artifact_id = ? AND purpose = 'library' ORDER BY created_at DESC LIMIT 1",
    )
      .bind(unique.artifacts[0].artifactId)
      .first<{ library_id: string }>();
    expect(movedGrant?.library_id).toBe(source.libraryId);
    const movedCode = await env.DB.prepare(
      "SELECT source_library_id FROM linked_library_codes WHERE code_hash = ?",
    )
      .bind(await sha256Hex(targetOwnedCode.code))
      .first<{ source_library_id: string }>();
    expect(movedCode?.source_library_id).toBe(source.libraryId);
    const targetState = await env.DB.prepare(
      `SELECT l.revoked_at,
              (SELECT COUNT(*) FROM library_maps WHERE library_id = l.id) AS map_count,
              (SELECT COUNT(*) FROM shares WHERE owner_library_id = l.id) AS share_count,
              (SELECT COUNT(*) FROM share_claims WHERE recipient_library_id = l.id) AS claim_count,
              (SELECT COUNT(*) FROM download_grants WHERE library_id = l.id) AS grant_count,
              (SELECT COUNT(*) FROM library_credentials WHERE library_id = l.id AND revoked_at IS NULL) AS credential_count
         FROM libraries l WHERE l.id = ?`,
    )
      .bind(target.libraryId)
      .first<{
        revoked_at: string | null;
        map_count: number;
        share_count: number;
        claim_count: number;
        grant_count: number;
        credential_count: number;
      }>();
    expect(targetState).toMatchObject({
      map_count: 0,
      share_count: 0,
      claim_count: 0,
      grant_count: 0,
      credential_count: 0,
    });
    expect(targetState?.revoked_at).not.toBeNull();
    const credentialsAfter = await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM library_credentials",
    ).first<{ count: number }>();
    expect(credentialsAfter?.count).toBe(credentialsBefore?.count);
  });

  it("rejects a link merge whose distinct map union exceeds the durable quota", async () => {
    const source = await seededLibrary();
    const target = await seededLibrary();
    await seedLibraryMapCount(source.libraryId, 60);
    const targetMaps = await seedLibraryMapCount(target.libraryId, 42);
    const link = await createLinkCode(env, source.libraryId);
    const credentialHash = await sha256Hex(target.credential);

    await expect(
      claimLinkCode(env, target.libraryId, credentialHash, link.code),
    ).rejects.toMatchObject({ status: 409 });
    expect(await libraryIDForCredential(target.credential, env)).toBe(
      target.libraryId,
    );

    await detachLibraryMap(env, target.libraryId, targetMaps[0]);
    await expect(
      claimLinkCode(env, target.libraryId, credentialHash, link.code),
    ).resolves.toEqual({ libraryId: source.libraryId });
    expect(
      await env.DB.prepare(
        "SELECT COUNT(*) AS count FROM library_maps WHERE library_id = ?",
      )
        .bind(source.libraryId)
        .first<{ count: number }>(),
    ).toMatchObject({ count: 100 });
  });

  it("keeps an over-quota link code unconsumed and repairs duplicate claim counts", async () => {
    const owner = await seededLibrary();
    const source = await seededLibrary();
    const target = await seededLibrary();
    const shared = await createShare(
      env,
      owner.libraryId,
      mapEntryID,
      undefined,
    );
    const token = shared.url.split("/").at(-1)!;
    await claimShare(env, source.libraryId, token);
    await claimShare(env, target.libraryId, token);
    expect(
      await env.DB.prepare("SELECT claim_count FROM shares WHERE id = ?")
        .bind(shared.shareId)
        .first<{ claim_count: number }>(),
    ).toMatchObject({ claim_count: 2 });

    const now = new Date().toISOString();
    const extraCredentialHashes = Array.from({ length: 7 }, (_, index) =>
      `${index + 1}`.padStart(64, "a"),
    );
    await env.DB.batch(
      extraCredentialHashes.map((hash) =>
        env.DB.prepare(
          `INSERT INTO library_credentials(
             credential_hash, library_id, created_at, last_used_at
           ) VALUES (?, ?, ?, ?)`,
        ).bind(hash, target.libraryId, now, now),
      ),
    );
    const link = await createLinkCode(env, source.libraryId);
    const targetCredentialHash = await sha256Hex(target.credential);
    await expect(
      claimLinkCode(env, target.libraryId, targetCredentialHash, link.code),
    ).rejects.toMatchObject({ status: 409 });
    expect(
      await env.DB.prepare(
        "SELECT claimed_at FROM linked_library_codes WHERE code_hash = ?",
      )
        .bind(await sha256Hex(link.code))
        .first<{ claimed_at: string | null }>(),
    ).toMatchObject({ claimed_at: null });

    await env.DB.prepare(
      "UPDATE library_credentials SET revoked_at = ? WHERE credential_hash = ?",
    )
      .bind(now, extraCredentialHashes[0])
      .run();
    await claimLinkCode(env, target.libraryId, targetCredentialHash, link.code);
    expect(
      await env.DB.prepare("SELECT claim_count FROM shares WHERE id = ?")
        .bind(shared.shareId)
        .first<{ claim_count: number }>(),
    ).toMatchObject({ claim_count: 1 });
    expect(
      await env.DB.prepare(
        `SELECT COUNT(*) AS count FROM library_credentials
          WHERE library_id = ? AND revoked_at IS NULL`,
      )
        .bind(source.libraryId)
        .first<{ count: number }>(),
    ).toMatchObject({ count: 8 });
  });

  it("allows only one concurrent claim for a one-time link code", async () => {
    const source = await bootstrapLibrary(env);
    const targets = await Promise.all([
      bootstrapLibrary(env),
      bootstrapLibrary(env),
    ]);
    const link = await createLinkCode(env, source.libraryId);
    const credentialHashes = await Promise.all(
      targets.map((target) => sha256Hex(target.credential!)),
    );
    const claims = await Promise.allSettled(
      targets.map((target, index) =>
        claimLinkCode(
          env,
          target.libraryId,
          credentialHashes[index],
          link.code,
        ),
      ),
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
    expect(loser.reason).toMatchObject({ status: 404 });
    expect(
      await libraryIDForCredential(targets[winnerIndex].credential!, env),
    ).toBe(source.libraryId);
    expect(
      await libraryIDForCredential(targets[loserIndex].credential!, env),
    ).toBe(targets[loserIndex].libraryId);
  });

  it("atomically caps live link codes and reclaims expired capacity", async () => {
    const library = await bootstrapLibrary(env);
    await env.DB.batch(
      Array.from({ length: 30 }, (_, index) =>
        env.DB.prepare(
          `INSERT INTO linked_library_codes(
             code_hash, source_library_id, created_at, expires_at
           ) VALUES (?, ?, ?, ?)`,
        ).bind(
          `expired-link-${index.toString().padStart(3, "0")}`,
          library.libraryId,
          "2019-01-01T00:00:00.000Z",
          "2020-01-01T00:00:00.000Z",
        ),
      ),
    );
    const first = await createLinkCode(env, library.libraryId);
    expect(
      await env.DB.prepare(
        `SELECT COUNT(*) AS count FROM linked_library_codes
          WHERE code_hash LIKE 'expired-link-%'`,
      ).first<{ count: number }>(),
    ).toMatchObject({ count: 5 });
    const initial = [
      first,
      ...(await Promise.all(
        Array.from({ length: 3 }, () => createLinkCode(env, library.libraryId)),
      )),
    ];
    const boundary = await Promise.allSettled([
      createLinkCode(env, library.libraryId),
      createLinkCode(env, library.libraryId),
    ]);
    expect(
      boundary.filter((result) => result.status === "fulfilled"),
    ).toHaveLength(1);
    expect(
      boundary.filter((result) => result.status === "rejected"),
    ).toHaveLength(1);
    const rejected = boundary.find((result) => result.status === "rejected");
    if (rejected?.status !== "rejected") {
      throw new Error("link code quota result shape is invalid");
    }
    expect(rejected.reason).toMatchObject({ status: 409 });
    expect(
      await env.DB.prepare(
        `SELECT COUNT(*) AS count FROM linked_library_codes
          WHERE source_library_id = ? AND claimed_at IS NULL AND expires_at > ?`,
      )
        .bind(library.libraryId, new Date().toISOString())
        .first<{ count: number }>(),
    ).toMatchObject({ count: 5 });

    await env.DB.prepare(
      "UPDATE linked_library_codes SET expires_at = ? WHERE code_hash = ?",
    )
      .bind("2020-01-01T00:00:00.000Z", await sha256Hex(initial[0].code))
      .run();
    await expect(createLinkCode(env, library.libraryId)).resolves.toMatchObject(
      { code: expect.any(String) },
    );
    expect(
      await env.DB.prepare(
        "SELECT COUNT(*) AS count FROM linked_library_codes WHERE source_library_id = ?",
      )
        .bind(library.libraryId)
        .first<{ count: number }>(),
    ).toMatchObject({ count: 5 });
  });

  it("bounds retained link-code evidence and reclaims rows beyond grace", async () => {
    const library = await bootstrapLibrary(env);
    const now = new Date().toISOString();
    await env.DB.batch(
      Array.from({ length: 50 }, (_, index) =>
        env.DB.prepare(
          `INSERT INTO linked_library_codes(
             code_hash, source_library_id, created_at, expires_at, claimed_at
           ) VALUES (?, ?, ?, ?, ?)`,
        ).bind(
          `claimed-link-${index.toString().padStart(3, "0")}`,
          library.libraryId,
          now,
          now,
          now,
        ),
      ),
    );
    await expect(createLinkCode(env, library.libraryId)).rejects.toMatchObject({
      status: 409,
    });
    expect(
      await env.DB.prepare(
        "SELECT COUNT(*) AS count FROM linked_library_codes WHERE source_library_id = ?",
      )
        .bind(library.libraryId)
        .first<{ count: number }>(),
    ).toMatchObject({ count: 50 });

    await env.DB.prepare(
      "UPDATE linked_library_codes SET claimed_at = ? WHERE code_hash = 'claimed-link-000'",
    )
      .bind("2020-01-01T00:00:00.000Z")
      .run();
    await expect(createLinkCode(env, library.libraryId)).resolves.toMatchObject(
      {
        code: expect.any(String),
      },
    );
    expect(
      await env.DB.prepare(
        "SELECT COUNT(*) AS count FROM linked_library_codes WHERE source_library_id = ?",
      )
        .bind(library.libraryId)
        .first<{ count: number }>(),
    ).toMatchObject({ count: 50 });
  });

  it("paginates more than one hundred shares with a stable tie-breaker", async () => {
    const owner = await seededLibrary();
    const rows = Array.from({ length: 105 }, (_, index) => ({
      id: `share_page_entry_${index.toString().padStart(3, "0")}`,
      createdAt: new Date(
        Date.UTC(2026, 7, 25, 0, 0, Math.floor(index / 2)),
      ).toISOString(),
      tokenHash: index.toString(16).padStart(64, "0"),
    }));
    const statements = rows.map((row) =>
      env.DB.prepare(
        `INSERT INTO shares(
           id, token_hash, owner_library_id, map_entry_id, title_snapshot, created_at
         ) VALUES (?, ?, ?, ?, ?, ?)`,
      ).bind(
        row.id,
        row.tokenHash,
        owner.libraryId,
        mapEntryID,
        row.id,
        row.createdAt,
      ),
    );
    for (let index = 0; index < statements.length; index += 50) {
      await env.DB.batch(statements.slice(index, index + 50));
    }

    const first = await listShares(env, owner.libraryId, null, "100");
    expect(first.shares).toHaveLength(100);
    expect(first.nextCursor).not.toBeNull();
    const second = await listShares(
      env,
      owner.libraryId,
      first.nextCursor,
      "100",
    );
    expect(second.shares).toHaveLength(5);
    expect(second.nextCursor).toBeNull();
    const actual = [...first.shares, ...second.shares].map(
      (share) => share.shareId,
    );
    const expected = rows
      .toSorted(
        (left, right) =>
          right.createdAt.localeCompare(left.createdAt) ||
          left.id.localeCompare(right.id),
      )
      .map((row) => row.id);
    expect(actual).toEqual(expected);
    expect(new Set(actual).size).toBe(105);
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
        null,
        verifyTestArtifact,
      ),
    ).rejects.toMatchObject({ status: 409 });
  });

  it("rejects changes to every immutable artifact field", async () => {
    await seededLibrary();
    const before = await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM publication_events",
    ).first<{ count: number }>();
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
          null,
          verifyTestArtifact,
        ),
      ).rejects.toMatchObject({ status: 409 });
    }

    const eventCount = await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM publication_events",
    ).first<{ count: number }>();
    expect(eventCount?.count).toBe(before?.count);
  });

  it("verifies every proposed R2 object before making a publication live", async () => {
    const candidate = publication();
    candidate.publicationId = "job-object-verification";
    candidate.mapEntryId = `map_v1_${"o".repeat(43)}`;
    candidate.legacyMapId = "object-verification-map";
    candidate.artifacts[0].artifactId = `artifact_v1_${"o".repeat(43)}`;
    candidate.artifacts[0].objectKey = candidate.artifacts[0].objectKey.replace(
      "test-map",
      "object-verification-map",
    );
    const secondArtifact = {
      ...candidate.artifacts[0],
      artifactId: `artifact_v1_${"p".repeat(43)}`,
      objectKey: `${candidate.artifacts[0].objectKey}.2d`,
      format: "two-dimensional-map-v1",
      filename: "object-verification-map-2d.bmap",
      sha256: "8".repeat(64),
      bytes: 23456,
    };
    candidate.artifacts.push(secondArtifact);
    const verified: Array<{
      id: string;
      bucket: string;
      objectKey: string;
      bytes: number;
      sha256: string;
    }> = [];

    const result = await finalizePublication(
      env,
      candidate,
      "object-verification",
      await sha256Hex(JSON.stringify(candidate)),
      null,
      async (artifact) => {
        verified.push({
          id: artifact.id,
          bucket: artifact.bucket_slot,
          objectKey: artifact.object_key,
          bytes: artifact.byte_count,
          sha256: artifact.sha256,
        });
        return true;
      },
    );

    expect(result.replayed).toBe(false);
    expect(verified).toEqual(
      candidate.artifacts.map((artifact) => ({
        id: artifact.artifactId,
        bucket: artifact.bucketSlot,
        objectKey: artifact.objectKey,
        bytes: artifact.bytes,
        sha256: artifact.sha256,
      })),
    );
  });

  it("does not catalog missing or conflicting R2 object metadata", async () => {
    const candidate = publication();
    candidate.publicationId = "job-missing-object";
    candidate.mapEntryId = `map_v1_${"x".repeat(43)}`;
    candidate.legacyMapId = "missing-object-map";
    candidate.artifacts[0].artifactId = `artifact_v1_${"x".repeat(43)}`;
    candidate.artifacts[0].objectKey = candidate.artifacts[0].objectKey.replace(
      "test-map",
      "missing-object-map",
    );

    await expect(
      finalizePublication(
        env,
        candidate,
        "missing-object",
        await sha256Hex(JSON.stringify(candidate)),
        null,
        async () => false,
      ),
    ).rejects.toMatchObject({ status: 409 });
    expect(
      await env.DB.prepare(
        "SELECT COUNT(*) AS count FROM publication_events WHERE publication_id = ?",
      )
        .bind(candidate.publicationId)
        .first<{ count: number }>(),
    ).toMatchObject({ count: 0 });
  });

  it("fails closed without D1 writes when R2 verification is transiently unavailable", async () => {
    const candidate = publication();
    candidate.publicationId = "job-transient-object-verification";
    candidate.mapEntryId = `map_v1_${"y".repeat(43)}`;
    candidate.legacyMapId = "transient-object-map";
    candidate.artifacts[0].artifactId = `artifact_v1_${"y".repeat(43)}`;
    candidate.artifacts[0].objectKey = candidate.artifacts[0].objectKey.replace(
      "test-map",
      "transient-object-map",
    );

    await expect(
      finalizePublication(
        env,
        candidate,
        "transient-object-verification",
        await sha256Hex(JSON.stringify(candidate)),
        null,
        async () => {
          throw new HttpError(503, "R2 artifact verification is unavailable");
        },
      ),
    ).rejects.toMatchObject({ status: 503 });
    expect(
      await env.DB.prepare(
        "SELECT COUNT(*) AS count FROM publication_events WHERE publication_id = ?",
      )
        .bind(candidate.publicationId)
        .first<{ count: number }>(),
    ).toMatchObject({ count: 0 });
  });
});

describe("catalog lifecycle boundaries", () => {
  it("leases promotion atomically, renews it, recovers stale work, and finalizes once", async () => {
    const development = developmentPublication("promotion-lease");
    await finalizePublication(
      env,
      development,
      development.publicationId,
      await sha256Hex(JSON.stringify(development)),
      null,
      verifyTestArtifact,
    );
    const startedAt = new Date();
    const concurrent = await Promise.allSettled([
      createPromotionGrant(env, development.mapEntryId, startedAt),
      createPromotionGrant(env, development.mapEntryId, startedAt),
    ]);
    expect(
      concurrent.filter((result) => result.status === "fulfilled"),
    ).toHaveLength(1);
    expect(
      concurrent.filter((result) => result.status === "rejected"),
    ).toHaveLength(1);
    const firstResult = concurrent.find(
      (result) => result.status === "fulfilled",
    );
    if (
      firstResult?.status !== "fulfilled" ||
      firstResult.value.state !== "granted"
    ) {
      throw new Error("promotion grant result shape is invalid");
    }
    const first = firstResult.value;
    const renewed = await renewPromotionLease(
      env,
      development.mapEntryId,
      first.leaseId,
      {
        artifactId: first.artifact.artifactId,
        objectKey: first.artifact.objectKey,
        bytes: first.artifact.bytes,
        sha256: first.artifact.sha256,
      },
      new Date(startedAt.getTime() + 30 * 60 * 1000),
    );
    expect(renewed.leaseExpiresAt).toBe(
      new Date(startedAt.getTime() + 90 * 60 * 1000).toISOString(),
    );

    await env.DB.prepare(
      "UPDATE promotion_leases SET expires_at = ? WHERE lease_id = ?",
    )
      .bind(
        new Date(startedAt.getTime() + 119 * 60 * 1000).toISOString(),
        first.leaseId,
      )
      .run();
    const recoveryClock = new Date(startedAt.getTime() + 120 * 60 * 1000);
    const recovered = await createPromotionGrant(
      env,
      development.mapEntryId,
      recoveryClock,
    );
    if (recovered.state !== "granted") {
      throw new Error("stale promotion was not recovered");
    }
    expect(recovered.leaseId).not.toBe(first.leaseId);
    await expect(
      renewPromotionLease(
        env,
        development.mapEntryId,
        first.leaseId,
        {
          artifactId: first.artifact.artifactId,
          objectKey: first.artifact.objectKey,
          bytes: first.artifact.bytes,
          sha256: first.artifact.sha256,
        },
        new Date(recoveryClock.getTime() + 60 * 1000),
      ),
    ).rejects.toMatchObject({ status: 409 });

    const promoted = structuredClone(development);
    promoted.publicationId = `promotion:production:${"6".repeat(64)}`;
    promoted.deliveryState = "production";
    const artifact = promoted.artifacts[0];
    artifact.artifactId = fixtureID("artifact");
    artifact.bucketSlot = "production";
    artifact.deliveryTier = "production";
    artifact.format = "bike-map-stream-v1";
    artifact.mediaType = "application/vnd.openbikecomputer.map-stream";
    artifact.filename = `${promoted.legacyMapId}.bmap`;
    artifact.objectKey = `maps/${promoted.legacyMapId}/bike-map-stream-v1/${"6".repeat(64)}.bmap`;
    artifact.bytes = 45678;
    artifact.sha256 = "6".repeat(64);
    artifact.signedManifestReceipt = promoted.contentReceipt;
    artifact.signatureKeyId = "prod";
    artifact.signatureKeySha256 = signerSha;
    artifact.producerBuildSha256 = producerSha;
    artifact.producerImageDigest = `sha256:${imageSha}`;
    artifact.requiredIosBuild = appIdentity.build;
    artifact.requiredIosGitSha = appIdentity.gitSha;
    artifact.requiredIosBuildSha256 = appIdentity.buildSha256;
    const bodyHash = await sha256Hex(JSON.stringify(promoted));
    const finalized = await Promise.all([
      finalizePublication(
        env,
        promoted,
        "promotion-finalize",
        bodyHash,
        recovered.leaseId,
        verifyTestArtifact,
      ),
      finalizePublication(
        env,
        promoted,
        "promotion-finalize",
        bodyHash,
        recovered.leaseId,
        verifyTestArtifact,
      ),
    ]);
    expect(finalized.map((result) => result.replayed).sort()).toEqual([
      false,
      true,
    ]);
    expect(
      await env.DB.prepare(
        "SELECT state FROM promotion_leases WHERE lease_id = ?",
      )
        .bind(recovered.leaseId)
        .first<{ state: string }>(),
    ).toMatchObject({ state: "finalized" });
    const replay = await createPromotionGrant(env, development.mapEntryId);
    expect(replay).toMatchObject({
      state: "already_production",
      mapEntryId: development.mapEntryId,
      artifact: { artifactId: artifact.artifactId },
    });
  });

  it("keeps promoted production artifacts live when development is quarantined", async () => {
    const development = publication();
    const quarantineMapEntryID = `map_v1_${"q".repeat(43)}`;
    development.publicationId = "job-development-quarantine";
    development.mapEntryId = quarantineMapEntryID;
    development.legacyMapId = "quarantine-map";
    development.originChannel = "development";
    development.deliveryState = "development";
    development.artifacts[0].artifactId = `artifact_v1_${"u".repeat(43)}`;
    development.artifacts[0].bucketSlot = "development";
    development.artifacts[0].deliveryTier = "development";
    development.artifacts[0].objectKey = development.artifacts[0].objectKey
      .replace("test-map", "quarantine-map")
      .concat(".development");
    await finalizePublication(
      env,
      development,
      "development-quarantine",
      await sha256Hex(JSON.stringify(development)),
      null,
      verifyTestArtifact,
    );

    const promoted = publication();
    promoted.publicationId = "job-production-promotion";
    promoted.mapEntryId = quarantineMapEntryID;
    promoted.legacyMapId = "quarantine-map";
    promoted.originChannel = "development";
    promoted.artifacts[0].artifactId = `artifact_v1_${"v".repeat(43)}`;
    promoted.artifacts[0].objectKey = promoted.artifacts[0].objectKey
      .replace("test-map", "quarantine-map")
      .concat(".production");
    await finalizePublication(
      env,
      promoted,
      "production-promotion",
      await sha256Hex(JSON.stringify(promoted)),
      null,
      verifyTestArtifact,
    );

    await quarantinePublication(env, development.publicationId, "development");

    const map = await env.DB.prepare(
      "SELECT delivery_state FROM map_entries WHERE id = ?",
    )
      .bind(quarantineMapEntryID)
      .first<{ delivery_state: string }>();
    expect(map?.delivery_state).toBe("production");
    const artifacts = await env.DB.prepare(
      "SELECT bucket_slot, state FROM artifacts WHERE map_entry_id = ? ORDER BY bucket_slot",
    )
      .bind(quarantineMapEntryID)
      .all<{ bucket_slot: string; state: string }>();
    expect(artifacts.results).toEqual([
      { bucket_slot: "development", state: "quarantined" },
      { bucket_slot: "production", state: "live" },
    ]);
  });

  it("tombstones and authorizes only old zero-reference artifacts after two grace windows", async () => {
    const candidate = publication();
    candidate.publicationId = "job-retention-candidate";
    candidate.mapEntryId = `map_v1_${"n".repeat(43)}`;
    candidate.legacyMapId = "retention-map";
    candidate.artifacts[0].artifactId = `artifact_v1_${"w".repeat(43)}`;
    candidate.artifacts[0].objectKey = candidate.artifacts[0].objectKey.replace(
      "test-map",
      "retention-map",
    );
    await finalizePublication(
      env,
      candidate,
      "retention-candidate",
      await sha256Hex(JSON.stringify(candidate)),
      null,
      verifyTestArtifact,
    );
    const firstClock = new Date("2026-10-01T00:00:00.000Z");
    await env.DB.prepare("UPDATE map_entries SET updated_at = ? WHERE id = ?")
      .bind("2026-08-01T00:00:00.000Z", candidate.mapEntryId)
      .run();

    const first = await prepareRetentionAuthorizations(
      env,
      "production",
      10,
      firstClock,
    );
    expect(first.artifacts).toEqual([]);
    const tombstoned = await env.DB.prepare(
      "SELECT state FROM artifacts WHERE id = ?",
    )
      .bind(candidate.artifacts[0].artifactId)
      .first<{ state: string }>();
    expect(tombstoned?.state).toBe("tombstoned");
    const recreatedLibrary = await bootstrapLibrary(env);
    const recreated = await attachLibrary(
      env,
      candidate.publicationId,
      recreatedLibrary.libraryId,
      undefined,
      "production",
    );
    expect(recreated.artifacts).toHaveLength(1);
    await env.DB.prepare(
      "DELETE FROM library_maps WHERE library_id = ? AND map_entry_id = ?",
    )
      .bind(recreatedLibrary.libraryId, candidate.mapEntryId)
      .run();
    await env.DB.prepare("UPDATE map_entries SET updated_at = ? WHERE id = ?")
      .bind("2026-08-01T00:00:00.000Z", candidate.mapEntryId)
      .run();
    await prepareRetentionAuthorizations(
      env,
      "production",
      10,
      new Date("2026-10-02T00:00:00.000Z"),
    );

    const second = await prepareRetentionAuthorizations(
      env,
      "production",
      10,
      new Date("2026-11-01T00:00:00.000Z"),
    );
    const authorization = second.artifacts.find(
      (artifact) => artifact.artifactId === candidate.artifacts[0].artifactId,
    );
    expect(authorization).toMatchObject({
      artifactId: candidate.artifacts[0].artifactId,
      bucketSlot: "production",
      objectKey: candidate.artifacts[0].objectKey,
      bytes: candidate.artifacts[0].bytes,
      sha256: candidate.artifacts[0].sha256,
    });
    await expect(
      claimRetentionDeletion(
        env,
        candidate.artifacts[0].artifactId,
        "development",
        authorization!,
        new Date("2026-11-01T00:01:00.000Z"),
      ),
    ).rejects.toMatchObject({ status: 400 });
    const concurrentClaims = await Promise.allSettled([
      claimRetentionDeletion(
        env,
        candidate.artifacts[0].artifactId,
        "production",
        authorization!,
        new Date("2026-11-01T00:01:00.000Z"),
      ),
      claimRetentionDeletion(
        env,
        candidate.artifacts[0].artifactId,
        "production",
        authorization!,
        new Date("2026-11-01T00:01:00.000Z"),
      ),
    ]);
    expect(
      concurrentClaims.filter((result) => result.status === "fulfilled"),
    ).toHaveLength(1);
    expect(
      concurrentClaims.filter((result) => result.status === "rejected"),
    ).toHaveLength(1);
    const fulfilledClaim = concurrentClaims.find(
      (result) => result.status === "fulfilled",
    );
    const rejectedClaim = concurrentClaims.find(
      (result) => result.status === "rejected",
    );
    if (
      fulfilledClaim?.status !== "fulfilled" ||
      rejectedClaim?.status !== "rejected"
    ) {
      throw new Error("retention claim result shape is invalid");
    }
    expect(rejectedClaim.reason).toMatchObject({ status: 409 });
    const claim = fulfilledClaim.value;
    expect(
      await env.DB.prepare(
        `SELECT COUNT(*) AS count FROM artifact_deletion_leases
          WHERE artifact_id = ? AND expires_at > ?`,
      )
        .bind(candidate.artifacts[0].artifactId, "2026-11-01T00:01:00.000Z")
        .first<{ count: number }>(),
    ).toMatchObject({ count: 1 });
    await expect(
      attachLibrary(
        env,
        candidate.publicationId,
        recreatedLibrary.libraryId,
        undefined,
        "production",
      ),
    ).rejects.toMatchObject({ status: 409 });
    await env.DB.prepare(
      `INSERT INTO library_maps(
         library_id, map_entry_id, alias, alias_source, added_at, updated_at
       ) VALUES (?, ?, 'Injected race', 'user', ?, ?)`,
    )
      .bind(
        recreatedLibrary.libraryId,
        candidate.mapEntryId,
        "2026-11-01T00:01:30.000Z",
        "2026-11-01T00:01:30.000Z",
      )
      .run();
    await expect(
      confirmRetentionDeletion(
        env,
        candidate.artifacts[0].artifactId,
        "production",
        { ...claim, confirmedAbsent: true },
        new Date("2026-11-01T00:01:45.000Z"),
      ),
    ).rejects.toMatchObject({ status: 409 });
    const retainedLease = await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM artifact_deletion_leases WHERE id = ?",
    )
      .bind(claim.leaseId)
      .first<{ count: number }>();
    expect(retainedLease?.count).toBe(1);
    await env.DB.prepare(
      "DELETE FROM library_maps WHERE library_id = ? AND map_entry_id = ?",
    )
      .bind(recreatedLibrary.libraryId, candidate.mapEntryId)
      .run();
    await confirmRetentionDeletion(
      env,
      candidate.artifacts[0].artifactId,
      "production",
      { ...claim, confirmedAbsent: true },
      new Date("2026-11-01T00:02:00.000Z"),
    );
    const deleted = await env.DB.prepare(
      "SELECT state FROM artifacts WHERE id = ?",
    )
      .bind(candidate.artifacts[0].artifactId)
      .first<{ state: string }>();
    expect(deleted?.state).toBe("deleted");
  });

  it("does not tombstone a map while a library reference is live", async () => {
    const library = await seededLibrary();
    await env.DB.prepare("UPDATE map_entries SET updated_at = ? WHERE id = ?")
      .bind("2026-01-01T00:00:00.000Z", mapEntryID)
      .run();
    const result = await prepareRetentionAuthorizations(
      env,
      "production",
      10,
      new Date("2026-11-01T00:00:00.000Z"),
    );
    expect(
      result.artifacts.some((artifact) => artifact.artifactId === artifactID),
    ).toBe(false);
    expect(
      (await getLibraryMap(env, library.libraryId, mapEntryID)).artifacts,
    ).toHaveLength(1);
    const artifact = await env.DB.prepare(
      "SELECT state FROM artifacts WHERE id = ?",
    )
      .bind(artifactID)
      .first<{ state: string }>();
    expect(artifact?.state).toBe("live");
  });

  it("reattaches after a stale deletion lease only when R2 still verifies", async () => {
    const candidate = publication();
    candidate.publicationId = "job-stale-lease";
    candidate.mapEntryId = `map_v1_${"j".repeat(43)}`;
    candidate.legacyMapId = "stale-lease-map";
    candidate.artifacts[0].artifactId = `artifact_v1_${"j".repeat(43)}`;
    candidate.artifacts[0].objectKey = candidate.artifacts[0].objectKey.replace(
      "test-map",
      "stale-lease-map",
    );
    await finalizePublication(
      env,
      candidate,
      "stale-lease",
      await sha256Hex(JSON.stringify(candidate)),
      null,
      verifyTestArtifact,
    );
    await env.DB.prepare("UPDATE map_entries SET updated_at = ? WHERE id = ?")
      .bind("2026-01-01T00:00:00.000Z", candidate.mapEntryId)
      .run();
    await prepareRetentionAuthorizations(
      env,
      "production",
      10,
      new Date("2026-10-01T00:00:00.000Z"),
    );
    const authorization = (
      await prepareRetentionAuthorizations(
        env,
        "production",
        10,
        new Date("2026-11-01T00:00:00.000Z"),
      )
    ).artifacts.find(
      (artifact) => artifact.artifactId === candidate.artifacts[0].artifactId,
    );
    await claimRetentionDeletion(
      env,
      candidate.artifacts[0].artifactId,
      "production",
      authorization!,
      new Date("2026-11-01T00:01:00.000Z"),
    );
    await env.DB.prepare(
      "UPDATE artifact_deletion_leases SET expires_at = ? WHERE artifact_id = ?",
    )
      .bind("2020-01-01T00:00:00.000Z", candidate.artifacts[0].artifactId)
      .run();
    const verified: string[] = [];
    const library = await bootstrapLibrary(env);
    const attached = await attachLibrary(
      env,
      candidate.publicationId,
      library.libraryId,
      undefined,
      "production",
      async (artifact) => {
        verified.push(artifact.id);
        return true;
      },
    );

    expect(verified).toEqual([candidate.artifacts[0].artifactId]);
    expect(attached.artifacts).toHaveLength(1);
    const lease = await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM artifact_deletion_leases WHERE artifact_id = ?",
    )
      .bind(candidate.artifacts[0].artifactId)
      .first<{ count: number }>();
    expect(lease?.count).toBe(0);
  });

  it("retains an unrevoked share through expiry plus the configured grace", async () => {
    const shared = publication();
    shared.publicationId = "job-share-retention";
    shared.mapEntryId = `map_v1_${"h".repeat(43)}`;
    shared.legacyMapId = "share-retention-map";
    shared.artifacts[0].artifactId = `artifact_v1_${"h".repeat(43)}`;
    shared.artifacts[0].objectKey = shared.artifacts[0].objectKey.replace(
      "test-map",
      "share-retention-map",
    );
    await finalizePublication(
      env,
      shared,
      "share-retention",
      await sha256Hex(JSON.stringify(shared)),
      null,
      verifyTestArtifact,
    );
    const library = await bootstrapLibrary(env);
    await attachLibrary(
      env,
      shared.publicationId,
      library.libraryId,
      undefined,
      "production",
    );
    await createShare(
      env,
      library.libraryId,
      shared.mapEntryId,
      "2026-09-01T00:00:00.000Z",
    );
    await detachLibraryMap(env, library.libraryId, shared.mapEntryId);
    await env.DB.prepare("UPDATE map_entries SET updated_at = ? WHERE id = ?")
      .bind("2026-01-01T00:00:00.000Z", shared.mapEntryId)
      .run();

    await prepareRetentionAuthorizations(
      { ...env, RETENTION_GRACE_DAYS: "30" },
      "production",
      10,
      new Date("2026-09-15T00:00:00.000Z"),
    );
    const protectedArtifact = await env.DB.prepare(
      "SELECT state FROM artifacts WHERE id = ?",
    )
      .bind(shared.artifacts[0].artifactId)
      .first<{ state: string }>();
    expect(protectedArtifact?.state).toBe("live");

    await prepareRetentionAuthorizations(
      { ...env, RETENTION_GRACE_DAYS: "30" },
      "production",
      10,
      new Date("2026-10-02T00:00:00.000Z"),
    );
    const tombstonedArtifact = await env.DB.prepare(
      "SELECT state FROM artifacts WHERE id = ?",
    )
      .bind(shared.artifacts[0].artifactId)
      .first<{ state: string }>();
    expect(tombstonedArtifact?.state).toBe("tombstoned");
  });

  it("keeps each retention pass below the free-tier D1 query cap", async () => {
    let queryInvocations = 0;
    const countedEnv = {
      ...env,
      DB: new Proxy(env.DB, {
        get(target, property, receiver) {
          if (property === "prepare") {
            return (query: string) => {
              queryInvocations += 1;
              return target.prepare(query);
            };
          }
          const value = Reflect.get(target, property, receiver) as unknown;
          return typeof value === "function" ? value.bind(target) : value;
        },
      }),
    } as typeof env;
    await prepareRetentionAuthorizations(
      countedEnv,
      "production",
      10,
      new Date("2027-12-01T00:00:00.000Z"),
    );
    expect(queryInvocations).toBeLessThan(50);
    await expect(
      prepareRetentionAuthorizations(
        env,
        "production",
        11,
        new Date("2027-12-01T00:00:00.000Z"),
      ),
    ).rejects.toMatchObject({ status: 400 });
  });
});
