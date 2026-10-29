import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

// Frozen producer output for durable map contract v1. Readers and the catalog
// must keep accepting these exact publications; never regenerate them.
import corpus from "../../backend/tests/fixtures/map-compatibility-v1/corpus.json";
import {
  attachLibrary,
  bootstrapLibrary,
  createLibraryDownloadGrant,
  finalizePublication,
} from "../src/catalog";
import { HttpError, sha256Hex } from "../src/security";
import { validatePublication } from "../src/validation";

const appIdentity = {
  build: "31",
  gitSha: "f".repeat(40),
  buildSha256: "9".repeat(64),
};
// OfflineMapReaderCapabilities.current, shared by Bicino and Bicino Dev.
const appReader = {
  schemaVersion: 1,
  streamFormats: [
    { format: "bike-map-stream-v1", manifestSchemaVersions: [1] },
  ],
  renderers: [
    {
      renderer: "esp32-fmb",
      formatVersions: [1, 2, 3, 4, 5],
      features: ["3d-buildings", "contours", "map-pois", "street-labels"],
    },
  ],
};

type CorpusPublication = Record<string, unknown> & {
  mapEntryId: string;
  publicationId: string;
  artifacts: Array<Record<string, unknown>>;
};

function signer(keyId: string) {
  const value = corpus.signers.find((item) => item.keyId === keyId)!;
  return { keyId: value.keyId, keySha256: value.publicKeySha256 };
}

const productionSigners = corpus.signers
  .filter((item) => item.channel === "production")
  .map((item) => signer(item.keyId));
const developmentAppSigners = corpus.signers.map((item) => signer(item.keyId));

function corpusMap(id: string) {
  return corpus.maps.find((item) => item.id === id)!;
}

async function publish(publication: CorpusPublication): Promise<void> {
  const validated = validatePublication(publication);
  await finalizePublication(
    env,
    validated,
    validated.publicationId,
    await sha256Hex(JSON.stringify(validated)),
    null,
    async () => true,
  );
}

async function libraryWith(id: string): Promise<string> {
  const entry = corpusMap(id);
  await publish(entry.development.publication as CorpusPublication);
  for (const production of entry.production) {
    await publish(production.publication as CorpusPublication);
  }
  const library = await bootstrapLibrary(env);
  await attachLibrary(
    env,
    entry.development.publication.publicationId,
    library.libraryId,
    undefined,
    "development",
  );
  return library.libraryId;
}

function stream(publication: { artifacts: Array<Record<string, unknown>> }) {
  return publication.artifacts.find(
    (artifact) => artifact.format === "bike-map-stream-v1",
  )!;
}

