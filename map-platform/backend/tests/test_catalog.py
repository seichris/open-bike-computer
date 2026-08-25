from __future__ import annotations

import json
import os
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

from map_platform.artifacts import ArtifactRecord
from map_platform.catalog import (
    CatalogClient,
    CatalogPublicationError,
    artifact_id,
    catalog_delivery_requirements,
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
            published = publish_ready_job(store, SuccessfulCatalog(), original.job_id)
            self.assertEqual(published.status, JobStatus.READY)
            self.assertEqual(published.catalog_publication_state, "finalized")
            self.assertEqual(published.catalog_map_entry_id, map_entry_id(original))
            self.assertEqual(published.artifacts, original.artifacts)

            round_trip = MapJob.from_dict(
                json.loads(json.dumps(published.to_dict(include_internal=True)))
            )
            self.assertEqual(round_trip.catalog_publication_state, "finalized")
            self.assertEqual(round_trip.catalog_map_entry_id, published.catalog_map_entry_id)

    def test_catalog_failure_never_demotes_ready_map(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(Path(tmp) / "jobs")
            store.save(ready_job())
            result = publish_ready_job(store, FailingCatalog(), "job-catalog-test")
            self.assertEqual(result.status, JobStatus.READY)
            self.assertEqual(result.catalog_publication_state, "failed")
            self.assertEqual(result.catalog_publication_attempts, 1)
            self.assertNotIn("secret value", result.catalog_publication_error)

    def test_catalog_client_requires_https_and_long_service_secret(self):
        with self.assertRaisesRegex(ValueError, "HTTPS origin"):
            CatalogClient("http://maps.invalid", "development", "dev", "x" * 32)
        with self.assertRaisesRegex(ValueError, "at least 32 bytes"):
            CatalogClient("https://maps.invalid", "development", "dev", "short")

    def test_catalog_delivery_identity_requires_complete_exact_tuple(self):
        with patch.dict(
            os.environ,
            {"MAP_PLATFORM_CATALOG_REQUIRED_IOS_BUILD": "123"},
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
                "MAP_PLATFORM_CATALOG_REQUIRED_IOS_BUILD": "123",
                "MAP_PLATFORM_CATALOG_REQUIRED_IOS_GIT_SHA": "a" * 40,
                "MAP_PLATFORM_CATALOG_REQUIRED_IOS_BUILD_SHA256": "b" * 64,
            },
            clear=True,
        ):
            self.assertEqual(
                catalog_delivery_requirements("production")["requiredIosBuild"],
                "123",
            )


if __name__ == "__main__":
    unittest.main()
