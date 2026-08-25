import { HttpError, normalizeAlias, randomToken, sha256Hex } from "./security";
import type { ArtifactRow, Channel, Env, MapEntryRow } from "./types";
import type { PublicationInput } from "./validation";

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const MAP_ENTRY_ID = /^map_v1_[A-Za-z0-9_-]{43}$/;
const SHARE_ID = /^[A-Za-z0-9_-]{16,128}$/;

export interface LibraryBootstrapResult {
  libraryId: string;
  credential?: string;
  created: boolean;
}

export async function bootstrapLibrary(
  env: Env,
): Promise<LibraryBootstrapResult> {
  const credential = randomToken(32);
  const credentialHash = await sha256Hex(credential);
  const libraryID = `library_v1_${randomToken(18)}`;
  const now = new Date().toISOString();
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO libraries(id, created_at, updated_at, schema_version)
       VALUES (?, ?, ?, 1)`,
    ).bind(libraryID, now, now),
    env.DB.prepare(
      `INSERT INTO library_credentials(
          credential_hash, library_id, created_at, last_used_at
       ) VALUES (?, ?, ?, ?)`,
    ).bind(credentialHash, libraryID, now, now),
  ]);
  return { libraryId: libraryID, credential, created: true };
}

export async function refreshLibrary(
  libraryID: string,
): Promise<LibraryBootstrapResult> {
  return { libraryId: libraryID, created: false };
}

export interface PublicArtifact {
  artifactId: string;
  objectKey: string;
  format: string;
  mediaType: string;
  filename: string;
  bytes: number;
  sha256: string;
  manifestReceipt: string | null;
  signedManifestReceipt: string | null;
  signatureKeyId: string | null;
  signatureKeySha256: string | null;
  producerBuildSha256: string | null;
  producerImageDigest: string | null;
  requiredIosBuild: string | null;
  requiredIosGitSha: string | null;
  requiredIosBuildSha256: string | null;
  requiredFirmwareVersion: string | null;
  requiredFirmwareBuild: number | null;
  requiredFirmwareGitSha: string | null;
  deliveryTier: Channel;
}

export interface LibraryMapResponse {
  mapEntryId: string;
  mapId: string;
  alias: string;
  aliasSource: string;
  aliasRevision: number;
  canonicalName: string;
  originChannel: Channel;
  sourceRegionName: string | null;
  bounds: unknown;
  renderer: string;
  rendererFormatVersion: number;
  features: string[];
  attribution: Record<string, unknown>;
  deliveryState: string;
  generatedAt: string | null;
  addedAt: string;
  updatedAt: string;
  artifacts: PublicArtifact[];
}

interface LibraryMapRow extends MapEntryRow {
  alias: string;
  alias_source: string;
  alias_revision: number;
  added_at: string;
  library_map_updated_at: string;
}

function parseJSON<T>(value: string | null, fallback: T): T {
  if (value === null) return fallback;
  try {
    return JSON.parse(value) as T;
  } catch {
    return fallback;
  }
}

function publicArtifact(row: ArtifactRow): PublicArtifact {
  return {
    artifactId: row.id,
    objectKey: row.object_key,
    format: row.format,
    mediaType: row.media_type,
    filename: row.filename,
    bytes: row.byte_count,
    sha256: row.sha256,
    manifestReceipt: row.manifest_receipt,
    signedManifestReceipt: row.signed_manifest_receipt,
    signatureKeyId: row.signature_key_id,
    signatureKeySha256: row.signature_key_sha256,
    producerBuildSha256: row.producer_build_sha256,
    producerImageDigest: row.producer_image_digest,
    requiredIosBuild: row.required_ios_build,
    requiredIosGitSha: row.required_ios_git_sha,
    requiredIosBuildSha256: row.required_ios_build_sha256,
    requiredFirmwareVersion: row.required_firmware_version,
    requiredFirmwareBuild: row.required_firmware_build,
    requiredFirmwareGitSha: row.required_firmware_git_sha,
    deliveryTier: row.delivery_tier,
  };
}

async function artifactsForMap(
  env: Env,
  mapEntryID: string,
): Promise<PublicArtifact[]> {
  const result = await env.DB.prepare(
    `SELECT * FROM artifacts
      WHERE map_entry_id = ? AND state = 'live'
      ORDER BY delivery_tier DESC, format ASC, created_at DESC`,
  )
    .bind(mapEntryID)
    .all<ArtifactRow>();
  return result.results.map(publicArtifact);
}

async function libraryMapResponse(
  env: Env,
  row: LibraryMapRow,
): Promise<LibraryMapResponse> {
  return {
    mapEntryId: row.id,
    mapId: row.legacy_map_id,
    alias: row.alias,
    aliasSource: row.alias_source,
    aliasRevision: row.alias_revision,
    canonicalName: row.canonical_name,
    originChannel: row.origin_channel,
    sourceRegionName: row.source_region_name,
    bounds: parseJSON(row.bounds_json, null),
    renderer: row.renderer,
    rendererFormatVersion: row.renderer_format_version,
    features: parseJSON<string[]>(row.features_json, []),
    attribution: parseJSON<Record<string, unknown>>(row.attribution_json, {}),
    deliveryState: row.delivery_state,
    generatedAt: row.generated_at,
    addedAt: row.added_at,
    updatedAt: row.library_map_updated_at,
    artifacts: await artifactsForMap(env, row.id),
  };
}

function encodeCursor(updatedAt: string, id: string): string {
  let binary = "";
  for (const byte of encoder.encode(`${updatedAt}\u0000${id}`)) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
}

function decodeCursor(cursor: string | null): [string, string] | null {
  if (!cursor) return null;
  if (!/^[A-Za-z0-9_-]{1,512}$/.test(cursor))
    throw new HttpError(400, "cursor is invalid");
  try {
    const padded = cursor
      .replaceAll("-", "+")
      .replaceAll("_", "/")
      .padEnd(Math.ceil(cursor.length / 4) * 4, "=");
    const binary = atob(padded);
    const bytes = Uint8Array.from(binary, (character) =>
      character.charCodeAt(0),
    );
    const [updatedAt, id, extra] = decoder.decode(bytes).split("\u0000");
    if (extra !== undefined || !updatedAt || !MAP_ENTRY_ID.test(id))
      throw new Error("invalid");
    return [updatedAt, id];
  } catch {
    throw new HttpError(400, "cursor is invalid");
  }
}

export async function listLibraryMaps(
  env: Env,
  libraryID: string,
  cursorValue: string | null,
  requestedLimit: string | null,
): Promise<{ maps: LibraryMapResponse[]; nextCursor: string | null }> {
  const limit = requestedLimit === null ? 50 : Number(requestedLimit);
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100) {
    throw new HttpError(400, "limit is invalid");
  }
  const cursor = decodeCursor(cursorValue);
  const statement = cursor
    ? env.DB.prepare(
        `SELECT me.*, lm.alias, lm.alias_source, lm.alias_revision,
                lm.added_at, lm.updated_at AS library_map_updated_at
           FROM library_maps lm
           JOIN map_entries me ON me.id = lm.map_entry_id
          WHERE lm.library_id = ?
            AND (lm.updated_at < ? OR (lm.updated_at = ? AND me.id > ?))
          ORDER BY lm.updated_at DESC, me.id ASC
          LIMIT ?`,
      ).bind(libraryID, cursor[0], cursor[0], cursor[1], limit + 1)
    : env.DB.prepare(
        `SELECT me.*, lm.alias, lm.alias_source, lm.alias_revision,
                lm.added_at, lm.updated_at AS library_map_updated_at
           FROM library_maps lm
           JOIN map_entries me ON me.id = lm.map_entry_id
          WHERE lm.library_id = ?
          ORDER BY lm.updated_at DESC, me.id ASC
          LIMIT ?`,
      ).bind(libraryID, limit + 1);
  const result = await statement.all<LibraryMapRow>();
  const rows = result.results.slice(0, limit);
  const maps = await Promise.all(
    rows.map((row) => libraryMapResponse(env, row)),
  );
  const last = rows.at(-1);
  return {
    maps,
    nextCursor:
      result.results.length > limit && last
        ? encodeCursor(last.library_map_updated_at, last.id)
        : null,
  };
}

async function libraryMapRow(
  env: Env,
  libraryID: string,
  mapEntryID: string,
): Promise<LibraryMapRow> {
  if (!MAP_ENTRY_ID.test(mapEntryID)) throw new HttpError(404, "map not found");
  const row = await env.DB.prepare(
    `SELECT me.*, lm.alias, lm.alias_source, lm.alias_revision,
            lm.added_at, lm.updated_at AS library_map_updated_at
       FROM library_maps lm
       JOIN map_entries me ON me.id = lm.map_entry_id
      WHERE lm.library_id = ? AND lm.map_entry_id = ?`,
  )
    .bind(libraryID, mapEntryID)
    .first<LibraryMapRow>();
  if (!row) throw new HttpError(404, "map not found");
  return row;
}

export async function getLibraryMap(
  env: Env,
  libraryID: string,
  mapEntryID: string,
): Promise<LibraryMapResponse> {
  return libraryMapResponse(
    env,
    await libraryMapRow(env, libraryID, mapEntryID),
  );
}

export async function updateAlias(
  env: Env,
  libraryID: string,
  mapEntryID: string,
  aliasValue: unknown,
  expectedRevision: unknown,
): Promise<LibraryMapResponse> {
  const alias = normalizeAlias(aliasValue);
  const current = await libraryMapRow(env, libraryID, mapEntryID);
  if (
    expectedRevision !== undefined &&
    (!Number.isSafeInteger(expectedRevision) ||
      expectedRevision !== current.alias_revision)
  ) {
    throw new HttpError(409, "alias revision conflict");
  }
  const now = new Date().toISOString();
  const update = await env.DB.prepare(
    `UPDATE library_maps
        SET alias = ?, alias_source = 'user', alias_revision = alias_revision + 1,
            updated_at = ?
      WHERE library_id = ? AND map_entry_id = ? AND alias_revision = ?`,
  )
    .bind(alias, now, libraryID, mapEntryID, current.alias_revision)
    .run();
  if (update.meta.changes !== 1)
    throw new HttpError(409, "alias revision conflict");
  return getLibraryMap(env, libraryID, mapEntryID);
}

export async function finalizePublication(
  env: Env,
  publication: PublicationInput,
  idempotencyKey: string,
  bodySha256: string,
): Promise<{
  publicationId: string;
  mapEntryId: string;
  state: string;
  replayed: boolean;
}> {
  const existingEvent = await env.DB.prepare(
    "SELECT * FROM publication_events WHERE idempotency_key = ? OR publication_id = ?",
  )
    .bind(idempotencyKey, publication.publicationId)
    .first<{
      idempotency_key: string;
      publication_id: string;
      map_entry_id: string;
      body_sha256: string;
      state: string;
    }>();
  if (existingEvent) {
    if (
      existingEvent.idempotency_key !== idempotencyKey ||
      existingEvent.publication_id !== publication.publicationId ||
      existingEvent.map_entry_id !== publication.mapEntryId ||
      existingEvent.body_sha256 !== bodySha256
    ) {
      throw new HttpError(409, "publication idempotency conflict");
    }
    return {
      publicationId: existingEvent.publication_id,
      mapEntryId: existingEvent.map_entry_id,
      state: existingEvent.state,
      replayed: true,
    };
  }

  const existingMap = await env.DB.prepare(
    "SELECT * FROM map_entries WHERE id = ?",
  )
    .bind(publication.mapEntryId)
    .first<MapEntryRow>();
  if (
    existingMap &&
    (existingMap.legacy_map_id !== publication.legacyMapId ||
      existingMap.content_receipt !== publication.contentReceipt ||
      existingMap.renderer !== publication.renderer ||
      existingMap.renderer_format_version !==
        publication.rendererFormatVersion ||
      existingMap.features_json !== JSON.stringify(publication.features))
  ) {
    throw new HttpError(409, "map content identity conflict");
  }
  for (const artifact of publication.artifacts) {
    const existingArtifact = await env.DB.prepare(
      "SELECT * FROM artifacts WHERE id = ? OR (bucket_slot = ? AND object_key = ?)",
    )
      .bind(artifact.artifactId, artifact.bucketSlot, artifact.objectKey)
      .first<ArtifactRow>();
    if (
      existingArtifact &&
      (existingArtifact.id !== artifact.artifactId ||
        existingArtifact.map_entry_id !== publication.mapEntryId ||
        existingArtifact.sha256 !== artifact.sha256 ||
        existingArtifact.byte_count !== artifact.bytes)
    ) {
      throw new HttpError(409, "artifact identity conflict");
    }
  }

  const now = new Date().toISOString();
  const statements: D1PreparedStatement[] = [];
  if (!existingMap) {
    statements.push(
      env.DB.prepare(
        `INSERT INTO map_entries(
          id, legacy_map_id, content_receipt, origin_channel, canonical_name,
          source_region_name, bounds_json, renderer, renderer_format_version,
          features_json, attribution_json, generated_at, delivery_state,
          created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ).bind(
        publication.mapEntryId,
        publication.legacyMapId,
        publication.contentReceipt,
        publication.originChannel,
        publication.canonicalName,
        publication.sourceRegionName ?? null,
        publication.bounds ? JSON.stringify(publication.bounds) : null,
        publication.renderer,
        publication.rendererFormatVersion,
        JSON.stringify(publication.features),
        JSON.stringify(publication.attribution),
        publication.generatedAt ?? null,
        publication.deliveryState,
        now,
        now,
      ),
    );
  } else if (
    publication.deliveryState === "production" &&
    existingMap.delivery_state !== "production"
  ) {
    statements.push(
      env.DB.prepare(
        "UPDATE map_entries SET delivery_state = 'production', updated_at = ? WHERE id = ?",
      ).bind(now, publication.mapEntryId),
    );
  }
  for (const artifact of publication.artifacts) {
    statements.push(
      env.DB.prepare(
        `INSERT OR IGNORE INTO artifacts(
          id, map_entry_id, bucket_slot, object_key, format, media_type,
          filename, byte_count, sha256, manifest_receipt, signed_manifest_receipt,
          signature_key_id, signature_key_sha256, producer_build_sha256,
          producer_image_digest, required_ios_build, required_ios_git_sha,
          required_ios_build_sha256, required_firmware_version,
          required_firmware_build, required_firmware_git_sha,
          delivery_tier, state, created_at, verified_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'live', ?, ?)`,
      ).bind(
        artifact.artifactId,
        publication.mapEntryId,
        artifact.bucketSlot,
        artifact.objectKey,
        artifact.format,
        artifact.mediaType,
        artifact.filename,
        artifact.bytes,
        artifact.sha256,
        artifact.manifestReceipt ?? null,
        artifact.signedManifestReceipt ?? null,
        artifact.signatureKeyId ?? null,
        artifact.signatureKeySha256 ?? null,
        artifact.producerBuildSha256 ?? null,
        artifact.producerImageDigest ?? null,
        artifact.requiredIosBuild ?? null,
        artifact.requiredIosGitSha ?? null,
        artifact.requiredIosBuildSha256 ?? null,
        artifact.requiredFirmwareVersion ?? null,
        artifact.requiredFirmwareBuild ?? null,
        artifact.requiredFirmwareGitSha ?? null,
        artifact.deliveryTier,
        now,
        now,
      ),
    );
  }
  statements.push(
    env.DB.prepare(
      `INSERT INTO publication_events(
        idempotency_key, publication_id, map_entry_id, channel,
        body_sha256, state, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, 'finalized', ?, ?)`,
    ).bind(
      idempotencyKey,
      publication.publicationId,
      publication.mapEntryId,
      publication.deliveryState,
      bodySha256,
      now,
      now,
    ),
  );
  await env.DB.batch(statements);
  return {
    publicationId: publication.publicationId,
    mapEntryId: publication.mapEntryId,
    state: "finalized",
    replayed: false,
  };
}

