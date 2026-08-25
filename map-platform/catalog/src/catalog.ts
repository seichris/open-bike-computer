import {
  HttpError,
  normalizeAlias,
  randomToken,
  requireExactKeys,
  sha256Hex,
} from "./security";
import { verifyArtifactObject } from "./r2";
import type { ArtifactRow, Channel, Env, MapEntryRow } from "./types";
import type { PublicationArtifactInput, PublicationInput } from "./validation";
import type { ReaderRequirements } from "./validation";

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const MAP_ENTRY_ID = /^map_v1_[A-Za-z0-9_-]{43}$/;
const ARTIFACT_ID = /^artifact_v1_[A-Za-z0-9_-]{43}$/;
const SHARE_ID = /^[A-Za-z0-9_-]{16,128}$/;
const PROMOTION_LEASE_ID = /^promotion_lease_v1_[A-Za-z0-9_-]{32}$/;
const MAX_LIBRARY_MAPS = 100;
const MAX_ACTIVE_SHARES = 100;
const MAX_TOTAL_SHARES = 500;
const MAX_SHARE_PURGE_BATCH = 25;
const MAX_EPHEMERAL_PURGE_BATCH = 25;
const MAX_ACTIVE_LINK_CODES = 5;
const MAX_TOTAL_LINK_CODES = 50;
const MAX_SHARE_CLAIMS = 500;
const MAX_ACTIVE_LIBRARY_CREDENTIALS = 8;
const MAX_LINKED_LIBRARY_PRINCIPALS = 8;
const MAX_LIVE_ARTIFACT_GENERATION_CLASSES = 16;
const MAX_RETENTION_BATCH = 10;
const RETENTION_AUTHORIZATION_MILLISECONDS = 15 * 60 * 1000;
const PROMOTION_LEASE_MILLISECONDS = 60 * 60 * 1000;

function retentionGraceMilliseconds(env: Env): number {
  const days = Number(env.RETENTION_GRACE_DAYS ?? "30");
  if (!Number.isSafeInteger(days) || days < 1 || days > 365) {
    throw new HttpError(503, "retention grace is not configured safely");
  }
  return days * 24 * 60 * 60 * 1000;
}

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
  readerRequirements: ReaderRequirements | null;
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

interface ArtifactWithReaderDescriptor extends ArtifactRow {
  map_renderer?: string;
  map_renderer_format_version?: number;
  map_features_json?: string;
}

function parseJSON<T>(value: string | null, fallback: T): T {
  if (value === null) return fallback;
  try {
    return JSON.parse(value) as T;
  } catch {
    return fallback;
  }
}

function readerRequirementsForArtifact(
  row: ArtifactWithReaderDescriptor,
): ReaderRequirements | null {
  const stored = parseJSON<ReaderRequirements | null>(
    row.reader_requirements_json,
    null,
  );
  if (stored !== null) return stored;
  if (
    row.format !== "bike-map-stream-v1" ||
    row.map_renderer === undefined ||
    row.map_renderer_format_version === undefined ||
    row.map_features_json === undefined
  ) {
    return null;
  }
  return {
    schemaVersion: 1,
    streamFormat: "bike-map-stream-v1",
    manifestSchemaVersion: 1,
    renderer: row.map_renderer,
    rendererFormatVersion: row.map_renderer_format_version,
    requiredFeatures: parseJSON<string[]>(row.map_features_json, []),
  };
}

function publicArtifact(row: ArtifactWithReaderDescriptor): PublicArtifact {
  const readerRequirements = readerRequirementsForArtifact(row);
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
    readerRequirements,
    requiredFirmwareVersion: row.required_firmware_version,
    requiredFirmwareBuild: row.required_firmware_build,
    requiredFirmwareGitSha: row.required_firmware_git_sha,
    deliveryTier: row.delivery_tier,
  };
}

async function artifactsForMaps(
  env: Env,
  mapEntryIDs: string[],
): Promise<Map<string, PublicArtifact[]>> {
  const artifacts = new Map<string, PublicArtifact[]>();
  for (const mapEntryID of mapEntryIDs) artifacts.set(mapEntryID, []);
  if (mapEntryIDs.length === 0) return artifacts;
  const placeholders = mapEntryIDs.map(() => "?").join(", ");
  const result = await env.DB.prepare(
    `SELECT artifacts.*, map_entries.renderer AS map_renderer,
            map_entries.renderer_format_version AS map_renderer_format_version,
            map_entries.features_json AS map_features_json
       FROM artifacts JOIN map_entries ON map_entries.id = artifacts.map_entry_id
      WHERE artifacts.map_entry_id IN (${placeholders})
        AND artifacts.generation_head = 1 AND artifacts.state = 'live'
      ORDER BY artifacts.map_entry_id ASC, artifacts.delivery_tier DESC,
               artifacts.format ASC, artifacts.created_at DESC`,
  )
    .bind(...mapEntryIDs)
    .all<ArtifactWithReaderDescriptor>();
  for (const row of result.results) {
    artifacts.get(row.map_entry_id)?.push(publicArtifact(row));
  }
  return artifacts;
}

