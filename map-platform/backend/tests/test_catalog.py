from __future__ import annotations

import json
import os
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import Mock, patch

from map_platform.artifacts import ArtifactRecord
from map_platform.catalog import (
    CatalogClient,
    CatalogPublicationError,
    artifact_id,
    catalog_delivery_requirements,
    delete_catalog_retention_artifacts,
    map_entry_id,
    publication_payload,
    publish_ready_job,
)
from map_platform.jobs import JobStore
from map_platform.models import (
    Bounds,
    GeometryMode,
    JobStatus,
    MapJob,
    NormalizedGeometry,
    SourceRegion,
)


def ready_job() -> MapJob:
    receipt = "4" * 64
    signer = "5" * 64
    producer = "6" * 64
    image = "7" * 64
    return MapJob(
        job_id="job-catalog-test",
        status=JobStatus.READY,
        request={
            "displayName": "Generated Shanghai Map",
            "target": {
                "renderer": "esp32-fmb",
                "rendererFormatVersion": 3,
            },
        },
        geometry=NormalizedGeometry(
            mode=GeometryMode.CUSTOM_BBOX,
            bounds=Bounds(120.0, 30.0, 121.0, 31.0),
            area_km2=100.0,
            vertex_count=4,
        ),
        source_region=SourceRegion(
            id="china",
            provider="geofabrik",
            name="China",
            url="https://download.invalid/china.osm.pbf",
            bounds=Bounds(70, 10, 140, 55),
        ),
        client_installation_id="installation-test",
        map_id="shanghai-test",
        pack_path="/tmp/shanghai-test.zip",
        pack_bytes=100,
        finished_at="2026-08-25T00:00:00Z",
        artifacts=[
            ArtifactRecord(
                format="zip-stored-v1",
                media_type="application/zip",
                filename="shanghai-test.zip",
                object_key=f"maps/shanghai-test/zip-stored-v1/{'1' * 64}.zip",
                bytes=100,
                sha256="1" * 64,
                manifest_receipt=receipt,
            ),
            ArtifactRecord(
                format="bike-map-stream-v1",
                media_type="application/vnd.openbikecomputer.map-stream",
                filename="shanghai-test.bmap",
                object_key=(
                    f"maps/shanghai-test/bike-map-stream-v1/prod/{signer}/"
                    f"{producer}/{image}/{receipt}.bmap"
                ),
                bytes=120,
                sha256="2" * 64,
                manifest_receipt=receipt,
                signed_manifest_receipt=receipt,
                signature_key_id="prod",
                signature_key_sha256=signer,
                producer_build_sha256=producer,
                producer_image_digest=f"sha256:{image}",
            ),
        ],
    )


class SuccessfulCatalog:
    channel = "production"

    def finalize(self, job):
        payload = publication_payload(job, self.channel)
        return {
            "publicationId": payload["publicationId"],
            "mapEntryId": payload["mapEntryId"],
            "state": "finalized",
        }


class FailingCatalog:
    channel = "production"

    def finalize(self, job):
        del job
        raise RuntimeError("catalog unavailable with secret value hidden")


class VerifyingArtifactStore:
    catalog_delivery_backed = True

    def __init__(self, *, valid=True):
        self.valid = valid
        self.verified = []

    def verify(self, object_key, *, sha256, expected_bytes):
        self.verified.append((object_key, sha256, expected_bytes))
        return self.valid


class RetentionArtifactStore:
    catalog_delivery_backed = True

    def __init__(self, object_keys):
        self.object_keys = set(object_keys)
        self.deleted = []

    def delete(self, object_key):
        self.deleted.append(object_key)
        return self.object_keys.discard(object_key) is None

    def absent(self, object_key):
        return object_key not in self.object_keys