export async function attachLibrary(
  env: Env,
  publicationID: string,
  libraryID: string,
  aliasValue: unknown,
  serviceChannel: Channel,
): Promise<LibraryMapResponse> {
  const publication = await env.DB.prepare(
    `SELECT map_entry_id FROM publication_events
      WHERE publication_id = ? AND channel = ? AND state = 'finalized'`,
  )
    .bind(publicationID, serviceChannel)
    .first<{ map_entry_id: string }>();
  if (!publication) throw new HttpError(404, "publication not found");
  const map = await env.DB.prepare(
    "SELECT canonical_name FROM map_entries WHERE id = ?",
  )
    .bind(publication.map_entry_id)
    .first<{ canonical_name: string }>();
  if (!map) throw new HttpError(404, "map not found");
  const alias =
    aliasValue === undefined || aliasValue === null
      ? map.canonical_name
      : normalizeAlias(aliasValue);
  const aliasSource =
    aliasValue === undefined || aliasValue === null ? "generated" : "creator";
  const now = new Date().toISOString();
  await env.DB.prepare(
    `INSERT INTO library_maps(
       library_id, map_entry_id, alias, alias_source, added_at, updated_at
     ) VALUES (?, ?, ?, ?, ?, ?)
     ON CONFLICT(library_id, map_entry_id) DO UPDATE SET
       alias = CASE WHEN library_maps.alias_source = 'generated' THEN excluded.alias ELSE library_maps.alias END,
       alias_source = CASE WHEN library_maps.alias_source = 'generated' THEN excluded.alias_source ELSE library_maps.alias_source END,
       updated_at = CASE WHEN library_maps.alias_source = 'generated' THEN excluded.updated_at ELSE library_maps.updated_at END`,
  )
    .bind(libraryID, publication.map_entry_id, alias, aliasSource, now, now)
    .run();
  return getLibraryMap(env, libraryID, publication.map_entry_id);
}

