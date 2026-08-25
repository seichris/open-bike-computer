import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

import { presignedDownloadURL } from "../src/r2";
import type { ArtifactRow } from "../src/types";

describe("R2 downloads", () => {
  it("uses the exact account host accepted by the app", async () => {
    const accountID = "a".repeat(32);
    const artifact: ArtifactRow = {
      id: `artifact_v1_${"r".repeat(43)}`,
      map_entry_id: `map_v1_${"m".repeat(43)}`,
      bucket_slot: "production",
      object_key: "maps/test-map/bike-map-stream-v1/test.bmap",
      format: "bike-map-stream-v1",
      media_type: "application/vnd.openbikecomputer.map-stream",
      filename: "test-map.bmap",
      byte_count: 12345,
      sha256: "b".repeat(64),
      manifest_receipt: null,
      signed_manifest_receipt: null,
      signature_key_id: null,
      signature_key_sha256: null,
      producer_build_sha256: null,
      producer_image_digest: null,
      required_ios_build: null,
      required_ios_git_sha: null,
      required_ios_build_sha256: null,
      required_firmware_version: null,
      required_firmware_build: null,
      required_firmware_git_sha: null,
      delivery_tier: "production",
      state: "live",
      created_at: "2026-08-25T00:00:00Z",
      verified_at: "2026-08-25T00:00:00Z",
    };

    const signed = new URL(
      await presignedDownloadURL(artifact, {
        ...env,
        R2_ACCOUNT_ID: accountID,
        R2_PRODUCTION_BUCKET: "bicino-final-maps-prod-staging",
      }),
    );

    expect(signed.protocol).toBe("https:");
    expect(signed.hostname).toBe(`${accountID}.r2.cloudflarestorage.com`);
    expect(signed.pathname).toBe(
      "/bicino-final-maps-prod-staging/map-artifacts/maps/test-map/bike-map-stream-v1/test.bmap",
    );
  });
});