class RetentionCatalog:
    channel = "production"

    def __init__(self, authorizations):
        self.authorizations = authorizations
        self.claimed = []
        self.confirmed = []

    def retention_authorizations(self, *, maximum_artifacts):
        return self.authorizations[:maximum_artifacts]

    def claim_retention_deletion(self, authorization):
        self.claimed.append(authorization["artifactId"])
        return {
            **authorization,
            "leaseId": "retention_lease_v1_" + "a" * 32,
        }

    def confirm_retention_deletion(self, authorization):
        self.confirmed.append(authorization["artifactId"])
        return {"artifactId": authorization["artifactId"], "state": "deleted"}


class CatalogTests(unittest.TestCase):
    def test_catalog_identity_is_exact_and_independent_of_user_label(self):
        job = ready_job()
        first = map_entry_id(job)
        job.user_label = "My Better Map Name"
        self.assertEqual(map_entry_id(job), first)
        payload = publication_payload(job, "production")
        self.assertEqual(payload["canonicalName"], "Generated Shanghai Map")
        self.assertEqual(payload["features"], ["3d-buildings", "street-labels"])
        self.assertEqual(payload["mapEntryId"], first)
        self.assertEqual(
            [value["format"] for value in payload["artifacts"]],
            ["bike-map-stream-v1", "zip-stored-v1"],
        )
        self.assertEqual(
            payload["artifacts"][0]["readerRequirements"],
            {
                "schemaVersion": 1,
                "streamFormat": "bike-map-stream-v1",
                "manifestSchemaVersion": 1,
                "renderer": "esp32-fmb",
                "rendererFormatVersion": 3,
                "requiredFeatures": ["3d-buildings", "street-labels"],
            },
        )
        self.assertEqual(
            artifact_id(job.artifacts[0]),
            "artifact_v1_" + "ERERERERERERERERERERERERERERERERERERERERERE",
        )

    def test_catalog_identity_prefers_unsigned_zip_manifest_receipt(self):
        job = ready_job()
        job.artifacts[0] = replace(
            job.artifacts[0],
            manifest_receipt="8" * 64,
        )
        first = map_entry_id(job)
        job.artifacts[1] = replace(
            job.artifacts[1],
            manifest_receipt="9" * 64,
        )
        self.assertEqual(map_entry_id(job), first)

    def test_ready_publication_is_persisted_without_changing_artifacts(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(Path(tmp) / "jobs")
            original = ready_job()
            store.save(original)
            artifact_store = VerifyingArtifactStore()
            published = publish_ready_job(
                store,
                SuccessfulCatalog(),
                original.job_id,
                artifact_store=artifact_store,
            )
            self.assertEqual(published.status, JobStatus.READY)
            self.assertEqual(published.catalog_publication_state, "finalized")
            self.assertEqual(published.catalog_map_entry_id, map_entry_id(original))
            self.assertEqual(published.artifacts, original.artifacts)
            self.assertEqual(len(artifact_store.verified), len(original.artifacts))

            round_trip = MapJob.from_dict(
                json.loads(json.dumps(published.to_dict(include_internal=True)))
            )
            self.assertEqual(round_trip.catalog_publication_state, "finalized")
            self.assertEqual(round_trip.catalog_map_entry_id, published.catalog_map_entry_id)

    def test_catalog_failure_never_demotes_ready_map(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(Path(tmp) / "jobs")
            store.save(ready_job())
            result = publish_ready_job(
                store,
                FailingCatalog(),
                "job-catalog-test",
                artifact_store=VerifyingArtifactStore(),
            )
            self.assertEqual(result.status, JobStatus.READY)
            self.assertEqual(result.catalog_publication_state, "failed")
            self.assertEqual(result.catalog_publication_attempts, 1)
            self.assertNotIn("secret value", result.catalog_publication_error)

    def test_catalog_never_finalizes_without_every_shared_artifact(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(Path(tmp) / "jobs")
            store.save(ready_job())
            catalog = SuccessfulCatalog()
            catalog.finalize = Mock(wraps=catalog.finalize)
            result = publish_ready_job(
                store,
                catalog,
                "job-catalog-test",
                artifact_store=VerifyingArtifactStore(valid=False),
            )
            self.assertEqual(result.status, JobStatus.READY)
            self.assertEqual(result.catalog_publication_state, "failed")
            catalog.finalize.assert_not_called()

    def test_catalog_retention_deletes_only_expired_finalized_local_artifacts(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(Path(tmp) / "jobs")
            job = ready_job()
            job.status = JobStatus.EXPIRED
            job.catalog_publication_state = "finalized"
            store.save(job)
            artifact = job.artifacts[0]
            authorization = {
                "artifactId": artifact_id(artifact),
                "bucketSlot": "production",
                "objectKey": artifact.object_key,
                "bytes": artifact.bytes,
                "sha256": artifact.sha256,
                "authorizationExpiresAt": "2999-01-01T00:00:00Z",
            }
            catalog = RetentionCatalog([authorization])
            artifact_store = RetentionArtifactStore([artifact.object_key])

            result = delete_catalog_retention_artifacts(
                store,
                catalog,
                artifact_store,
                maximum_artifacts=10,
            )

            self.assertEqual(
                result,
                {"authorized": 1, "deleted": 1, "deferred": 0},
            )
            self.assertEqual(artifact_store.deleted, [artifact.object_key])
            self.assertEqual(catalog.claimed, [artifact_id(artifact)])
            self.assertEqual(catalog.confirmed, [artifact_id(artifact)])

            live = ready_job()
            live.job_id = "job-live-retention"
            live.artifacts = [live.artifacts[1]]
            live.catalog_publication_state = "finalized"
            store.save(live)
            protected = live.artifacts[0]
            protected_authorization = {
                "artifactId": artifact_id(protected),
                "bucketSlot": "production",
                "objectKey": protected.object_key,
                "bytes": protected.bytes,
                "sha256": protected.sha256,
                "authorizationExpiresAt": "2999-01-01T00:00:00Z",
            }
            protected_catalog = RetentionCatalog([protected_authorization])
            protected_store = RetentionArtifactStore([protected.object_key])
            self.assertEqual(
                delete_catalog_retention_artifacts(
                    store,
                    protected_catalog,
                    protected_store,
                    maximum_artifacts=10,
                ),
                {"authorized": 1, "deleted": 0, "deferred": 1},
            )
            self.assertEqual(protected_store.deleted, [])
            self.assertEqual(protected_catalog.claimed, [])
            self.assertEqual(protected_catalog.confirmed, [])

    def test_catalog_client_requires_https_and_long_service_secret(self):
        with self.assertRaisesRegex(ValueError, "HTTPS origin"):
            CatalogClient("http://maps.invalid", "development", "dev", "x" * 32)
        with self.assertRaisesRegex(ValueError, "at least 32 bytes"):
            CatalogClient("https://maps.invalid", "development", "dev", "short")

    def test_catalog_delivery_identity_only_accepts_complete_firmware_tuple(self):
        with patch.dict(
            os.environ,
            {"MAP_PLATFORM_CATALOG_REQUIRED_FIRMWARE_VERSION": "1.2.3"},
            clear=True,
        ):
            with self.assertRaisesRegex(
                CatalogPublicationError,
                "identity is incomplete",
            ):
                catalog_delivery_requirements("production")
        with patch.dict(
            os.environ,
            {
                "MAP_PLATFORM_CATALOG_REQUIRED_FIRMWARE_VERSION": "1.2.3",
                "MAP_PLATFORM_CATALOG_REQUIRED_FIRMWARE_BUILD": "123",
                "MAP_PLATFORM_CATALOG_REQUIRED_FIRMWARE_GIT_SHA": "a" * 40,
            },
            clear=True,
        ):
            self.assertEqual(
                catalog_delivery_requirements("production")
                ["requiredFirmwareBuild"],
                123,
            )


if __name__ == "__main__":
    unittest.main()