export async function createShare(
  env: Env,
  libraryID: string,
  mapEntryID: string,
  expiresAtValue: unknown,
): Promise<{
  shareId: string;
  url: string;
  title: string;
  expiresAt: string | null;
}> {
  const map = await libraryMapRow(env, libraryID, mapEntryID);
  let expiresAt: string | null = null;
  if (expiresAtValue !== undefined && expiresAtValue !== null) {
    if (typeof expiresAtValue !== "string")
      throw new HttpError(400, "expiresAt is invalid");
    const date = new Date(expiresAtValue);
    if (!Number.isFinite(date.getTime()) || date.getTime() <= Date.now()) {
      throw new HttpError(400, "expiresAt is invalid");
    }
    expiresAt = date.toISOString();
  }
  const token = randomToken(32);
  const shareID = `share_v1_${randomToken(18)}`;
  const now = new Date().toISOString();
  await env.DB.prepare(
    `INSERT INTO shares(
       id, token_hash, owner_library_id, map_entry_id, title_snapshot,
       created_at, expires_at
     ) VALUES (?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      shareID,
      await sha256Hex(token),
      libraryID,
      mapEntryID,
      map.alias,
      now,
      expiresAt,
    )
    .run();
  return {
    shareId: shareID,
    url: `${env.PUBLIC_BASE_URL.replace(/\/$/, "")}/s/${token}`,
    title: map.alias,
    expiresAt,
  };
}

interface ShareListRow {
  id: string;
  map_entry_id: string;
  title_snapshot: string;
  created_at: string;
  expires_at: string | null;
  revoked_at: string | null;
  claim_count: number;
}

export async function listShares(
  env: Env,
  libraryID: string,
): Promise<{ shares: Array<Record<string, unknown>> }> {
  const result = await env.DB.prepare(
    `SELECT id, map_entry_id, title_snapshot, created_at, expires_at, revoked_at, claim_count
       FROM shares WHERE owner_library_id = ?
      ORDER BY created_at DESC LIMIT 100`,
  )
    .bind(libraryID)
    .all<ShareListRow>();
  return {
    shares: result.results.map((row) => ({
      shareId: row.id,
      mapEntryId: row.map_entry_id,
      title: row.title_snapshot,
      createdAt: row.created_at,
      expiresAt: row.expires_at,
      revokedAt: row.revoked_at,
      claimCount: row.claim_count,
    })),
  };
}

export async function revokeShare(
  env: Env,
  libraryID: string,
  shareID: string,
): Promise<void> {
  if (!SHARE_ID.test(shareID)) throw new HttpError(404, "share not found");
  const result = await env.DB.prepare(
    `UPDATE shares SET revoked_at = COALESCE(revoked_at, ?)
      WHERE id = ? AND owner_library_id = ?`,
  )
    .bind(new Date().toISOString(), shareID, libraryID)
    .run();
  if (result.meta.changes !== 1) throw new HttpError(404, "share not found");
}

interface SharePreviewRow extends MapEntryRow {
  share_id: string;
  title_snapshot: string;
  expires_at: string | null;
  revoked_at: string | null;
}

export async function sharePreview(
  env: Env,
  token: string,
): Promise<{
  shareId: string;
  mapEntryId: string;
  title: string;
  bounds: unknown;
  renderer: string;
  rendererFormatVersion: number;
  features: string[];
  attribution: Record<string, unknown>;
  approximateBytes: number;
  deliveryState: string;
  expiresAt: string | null;
}> {
  const row = await env.DB.prepare(
    `SELECT me.*, s.id AS share_id, s.title_snapshot, s.expires_at, s.revoked_at
       FROM shares s JOIN map_entries me ON me.id = s.map_entry_id
      WHERE s.token_hash = ?`,
  )
    .bind(await sha256Hex(token))
    .first<SharePreviewRow>();
  if (
    !row ||
    row.revoked_at ||
    (row.expires_at && row.expires_at <= new Date().toISOString())
  ) {
    throw new HttpError(404, "share not found");
  }
  const bytes = await env.DB.prepare(
    `SELECT MAX(byte_count) AS byte_count FROM artifacts
      WHERE map_entry_id = ? AND state = 'live'`,
  )
    .bind(row.id)
    .first<{ byte_count: number | null }>();
  return {
    shareId: row.share_id,
    mapEntryId: row.id,
    title: row.title_snapshot,
    bounds: parseJSON(row.bounds_json, null),
    renderer: row.renderer,
    rendererFormatVersion: row.renderer_format_version,
    features: parseJSON(row.features_json, []),
    attribution: parseJSON(row.attribution_json, {}),
    approximateBytes: bytes?.byte_count ?? 0,
    deliveryState: row.delivery_state,
    expiresAt: row.expires_at,
  };
}

export async function claimShare(
  env: Env,
  libraryID: string,
  token: string,
): Promise<LibraryMapResponse> {
  const preview = await sharePreview(env, token);
  const now = new Date().toISOString();
  const result = await env.DB.batch([
    env.DB.prepare(
      `INSERT OR IGNORE INTO library_maps(
         library_id, map_entry_id, alias, alias_source, added_at, updated_at, source_share_id
       ) VALUES (?, ?, ?, 'share', ?, ?, ?)`,
    ).bind(
      libraryID,
      preview.mapEntryId,
      preview.title,
      now,
      now,
      preview.shareId,
    ),
    env.DB.prepare(
      `INSERT OR IGNORE INTO share_claims(share_id, recipient_library_id, claimed_at)
       VALUES (?, ?, ?)`,
    ).bind(preview.shareId, libraryID, now),
  ]);
  const claimInserted = result[1]?.meta.changes === 1;
  if (claimInserted) {
    await env.DB.prepare(
      "UPDATE shares SET claim_count = claim_count + 1 WHERE id = ?",
    )
      .bind(preview.shareId)
      .run();
  }
  return getLibraryMap(env, libraryID, preview.mapEntryId);
}

interface AcceptedSigner {
  keyId: string;
  keySha256: string;
}

interface AppIdentity {
  build: string;
  gitSha: string;
  buildSha256: string;
}

export async function createLibraryDownloadGrant(
  env: Env,
  libraryID: string,
  mapEntryID: string,
  channel: Channel,
  acceptedSignersValue: unknown,
  appIdentityValue: unknown,
): Promise<{
  downloadURL: string;
  expiresAt: string;
  artifact: PublicArtifact;
}> {
  await libraryMapRow(env, libraryID, mapEntryID);
  if (
    !Array.isArray(acceptedSignersValue) ||
    acceptedSignersValue.length > 32
  ) {
    throw new HttpError(400, "acceptedSigners are invalid");
  }
  const acceptedSigners = acceptedSignersValue.map((value): AcceptedSigner => {
    if (
      value === null ||
      Array.isArray(value) ||
      typeof value !== "object" ||
      typeof (value as Record<string, unknown>).keyId !== "string" ||
      typeof (value as Record<string, unknown>).keySha256 !== "string" ||
      !/^[A-Za-z0-9._-]{1,64}$/.test((value as { keyId: string }).keyId) ||
      !/^[0-9a-f]{64}$/.test((value as { keySha256: string }).keySha256)
    ) {
      throw new HttpError(400, "acceptedSigners are invalid");
    }
    return value as AcceptedSigner;
  });
  if (
    appIdentityValue === null ||
    Array.isArray(appIdentityValue) ||
    typeof appIdentityValue !== "object"
  ) {
    throw new HttpError(400, "appIdentity is invalid");
  }
  const appIdentity = appIdentityValue as Record<string, unknown>;
  const appIdentityKeys = Object.keys(appIdentity).sort().join(",");
  if (
    appIdentityKeys !== "build,buildSha256,gitSha" ||
    typeof appIdentity.build !== "string" ||
    !/^[0-9]{1,18}(?:\.[0-9]{1,18}){0,2}$/.test(appIdentity.build) ||
    typeof appIdentity.gitSha !== "string" ||
    !/^[0-9a-f]{40}$/.test(appIdentity.gitSha) ||
    typeof appIdentity.buildSha256 !== "string" ||
    !/^[0-9a-f]{64}$/.test(appIdentity.buildSha256)
  ) {
    throw new HttpError(400, "appIdentity is invalid");
  }
  const tiers =
    channel === "production" ? ["production"] : ["development", "production"];
  const result = await env.DB.prepare(
    `SELECT * FROM artifacts
      WHERE map_entry_id = ? AND state = 'live' AND format = 'bike-map-stream-v1'
        AND delivery_tier IN (?, ?)
      ORDER BY CASE delivery_tier WHEN ? THEN 0 ELSE 1 END, created_at DESC`,
  )
    .bind(mapEntryID, tiers[0], tiers[1] ?? tiers[0], tiers[0])
    .all<ArtifactRow>();
  const artifact = result.results.find((candidate) => {
    const signerAccepted = acceptedSigners.some(
      (signer) =>
        signer.keyId === candidate.signature_key_id &&
        signer.keySha256 === candidate.signature_key_sha256,
    );
    if (!signerAccepted) return false;
    if (candidate.required_ios_build === null) {
      return channel === "development";
    }
    return (
      candidate.required_ios_build === appIdentity.build &&
      candidate.required_ios_git_sha === appIdentity.gitSha &&
      candidate.required_ios_build_sha256 === appIdentity.buildSha256
    );
  });
  if (!artifact) {
    if (channel === "production")
      throw new HttpError(409, "production promotion required");
    throw new HttpError(409, "no compatible artifact is available");
  }
  const grant = randomToken(32);
  const now = new Date();
  const expires = new Date(now.getTime() + 15 * 60 * 1000);
  await env.DB.prepare(
    `INSERT INTO download_grants(
       token_hash, library_id, artifact_id, purpose, created_at, expires_at
     ) VALUES (?, ?, ?, 'library', ?, ?)`,
  )
    .bind(
      await sha256Hex(grant),
      libraryID,
      artifact.id,
      now.toISOString(),
      expires.toISOString(),
    )
    .run();
  const publicValue = publicArtifact(artifact);
  if (publicValue.requiredIosBuild === null && channel === "development") {
    publicValue.requiredIosBuild = appIdentity.build as string;
    publicValue.requiredIosGitSha = appIdentity.gitSha as string;
    publicValue.requiredIosBuildSha256 = appIdentity.buildSha256 as string;
  }
  return {
    downloadURL: `${env.PUBLIC_BASE_URL.replace(/\/$/, "")}/v1/downloads/${grant}`,
    expiresAt: expires.toISOString(),
    artifact: publicValue,
  };
}

export async function resolveDownloadGrant(
  env: Env,
  token: string,
  purpose: "library" | "promotion",
): Promise<ArtifactRow> {
  const row = await env.DB.prepare(
    `SELECT a.*
       FROM download_grants dg JOIN artifacts a ON a.id = dg.artifact_id
      WHERE dg.token_hash = ? AND dg.purpose = ? AND dg.expires_at > ?
        AND a.state = 'live'`,
  )
    .bind(await sha256Hex(token), purpose, new Date().toISOString())
    .first<ArtifactRow>();
  if (!row) throw new HttpError(404, "download grant not found");
  return row;
}

export async function createPromotionGrant(
  env: Env,
  mapEntryID: string,
): Promise<{
  downloadURL: string;
  expiresAt: string;
  artifact: PublicArtifact;
  map: Record<string, unknown>;
}> {
  if (!MAP_ENTRY_ID.test(mapEntryID)) throw new HttpError(404, "map not found");
  const map = await env.DB.prepare("SELECT * FROM map_entries WHERE id = ?")
    .bind(mapEntryID)
    .first<MapEntryRow>();
  if (!map) throw new HttpError(404, "map not found");
  const artifact = await env.DB.prepare(
    `SELECT * FROM artifacts
      WHERE map_entry_id = ? AND bucket_slot = 'development'
        AND delivery_tier = 'development' AND format = 'zip-stored-v1'
        AND state = 'live'
      ORDER BY created_at DESC LIMIT 1`,
  )
    .bind(mapEntryID)
    .first<ArtifactRow>();
  if (!artifact) throw new HttpError(404, "promotable artifact not found");
  const grant = randomToken(32);
  const now = new Date();
  const expires = new Date(now.getTime() + 15 * 60 * 1000);
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO download_grants(
         token_hash, artifact_id, purpose, created_at, expires_at
       ) VALUES (?, ?, 'promotion', ?, ?)`,
    ).bind(
      await sha256Hex(grant),
      artifact.id,
      now.toISOString(),
      expires.toISOString(),
    ),
    env.DB.prepare(
      `UPDATE map_entries SET delivery_state = 'promotion_pending', updated_at = ?
        WHERE id = ? AND delivery_state = 'development'`,
    ).bind(now.toISOString(), mapEntryID),
  ]);
  return {
    downloadURL: `${env.PUBLIC_BASE_URL.replace(/\/$/, "")}/v1/internal/promotions/downloads/${grant}`,
    expiresAt: expires.toISOString(),
    artifact: publicArtifact(artifact),
    map: {
      mapEntryId: map.id,
      mapId: map.legacy_map_id,
      contentReceipt: map.content_receipt,
      originChannel: map.origin_channel,
      canonicalName: map.canonical_name,
      sourceRegionName: map.source_region_name,
      bounds: parseJSON(map.bounds_json, null),
      renderer: map.renderer,
      rendererFormatVersion: map.renderer_format_version,
      features: parseJSON<string[]>(map.features_json, []),
      attribution: parseJSON<Record<string, unknown>>(map.attribution_json, {}),
      generatedAt: map.generated_at,
    },
  };
}

