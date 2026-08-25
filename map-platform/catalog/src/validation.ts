import { HttpError, normalizeAlias, requireExactKeys } from "./security";
import type { Channel } from "./types";

const ID = /^[A-Za-z0-9._:-]{1,128}$/;
const MAP_ENTRY_ID = /^map_v1_[A-Za-z0-9_-]{43}$/;
const ARTIFACT_ID = /^artifact_v1_[A-Za-z0-9_-]{43}$/;
const SHA256 = /^[0-9a-f]{64}$/;
const OBJECT_KEY =
  /^(?!\/)(?!.*(?:^|\/)\.\.(?:\/|$))[A-Za-z0-9!_.*'()\/-]{1,1024}$/;
const FORMAT = /^[a-z0-9._-]{1,64}$/;
const MEDIA_TYPE = /^[A-Za-z0-9.+-]+\/[A-Za-z0-9.+-]+$/;
const FILENAME = /^[A-Za-z0-9._-]{1,128}$/;
const SIGNING_ID = /^[A-Za-z0-9._-]{1,64}$/;
const OCI_DIGEST = /^sha256:[0-9a-f]{64}$/;

export interface PublicationArtifactInput {
  artifactId: string;
  bucketSlot: Channel;
  objectKey: string;
  format: string;
  mediaType: string;
  filename: string;
  bytes: number;
  sha256: string;
  manifestReceipt?: string | null;
  signedManifestReceipt?: string | null;
  signatureKeyId?: string | null;
  signatureKeySha256?: string | null;
  producerBuildSha256?: string | null;
  producerImageDigest?: string | null;
  requiredIosBuild?: string | null;
  requiredIosGitSha?: string | null;
  requiredIosBuildSha256?: string | null;
  requiredFirmwareVersion?: string | null;
  requiredFirmwareBuild?: number | null;
  requiredFirmwareGitSha?: string | null;
  deliveryTier: Channel;
}

export interface PublicationInput {
  publicationId: string;
  mapEntryId: string;
  legacyMapId: string;
  contentReceipt: string;
  originChannel: Channel;
  canonicalName: string;
  sourceRegionName?: string | null;
  bounds?: [number, number, number, number] | null;
  renderer: string;
  rendererFormatVersion: number;
  features: string[];
  attribution: Record<string, unknown>;
  generatedAt?: string | null;
  deliveryState: "development" | "production";
  artifacts: PublicationArtifactInput[];
}

function stringField(value: unknown, pattern: RegExp, field: string): string {
  if (typeof value !== "string" || !pattern.test(value)) {
    throw new HttpError(400, `${field} is invalid`);
  }
  return value;
}

function nullableString(
  value: unknown,
  pattern: RegExp,
  field: string,
): string | null {
  if (value === null || value === undefined) return null;
  return stringField(value, pattern, field);
}

function channel(value: unknown, field: string): Channel {
  if (value !== "development" && value !== "production") {
    throw new HttpError(400, `${field} is invalid`);
  }
  return value;
}

export function validatePublication(
  value: Record<string, unknown>,
): PublicationInput {
  requireExactKeys(
    value,
    [
      "publicationId",
      "mapEntryId",
      "legacyMapId",
      "contentReceipt",
      "originChannel",
      "canonicalName",
      "renderer",
      "rendererFormatVersion",
      "features",
      "attribution",
      "deliveryState",
      "artifacts",
    ],
    ["sourceRegionName", "bounds", "generatedAt"],
  );
  const canonicalName = normalizeAlias(value.canonicalName);
  const originChannel = channel(value.originChannel, "originChannel");
  const deliveryState = channel(value.deliveryState, "deliveryState");
  if (originChannel === "development" && deliveryState === "production") {
    // Production promotion retains development provenance and is accepted.
  } else if (originChannel !== deliveryState) {
    throw new HttpError(400, "deliveryState is invalid for originChannel");
  }
  if (
    !Number.isSafeInteger(value.rendererFormatVersion) ||
    Number(value.rendererFormatVersion) < 1 ||
    Number(value.rendererFormatVersion) > 255
  ) {
    throw new HttpError(400, "rendererFormatVersion is invalid");
  }
  if (
    !Array.isArray(value.features) ||
    value.features.length > 32 ||
    value.features.some(
      (item) => typeof item !== "string" || !FORMAT.test(item),
    ) ||
    value.features.join("\u0000") !==
      [...value.features].sort().join("\u0000") ||
    new Set(value.features).size !== value.features.length
  ) {
    throw new HttpError(400, "features are invalid");
  }
  if (
    value.attribution === null ||
    Array.isArray(value.attribution) ||
    typeof value.attribution !== "object" ||
    JSON.stringify(value.attribution).length > 16_384
  ) {
    throw new HttpError(400, "attribution is invalid");
  }
  let bounds: [number, number, number, number] | null = null;
  if (value.bounds !== undefined && value.bounds !== null) {
    if (
      !Array.isArray(value.bounds) ||
      value.bounds.length !== 4 ||
      value.bounds.some(
        (item) => typeof item !== "number" || !Number.isFinite(item),
      )
    ) {
      throw new HttpError(400, "bounds are invalid");
    }
    bounds = value.bounds as [number, number, number, number];
  }
  if (
    !Array.isArray(value.artifacts) ||
    value.artifacts.length < 1 ||
    value.artifacts.length > 4
  ) {
    throw new HttpError(400, "artifacts are invalid");
  }
  const artifacts = value.artifacts.map((raw): PublicationArtifactInput => {
    if (raw === null || Array.isArray(raw) || typeof raw !== "object") {
      throw new HttpError(400, "artifact is invalid");
    }
    const artifact = raw as Record<string, unknown>;
    requireExactKeys(
      artifact,
      [
        "artifactId",
        "bucketSlot",
        "objectKey",
        "format",
        "mediaType",
        "filename",
        "bytes",
        "sha256",
        "deliveryTier",
      ],
      [
        "manifestReceipt",
        "signedManifestReceipt",
        "signatureKeyId",
        "signatureKeySha256",
        "producerBuildSha256",
        "producerImageDigest",
        "requiredIosBuild",
        "requiredIosGitSha",
        "requiredIosBuildSha256",
        "requiredFirmwareVersion",
        "requiredFirmwareBuild",
        "requiredFirmwareGitSha",
      ],
    );
    if (!Number.isSafeInteger(artifact.bytes) || Number(artifact.bytes) <= 0) {
      throw new HttpError(400, "artifact bytes are invalid");
    }
    const bucketSlot = channel(artifact.bucketSlot, "artifact bucketSlot");
    const deliveryTier = channel(
      artifact.deliveryTier,
      "artifact deliveryTier",
    );
    if (bucketSlot !== deliveryTier || deliveryTier !== deliveryState) {
      throw new HttpError(400, "artifact delivery tier is invalid");
    }
    return {
      artifactId: stringField(artifact.artifactId, ARTIFACT_ID, "artifactId"),
      bucketSlot,
      objectKey: stringField(artifact.objectKey, OBJECT_KEY, "objectKey"),
      format: stringField(artifact.format, FORMAT, "format"),
      mediaType: stringField(artifact.mediaType, MEDIA_TYPE, "mediaType"),
      filename: stringField(artifact.filename, FILENAME, "filename"),
      bytes: Number(artifact.bytes),
      sha256: stringField(artifact.sha256, SHA256, "sha256"),
      manifestReceipt: nullableString(
        artifact.manifestReceipt,
        SHA256,
        "manifestReceipt",
      ),
      signedManifestReceipt: nullableString(
        artifact.signedManifestReceipt,
        SHA256,
        "signedManifestReceipt",
      ),
      signatureKeyId: nullableString(
        artifact.signatureKeyId,
        SIGNING_ID,
        "signatureKeyId",
      ),
      signatureKeySha256: nullableString(
        artifact.signatureKeySha256,
        SHA256,
        "signatureKeySha256",
      ),
      producerBuildSha256: nullableString(
        artifact.producerBuildSha256,
        SHA256,
        "producerBuildSha256",
      ),
      producerImageDigest: nullableString(
        artifact.producerImageDigest,
        OCI_DIGEST,
        "producerImageDigest",
      ),
      requiredIosBuild: nullableString(
        artifact.requiredIosBuild,
        /^[0-9]{1,18}(?:\.[0-9]{1,18}){0,2}$/,
        "requiredIosBuild",
      ),
      requiredIosGitSha: nullableString(
        artifact.requiredIosGitSha,
        /^[0-9a-f]{40}$/,
        "requiredIosGitSha",
      ),
      requiredIosBuildSha256: nullableString(
        artifact.requiredIosBuildSha256,
        SHA256,
        "requiredIosBuildSha256",
      ),
      requiredFirmwareVersion: nullableString(
        artifact.requiredFirmwareVersion,
        /^[A-Za-z0-9._+-]{1,64}$/,
        "requiredFirmwareVersion",
      ),
      requiredFirmwareBuild:
        artifact.requiredFirmwareBuild === null ||
        artifact.requiredFirmwareBuild === undefined
          ? null
          : Number(artifact.requiredFirmwareBuild),
      requiredFirmwareGitSha: nullableString(
        artifact.requiredFirmwareGitSha,
        /^[0-9a-f]{40}$/,
        "requiredFirmwareGitSha",
      ),
      deliveryTier,
    };
  });
  for (const artifact of artifacts) {
    const iosIdentity = [
      artifact.requiredIosBuild,
      artifact.requiredIosGitSha,
      artifact.requiredIosBuildSha256,
    ];
    const firmwareIdentity = [
      artifact.requiredFirmwareVersion,
      artifact.requiredFirmwareBuild,
      artifact.requiredFirmwareGitSha,
    ];
    if (iosIdentity.some(Boolean) && !iosIdentity.every(Boolean)) {
      throw new HttpError(400, "artifact required iOS identity is incomplete");
    }
    if (
      firmwareIdentity.some((value) => value !== null) &&
      !firmwareIdentity.every((value) => value !== null)
    ) {
      throw new HttpError(
        400,
        "artifact required firmware identity is incomplete",
      );
    }
    if (
      artifact.requiredFirmwareBuild != null &&
      (!Number.isSafeInteger(artifact.requiredFirmwareBuild) ||
        artifact.requiredFirmwareBuild <= 0)
    ) {
      throw new HttpError(400, "requiredFirmwareBuild is invalid");
    }
  }
  if (
    new Set(artifacts.map((artifact) => artifact.artifactId)).size !==
    artifacts.length
  ) {
    throw new HttpError(400, "artifact IDs are duplicated");
  }
  return {
    publicationId: stringField(value.publicationId, ID, "publicationId"),
    mapEntryId: stringField(value.mapEntryId, MAP_ENTRY_ID, "mapEntryId"),
    legacyMapId: stringField(value.legacyMapId, ID, "legacyMapId"),
    contentReceipt: stringField(value.contentReceipt, SHA256, "contentReceipt"),
    originChannel,
    canonicalName,
    sourceRegionName:
      value.sourceRegionName === null || value.sourceRegionName === undefined
        ? null
        : normalizeAlias(value.sourceRegionName),
    bounds,
    renderer: stringField(value.renderer, FORMAT, "renderer"),
    rendererFormatVersion: Number(value.rendererFormatVersion),
    features: value.features as string[],
    attribution: value.attribution as Record<string, unknown>,
    generatedAt:
      value.generatedAt === null || value.generatedAt === undefined
        ? null
        : stringField(
            value.generatedAt,
            /^\d{4}-\d{2}-\d{2}T.+Z$/,
            "generatedAt",
          ),
    deliveryState,
    artifacts,
  };
}
