import {
  GetObjectCommand,
  HeadObjectCommand,
  S3Client,
} from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";

import { HttpError } from "./security";
import type { ArtifactRow, BucketSlot, Env } from "./types";

const SAFE_OBJECT_KEY =
  /^(?!\/)(?!.*(?:^|\/)\.\.(?:\/|$))[A-Za-z0-9!_.*'()\/-]{1,1024}$/;

function client(slot: BucketSlot, env: Env): S3Client {
  const credentials =
    slot === "development"
      ? {
          accessKeyId: env.R2_DEVELOPMENT_ACCESS_KEY_ID,
          secretAccessKey: env.R2_DEVELOPMENT_SECRET_ACCESS_KEY,
        }
      : {
          accessKeyId: env.R2_PRODUCTION_ACCESS_KEY_ID,
          secretAccessKey: env.R2_PRODUCTION_SECRET_ACCESS_KEY,
        };
  if (
    !/^[0-9a-f]{32}$/i.test(env.R2_ACCOUNT_ID) ||
    credentials.accessKeyId.length < 16 ||
    credentials.secretAccessKey.length < 32
  ) {
    throw new HttpError(503, "R2 download signing is unavailable");
  }
  return new S3Client({
    region: "auto",
    endpoint: `https://${env.R2_ACCOUNT_ID}.r2.cloudflarestorage.com`,
    forcePathStyle: true,
    credentials,
  });
}

function objectLocation(
  artifact: ArtifactRow,
  env: Env,
): {
  bucket: string;
  key: string;
} {
  if (!SAFE_OBJECT_KEY.test(artifact.object_key)) {
    throw new HttpError(500, "catalog artifact key is invalid");
  }
  const prefix = env.R2_OBJECT_PREFIX.replace(/^\/+|\/+$/g, "");
  return {
    key: prefix ? `${prefix}/${artifact.object_key}` : artifact.object_key,
    bucket:
      artifact.bucket_slot === "development"
        ? env.R2_DEVELOPMENT_BUCKET
        : env.R2_PRODUCTION_BUCKET,
  };
}

export async function verifyArtifactObject(
  artifact: ArtifactRow,
  env: Env,
): Promise<boolean> {
  const location = objectLocation(artifact, env);
  try {
    const result = await client(artifact.bucket_slot, env).send(
      new HeadObjectCommand({ Bucket: location.bucket, Key: location.key }),
    );
    const metadata = Object.fromEntries(
      Object.entries(result.Metadata ?? {}).map(([key, value]) => [
        key.toLowerCase(),
        value,
      ]),
    );
    return (
      result.ContentLength === artifact.byte_count &&
      metadata.sha256 === artifact.sha256
    );
  } catch (error) {
    const status = (error as { $metadata?: { httpStatusCode?: number } })
      .$metadata?.httpStatusCode;
    const name = (error as { name?: string }).name;
    if (status === 404 || name === "NotFound" || name === "NoSuchKey") {
      return false;
    }
    if (error instanceof HttpError) throw error;
    throw new HttpError(503, "R2 artifact verification is unavailable");
  }
}

export async function presignedDownloadURL(
  artifact: ArtifactRow,
  env: Env,
): Promise<string> {
  const location = objectLocation(artifact, env);
  const command = new GetObjectCommand({
    Bucket: location.bucket,
    Key: location.key,
    ResponseContentType: artifact.media_type,
    ResponseContentDisposition: `attachment; filename*=UTF-8''${encodeURIComponent(artifact.filename)}`,
  });
  return getSignedUrl(client(artifact.bucket_slot, env), command, {
    expiresIn: 15 * 60,
  });
}