export async function quarantinePublication(
  env: Env,
  publicationID: string,
  serviceChannel: Channel,
): Promise<void> {
  const event = await env.DB.prepare(
    "SELECT map_entry_id FROM publication_events WHERE publication_id = ? AND channel = ?",
  )
    .bind(publicationID, serviceChannel)
    .first<{ map_entry_id: string }>();
  if (!event) throw new HttpError(404, "publication not found");
  const now = new Date().toISOString();
  await env.DB.batch([
    env.DB.prepare(
      "UPDATE publication_events SET state = 'quarantined', updated_at = ? WHERE publication_id = ?",
    ).bind(now, publicationID),
    env.DB.prepare(
      "UPDATE map_entries SET delivery_state = 'blocked', updated_at = ? WHERE id = ?",
    ).bind(now, event.map_entry_id),
    env.DB.prepare(
      "UPDATE artifacts SET state = 'quarantined' WHERE map_entry_id = ? AND state = 'live'",
    ).bind(event.map_entry_id),
  ]);
}

export async function createLinkCode(
  env: Env,
  libraryID: string,
): Promise<{ code: string; expiresAt: string }> {
  const code =
    `${randomToken(6).slice(0, 4)}-${randomToken(6).slice(0, 4)}`.toUpperCase();
  const now = new Date();
  const expires = new Date(now.getTime() + 10 * 60 * 1000);
  await env.DB.prepare(
    `INSERT INTO linked_library_codes(code_hash, source_library_id, created_at, expires_at)
     VALUES (?, ?, ?, ?)`,
  )
    .bind(
      await sha256Hex(code),
      libraryID,
      now.toISOString(),
      expires.toISOString(),
    )
    .run();
  return { code, expiresAt: expires.toISOString() };
}

