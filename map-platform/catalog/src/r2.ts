import { GetObjectCommand, S3Client } from "@aws-sdk/client-s3";
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
    credentials,
  });
}

export async function presignedDownloadURL(
  artifact: ArtifactRow,
  env: Env,
): Promise<string> {
  if (!SAFE_OBJECT_KEY.test(artifact.object_key)) {
    throw new HttpError(500, "catalog artifact key is invalid");
  }
  const prefix = env.R2_OBJECT_PREFIX.replace(/^\/+|\/+$/g, "");
  const key = prefix ? `${prefix}/${artifact.object_key}` : artifact.object_key;
  const bucket =
    artifact.bucket_slot === "development"
      ? env.R2_DEVELOPMENT_BUCKET
      : env.R2_PRODUCTION_BUCKET;
  const command = new GetObjectCommand({
    Bucket: bucket,
    Key: key,
    ResponseContentType: artifact.media_type,
    ResponseContentDisposition: `attachment; filename*=UTF-8''${encodeURIComponent(artifact.filename)}`,
  });
  return getSignedUrl(client(artifact.bucket_slot, env), command, {
    expiresIn: 15 * 60,
  });
}