function libraryMapResponse(
  row: LibraryMapRow,
  artifacts: PublicArtifact[],
): LibraryMapResponse {
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
    artifacts,
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
  const artifacts = await artifactsForMaps(
    env,
    rows.map((row) => row.id),
  );
  const maps = rows.map((row) =>
    libraryMapResponse(row, artifacts.get(row.id) ?? []),
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
  const row = await libraryMapRow(env, libraryID, mapEntryID);
  const artifacts = await artifactsForMaps(env, [row.id]);
  return libraryMapResponse(row, artifacts.get(row.id) ?? []);
}

export async function detachLibraryMap(
  env: Env,
  libraryID: string,
  mapEntryID: string,
): Promise<void> {
  if (!MAP_ENTRY_ID.test(mapEntryID)) {
    throw new HttpError(404, "map not found");
  }
  const now = new Date().toISOString();
  await env.DB.batch([
    env.DB.prepare(
      `DELETE FROM share_claims
        WHERE recipient_library_id = ? AND share_id IN (
          SELECT id FROM shares WHERE map_entry_id = ?
        )`,
    ).bind(libraryID, mapEntryID),
    env.DB.prepare(
      `UPDATE shares AS s SET claim_count = (
         SELECT COUNT(*) FROM share_claims sc WHERE sc.share_id = s.id
       ) WHERE s.map_entry_id = ? AND s.claim_count <> (
         SELECT COUNT(*) FROM share_claims sc WHERE sc.share_id = s.id
       )`,
    ).bind(mapEntryID),
    env.DB.prepare(
      `UPDATE map_entries SET updated_at = ?
        WHERE id = ? AND EXISTS (
          SELECT 1 FROM library_maps
           WHERE library_id = ? AND map_entry_id = ?
        )`,
    ).bind(now, mapEntryID, libraryID, mapEntryID),
    env.DB.prepare(
      "DELETE FROM library_maps WHERE library_id = ? AND map_entry_id = ?",
    ).bind(libraryID, mapEntryID),
  ]);
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

function artifactReaderRequirementsJSON(
  artifact: PublicationArtifactInput,
): string | null {
  return artifact.readerRequirements === null ||
    artifact.readerRequirements === undefined
    ? null
    : JSON.stringify(artifact.readerRequirements);
}

function artifactGenerationClass(artifact: PublicationArtifactInput): string {
  return JSON.stringify({
    schemaVersion: 1,
    bucketSlot: artifact.bucketSlot,
    deliveryTier: artifact.deliveryTier,
    format: artifact.format,
    signatureKeyId: artifact.signatureKeyId ?? null,
    signatureKeySha256: artifact.signatureKeySha256 ?? null,
    readerRequirementsJSON: artifactReaderRequirementsJSON(artifact),
    requiredFirmwareVersion: artifact.requiredFirmwareVersion ?? null,
    requiredFirmwareBuild: artifact.requiredFirmwareBuild ?? null,
    requiredFirmwareGitSha: artifact.requiredFirmwareGitSha ?? null,
  });
}

function artifactMatchesPublication(
  existing: ArtifactRow,
  mapEntryID: string,
  artifact: PublicationArtifactInput,
): boolean {
  return (
    existing.id === artifact.artifactId &&
    existing.map_entry_id === mapEntryID &&
    existing.bucket_slot === artifact.bucketSlot &&
    existing.object_key === artifact.objectKey &&
    existing.format === artifact.format &&
    existing.media_type === artifact.mediaType &&
    existing.filename === artifact.filename &&
    existing.sha256 === artifact.sha256 &&
    existing.byte_count === artifact.bytes &&
    existing.manifest_receipt === (artifact.manifestReceipt ?? null) &&
    existing.signed_manifest_receipt ===
      (artifact.signedManifestReceipt ?? null) &&
    existing.signature_key_id === (artifact.signatureKeyId ?? null) &&
    existing.signature_key_sha256 === (artifact.signatureKeySha256 ?? null) &&
    existing.producer_build_sha256 === (artifact.producerBuildSha256 ?? null) &&
    existing.producer_image_digest === (artifact.producerImageDigest ?? null) &&
    existing.reader_requirements_json ===
      artifactReaderRequirementsJSON(artifact) &&
    existing.generation_class === artifactGenerationClass(artifact) &&
    existing.required_ios_build === (artifact.requiredIosBuild ?? null) &&
    existing.required_ios_git_sha === (artifact.requiredIosGitSha ?? null) &&
    existing.required_ios_build_sha256 ===
      (artifact.requiredIosBuildSha256 ?? null) &&
    existing.required_firmware_version ===
      (artifact.requiredFirmwareVersion ?? null) &&
    existing.required_firmware_build ===
      (artifact.requiredFirmwareBuild ?? null) &&
    existing.required_firmware_git_sha ===
      (artifact.requiredFirmwareGitSha ?? null) &&
    existing.delivery_tier === artifact.deliveryTier &&
    (existing.state === "live" || existing.superseded_at !== null)
  );
}

export async function finalizePublication(
  env: Env,
  publication: PublicationInput,
  idempotencyKey: string,
  bodySha256: string,
  promotionLeaseID: string | null = null,
  verifyObject: (
    artifact: ArtifactRow,
    env: Env,
  ) => Promise<boolean> = verifyArtifactObject,
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
      promotion_lease_id: string | null;
    }>();
  if (existingEvent) {
    if (
      existingEvent.idempotency_key !== idempotencyKey ||
      existingEvent.publication_id !== publication.publicationId ||
      existingEvent.map_entry_id !== publication.mapEntryId ||
      existingEvent.body_sha256 !== bodySha256 ||
      existingEvent.promotion_lease_id !== promotionLeaseID
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

  if (promotionLeaseID !== null) {
    if (
      !PROMOTION_LEASE_ID.test(promotionLeaseID) ||
      publication.originChannel !== "development" ||
      publication.deliveryState !== "production" ||
      publication.artifacts.length !== 1 ||
      publication.artifacts[0].bucketSlot !== "production" ||
      publication.artifacts[0].deliveryTier !== "production" ||
      publication.artifacts[0].format !== "bike-map-stream-v1"
    ) {
      throw new HttpError(400, "promotion publication is invalid");
    }
    const activeLease = await env.DB.prepare(
      `SELECT 1 AS present FROM promotion_leases lease
        JOIN artifacts source ON source.id = lease.source_artifact_id
       WHERE lease.lease_id = ? AND lease.map_entry_id = ?
         AND lease.state = 'active' AND lease.expires_at > ?
         AND source.map_entry_id = lease.map_entry_id
         AND source.bucket_slot = 'development'
         AND source.delivery_tier = 'development'
         AND source.format = 'zip-stored-v1' AND source.state = 'live'
         AND source.object_key = lease.source_object_key
         AND source.byte_count = lease.source_byte_count
         AND source.sha256 = lease.source_sha256`,
    )
      .bind(promotionLeaseID, publication.mapEntryId, new Date().toISOString())
      .first<{ present: number }>();
    if (!activeLease) {
      throw new HttpError(409, "promotion lease is not active");
    }
  }

  const existingMap = await env.DB.prepare(
    "SELECT * FROM map_entries WHERE id = ?",
  )
    .bind(publication.mapEntryId)
    .first<MapEntryRow>();
  if (existingMap?.delivery_state === "tombstoned") {
    throw new HttpError(409, "map is tombstoned");
  }
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
  const now = new Date().toISOString();
  const proposedArtifacts: ArtifactRow[] = publication.artifacts.map(
    (artifact) => ({
      id: artifact.artifactId,
      map_entry_id: publication.mapEntryId,
      bucket_slot: artifact.bucketSlot,
      object_key: artifact.objectKey,
      format: artifact.format,
      media_type: artifact.mediaType,
      filename: artifact.filename,
      byte_count: artifact.bytes,
      sha256: artifact.sha256,
      manifest_receipt: artifact.manifestReceipt ?? null,
      signed_manifest_receipt: artifact.signedManifestReceipt ?? null,
      signature_key_id: artifact.signatureKeyId ?? null,
      signature_key_sha256: artifact.signatureKeySha256 ?? null,
      producer_build_sha256: artifact.producerBuildSha256 ?? null,
      producer_image_digest: artifact.producerImageDigest ?? null,
      reader_requirements_json: artifactReaderRequirementsJSON(artifact),
      generation_class: artifactGenerationClass(artifact),
      superseded_at: null,
      generation_head: 1,
      required_ios_build: artifact.requiredIosBuild ?? null,
      required_ios_git_sha: artifact.requiredIosGitSha ?? null,
      required_ios_build_sha256: artifact.requiredIosBuildSha256 ?? null,
      required_firmware_version: artifact.requiredFirmwareVersion ?? null,
      required_firmware_build: artifact.requiredFirmwareBuild ?? null,
      required_firmware_git_sha: artifact.requiredFirmwareGitSha ?? null,
      delivery_tier: artifact.deliveryTier,
      state: "live",
      created_at: now,
      verified_at: now,
    }),
  );
  if (
    new Set(proposedArtifacts.map((artifact) => artifact.generation_class))
      .size !== proposedArtifacts.length
  ) {
    throw new HttpError(400, "publication artifact generations are duplicated");
  }
  const retainedGenerationClasses = await env.DB.prepare(
    `SELECT DISTINCT generation_class FROM artifacts
      WHERE map_entry_id = ? AND state <> 'deleted'`,
  )
    .bind(publication.mapEntryId)
    .all<{ generation_class: string }>();
  const resultingGenerationClasses = new Set(
    retainedGenerationClasses.results.map((row) => row.generation_class),
  );
  for (const artifact of proposedArtifacts) {
    resultingGenerationClasses.add(artifact.generation_class);
  }
  if (resultingGenerationClasses.size > MAX_LIVE_ARTIFACT_GENERATION_CLASSES) {
    throw new HttpError(409, "map artifact generation class quota exceeded");
  }
  for (const artifact of publication.artifacts) {
    const existingArtifact = await env.DB.prepare(
      "SELECT * FROM artifacts WHERE id = ? OR (bucket_slot = ? AND object_key = ?)",
    )
      .bind(artifact.artifactId, artifact.bucketSlot, artifact.objectKey)
      .first<ArtifactRow>();
    if (
      existingArtifact &&
      !artifactMatchesPublication(
        existingArtifact,
        publication.mapEntryId,
        artifact,
      )
    ) {
      throw new HttpError(409, "artifact identity conflict");
    }
  }
  const objectVerification = await Promise.all(
    proposedArtifacts.map((artifact) => verifyObject(artifact, env)),
  );
  if (objectVerification.some((available) => !available)) {
    throw new HttpError(409, "artifact object identity is unavailable");
  }

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
  const artifactIDPlaceholders = publication.artifacts
    .map(() => "?")
    .join(", ");
  statements.push(
    env.DB.prepare(
      `DELETE FROM artifact_deletion_leases
        WHERE expires_at <= ? AND artifact_id IN (${artifactIDPlaceholders})`,
    ).bind(
      now,
      ...publication.artifacts.map((artifact) => artifact.artifactId),
    ),
  );
  for (const artifact of publication.artifacts) {
    const generationClass = artifactGenerationClass(artifact);
    statements.push(
      env.DB.prepare(
        `UPDATE artifacts
            SET generation_head = 0, superseded_at = COALESCE(superseded_at, ?),
                verified_at = CASE WHEN superseded_at IS NULL THEN ? ELSE verified_at END
          WHERE map_entry_id = ? AND generation_class = ? AND id <> ?
            AND generation_head = 1 AND state IN ('live', 'quarantined')`,
      ).bind(
        now,
        now,
        publication.mapEntryId,
        generationClass,
        artifact.artifactId,
      ),
      env.DB.prepare(
        `INSERT INTO artifacts(
          id, map_entry_id, bucket_slot, object_key, format, media_type,
          filename, byte_count, sha256, manifest_receipt, signed_manifest_receipt,
          signature_key_id, signature_key_sha256, producer_build_sha256,
          producer_image_digest, reader_requirements_json,
          generation_class, superseded_at, generation_head,
          required_ios_build, required_ios_git_sha,
          required_ios_build_sha256, required_firmware_version,
          required_firmware_build, required_firmware_git_sha,
          delivery_tier, state, created_at, verified_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, 1, ?, ?, ?, ?, ?, ?, ?, 'live', ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          state = 'live', superseded_at = NULL, generation_head = 1,
          verified_at = excluded.verified_at
        WHERE (artifacts.generation_head = 0 OR artifacts.superseded_at IS NOT NULL)
          AND NOT EXISTS (
            SELECT 1 FROM artifact_deletion_leases lease
             WHERE lease.artifact_id = artifacts.id
          )`,
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
        artifactReaderRequirementsJSON(artifact),
        generationClass,
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
      env.DB.prepare(
        `UPDATE artifacts AS older
            SET state = 'tombstoned'
          WHERE older.map_entry_id = ? AND older.generation_class = ?
            AND older.id <> ? AND older.generation_head = 0
            AND older.superseded_at IS NOT NULL
            AND older.state IN ('live', 'quarantined')
            AND EXISTS (
              SELECT 1 FROM artifacts replacement
               WHERE replacement.id = ? AND replacement.generation_head = 1
                 AND replacement.map_entry_id = older.map_entry_id
                 AND replacement.generation_class = older.generation_class
                 AND replacement.state = 'live'
            )
            AND NOT EXISTS (
              SELECT 1 FROM download_grants grant_row
               WHERE grant_row.artifact_id = older.id AND grant_row.expires_at > ?
            )
            AND NOT EXISTS (
              SELECT 1 FROM promotion_leases lease
               WHERE lease.source_artifact_id = older.id
                 AND lease.state = 'active' AND lease.expires_at > ?
            )`,
      ).bind(
        publication.mapEntryId,
        generationClass,
        artifact.artifactId,
        artifact.artifactId,
        now,
        now,
      ),
    );
  }
  statements.push(
    env.DB.prepare(
      `INSERT INTO publication_events(
        idempotency_key, publication_id, map_entry_id, channel,
        body_sha256, state, created_at, updated_at, promotion_lease_id
      ) VALUES (?, ?, ?, ?, ?, 'finalized', ?, ?, ?)`,
    ).bind(
      idempotencyKey,
      publication.publicationId,
      publication.mapEntryId,
      publication.deliveryState,
      bodySha256,
      now,
      now,
      promotionLeaseID,
    ),
  );
  if (promotionLeaseID !== null) {
    statements.push(
      env.DB.prepare(
        `UPDATE promotion_leases
            SET state = 'finalized', finalized_at = ?,
                production_publication_id = ?, production_artifact_id = ?
          WHERE lease_id = ? AND map_entry_id = ? AND state = 'active'
            AND expires_at > ?`,
      ).bind(
        now,
        publication.publicationId,
        publication.artifacts[0].artifactId,
        promotionLeaseID,
        publication.mapEntryId,
        now,
      ),
      env.DB.prepare(
        "DELETE FROM download_grants WHERE promotion_lease_id = ?",
      ).bind(promotionLeaseID),
    );
  }
  try {
    await env.DB.batch(statements);
  } catch (error) {
    const replay = await env.DB.prepare(
      "SELECT * FROM publication_events WHERE idempotency_key = ? OR publication_id = ?",
    )
      .bind(idempotencyKey, publication.publicationId)
      .first<{
        idempotency_key: string;
        publication_id: string;
        map_entry_id: string;
        body_sha256: string;
        state: string;
        promotion_lease_id: string | null;
      }>();
    if (
      replay?.idempotency_key === idempotencyKey &&
      replay.publication_id === publication.publicationId &&
      replay.map_entry_id === publication.mapEntryId &&
      replay.body_sha256 === bodySha256 &&
      replay.promotion_lease_id === promotionLeaseID
    ) {
      return {
        publicationId: replay.publication_id,
        mapEntryId: replay.map_entry_id,
        state: replay.state,
        replayed: true,
      };
    }
    if (
      error instanceof Error &&
      error.message.includes("artifact generation class limit")
    ) {
      throw new HttpError(409, "map artifact generation class quota exceeded");
    }
    for (const artifact of publication.artifacts) {
      const conflictingArtifact = await env.DB.prepare(
        "SELECT * FROM artifacts WHERE id = ? OR (bucket_slot = ? AND object_key = ?)",
      )
        .bind(artifact.artifactId, artifact.bucketSlot, artifact.objectKey)
        .first<ArtifactRow>();
      if (
        conflictingArtifact &&
        !artifactMatchesPublication(
          conflictingArtifact,
          publication.mapEntryId,
          artifact,
        )
      ) {
        throw new HttpError(409, "artifact identity conflict");
      }
      if (conflictingArtifact && conflictingArtifact.superseded_at !== null) {
        const activeDeletion = await env.DB.prepare(
          `SELECT 1 AS present FROM artifact_deletion_leases
            WHERE artifact_id = ? AND expires_at > ?`,
        )
          .bind(conflictingArtifact.id, now)
          .first<{ present: number }>();
        if (activeDeletion) {
          throw new HttpError(409, "artifact deletion is in progress");
        }
      }
    }
    if (promotionLeaseID !== null) {
      const lease = await env.DB.prepare(
        `SELECT 1 AS present FROM promotion_leases
          WHERE lease_id = ? AND map_entry_id = ? AND state = 'active'
            AND expires_at > ?`,
      )
        .bind(promotionLeaseID, publication.mapEntryId, now)
        .first<{ present: number }>();
      if (!lease) {
        throw new HttpError(409, "promotion lease is not active");
      }
    }
    throw error;
  }
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
  verifyObject: (
    artifact: ArtifactRow,
    env: Env,
  ) => Promise<boolean> = verifyArtifactObject,
): Promise<LibraryMapResponse> {
  const publication = await env.DB.prepare(
    `SELECT pe.map_entry_id
       FROM publication_events pe
      WHERE pe.publication_id = ? AND pe.channel = ? AND pe.state = 'finalized'`,
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
  const staleLeases = await env.DB.prepare(
    `SELECT a.*
       FROM artifact_deletion_leases lease
      JOIN artifacts a ON a.id = lease.artifact_id
      WHERE a.map_entry_id = ? AND lease.channel = ? AND lease.expires_at <= ?
        AND a.superseded_at IS NULL
      ORDER BY a.id ASC LIMIT 33`,
  )
    .bind(publication.map_entry_id, serviceChannel, now)
    .all<ArtifactRow>();
  const activeLease = await env.DB.prepare(
    `SELECT 1 AS present
       FROM artifact_deletion_leases lease
      JOIN artifacts a ON a.id = lease.artifact_id
      WHERE a.map_entry_id = ? AND lease.channel = ? AND lease.expires_at > ?
        AND a.superseded_at IS NULL
      LIMIT 1`,
  )
    .bind(publication.map_entry_id, serviceChannel, now)
    .first<{ present: number }>();
  if (activeLease) {
    throw new HttpError(409, "retention deletion is in progress");
  }
  if (staleLeases.results.length > 32) {
    throw new HttpError(503, "retention recovery requires maintenance");
  }
  for (const artifact of staleLeases.results) {
    if (!(await verifyObject(artifact, env))) {
      throw new HttpError(409, "retained artifact is unavailable");
    }
  }
  const results = await env.DB.batch([
    env.DB.prepare(
      `DELETE FROM artifact_deletion_leases
        WHERE channel = ? AND expires_at <= ? AND artifact_id IN (
          SELECT id FROM artifacts WHERE map_entry_id = ? AND bucket_slot = ?
            AND superseded_at IS NULL
        )`,
    ).bind(serviceChannel, now, publication.map_entry_id, serviceChannel),
    env.DB.prepare(
      `UPDATE artifacts AS a SET state = 'live', verified_at = ?
        WHERE a.map_entry_id = ? AND a.bucket_slot = ? AND a.state = 'tombstoned'
          AND a.superseded_at IS NULL AND a.generation_head = 1
          AND NOT EXISTS (
            SELECT 1 FROM artifact_deletion_leases lease
             WHERE lease.artifact_id = a.id
          )`,
    ).bind(now, publication.map_entry_id, serviceChannel),
    env.DB.prepare(
      `UPDATE map_entries AS me
          SET delivery_state = CASE
                WHEN EXISTS (
                  SELECT 1 FROM artifacts a
                   WHERE a.map_entry_id = me.id AND a.bucket_slot = 'production'
                     AND a.generation_head = 1 AND a.state = 'live'
                ) THEN 'production'
                ELSE ?
              END,
              updated_at = ?
        WHERE me.id = ?
          AND EXISTS (
            SELECT 1 FROM artifacts a
             WHERE a.map_entry_id = me.id AND a.bucket_slot = ?
               AND a.generation_head = 1 AND a.state = 'live'
          )`,
    ).bind(serviceChannel, now, publication.map_entry_id, serviceChannel),
    env.DB.prepare(
      `INSERT INTO library_maps(
         library_id, map_entry_id, alias, alias_source, added_at, updated_at
       ) SELECT ?, ?, ?, ?, ?, ?
          WHERE EXISTS (
            SELECT 1 FROM artifacts a
             WHERE a.map_entry_id = ? AND a.bucket_slot = ?
               AND a.generation_head = 1 AND a.state = 'live'
          )
            AND NOT EXISTS (
              SELECT 1 FROM artifact_deletion_leases lease
                JOIN artifacts a ON a.id = lease.artifact_id
               WHERE a.map_entry_id = ? AND a.bucket_slot = ?
            )
            AND (
              EXISTS (
                SELECT 1 FROM library_maps
                 WHERE library_id = ? AND map_entry_id = ?
              )
              OR (
                SELECT COUNT(*) FROM library_maps WHERE library_id = ?
              ) < ?
            )
       ON CONFLICT(library_id, map_entry_id) DO UPDATE SET
         alias = CASE WHEN library_maps.alias_source = 'generated' THEN excluded.alias ELSE library_maps.alias END,
         alias_source = CASE WHEN library_maps.alias_source = 'generated' THEN excluded.alias_source ELSE library_maps.alias_source END,
         updated_at = CASE WHEN library_maps.alias_source = 'generated' THEN excluded.updated_at ELSE library_maps.updated_at END`,
    ).bind(
      libraryID,
      publication.map_entry_id,
      alias,
      aliasSource,
      now,
      now,
      publication.map_entry_id,
      serviceChannel,
      publication.map_entry_id,
      serviceChannel,
      libraryID,
      publication.map_entry_id,
      libraryID,
      MAX_LIBRARY_MAPS,
    ),
  ]);
  if (results[3]?.meta.changes !== 1) {
    const usage = await env.DB.prepare(
      "SELECT COUNT(*) AS map_count FROM library_maps WHERE library_id = ?",
    )
      .bind(libraryID)
      .first<{ map_count: number }>();
    if ((usage?.map_count ?? 0) >= MAX_LIBRARY_MAPS) {
      throw new HttpError(409, "library map quota exceeded");
    }
    throw new HttpError(409, "retention deletion is in progress");
  }
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
  const clock = new Date();
  const now = clock.toISOString();
  const purgeCutoff = new Date(
    clock.getTime() - retentionGraceMilliseconds(env),
  ).toISOString();
  const results = await env.DB.batch([
    env.DB.prepare(
      `DELETE FROM shares WHERE id IN (
         SELECT id FROM shares
          WHERE owner_library_id = ?
            AND (
              (revoked_at IS NOT NULL AND revoked_at <= ?)
              OR (expires_at IS NOT NULL AND expires_at <= ?)
            )
          ORDER BY CASE
            WHEN revoked_at IS NULL THEN expires_at
            WHEN expires_at IS NULL THEN revoked_at
            WHEN revoked_at < expires_at THEN revoked_at
            ELSE expires_at
          END ASC, id ASC
          LIMIT ?
       )`,
    ).bind(libraryID, purgeCutoff, purgeCutoff, MAX_SHARE_PURGE_BATCH),
    env.DB.prepare(
      `INSERT INTO shares(
         id, token_hash, owner_library_id, map_entry_id, title_snapshot,
         created_at, expires_at
       ) SELECT ?, ?, ?, ?, ?, ?, ?
          WHERE (
            SELECT COUNT(*) FROM shares WHERE owner_library_id = ?
          ) < ?
            AND (
              SELECT COUNT(*) FROM shares
               WHERE owner_library_id = ? AND revoked_at IS NULL
                 AND (expires_at IS NULL OR expires_at > ?)
            ) < ?`,
    ).bind(
      shareID,
      await sha256Hex(token),
      libraryID,
      mapEntryID,
      map.alias,
      now,
      expiresAt,
      libraryID,
      MAX_TOTAL_SHARES,
      libraryID,
      now,
      MAX_ACTIVE_SHARES,
    ),
  ]);
  if (results[1]?.meta.changes !== 1) {
    throw new HttpError(409, "library share quota exceeded");
  }
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

function decodeShareCursor(cursor: string | null): [string, string] | null {
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
    const [createdAt, id, extra] = decoder.decode(bytes).split("\u0000");
    if (extra !== undefined || !createdAt || !SHARE_ID.test(id)) {
      throw new Error("invalid");
    }
    return [createdAt, id];
  } catch {
    throw new HttpError(400, "cursor is invalid");
  }
}

export async function listShares(
  env: Env,
  libraryID: string,
  cursorValue: string | null,
  requestedLimit: string | null,
): Promise<{
  shares: Array<Record<string, unknown>>;
  nextCursor: string | null;
}> {
  const limit = requestedLimit === null ? 50 : Number(requestedLimit);
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100) {
    throw new HttpError(400, "limit is invalid");
  }
  const cursor = decodeShareCursor(cursorValue);
  const statement = cursor
    ? env.DB.prepare(
        `SELECT id, map_entry_id, title_snapshot, created_at, expires_at, revoked_at, claim_count
           FROM shares
          WHERE owner_library_id = ?
            AND (created_at < ? OR (created_at = ? AND id > ?))
          ORDER BY created_at DESC, id ASC LIMIT ?`,
      ).bind(libraryID, cursor[0], cursor[0], cursor[1], limit + 1)
    : env.DB.prepare(
        `SELECT id, map_entry_id, title_snapshot, created_at, expires_at, revoked_at, claim_count
           FROM shares WHERE owner_library_id = ?
          ORDER BY created_at DESC, id ASC LIMIT ?`,
      ).bind(libraryID, limit + 1);
  const result = await statement.all<ShareListRow>();
  const rows = result.results.slice(0, limit);
  const last = rows.at(-1);
  return {
    shares: rows.map((row) => ({
      shareId: row.id,
      mapEntryId: row.map_entry_id,
      title: row.title_snapshot,
      createdAt: row.created_at,
      expiresAt: row.expires_at,
      revokedAt: row.revoked_at,
      claimCount: row.claim_count,
    })),
    nextCursor:
      result.results.length > limit && last
        ? encodeCursor(last.created_at, last.id)
        : null,
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

async function sharePreviewByHash(
  env: Env,
  tokenHash: string,
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
    .bind(tokenHash)
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
      WHERE map_entry_id = ? AND generation_head = 1 AND state = 'live'`,
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

export async function sharePreview(
  env: Env,
  token: string,
): ReturnType<typeof sharePreviewByHash> {
  return sharePreviewByHash(env, await sha256Hex(token));
}

export async function claimShare(
  env: Env,
  libraryID: string,
  token: string,
): Promise<LibraryMapResponse> {
  const tokenHash = await sha256Hex(token);
  const preview = await sharePreviewByHash(env, tokenHash);
  const now = new Date().toISOString();
  const result = await env.DB.batch([
    env.DB.prepare(
      `INSERT OR IGNORE INTO library_maps(
         library_id, map_entry_id, alias, alias_source, added_at, updated_at, source_share_id
       ) SELECT ?, s.map_entry_id, s.title_snapshot, 'share', ?, ?, s.id
           FROM shares s
          WHERE s.id = ? AND s.token_hash = ? AND s.map_entry_id = ?
            AND s.revoked_at IS NULL
            AND (s.expires_at IS NULL OR s.expires_at > ?)
            AND (
              EXISTS (
                SELECT 1 FROM share_claims
                 WHERE share_id = s.id AND recipient_library_id = ?
              ) OR (
                SELECT COUNT(*) FROM share_claims
                 WHERE recipient_library_id = ?
              ) < ?
            )
            AND (EXISTS (
              SELECT 1 FROM library_maps
               WHERE library_id = ? AND map_entry_id = s.map_entry_id
            ) OR (
            SELECT COUNT(*) FROM library_maps WHERE library_id = ?
          ) < ?)`,
    ).bind(
      libraryID,
      now,
      now,
      preview.shareId,
      tokenHash,
      preview.mapEntryId,
      now,
      libraryID,
      libraryID,
      MAX_SHARE_CLAIMS,
      libraryID,
      libraryID,
      MAX_LIBRARY_MAPS,
    ),
    env.DB.prepare(
      `INSERT OR IGNORE INTO share_claims(share_id, recipient_library_id, claimed_at)
       SELECT s.id, ?, ? FROM shares s
        WHERE s.id = ? AND s.token_hash = ? AND s.map_entry_id = ?
          AND s.revoked_at IS NULL
          AND (s.expires_at IS NULL OR s.expires_at > ?)
          AND (
            EXISTS (
              SELECT 1 FROM share_claims
               WHERE share_id = s.id AND recipient_library_id = ?
            ) OR (
              SELECT COUNT(*) FROM share_claims
               WHERE recipient_library_id = ?
            ) < ?
          )
          AND EXISTS (
            SELECT 1 FROM library_maps
             WHERE library_id = ? AND map_entry_id = s.map_entry_id
          )`,
    ).bind(
      libraryID,
      now,
      preview.shareId,
      tokenHash,
      preview.mapEntryId,
      now,
      libraryID,
      libraryID,
      MAX_SHARE_CLAIMS,
      libraryID,
    ),
    env.DB.prepare(
      `UPDATE shares SET claim_count = (
         SELECT COUNT(*) FROM share_claims WHERE share_id = shares.id
       ) WHERE id = ? AND token_hash = ? AND revoked_at IS NULL
           AND (expires_at IS NULL OR expires_at > ?)`,
    ).bind(preview.shareId, tokenHash, now),
  ]);
  if (result[2]?.meta.changes !== 1) {
    throw new HttpError(404, "share not found");
  }
  if (result[1]?.meta.changes !== 1) {
    const existingClaim = await env.DB.prepare(
      `SELECT 1 AS present FROM share_claims
        WHERE share_id = ? AND recipient_library_id = ?`,
    )
      .bind(preview.shareId, libraryID)
      .first<{ present: number }>();
    if (!existingClaim) {
      throw new HttpError(409, "library share claim quota exceeded");
    }
  }
  if (result[0]?.meta.changes !== 1) {
    const attached = await env.DB.prepare(
      `SELECT 1 AS present FROM library_maps
        WHERE library_id = ? AND map_entry_id = ?`,
    )
      .bind(libraryID, preview.mapEntryId)
      .first<{ present: number }>();
    if (!attached) {
      throw new HttpError(409, "library map quota exceeded");
    }
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

interface ReaderCapabilities {
  schemaVersion: 1;
  streamFormats: Array<{
    format: string;
    manifestSchemaVersions: number[];
  }>;
  renderers: Array<{
    renderer: string;
    formatVersions: number[];
    features: string[];
  }>;
}

const READER_IDENTIFIER = /^[a-z0-9._-]{1,64}$/;

function readerVersionArray(value: unknown, field: string): number[] {
  if (
    !Array.isArray(value) ||
    value.length < 1 ||
    value.length > 32 ||
    value.some(
      (version) =>
        !Number.isSafeInteger(version) ||
        Number(version) < 1 ||
        Number(version) > 255,
    ) ||
    new Set(value).size !== value.length
  ) {
    throw new HttpError(400, `${field} are invalid`);
  }
  return value.map(Number);
}

function parseReaderCapabilities(value: unknown): ReaderCapabilities {
  if (value === null || Array.isArray(value) || typeof value !== "object") {
    throw new HttpError(400, "readerCapabilities are invalid");
  }
  const capabilities = value as Record<string, unknown>;
  requireExactKeys(capabilities, [
    "schemaVersion",
    "streamFormats",
    "renderers",
  ]);
  if (
    capabilities.schemaVersion !== 1 ||
    !Array.isArray(capabilities.streamFormats) ||
    capabilities.streamFormats.length < 1 ||
    capabilities.streamFormats.length > 16 ||
    !Array.isArray(capabilities.renderers) ||
    capabilities.renderers.length < 1 ||
    capabilities.renderers.length > 16
  ) {
    throw new HttpError(400, "readerCapabilities are invalid");
  }
  const streamFormats = capabilities.streamFormats.map((raw) => {
    if (raw === null || Array.isArray(raw) || typeof raw !== "object") {
      throw new HttpError(400, "readerCapabilities streamFormats are invalid");
    }
    const stream = raw as Record<string, unknown>;
    requireExactKeys(stream, ["format", "manifestSchemaVersions"]);
    if (
      typeof stream.format !== "string" ||
      !READER_IDENTIFIER.test(stream.format)
    ) {
      throw new HttpError(400, "readerCapabilities streamFormats are invalid");
    }
    return {
      format: stream.format,
      manifestSchemaVersions: readerVersionArray(
        stream.manifestSchemaVersions,
        "readerCapabilities manifestSchemaVersions",
      ),
    };
  });
  const renderers = capabilities.renderers.map((raw) => {
    if (raw === null || Array.isArray(raw) || typeof raw !== "object") {
      throw new HttpError(400, "readerCapabilities renderers are invalid");
    }
    const renderer = raw as Record<string, unknown>;
    requireExactKeys(renderer, ["renderer", "formatVersions", "features"]);
    if (
      typeof renderer.renderer !== "string" ||
      !READER_IDENTIFIER.test(renderer.renderer) ||
      !Array.isArray(renderer.features) ||
      renderer.features.length > 32 ||
      renderer.features.some(
        (feature) =>
          typeof feature !== "string" || !READER_IDENTIFIER.test(feature),
      ) ||
      new Set(renderer.features).size !== renderer.features.length
    ) {
      throw new HttpError(400, "readerCapabilities renderers are invalid");
    }
    return {
      renderer: renderer.renderer,
      formatVersions: readerVersionArray(
        renderer.formatVersions,
        "readerCapabilities formatVersions",
      ),
      features: renderer.features as string[],
    };
  });
  if (
    new Set(streamFormats.map((stream) => stream.format)).size !==
      streamFormats.length ||
    new Set(renderers.map((renderer) => renderer.renderer)).size !==
      renderers.length
  ) {
    throw new HttpError(400, "readerCapabilities contain duplicates");
  }
  return { schemaVersion: 1, streamFormats, renderers };
}

function readerCanUse(
  capabilities: ReaderCapabilities,
  requirements: ReaderRequirements,
): boolean {
  if (requirements.schemaVersion !== capabilities.schemaVersion) return false;
  const stream = capabilities.streamFormats.find(
    (candidate) => candidate.format === requirements.streamFormat,
  );
  if (
    !stream?.manifestSchemaVersions.includes(requirements.manifestSchemaVersion)
  ) {
    return false;
  }
  const renderer = capabilities.renderers.find(
    (candidate) => candidate.renderer === requirements.renderer,
  );
  return (
    renderer?.formatVersions.includes(requirements.rendererFormatVersion) ===
      true &&
    requirements.requiredFeatures.every((feature) =>
      renderer.features.includes(feature),
    )
  );
}

export async function createLibraryDownloadGrant(
  env: Env,
  libraryID: string,
  mapEntryID: string,
  channel: Channel,
  acceptedSignersValue: unknown,
  appIdentityValue: unknown,
  readerCapabilitiesValue: unknown,
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
  // The build tuple is retained in the signed request as audit context. It is
  // deliberately not an immutable artifact requirement or compatibility key.
  const readerCapabilities = parseReaderCapabilities(readerCapabilitiesValue);
  void appIdentity;
  const tiers =
    channel === "production" ? ["production"] : ["development", "production"];
  const result = await env.DB.prepare(
    `SELECT artifacts.*, map_entries.renderer AS map_renderer,
            map_entries.renderer_format_version AS map_renderer_format_version,
            map_entries.features_json AS map_features_json
       FROM artifacts JOIN map_entries ON map_entries.id = artifacts.map_entry_id
      WHERE artifacts.map_entry_id = ? AND artifacts.generation_head = 1
        AND artifacts.state = 'live'
        AND artifacts.delivery_tier IN (?, ?)
      ORDER BY CASE artifacts.delivery_tier WHEN ? THEN 0 ELSE 1 END,
               artifacts.created_at DESC`,
  )
    .bind(mapEntryID, tiers[0], tiers[1] ?? tiers[0], tiers[0])
    .all<ArtifactWithReaderDescriptor>();
  const artifact = result.results.find((candidate) => {
    const signerAccepted = acceptedSigners.some(
      (signer) =>
        signer.keyId === candidate.signature_key_id &&
        signer.keySha256 === candidate.signature_key_sha256,
    );
    if (!signerAccepted) return false;
    const requirements = readerRequirementsForArtifact(candidate);
    return (
      requirements !== null && readerCanUse(readerCapabilities, requirements)
    );
  });
  if (!artifact) {
    if (channel === "production" && result.results.length === 0)
      throw new HttpError(409, "production promotion required");
    throw new HttpError(409, "no compatible artifact is available");
  }
  const grant = randomToken(32);
  const now = new Date();
  const expires = new Date(now.getTime() + 15 * 60 * 1000);
  await env.DB.batch([
    env.DB.prepare(
      `DELETE FROM download_grants WHERE token_hash IN (
         SELECT token_hash FROM download_grants
          WHERE expires_at <= ? ORDER BY expires_at ASC, token_hash ASC LIMIT ?
       )`,
    ).bind(now.toISOString(), MAX_EPHEMERAL_PURGE_BATCH),
    env.DB.prepare(
      `INSERT INTO download_grants(
         token_hash, library_id, artifact_id, purpose, created_at, expires_at
       ) VALUES (?, ?, ?, 'library', ?, ?)`,
    ).bind(
      await sha256Hex(grant),
      libraryID,
      artifact.id,
      now.toISOString(),
      expires.toISOString(),
    ),
  ]);
  const publicValue = publicArtifact(artifact);
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
  const now = new Date().toISOString();
  const row = await env.DB.prepare(
    `SELECT a.*
       FROM download_grants dg JOIN artifacts a ON a.id = dg.artifact_id
      WHERE dg.token_hash = ? AND dg.purpose = ? AND dg.expires_at > ?
        AND a.state = 'live'
        AND (
          (? = 'library' AND dg.promotion_lease_id IS NULL)
          OR (
            ? = 'promotion' AND dg.promotion_lease_id IS NOT NULL
            AND EXISTS (
              SELECT 1 FROM promotion_leases lease
               WHERE lease.lease_id = dg.promotion_lease_id
                 AND lease.map_entry_id = a.map_entry_id
                 AND lease.source_artifact_id = a.id
                 AND lease.source_object_key = a.object_key
                 AND lease.source_byte_count = a.byte_count
                 AND lease.source_sha256 = a.sha256
                 AND lease.state = 'active' AND lease.expires_at > ?
            )
          )
        )`,
  )
    .bind(await sha256Hex(token), purpose, now, purpose, purpose, now)
    .first<ArtifactRow>();
  if (!row) throw new HttpError(404, "download grant not found");
  return row;
}

async function existingProductionPromotion(
  env: Env,
  mapEntryID: string,
): Promise<{
  state: "already_production";
  mapEntryId: string;
  publicationId: string | null;
  artifact: PublicArtifact;
} | null> {
  const artifact = await env.DB.prepare(
    `SELECT * FROM artifacts
      WHERE map_entry_id = ? AND bucket_slot = 'production'
        AND delivery_tier = 'production' AND format = 'bike-map-stream-v1'
        AND generation_head = 1 AND state = 'live'
      ORDER BY created_at DESC LIMIT 1`,
  )
    .bind(mapEntryID)
    .first<ArtifactRow>();
  if (!artifact) return null;
  const event = await env.DB.prepare(
    `SELECT publication_id FROM publication_events
      WHERE map_entry_id = ? AND channel = 'production' AND state = 'finalized'
      ORDER BY created_at DESC LIMIT 1`,
  )
    .bind(mapEntryID)
    .first<{ publication_id: string }>();
  return {
    state: "already_production",
    mapEntryId: mapEntryID,
    publicationId: event?.publication_id ?? null,
    artifact: publicArtifact(artifact),
  };
}

export async function createPromotionGrant(
  env: Env,
  mapEntryID: string,
  clock = new Date(),
): Promise<
  | {
      state: "granted";
      leaseId: string;
      downloadURL: string;
      expiresAt: string;
      leaseExpiresAt: string;
      artifact: PublicArtifact;
      map: Record<string, unknown>;
    }
  | {
      state: "already_production";
      mapEntryId: string;
      publicationId: string | null;
      artifact: PublicArtifact;
    }
> {
  if (!MAP_ENTRY_ID.test(mapEntryID)) throw new HttpError(404, "map not found");
  const map = await env.DB.prepare("SELECT * FROM map_entries WHERE id = ?")
    .bind(mapEntryID)
    .first<MapEntryRow>();
  if (!map) throw new HttpError(404, "map not found");
  const production = await existingProductionPromotion(env, mapEntryID);
  if (production) return production;
  const artifact = await env.DB.prepare(
    `SELECT * FROM artifacts
      WHERE map_entry_id = ? AND bucket_slot = 'development'
        AND delivery_tier = 'development' AND format = 'zip-stored-v1'
        AND generation_head = 1 AND state = 'live'
      ORDER BY created_at DESC LIMIT 1`,
  )
    .bind(mapEntryID)
    .first<ArtifactRow>();
  if (!artifact) throw new HttpError(404, "promotable artifact not found");
  const grant = randomToken(32);
  const leaseID = `promotion_lease_v1_${randomToken(24)}`;
  const now = clock;
  const nowValue = now.toISOString();
  const expires = new Date(now.getTime() + 15 * 60 * 1000);
  const leaseExpires = new Date(now.getTime() + PROMOTION_LEASE_MILLISECONDS);
  const results = await env.DB.batch([
    env.DB.prepare(
      `DELETE FROM download_grants WHERE token_hash IN (
         SELECT token_hash FROM download_grants
          WHERE expires_at <= ? ORDER BY expires_at ASC, token_hash ASC LIMIT ?
       )`,
    ).bind(nowValue, MAX_EPHEMERAL_PURGE_BATCH),
    env.DB.prepare(
      `INSERT INTO promotion_leases(
         map_entry_id, lease_id, source_artifact_id, source_object_key,
         source_byte_count, source_sha256, state, created_at, expires_at
       ) SELECT me.id, ?, a.id, a.object_key, a.byte_count, a.sha256,
                'active', ?, ?
           FROM map_entries me JOIN artifacts a ON a.map_entry_id = me.id
          WHERE me.id = ? AND me.delivery_state <> 'production'
            AND a.id = ? AND a.bucket_slot = 'development'
            AND a.delivery_tier = 'development' AND a.format = 'zip-stored-v1'
            AND a.state = 'live' AND a.object_key = ?
            AND a.byte_count = ? AND a.sha256 = ?
       ON CONFLICT(map_entry_id) DO UPDATE SET
         lease_id = excluded.lease_id,
         source_artifact_id = excluded.source_artifact_id,
         source_object_key = excluded.source_object_key,
         source_byte_count = excluded.source_byte_count,
         source_sha256 = excluded.source_sha256,
         state = 'active', created_at = excluded.created_at,
         expires_at = excluded.expires_at, finalized_at = NULL,
         production_publication_id = NULL, production_artifact_id = NULL
       WHERE promotion_leases.state = 'active'
         AND promotion_leases.expires_at <= excluded.created_at`,
    ).bind(
      leaseID,
      nowValue,
      leaseExpires.toISOString(),
      mapEntryID,
      artifact.id,
      artifact.object_key,
      artifact.byte_count,
      artifact.sha256,
    ),
    env.DB.prepare(
      `INSERT INTO download_grants(
         token_hash, artifact_id, purpose, created_at, expires_at,
         promotion_lease_id
       ) SELECT ?, ?, 'promotion', ?, ?, ? WHERE EXISTS (
         SELECT 1 FROM promotion_leases
          WHERE map_entry_id = ? AND lease_id = ? AND source_artifact_id = ?
            AND source_object_key = ? AND source_byte_count = ?
            AND source_sha256 = ? AND state = 'active' AND expires_at > ?
       )`,
    ).bind(
      await sha256Hex(grant),
      artifact.id,
      nowValue,
      expires.toISOString(),
      leaseID,
      mapEntryID,
      leaseID,
      artifact.id,
      artifact.object_key,
      artifact.byte_count,
      artifact.sha256,
      nowValue,
    ),
    env.DB.prepare(
      `UPDATE map_entries SET delivery_state = 'promotion_pending', updated_at = ?
        WHERE id = ? AND delivery_state IN ('development', 'promotion_pending')
          AND EXISTS (
            SELECT 1 FROM promotion_leases
             WHERE map_entry_id = ? AND lease_id = ? AND state = 'active'
          )`,
    ).bind(nowValue, mapEntryID, mapEntryID, leaseID),
  ]);
  if (results[1]?.meta.changes !== 1 || results[2]?.meta.changes !== 1) {
    const currentProduction = await existingProductionPromotion(
      env,
      mapEntryID,
    );
    if (currentProduction) return currentProduction;
    throw new HttpError(409, "promotion is already in progress");
  }
  return {
    state: "granted",
    leaseId: leaseID,
    downloadURL: `${env.PUBLIC_BASE_URL.replace(/\/$/, "")}/v1/internal/promotions/downloads/${grant}`,
    expiresAt: expires.toISOString(),
    leaseExpiresAt: leaseExpires.toISOString(),
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

export async function renewPromotionLease(
  env: Env,
  mapEntryID: string,
  leaseID: string,
  identity: {
    artifactId: unknown;
    objectKey: unknown;
    bytes: unknown;
    sha256: unknown;
  },
  clock = new Date(),
): Promise<{
  mapEntryId: string;
  leaseId: string;
  leaseExpiresAt: string;
}> {
  if (
    !MAP_ENTRY_ID.test(mapEntryID) ||
    !PROMOTION_LEASE_ID.test(leaseID) ||
    typeof identity.artifactId !== "string" ||
    !ARTIFACT_ID.test(identity.artifactId) ||
    typeof identity.objectKey !== "string" ||
    !/^(?!\/)(?!.*(?:^|\/)\.\.(?:\/|$))[A-Za-z0-9!_.*'()\/-]{1,1024}$/.test(
      identity.objectKey,
    ) ||
    !Number.isSafeInteger(identity.bytes) ||
    Number(identity.bytes) <= 0 ||
    typeof identity.sha256 !== "string" ||
    !/^[0-9a-f]{64}$/.test(identity.sha256)
  ) {
    throw new HttpError(400, "promotion lease identity is invalid");
  }
  const now = clock.toISOString();
  const leaseExpiresAt = new Date(
    clock.getTime() + PROMOTION_LEASE_MILLISECONDS,
  ).toISOString();
  const result = await env.DB.prepare(
    `UPDATE promotion_leases SET expires_at = ?
      WHERE map_entry_id = ? AND lease_id = ? AND state = 'active'
        AND expires_at > ? AND source_artifact_id = ?
        AND source_object_key = ? AND source_byte_count = ?
        AND source_sha256 = ?
        AND EXISTS (
          SELECT 1 FROM artifacts source
           WHERE source.id = promotion_leases.source_artifact_id
             AND source.map_entry_id = promotion_leases.map_entry_id
             AND source.bucket_slot = 'development'
             AND source.delivery_tier = 'development'
             AND source.format = 'zip-stored-v1' AND source.state = 'live'
             AND source.object_key = promotion_leases.source_object_key
             AND source.byte_count = promotion_leases.source_byte_count
             AND source.sha256 = promotion_leases.source_sha256
        )`,
  )
    .bind(
      leaseExpiresAt,
      mapEntryID,
      leaseID,
      now,
      identity.artifactId,
      identity.objectKey,
      identity.bytes,
      identity.sha256,
    )
    .run();
  if (result.meta.changes !== 1) {
    throw new HttpError(409, "promotion lease is not active");
  }
  return { mapEntryId: mapEntryID, leaseId: leaseID, leaseExpiresAt };
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
      `UPDATE map_entries SET delivery_state = 'blocked', updated_at = ?
        WHERE id = ? AND (
          ? = 'production' OR NOT EXISTS (
            SELECT 1 FROM artifacts
             WHERE map_entry_id = ? AND bucket_slot = 'production' AND state = 'live'
          )
        )`,
    ).bind(now, event.map_entry_id, serviceChannel, event.map_entry_id),
    env.DB.prepare(
      `UPDATE artifacts SET state = 'quarantined', verified_at = ?
        WHERE map_entry_id = ? AND bucket_slot = ? AND state = 'live'`,
    ).bind(now, event.map_entry_id, serviceChannel),
  ]);
}

export interface RetentionAuthorization {
  artifactId: string;
  bucketSlot: Channel;
  objectKey: string;
  bytes: number;
  sha256: string;
  authorizationExpiresAt: string;
}

export interface RetentionDeletionClaim extends RetentionAuthorization {
  leaseId: string;
}

interface RetentionCandidate extends ArtifactRow {
  map_updated_at: string;
}

function noMapReferencePredicates(mapAlias: string): string {
  return `NOT EXISTS (
            SELECT 1 FROM library_maps lm WHERE lm.map_entry_id = ${mapAlias}.id
          )
          AND NOT EXISTS (
            SELECT 1 FROM shares s
             WHERE s.map_entry_id = ${mapAlias}.id AND s.revoked_at IS NULL
               AND (s.expires_at IS NULL OR s.expires_at > ?)
          )`;
}

function noActiveArtifactUsePredicates(artifactAlias: string): string {
  return `NOT EXISTS (
            SELECT 1 FROM download_grants dg
             WHERE dg.artifact_id = ${artifactAlias}.id AND dg.expires_at > ?
          )
          AND NOT EXISTS (
            SELECT 1 FROM promotion_leases lease
             WHERE lease.source_artifact_id = ${artifactAlias}.id
               AND lease.state = 'active' AND lease.expires_at > ?
          )`;
}

function liveGenerationReplacementPredicate(artifactAlias: string): string {
  return `EXISTS (
            SELECT 1 FROM artifacts replacement
             WHERE replacement.map_entry_id = ${artifactAlias}.map_entry_id
               AND replacement.generation_class = ${artifactAlias}.generation_class
               AND replacement.id <> ${artifactAlias}.id
               AND replacement.generation_head = 1
               AND replacement.state = 'live'
          )`;
}

function zeroReferencePredicates(
  artifactAlias: string,
  mapAlias: string,
): string {
  return `${noMapReferencePredicates(mapAlias)}
          AND ${noActiveArtifactUsePredicates(artifactAlias)}`;
}

function deletionEligibilityPredicates(
  artifactAlias: string,
  mapAlias: string,
): string {
  return `(
            (
              ${artifactAlias}.state = 'quarantined'
              AND ${artifactAlias}.verified_at <= ?
              AND ${noActiveArtifactUsePredicates(artifactAlias)}
            ) OR (
              ${artifactAlias}.superseded_at IS NOT NULL
              AND ${liveGenerationReplacementPredicate(artifactAlias)}
              AND ${noActiveArtifactUsePredicates(artifactAlias)}
            ) OR (
              ${zeroReferencePredicates(artifactAlias, mapAlias)}
            )
          )`;
}

export async function prepareRetentionAuthorizations(
  env: Env,
  serviceChannel: Channel,
  requestedLimit: unknown,
  clock = new Date(),
): Promise<{ artifacts: RetentionAuthorization[] }> {
  if (
    !Number.isSafeInteger(requestedLimit) ||
    Number(requestedLimit) < 1 ||
    Number(requestedLimit) > MAX_RETENTION_BATCH
  ) {
    throw new HttpError(400, "retention limit is invalid");
  }
  const limit = Number(requestedLimit);
  const now = clock.toISOString();
  const retentionGrace = retentionGraceMilliseconds(env);
  const cutoff = new Date(clock.getTime() - retentionGrace).toISOString();

  await env.DB.prepare(
    `UPDATE artifacts AS older
        SET state = 'tombstoned'
      WHERE older.id IN (
        SELECT candidate.id FROM artifacts candidate
         WHERE candidate.bucket_slot = ?
           AND candidate.state IN ('live', 'quarantined')
           AND candidate.generation_head = 0
           AND candidate.superseded_at IS NOT NULL
           AND EXISTS (
             SELECT 1 FROM artifacts replacement
              WHERE replacement.map_entry_id = candidate.map_entry_id
                AND replacement.generation_class = candidate.generation_class
                AND replacement.generation_head = 1
                AND replacement.state = 'live'
           )
           AND ${noActiveArtifactUsePredicates("candidate")}
         ORDER BY candidate.created_at ASC, candidate.id ASC LIMIT ?
      )`,
  )
    .bind(serviceChannel, now, now, limit)
    .run();

  const candidates = await env.DB.prepare(
    `SELECT a.*, me.updated_at AS map_updated_at
       FROM artifacts a JOIN map_entries me ON me.id = a.map_entry_id
      WHERE a.bucket_slot = ? AND a.state IN ('live', 'quarantined')
        AND a.superseded_at IS NULL
        AND me.updated_at <= ?
        AND ${zeroReferencePredicates("a", "me")}
      ORDER BY me.updated_at ASC, a.id ASC LIMIT ?`,
  )
    .bind(serviceChannel, cutoff, cutoff, now, now, limit)
    .all<RetentionCandidate>();

  if (candidates.results.length > 0) {
    const statements: D1PreparedStatement[] = candidates.results.map(
      (artifact) =>
        env.DB.prepare(
          `UPDATE artifacts AS a SET state = 'tombstoned', verified_at = ?
          WHERE a.id = ? AND a.bucket_slot = ?
            AND a.state IN ('live', 'quarantined')
            AND a.superseded_at IS NULL
            AND EXISTS (
              SELECT 1 FROM map_entries me
               WHERE me.id = a.map_entry_id AND me.updated_at <= ?
                 AND ${zeroReferencePredicates("a", "me")}
            )`,
        ).bind(now, artifact.id, serviceChannel, cutoff, cutoff, now, now),
    );
    for (const mapEntryID of new Set(
      candidates.results.map((artifact) => artifact.map_entry_id),
    )) {
      statements.push(
        env.DB.prepare(
          `UPDATE map_entries AS me
              SET delivery_state = 'tombstoned', updated_at = ?
            WHERE me.id = ?
              AND NOT EXISTS (
                SELECT 1 FROM library_maps lm WHERE lm.map_entry_id = me.id
              )
              AND NOT EXISTS (
                SELECT 1 FROM shares s
                 WHERE s.map_entry_id = me.id AND s.revoked_at IS NULL
                   AND (s.expires_at IS NULL OR s.expires_at > ?)
              )
              AND NOT EXISTS (
                SELECT 1 FROM artifacts a
                 WHERE a.map_entry_id = me.id AND a.state IN ('live', 'quarantined')
              )`,
        ).bind(now, mapEntryID, cutoff),
      );
    }
    await env.DB.batch(statements);
  }

  const matured = await env.DB.prepare(
    `SELECT a.*, me.updated_at AS map_updated_at
       FROM artifacts a JOIN map_entries me ON me.id = a.map_entry_id
      WHERE a.bucket_slot = ? AND a.state IN ('tombstoned', 'quarantined')
        AND a.verified_at <= ?
        AND ${deletionEligibilityPredicates("a", "me")}
        AND NOT EXISTS (
          SELECT 1 FROM artifact_deletion_leases lease
           WHERE lease.artifact_id = a.id AND lease.expires_at > ?
        )
      ORDER BY a.verified_at ASC, a.id ASC LIMIT ?`,
  )
    .bind(
      serviceChannel,
      cutoff,
      cutoff,
      now,
      now,
      now,
      now,
      cutoff,
      now,
      now,
      now,
      limit,
    )
    .all<RetentionCandidate>();
  const authorizationExpiresAt = new Date(
    clock.getTime() + RETENTION_AUTHORIZATION_MILLISECONDS,
  ).toISOString();
  return {
    artifacts: matured.results.map((artifact) => ({
      artifactId: artifact.id,
      bucketSlot: artifact.bucket_slot,
      objectKey: artifact.object_key,
      bytes: artifact.byte_count,
      sha256: artifact.sha256,
      authorizationExpiresAt,
    })),
  };
}

function validateRetentionIdentity(
  identity: {
    bucketSlot: unknown;
    objectKey: unknown;
    bytes: unknown;
    sha256: unknown;
  },
  serviceChannel: Channel,
): asserts identity is {
  bucketSlot: Channel;
  objectKey: string;
  bytes: number;
  sha256: string;
} {
  if (
    identity.bucketSlot !== serviceChannel ||
    typeof identity.objectKey !== "string" ||
    !/^(?!\/)(?!.*(?:^|\/)\.\.(?:\/|$))[A-Za-z0-9!_.*'()\/-]{1,1024}$/.test(
      identity.objectKey,
    ) ||
    !Number.isSafeInteger(identity.bytes) ||
    Number(identity.bytes) <= 0 ||
    typeof identity.sha256 !== "string" ||
    !/^[0-9a-f]{64}$/.test(identity.sha256)
  ) {
    throw new HttpError(400, "retention artifact identity is invalid");
  }
}

async function retentionArtifact(
  env: Env,
  artifactID: string,
  serviceChannel: Channel,
  identity: {
    bucketSlot: unknown;
    objectKey: unknown;
    bytes: unknown;
    sha256: unknown;
  },
): Promise<ArtifactRow> {
  if (!ARTIFACT_ID.test(artifactID)) {
    throw new HttpError(404, "retention artifact not found");
  }
  validateRetentionIdentity(identity, serviceChannel);
  const artifact = await env.DB.prepare("SELECT * FROM artifacts WHERE id = ?")
    .bind(artifactID)
    .first<ArtifactRow>();
  if (
    !artifact ||
    artifact.bucket_slot !== serviceChannel ||
    artifact.object_key !== identity.objectKey ||
    artifact.byte_count !== identity.bytes ||
    artifact.sha256 !== identity.sha256
  ) {
    throw new HttpError(409, "retention artifact identity conflict");
  }
  return artifact;
}

export async function claimRetentionDeletion(
  env: Env,
  artifactID: string,
  serviceChannel: Channel,
  identity: {
    bucketSlot: unknown;
    objectKey: unknown;
    bytes: unknown;
    sha256: unknown;
  },
  clock = new Date(),
): Promise<RetentionDeletionClaim> {
  const artifact = await retentionArtifact(
    env,
    artifactID,
    serviceChannel,
    identity,
  );
  if (artifact.state !== "tombstoned" && artifact.state !== "quarantined") {
    throw new HttpError(409, "retention artifact is not eligible");
  }
  const now = clock.toISOString();
  const shareCutoff = new Date(
    clock.getTime() - retentionGraceMilliseconds(env),
  ).toISOString();
  const authorizationExpiresAt = new Date(
    clock.getTime() + RETENTION_AUTHORIZATION_MILLISECONDS,
  ).toISOString();
  const leaseID = `retention_lease_v1_${randomToken(24)}`;
  const results = await env.DB.batch([
    env.DB.prepare(
      `DELETE FROM artifact_deletion_leases
        WHERE artifact_id = ? AND expires_at <= ?`,
    ).bind(artifactID, now),
    env.DB.prepare(
      `INSERT INTO artifact_deletion_leases(
         id, artifact_id, channel, object_key, byte_count, sha256,
         state, created_at, expires_at
       ) SELECT ?, a.id, ?, a.object_key, a.byte_count, a.sha256,
                'claimed', ?, ?
           FROM artifacts a JOIN map_entries me ON me.id = a.map_entry_id
          WHERE a.id = ? AND a.bucket_slot = ? AND a.object_key = ?
            AND a.byte_count = ? AND a.sha256 = ?
            AND a.state IN ('tombstoned', 'quarantined')
            AND NOT EXISTS (
              SELECT 1 FROM artifact_deletion_leases lease
               WHERE lease.artifact_id = a.id AND lease.expires_at > ?
            )
            AND ${deletionEligibilityPredicates("a", "me")}`,
    ).bind(
      leaseID,
      serviceChannel,
      now,
      authorizationExpiresAt,
      artifactID,
      serviceChannel,
      identity.objectKey,
      identity.bytes,
      identity.sha256,
      now,
      shareCutoff,
      now,
      now,
      now,
      now,
      shareCutoff,
      now,
      now,
    ),
  ]);
  if (results[1]?.meta.changes !== 1) {
    const activeLease = await env.DB.prepare(
      `SELECT 1 AS present FROM artifact_deletion_leases
        WHERE artifact_id = ? AND expires_at > ?`,
    )
      .bind(artifactID, now)
      .first<{ present: number }>();
    if (activeLease) {
      throw new HttpError(409, "retention artifact is already claimed");
    }
    throw new HttpError(409, "retention artifact gained a live reference");
  }
  return {
    artifactId: artifact.id,
    bucketSlot: artifact.bucket_slot,
    objectKey: artifact.object_key,
    bytes: artifact.byte_count,
    sha256: artifact.sha256,
    authorizationExpiresAt,
    leaseId: leaseID,
  };
}

export async function confirmRetentionDeletion(
  env: Env,
  artifactID: string,
  serviceChannel: Channel,
  identity: {
    bucketSlot: unknown;
    objectKey: unknown;
    bytes: unknown;
    sha256: unknown;
    leaseId: unknown;
    confirmedAbsent: unknown;
  },
  clock = new Date(),
): Promise<{ artifactId: string; state: "deleted" }> {
  const artifact = await retentionArtifact(
    env,
    artifactID,
    serviceChannel,
    identity,
  );
  if (
    typeof identity.leaseId !== "string" ||
    !/^retention_lease_v1_[A-Za-z0-9_-]{32}$/.test(identity.leaseId) ||
    identity.confirmedAbsent !== true
  ) {
    throw new HttpError(400, "retention deletion confirmation is invalid");
  }
  if (artifact.state === "deleted") {
    return { artifactId: artifactID, state: "deleted" };
  }
  if (artifact.state !== "tombstoned" && artifact.state !== "quarantined") {
    throw new HttpError(409, "retention artifact is not eligible");
  }
  const now = clock.toISOString();
  const shareCutoff = new Date(
    clock.getTime() - retentionGraceMilliseconds(env),
  ).toISOString();
  const results = await env.DB.batch([
    env.DB.prepare(
      `UPDATE artifacts AS a
          SET state = 'deleted', generation_head = 0, verified_at = ?
        WHERE a.id = ? AND a.bucket_slot = ? AND a.object_key = ?
           AND a.byte_count = ? AND a.sha256 = ?
           AND a.state IN ('tombstoned', 'quarantined')
          AND EXISTS (
            SELECT 1 FROM artifact_deletion_leases lease
             WHERE lease.artifact_id = a.id AND lease.id = ?
               AND lease.channel = ? AND lease.object_key = a.object_key
               AND lease.byte_count = a.byte_count AND lease.sha256 = a.sha256
               AND lease.state = 'claimed' AND lease.expires_at > ?
          )
          AND EXISTS (
            SELECT 1 FROM map_entries me
             WHERE me.id = a.map_entry_id
               AND ${deletionEligibilityPredicates("a", "me")}
          )`,
    ).bind(
      now,
      artifactID,
      serviceChannel,
      identity.objectKey,
      identity.bytes,
      identity.sha256,
      identity.leaseId,
      serviceChannel,
      now,
      shareCutoff,
      now,
      now,
      now,
      now,
      shareCutoff,
      now,
      now,
    ),
    env.DB.prepare(
      `DELETE FROM artifact_deletion_leases
        WHERE artifact_id = ? AND id = ?
          AND EXISTS (
            SELECT 1 FROM artifacts a
             WHERE a.id = artifact_deletion_leases.artifact_id AND a.state = 'deleted'
          )`,
    ).bind(artifactID, identity.leaseId),
    env.DB.prepare(
      `UPDATE map_entries AS me
          SET delivery_state = 'tombstoned', updated_at = ?
        WHERE me.id = ?
          AND NOT EXISTS (
            SELECT 1 FROM library_maps lm WHERE lm.map_entry_id = me.id
          )
          AND NOT EXISTS (
            SELECT 1 FROM shares s
             WHERE s.map_entry_id = me.id AND s.revoked_at IS NULL
               AND (s.expires_at IS NULL OR s.expires_at > ?)
          )
          AND NOT EXISTS (
            SELECT 1 FROM artifacts a
             WHERE a.map_entry_id = me.id
               AND a.state IN ('live', 'quarantined', 'tombstoned')
          )`,
    ).bind(now, artifact.map_entry_id, shareCutoff),
  ]);
  if (results[0]?.meta.changes !== 1) {
    throw new HttpError(409, "retention artifact gained a live reference");
  }
  return { artifactId: artifactID, state: "deleted" };
}

export async function createLinkCode(
  env: Env,
  libraryID: string,
): Promise<{ code: string; expiresAt: string }> {
  const code =
    `${randomToken(6).slice(0, 4)}-${randomToken(6).slice(0, 4)}`.toUpperCase();
  const now = new Date();
  const expires = new Date(now.getTime() + 10 * 60 * 1000);
  const nowValue = now.toISOString();
  const purgeCutoff = new Date(
    now.getTime() - retentionGraceMilliseconds(env),
  ).toISOString();
  const results = await env.DB.batch([
    env.DB.prepare(
      `DELETE FROM linked_library_codes WHERE code_hash IN (
         SELECT code_hash FROM linked_library_codes
          WHERE source_library_id = ? AND (
            (claimed_at IS NULL AND expires_at <= ?)
             OR (claimed_at IS NOT NULL AND claimed_at <= ?)
          )
          ORDER BY COALESCE(claimed_at, expires_at) ASC, code_hash ASC
          LIMIT ?
       )`,
    ).bind(libraryID, nowValue, purgeCutoff, MAX_EPHEMERAL_PURGE_BATCH),
    env.DB.prepare(
      `INSERT INTO linked_library_codes(code_hash, source_library_id, created_at, expires_at)
       SELECT ?, ?, ?, ?
        WHERE (
          SELECT COUNT(*) FROM linked_library_codes
           WHERE source_library_id = ? AND claimed_at IS NULL AND expires_at > ?
        ) < ?
          AND (
            SELECT COUNT(*) FROM linked_library_codes
             WHERE source_library_id = ?
          ) < ?`,
    ).bind(
      await sha256Hex(code),
      libraryID,
      nowValue,
      expires.toISOString(),
      libraryID,
      nowValue,
      MAX_ACTIVE_LINK_CODES,
      libraryID,
      MAX_TOTAL_LINK_CODES,
    ),
  ]);
  if (results[1]?.meta.changes !== 1) {
    throw new HttpError(409, "library link code quota exceeded");
  }
  return { code, expiresAt: expires.toISOString() };
}

export async function claimLinkCode(
  env: Env,
  targetLibraryID: string,
  targetCredentialHash: string,
  code: string,
): Promise<{ libraryId: string }> {
  if (!/^[A-Z0-9_-]{4}-[A-Z0-9_-]{4}$/.test(code))
    throw new HttpError(404, "link code not found");
  if (!/^[0-9a-f]{64}$/.test(targetCredentialHash)) {
    throw new HttpError(401, "invalid library authorization");
  }
  const now = new Date().toISOString();
  const codeHash = await sha256Hex(code);
  const row = await env.DB.prepare(
    `SELECT source_library_id, expires_at, claimed_at, claim_credential_hash
       FROM linked_library_codes WHERE code_hash = ?`,
  )
    .bind(codeHash)
    .first<{
      source_library_id: string;
      expires_at: string;
      claimed_at: string | null;
      claim_credential_hash: string | null;
    }>();
  if (!row) throw new HttpError(404, "link code not found");
  if (row.claimed_at !== null) {
    if (
      row.claim_credential_hash === targetCredentialHash ||
      row.source_library_id === targetLibraryID
    ) {
      return { libraryId: row.source_library_id };
    }
    throw new HttpError(404, "link code not found");
  }
  if (row.expires_at <= now) throw new HttpError(404, "link code not found");
  if (row.source_library_id === targetLibraryID) {
    throw new HttpError(409, "apps already use this library");
  }
  const results = await env.DB.batch([
    env.DB.prepare(
      `UPDATE linked_library_codes
          SET claimed_at = ?, claim_credential_hash = ?
        WHERE code_hash = ? AND claimed_at IS NULL AND expires_at > ?
          AND source_library_id = ? AND source_library_id <> ?
          AND EXISTS (
            SELECT 1 FROM library_credentials
             WHERE credential_hash = ? AND library_id = ? AND revoked_at IS NULL
          )
          AND (
            SELECT COUNT(DISTINCT map_entry_id) FROM library_maps
             WHERE library_id IN (?, ?)
          ) <= ?
          AND (
            SELECT COUNT(*) FROM shares WHERE owner_library_id IN (?, ?)
          ) <= ?
          AND (
            SELECT COUNT(*) FROM shares
             WHERE owner_library_id IN (?, ?) AND revoked_at IS NULL
               AND (expires_at IS NULL OR expires_at > ?)
          ) <= ?
          AND (
            SELECT COUNT(*) FROM linked_library_codes
             WHERE source_library_id IN (?, ?)
          ) <= ?
          AND (
            SELECT COUNT(*) FROM linked_library_codes
             WHERE source_library_id IN (?, ?) AND claimed_at IS NULL
               AND expires_at > ?
          ) <= ?
          AND (
            SELECT COUNT(*) FROM (
              SELECT share_id FROM share_claims
               WHERE recipient_library_id IN (?, ?)
               GROUP BY share_id
            )
          ) <= ?
          AND (
            SELECT COUNT(*) FROM library_credentials
             WHERE library_id IN (?, ?) AND revoked_at IS NULL
          ) <= ?
          AND (
            SELECT SUM(merge_principal_count) FROM libraries
             WHERE id IN (?, ?) AND revoked_at IS NULL
          ) <= ?`,
    ).bind(
      now,
      targetCredentialHash,
      codeHash,
      now,
      row.source_library_id,
      targetLibraryID,
      targetCredentialHash,
      targetLibraryID,
      row.source_library_id,
      targetLibraryID,
      MAX_LIBRARY_MAPS,
      row.source_library_id,
      targetLibraryID,
      MAX_TOTAL_SHARES,
      row.source_library_id,
      targetLibraryID,
      now,
      MAX_ACTIVE_SHARES,
      row.source_library_id,
      targetLibraryID,
      MAX_TOTAL_LINK_CODES,
      row.source_library_id,
      targetLibraryID,
      now,
      MAX_ACTIVE_LINK_CODES + 1,
      row.source_library_id,
      targetLibraryID,
      MAX_SHARE_CLAIMS,
      row.source_library_id,
      targetLibraryID,
      MAX_ACTIVE_LIBRARY_CREDENTIALS,
      row.source_library_id,
      targetLibraryID,
      MAX_LINKED_LIBRARY_PRINCIPALS,
    ),
    env.DB.prepare(
      `UPDATE libraries
          SET merge_principal_count = (
            SELECT SUM(merge_principal_count) FROM libraries
             WHERE id IN (?, ?)
          ), updated_at = ?
        WHERE id = ? AND EXISTS (
          SELECT 1 FROM linked_library_codes
           WHERE code_hash = ? AND claim_credential_hash = ?
        )`,
    ).bind(
      row.source_library_id,
      targetLibraryID,
      now,
      row.source_library_id,
      codeHash,
      targetCredentialHash,
    ),
    env.DB.prepare(
      `INSERT OR IGNORE INTO library_maps(
         library_id, map_entry_id, alias, alias_source, alias_revision,
         added_at, updated_at, source_share_id
       ) SELECT ?, map_entry_id, alias, alias_source, alias_revision,
                added_at, updated_at, source_share_id
           FROM library_maps
          WHERE library_id = ? AND EXISTS (
            SELECT 1 FROM linked_library_codes
             WHERE code_hash = ? AND claim_credential_hash = ?
          )`,
    ).bind(
      row.source_library_id,
      targetLibraryID,
      codeHash,
      targetCredentialHash,
    ),
    env.DB.prepare(
      `DELETE FROM library_maps WHERE library_id = ? AND EXISTS (
         SELECT 1 FROM linked_library_codes
          WHERE code_hash = ? AND claim_credential_hash = ?
       )`,
    ).bind(targetLibraryID, codeHash, targetCredentialHash),
    env.DB.prepare(
      `UPDATE shares SET owner_library_id = ?
        WHERE owner_library_id = ? AND EXISTS (
          SELECT 1 FROM linked_library_codes
           WHERE code_hash = ? AND claim_credential_hash = ?
        )`,
    ).bind(
      row.source_library_id,
      targetLibraryID,
      codeHash,
      targetCredentialHash,
    ),
    env.DB.prepare(
      `INSERT OR IGNORE INTO share_claims(
         share_id, recipient_library_id, claimed_at
       ) SELECT share_id, ?, claimed_at FROM share_claims
          WHERE recipient_library_id = ? AND EXISTS (
            SELECT 1 FROM linked_library_codes
             WHERE code_hash = ? AND claim_credential_hash = ?
          )`,
    ).bind(
      row.source_library_id,
      targetLibraryID,
      codeHash,
      targetCredentialHash,
    ),
    env.DB.prepare(
      `DELETE FROM share_claims WHERE recipient_library_id = ? AND EXISTS (
         SELECT 1 FROM linked_library_codes
          WHERE code_hash = ? AND claim_credential_hash = ?
       )`,
    ).bind(targetLibraryID, codeHash, targetCredentialHash),
    env.DB.prepare(
      `UPDATE shares AS s SET claim_count = (
         SELECT COUNT(*) FROM share_claims sc WHERE sc.share_id = s.id
       ) WHERE EXISTS (
         SELECT 1 FROM share_claims sc
          WHERE sc.share_id = s.id AND sc.recipient_library_id = ?
       ) AND s.claim_count <> (
         SELECT COUNT(*) FROM share_claims sc WHERE sc.share_id = s.id
       ) AND EXISTS (
         SELECT 1 FROM linked_library_codes
          WHERE code_hash = ? AND claim_credential_hash = ?
       )`,
    ).bind(row.source_library_id, codeHash, targetCredentialHash),
    env.DB.prepare(
      `UPDATE download_grants SET library_id = ?
        WHERE library_id = ? AND EXISTS (
          SELECT 1 FROM linked_library_codes
           WHERE code_hash = ? AND claim_credential_hash = ?
        )`,
    ).bind(
      row.source_library_id,
      targetLibraryID,
      codeHash,
      targetCredentialHash,
    ),
    env.DB.prepare(
      `UPDATE linked_library_codes SET source_library_id = ?
        WHERE source_library_id = ? AND code_hash <> ? AND EXISTS (
          SELECT 1 FROM linked_library_codes AS claimed_code
           WHERE claimed_code.code_hash = ?
             AND claimed_code.claim_credential_hash = ?
        )`,
    ).bind(
      row.source_library_id,
      targetLibraryID,
      codeHash,
      codeHash,
      targetCredentialHash,
    ),
    env.DB.prepare(
      `UPDATE library_credentials SET library_id = ?
        WHERE library_id = ? AND revoked_at IS NULL
          AND EXISTS (
            SELECT 1 FROM linked_library_codes
             WHERE code_hash = ? AND claim_credential_hash = ?
          )`,
    ).bind(
      row.source_library_id,
      targetLibraryID,
      codeHash,
      targetCredentialHash,
    ),
    env.DB.prepare(
      `UPDATE libraries SET revoked_at = ?, updated_at = ?
        WHERE id = ?
          AND EXISTS (
            SELECT 1 FROM linked_library_codes
             WHERE code_hash = ? AND claim_credential_hash = ?
          )
          AND NOT EXISTS (
            SELECT 1 FROM library_maps WHERE library_id = ?
          )
          AND NOT EXISTS (
            SELECT 1 FROM shares WHERE owner_library_id = ?
          )
          AND NOT EXISTS (
            SELECT 1 FROM share_claims WHERE recipient_library_id = ?
          )
          AND NOT EXISTS (
            SELECT 1 FROM download_grants WHERE library_id = ?
          )
          AND NOT EXISTS (
            SELECT 1 FROM library_credentials
             WHERE library_id = ? AND revoked_at IS NULL
          )`,
    ).bind(
      now,
      now,
      targetLibraryID,
      codeHash,
      targetCredentialHash,
      targetLibraryID,
      targetLibraryID,
      targetLibraryID,
      targetLibraryID,
      targetLibraryID,
    ),
  ]);
  if (results[0]?.meta.changes !== 1) {
    const current = await env.DB.prepare(
      `SELECT source_library_id, claimed_at, claim_credential_hash
         FROM linked_library_codes WHERE code_hash = ?`,
    )
      .bind(codeHash)
      .first<{
        source_library_id: string;
        claimed_at: string | null;
        claim_credential_hash: string | null;
      }>();
    if (
      current?.claimed_at &&
      (current.claim_credential_hash === targetCredentialHash ||
        current.source_library_id === targetLibraryID)
    ) {
      return { libraryId: current.source_library_id };
    }
    if (
      current?.claimed_at === null &&
      current.source_library_id === row.source_library_id
    ) {
      const quota = await env.DB.prepare(
        `SELECT
           (SELECT COUNT(DISTINCT map_entry_id) FROM library_maps
             WHERE library_id IN (?, ?)) AS map_count,
           (SELECT COUNT(*) FROM shares
             WHERE owner_library_id IN (?, ?)) AS total_share_count,
           (SELECT COUNT(*) FROM shares
             WHERE owner_library_id IN (?, ?) AND revoked_at IS NULL
               AND (expires_at IS NULL OR expires_at > ?)) AS active_share_count,
           (SELECT COUNT(*) FROM linked_library_codes
             WHERE source_library_id IN (?, ?)) AS total_link_code_count,
           (SELECT COUNT(*) FROM linked_library_codes
             WHERE source_library_id IN (?, ?) AND claimed_at IS NULL
               AND expires_at > ?) AS active_link_code_count,
           (SELECT COUNT(*) FROM (
             SELECT share_id FROM share_claims
              WHERE recipient_library_id IN (?, ?)
              GROUP BY share_id
           )) AS share_claim_count,
           (SELECT COUNT(*) FROM library_credentials
             WHERE library_id IN (?, ?) AND revoked_at IS NULL
           ) AS active_credential_count,
           (SELECT SUM(merge_principal_count) FROM libraries
             WHERE id IN (?, ?) AND revoked_at IS NULL
           ) AS merge_principal_count`,
      )
        .bind(
          row.source_library_id,
          targetLibraryID,
          row.source_library_id,
          targetLibraryID,
          row.source_library_id,
          targetLibraryID,
          now,
          row.source_library_id,
          targetLibraryID,
          row.source_library_id,
          targetLibraryID,
          now,
          row.source_library_id,
          targetLibraryID,
          row.source_library_id,
          targetLibraryID,
          row.source_library_id,
          targetLibraryID,
        )
        .first<{
          map_count: number;
          total_share_count: number;
          active_share_count: number;
          total_link_code_count: number;
          active_link_code_count: number;
          share_claim_count: number;
          active_credential_count: number;
          merge_principal_count: number;
        }>();
      if (
        quota &&
        (quota.map_count > MAX_LIBRARY_MAPS ||
          quota.total_share_count > MAX_TOTAL_SHARES ||
          quota.active_share_count > MAX_ACTIVE_SHARES ||
          quota.total_link_code_count > MAX_TOTAL_LINK_CODES ||
          quota.active_link_code_count > MAX_ACTIVE_LINK_CODES + 1 ||
          quota.share_claim_count > MAX_SHARE_CLAIMS ||
          quota.active_credential_count > MAX_ACTIVE_LIBRARY_CREDENTIALS ||
          quota.merge_principal_count > MAX_LINKED_LIBRARY_PRINCIPALS)
      ) {
        throw new HttpError(409, "merged library quota exceeded");
      }
    }
    throw new HttpError(404, "link code not found");
  }
  return { libraryId: row.source_library_id };
}