export async function claimLinkCode(
  env: Env,
  targetLibraryID: string,
  code: string,
): Promise<{ libraryId: string; credential: string }> {
  if (!/^[A-Z0-9_-]{4}-[A-Z0-9_-]{4}$/.test(code))
    throw new HttpError(404, "link code not found");
  const row = await env.DB.prepare(
    `SELECT source_library_id FROM linked_library_codes
      WHERE code_hash = ? AND claimed_at IS NULL AND expires_at > ?`,
  )
    .bind(await sha256Hex(code), new Date().toISOString())
    .first<{ source_library_id: string }>();
  if (!row) throw new HttpError(404, "link code not found");
  if (row.source_library_id === targetLibraryID) {
    throw new HttpError(409, "apps already use this library");
  }
  const targetContent = await env.DB.prepare(
    `SELECT
       (SELECT COUNT(*) FROM library_maps WHERE library_id = ?) +
       (SELECT COUNT(*) FROM shares WHERE owner_library_id = ?) AS item_count`,
  )
    .bind(targetLibraryID, targetLibraryID)
    .first<{ item_count: number }>();
  if (!targetContent || targetContent.item_count !== 0) {
    throw new HttpError(409, "target library is not empty");
  }
  const credential = randomToken(32);
  const credentialHash = await sha256Hex(credential);
  const now = new Date().toISOString();
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO library_credentials(
         credential_hash, library_id, created_at, last_used_at
       ) VALUES (?, ?, ?, ?)`,
    ).bind(credentialHash, row.source_library_id, now, now),
    env.DB.prepare(
      `UPDATE library_credentials SET revoked_at = ?
        WHERE library_id = ? AND revoked_at IS NULL`,
    ).bind(now, targetLibraryID),
    env.DB.prepare(
      "UPDATE libraries SET revoked_at = ?, updated_at = ? WHERE id = ?",
    ).bind(now, now, targetLibraryID),
    env.DB.prepare(
      "UPDATE linked_library_codes SET claimed_at = ? WHERE code_hash = ?",
    ).bind(now, await sha256Hex(code)),
  ]);
  return { libraryId: row.source_library_id, credential };
}
