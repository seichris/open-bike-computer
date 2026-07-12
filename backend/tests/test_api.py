import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from fastapi.testclient import TestClient

from map_platform.api import create_app
from map_platform.downloads import DownloadSigner


class MapJobRunAPITests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo_root = Path(__file__).resolve().parents[2]
        self.environment = patch.dict(
            os.environ,
            {
                "MAP_PLATFORM_REPO_ROOT": str(self.repo_root),
                "MAP_PLATFORM_DATA_ROOT": self.tmp.name,
                "MAP_PLATFORM_SOURCE_INDEX": str(self.repo_root / "backend" / "config" / "source-regions.json"),
                "MAP_PLATFORM_API_TOKEN": "",
                "MAP_PLATFORM_ADMIN_TOKEN": "admin-secret",
                "MAP_PLATFORM_DOWNLOAD_SECRET": "test-secret",
            },
            clear=False,
        )
        self.environment.start()
        self.client = TestClient(create_app())

    def tearDown(self):
        self.client.close()
        self.environment.stop()
        self.tmp.cleanup()

    def create_job(self) -> str:
        response = self.client.post(
            "/v1/map-jobs",
            json={"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]},
        )
        self.assertEqual(response.status_code, 200)
        return response.json()["jobId"]

    def update_job(self, job_id: str, **values) -> None:
        job_path = Path(self.tmp.name) / "jobs" / f"{job_id}.json"
        job = json.loads(job_path.read_text())
        job.update(values)
        job_path.write_text(json.dumps(job))

    def test_run_route_returns_queued_job_result(self):
        job_id = self.create_job()
        result = Mock()
        result.to_dict.return_value = {"jobId": job_id, "status": "ready"}

        client_response = self.client.post(
            f"/v1/map-jobs/{job_id}/run",
            headers={"Authorization": "Bearer app-bundled-token"},
        )
        self.assertEqual(client_response.status_code, 401)

        with patch("map_platform.api.run_job", return_value=result):
            response = self.client.post(
                f"/v1/map-jobs/{job_id}/run",
                headers={"Authorization": "Bearer admin-secret"},
            )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["status"], "ready")

    def test_same_map_jobs_publish_and_download_exact_job_artifacts(self):
        def create_owned(request_id: str) -> str:
            response = self.client.post(
                "/v1/map-jobs",
                json={
                    "mode": "custom_bbox",
                    "bbox": [103.75, 1.24, 103.93, 1.37],
                    "clientInstallationId": "installation-owner",
                    "clientRequestId": request_id,
                },
            )
            self.assertEqual(response.status_code, 200)
            return response.json()["jobId"]

        first_job_id = create_owned("request-first-map")
        second_job_id = create_owned("request-second-map")
        first_built_archive = Path(self.tmp.name) / "work" / "first-built.zip"
        second_built_archive = Path(self.tmp.name) / "work" / "second-built.zip"
        first_built_archive.parent.mkdir(parents=True)
        first_built_archive.write_bytes(b"first-job-exact-bytes")
        second_built_archive.write_bytes(b"second-job-exact-bytes")

        with patch(
            "map_platform.api.MapBuildPipeline.build",
            side_effect=[
                ("map-shared", first_built_archive),
                ("map-shared", second_built_archive),
            ],
        ):
            admin_headers = {"Authorization": "Bearer admin-secret"}
            first_worker_run = self.client.post("/v1/workers/run-next", headers=admin_headers)
            second_worker_run = self.client.post("/v1/workers/run-next", headers=admin_headers)

        self.assertEqual(first_worker_run.status_code, 200)
        self.assertEqual(second_worker_run.status_code, 200)
        first_result = first_worker_run.json()["job"]
        second_result = second_worker_run.json()["job"]
        self.assertEqual(
            {first_result["jobId"], second_result["jobId"]},
            {first_job_id, second_job_id},
        )
        results_with_expected_bytes = [
            (first_result, b"first-job-exact-bytes"),
            (second_result, b"second-job-exact-bytes"),
        ]
        pack_paths = []
        for result, expected in results_with_expected_bytes:
            job_id = result["jobId"]
            pack_path = Path(result["packPath"])
            pack_paths.append(pack_path)
            self.assertEqual(
                pack_path,
                Path(self.tmp.name) / "packs" / "map-shared" / f"{job_id}.zip",
            )
            signed = self.client.post(
                "/v1/map-packs/map-shared/download-url",
                params={
                    "clientInstallationId": "installation-owner",
                    "jobId": job_id,
                },
            )
            self.assertEqual(signed.status_code, 200)
            downloaded = self.client.get(signed.json()["url"])
            self.assertEqual(downloaded.status_code, 200)
            self.assertEqual(downloaded.content, expected)
        self.assertNotEqual(pack_paths[0], pack_paths[1])

    def test_pre_deploy_signed_url_can_download_legacy_shared_artifact(self):
        legacy_job_id = self.create_job()
        legacy_pack_path = Path(self.tmp.name) / "packs" / "map-legacy.zip"
        legacy_pack_path.parent.mkdir(parents=True)
        legacy_pack_path.write_bytes(b"legacy-shared-bytes")
        self.update_job(
            legacy_job_id,
            status="ready",
            mapId="map-legacy",
            packPath=str(legacy_pack_path),
            createdAt="2026-07-12T01:00:00Z",
        )

        newer_job_id = self.create_job()
        newer_pack_path = Path(self.tmp.name) / "packs" / "map-legacy" / f"{newer_job_id}.zip"
        newer_pack_path.parent.mkdir(parents=True)
        newer_pack_path.write_bytes(b"new-job-bytes")
        self.update_job(
            newer_job_id,
            status="ready",
            mapId="map-legacy",
            packPath=str(newer_pack_path),
            createdAt="2026-07-12T02:00:00Z",
        )
        signed = DownloadSigner("test-secret").sign(
            "map-legacy",
            legacy_pack_path,
            ttl_seconds=900,
        )

        response = self.client.get(
            f"/v1/map-packs/map-legacy/download?{signed.query()}"
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.content, b"legacy-shared-bytes")

    def test_expired_job_cannot_issue_a_new_download_url(self):
        job_id = self.create_job()
        protecting_job_id = self.create_job()
        pack_path = Path(self.tmp.name) / "packs" / "map-expired" / f"{job_id}.zip"
        pack_path.parent.mkdir(parents=True)
        pack_path.write_bytes(b"expired")
        self.update_job(
            job_id,
            status="ready",
            mapId="map-expired",
            packPath=str(pack_path),
            updatedAt="2020-01-01T00:00:00Z",
        )
        # Keep the artifact present after expiry so the signed-download
        # assertion below proves READY-state gating, not a missing file.
        self.update_job(protecting_job_id, packPath=str(pack_path))

        issued = self.client.post(
            "/v1/map-packs/map-expired/download-url",
            params={"jobId": job_id},
        )
        self.assertEqual(issued.status_code, 200)

        client_authorized_expiry = self.client.post(
            "/v1/maintenance/expire",
            json={"olderThanDays": 1},
            headers={"Authorization": "Bearer app-bundled-token"},
        )
        expired = self.client.post(
            "/v1/maintenance/expire",
            json={"olderThanDays": 1},
            headers={"Authorization": "Bearer admin-secret"},
        )
        download = self.client.post(
            "/v1/map-packs/map-expired/download-url",
            params={
                "clientInstallationId": "installation-owner",
                "jobId": job_id,
            },
        )
        previously_issued_download = self.client.get(issued.json()["url"])

        self.assertEqual(client_authorized_expiry.status_code, 401)
        self.assertEqual(expired.status_code, 200)
        self.assertEqual(expired.json()["expired"], 1)
        self.assertEqual(download.status_code, 404)
        self.assertEqual(previously_issued_download.status_code, 404)
        self.assertTrue(pack_path.exists())

        invalid_retention = self.client.post(
            "/v1/maintenance/expire",
            json={"olderThanDays": 0},
            headers={"Authorization": "Bearer admin-secret"},
        )
        self.assertEqual(invalid_retention.status_code, 400)
        for invalid_value in (True, 1.5, "30"):
            invalid_type = self.client.post(
                "/v1/maintenance/expire",
                json={"olderThanDays": invalid_value},
                headers={"Authorization": "Bearer admin-secret"},
            )
            self.assertEqual(invalid_type.status_code, 400)

    def test_run_route_rejects_active_job(self):
        job_id = self.create_job()
        job_path = Path(self.tmp.name) / "jobs" / f"{job_id}.json"
        job = json.loads(job_path.read_text())
        job["status"] = "validating"
        job["workerId"] = "worker-active"
        job_path.write_text(json.dumps(job))

        response = self.client.post(
            f"/v1/map-jobs/{job_id}/run",
            headers={"Authorization": "Bearer admin-secret"},
        )

        self.assertEqual(response.status_code, 409)
        self.assertIn("not queued", response.json()["detail"])

    def test_run_route_rejects_cancelled_job(self):
        job_id = self.create_job()
        self.assertEqual(self.client.post(f"/v1/map-jobs/{job_id}/cancel").status_code, 200)

        response = self.client.post(
            f"/v1/map-jobs/{job_id}/run",
            headers={"Authorization": "Bearer admin-secret"},
        )

        self.assertEqual(response.status_code, 409)
        self.assertIn("cancelled", response.json()["detail"])

    def test_run_route_returns_not_found_for_missing_job(self):
        response = self.client.post(
            "/v1/map-jobs/missing-job/run",
            headers={"Authorization": "Bearer admin-secret"},
        )

        self.assertEqual(response.status_code, 404)

    def test_list_jobs_filters_by_client_installation(self):
        first = self.client.post(
            "/v1/map-jobs",
            json={
                "mode": "custom_bbox",
                "bbox": [103.75, 1.24, 103.93, 1.37],
                "clientInstallationId": "installation-first",
                "clientRequestId": "request-first-123",
            },
        )
        self.assertEqual(first.status_code, 200)
        second = self.client.post(
            "/v1/map-jobs",
            json={
                "mode": "custom_bbox",
                "bbox": [103.76, 1.25, 103.94, 1.38],
                "clientInstallationId": "installation-second",
                "clientRequestId": "request-second-123",
            },
        )
        self.assertEqual(second.status_code, 200)

        response = self.client.get(
            "/v1/map-jobs",
            params={"clientInstallationId": "installation-first"},
        )

        self.assertEqual(response.status_code, 200)
        jobs = response.json()["jobs"]
        self.assertEqual([job["jobId"] for job in jobs], [first.json()["jobId"]])

    def test_job_reads_require_matching_installation(self):
        owned = self.client.post(
            "/v1/map-jobs",
            json={
                "mode": "custom_bbox",
                "bbox": [103.75, 1.24, 103.93, 1.37],
                "clientInstallationId": "installation-owner",
                "clientRequestId": "request-owner-123",
            },
        ).json()

        missing_filter = self.client.get("/v1/map-jobs")
        matching = self.client.get(
            f"/v1/map-jobs/{owned['jobId']}",
            params={"clientInstallationId": "installation-owner"},
        )
        other = self.client.get(
            f"/v1/map-jobs/{owned['jobId']}",
            params={"clientInstallationId": "installation-other"},
        )
        unscoped = self.client.get(f"/v1/map-jobs/{owned['jobId']}")

        self.assertEqual(missing_filter.status_code, 400)
        self.assertEqual(matching.status_code, 200)
        self.assertEqual(other.status_code, 404)
        self.assertEqual(unscoped.status_code, 404)

    def test_legacy_job_remains_recoverable_by_an_installation(self):
        legacy_job_id = self.create_job()

        response = self.client.get(
            f"/v1/map-jobs/{legacy_job_id}",
            params={"clientInstallationId": "installation-owner"},
        )
        legacy_unscoped = self.client.get(f"/v1/map-jobs/{legacy_job_id}")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(legacy_unscoped.status_code, 200)

    def test_client_metadata_validation_returns_bad_request(self):
        valid = {
            "mode": "custom_bbox",
            "bbox": [103.75, 1.24, 103.93, 1.37],
        }
        invalid_payloads = [
            {**valid, "clientInstallationId": "installation-only"},
            {
                **valid,
                "clientInstallationId": "installation-owner",
                "clientRequestId": "request-owner-123",
                "installOnDevice": "yes",
            },
            {
                **valid,
                "clientInstallationId": "bad",
                "clientRequestId": "request-owner-123",
            },
            {
                **valid,
                "clientInstallationId": 123,
                "clientRequestId": "request-owner-123",
            },
        ]

        for payload in invalid_payloads:
            with self.subTest(payload=payload):
                response = self.client.post("/v1/map-jobs", json=payload)
                self.assertEqual(response.status_code, 400)
                self.assertTrue(response.json()["detail"])

        invalid_filter = self.client.get(
            "/v1/map-jobs",
            params={"clientInstallationId": "bad"},
        )
        self.assertEqual(invalid_filter.status_code, 400)

    def test_map_pack_reads_are_scoped_and_choose_newest_owned_job(self):
        def create_owned(installation_id: str, request_id: str, bbox: list[float]) -> str:
            response = self.client.post(
                "/v1/map-jobs",
                json={
                    "mode": "custom_bbox",
                    "bbox": bbox,
                    "clientInstallationId": installation_id,
                    "clientRequestId": request_id,
                },
            )
            self.assertEqual(response.status_code, 200)
            return response.json()["jobId"]

        older = create_owned(
            "installation-owner",
            "request-owner-old",
            [103.75, 1.24, 103.93, 1.37],
        )
        newer = create_owned(
            "installation-owner",
            "request-owner-new",
            [103.76, 1.25, 103.94, 1.38],
        )
        other = create_owned(
            "installation-other",
            "request-other-new",
            [103.77, 1.26, 103.95, 1.39],
        )
        older_path = Path(self.tmp.name) / "older.zip"
        newer_path = Path(self.tmp.name) / "newer.zip"
        other_path = Path(self.tmp.name) / "other.zip"
        older_path.write_bytes(b"older")
        newer_path.write_bytes(b"newer")
        other_path.write_bytes(b"other")
        self.update_job(
            older,
            status="ready",
            mapId="map-shared",
            packPath=str(older_path),
            createdAt="2026-07-12T01:00:00Z",
        )
        self.update_job(
            newer,
            status="ready",
            mapId="map-shared",
            packPath=str(newer_path),
            createdAt="2026-07-12T03:00:00Z",
        )
        self.update_job(
            other,
            status="ready",
            mapId="map-shared",
            packPath=str(other_path),
            createdAt="2026-07-12T04:00:00Z",
        )

        matching = self.client.get(
            "/v1/map-packs/map-shared",
            params={"clientInstallationId": "installation-owner"},
        )
        unknown = self.client.get(
            "/v1/map-packs/map-shared",
            params={"clientInstallationId": "installation-unknown"},
        )
        unscoped = self.client.get("/v1/map-packs/map-shared")
        download = self.client.post(
            "/v1/map-packs/map-shared/download-url",
            params={
                "clientInstallationId": "installation-owner",
                "jobId": newer,
            },
        )
        older_download = self.client.post(
            "/v1/map-packs/map-shared/download-url",
            params={
                "clientInstallationId": "installation-owner",
                "jobId": older,
            },
        )
        cross_install_download = self.client.post(
            "/v1/map-packs/map-shared/download-url",
            params={
                "clientInstallationId": "installation-owner",
                "jobId": other,
            },
        )

        self.assertEqual(matching.status_code, 200)
        self.assertEqual(matching.json()["jobId"], newer)
        self.assertEqual(unknown.status_code, 404)
        self.assertEqual(unscoped.status_code, 404)
        self.assertEqual(download.status_code, 200)
        downloaded = self.client.get(download.json()["url"])
        self.assertEqual(downloaded.status_code, 200)
        self.assertEqual(downloaded.content, b"newer")
        self.assertEqual(older_download.status_code, 200)
        older_file = self.client.get(older_download.json()["url"])
        self.assertEqual(older_file.status_code, 200)
        self.assertEqual(older_file.content, b"older")
        self.assertEqual(cross_install_download.status_code, 404)

        legacy = self.create_job()
        legacy_path = Path(self.tmp.name) / "legacy.zip"
        legacy_path.write_bytes(b"legacy")
        self.update_job(
            legacy,
            status="ready",
            mapId="map-legacy",
            packPath=str(legacy_path),
        )
        self.assertEqual(self.client.get("/v1/map-packs/map-legacy").status_code, 200)
        legacy_download = self.client.post(
            "/v1/map-packs/map-legacy/download-url",
            params={
                "clientInstallationId": "installation-owner",
                "jobId": legacy,
            },
        )
        self.assertEqual(legacy_download.status_code, 200)
        legacy_file = self.client.get(legacy_download.json()["url"])
        self.assertEqual(legacy_file.status_code, 200)
        self.assertEqual(legacy_file.content, b"legacy")

    def test_modern_job_mutations_require_matching_installation(self):
        response = self.client.post(
            "/v1/map-jobs",
            json={
                "mode": "custom_bbox",
                "bbox": [103.75, 1.24, 103.93, 1.37],
                "clientInstallationId": "installation-owner",
                "clientRequestId": "request-owner-123",
            },
        )
        self.assertEqual(response.status_code, 200)
        job_id = response.json()["jobId"]

        self.assertEqual(
            self.client.post(
                f"/v1/map-jobs/{job_id}/run",
                headers={"Authorization": "Bearer admin-secret"},
            ).status_code,
            404,
        )
        self.assertEqual(
            self.client.post(
                f"/v1/map-jobs/{job_id}/cancel",
                params={"clientInstallationId": "installation-other"},
            ).status_code,
            404,
        )
        cancelled = self.client.post(
            f"/v1/map-jobs/{job_id}/cancel",
            params={"clientInstallationId": "installation-owner"},
        )
        self.assertEqual(cancelled.status_code, 200)
        self.assertEqual(cancelled.json()["status"], "cancelled")


if __name__ == "__main__":
    unittest.main()