describe("durable map contract v1", () => {
  it("accepts every frozen publication without a firmware gate", () => {
    for (const entry of corpus.maps) {
      for (const variant of [entry.development, ...entry.production]) {
        const validated = validatePublication(
          variant.publication as CorpusPublication,
        );
        const artifact = validated.artifacts.find(
          (item) => item.format === "bike-map-stream-v1",
        )!;
        expect(artifact.readerRequirements?.requiredFeatures).toEqual(
          entry.features,
        );
        expect(artifact.requiredFirmwareVersion ?? null).toBeNull();
        expect(artifact.requiredFirmwareBuild ?? null).toBeNull();
        expect(artifact.requiredFirmwareGitSha ?? null).toBeNull();
      }
    }
  });

  it("gives Bicino the production map across key rotation and worker updates", async () => {
    const entry = corpusMap("buildings-3d-v1");
    const libraryID = await libraryWith("buildings-3d-v1");
    const production = Object.fromEntries(
      entry.production.map((item) => [item.variant, stream(item.publication)]),
    );
    const any = await createLibraryDownloadGrant(
      env,
      libraryID,
      entry.mapEntryId,
      "production",
      productionSigners,
      appIdentity,
      appReader,
    );
    expect(any.artifact.deliveryTier).toBe("production");
    // A worker update supersedes the same signer's generation; a rotated
    // signer keeps its own generation for apps that only trust that key.
    const original = await createLibraryDownloadGrant(
      env,
      libraryID,
      entry.mapEntryId,
      "production",
      [signer("map-compat-fixture-prod-1")],
      appIdentity,
      appReader,
    );
    expect(original.artifact.sha256).toBe(
      production["production-updated-worker"].sha256,
    );
    const rotated = await createLibraryDownloadGrant(
      env,
      libraryID,
      entry.mapEntryId,
      "production",
      [signer("map-compat-fixture-prod-2")],
      appIdentity,
      appReader,
    );
    expect(rotated.artifact.sha256).toBe(
      production["production-rotated-key"].sha256,
    );
    await expect(
      createLibraryDownloadGrant(
        env,
        libraryID,
        entry.mapEntryId,
        "production",
        [signer("map-compat-fixture-dev-1")],
        appIdentity,
        appReader,
      ),
    ).rejects.toThrow(HttpError);
  });

  it("gives Bicino Dev development artifacts first, then production", async () => {
    const entry = corpusMap("topographic-contours-v1");
    const libraryID = await libraryWith("topographic-contours-v1");
    const development = await createLibraryDownloadGrant(
      env,
      libraryID,
      entry.mapEntryId,
      "development",
      developmentAppSigners,
      appIdentity,
      appReader,
    );
    expect(development.artifact.deliveryTier).toBe("development");
    expect(development.artifact.sha256).toBe(
      stream(entry.development.publication).sha256,
    );
    expect(development.companion?.artifact.deliveryTier).toBe("development");
    const fallback = await createLibraryDownloadGrant(
      env,
      libraryID,
      entry.mapEntryId,
      "development",
      productionSigners,
      appIdentity,
      appReader,
    );
    expect(fallback.artifact.deliveryTier).toBe("production");
    expect(fallback.companion?.artifact.objectKey).toContain(
      "/topography-ios-v1/production/",
    );
    expect(fallback.companion?.artifact.sha256).toBe(
      development.companion?.artifact.sha256,
    );
  });

  it("serves the optional terrain layer as the same contour profile", async () => {
    const entry = corpusMap("topographic-contours-v1-terrain");
    expect(entry.profile).toBe("topographic-contours-v1");
    const libraryID = await libraryWith(entry.id);
    for (const [channel, signers, tier] of [
      ["production", productionSigners, "production"],
      ["development", developmentAppSigners, "development"],
    ] as const) {
      const grant = await createLibraryDownloadGrant(
        env,
        libraryID,
        entry.mapEntryId,
        channel,
        signers,
        appIdentity,
        appReader,
      );
      expect(grant.artifact.deliveryTier).toBe(tier);
      expect(grant.artifact.readerRequirements?.requiredFeatures).toEqual(
        entry.features,
      );
      expect(grant.companion?.artifact.deliveryTier).toBe(tier);
    }
  });

  it("keeps development-only POI maps away from Bicino", async () => {
    for (const id of ["map-pois-v1", "map-pois-contours-v1"]) {
      const entry = corpusMap(id);
      const libraryID = await libraryWith(id);
      await expect(
        createLibraryDownloadGrant(
          env,
          libraryID,
          entry.mapEntryId,
          "production",
          productionSigners,
          appIdentity,
          appReader,
        ),
      ).rejects.toThrow("production promotion required");
      const grant = await createLibraryDownloadGrant(
        env,
        libraryID,
        entry.mapEntryId,
        "development",
        developmentAppSigners,
        appIdentity,
        appReader,
      );
      expect(grant.artifact.readerRequirements?.requiredFeatures).toEqual(
        entry.features,
      );
      expect(grant.companion !== null).toBe(entry.companionFile !== null);
    }
  });

  it("does not grant a durable map to a reader without its features", async () => {
    const entry = corpusMap("map-pois-contours-v1");
    const libraryID = await libraryWith("map-pois-contours-v1");
    await expect(
      createLibraryDownloadGrant(
        env,
        libraryID,
        entry.mapEntryId,
        "development",
        developmentAppSigners,
        appIdentity,
        {
          ...appReader,
          renderers: [
            {
              renderer: "esp32-fmb",
              formatVersions: [1, 2, 3, 4],
              features: ["3d-buildings", "contours", "street-labels"],
            },
          ],
        },
      ),
    ).rejects.toThrow("no compatible artifact is available");
  });
});
