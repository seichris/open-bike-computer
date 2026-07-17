import json
import hashlib
import os
import sqlite3
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
from pathlib import Path
from unittest.mock import Mock, patch

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi.testclient import TestClient

from map_platform.api import create_app
from map_platform.downloads import DownloadSigner
from map_platform.models import MapJob


class MapJobRunAPITests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo_root = Path(__file__).resolve().parents[2]
        self.hardware_requirements_path = (
            self.repo_root / "config" / "map-stream-hardware-gate.json"
        )
        requirements_sha256 = hashlib.sha256(
            self.hardware_requirements_path.read_bytes()
        ).hexdigest()
        self.trust_registry_path = Path(self.tmp.name) / "map-stream-trust.json"
        trust_public_key = ec.derive_private_key(
            7,
            ec.SECP256R1(),
        ).public_key().public_bytes(
            serialization.Encoding.X962,
            serialization.PublicFormat.UncompressedPoint,
        ).hex()
        self.trust_key_sha256 = hashlib.sha256(
            bytes.fromhex(trust_public_key)
        ).hexdigest()
        self.stream_trust_header = (
            f"map-prod-1={self.trust_key_sha256}"
        )
        self.worker_image_digest = "sha256:" + "8" * 64
        self.ios_git_sha = "9" * 40
        self.ios_build_sha256 = "a" * 64
        self.trust_registry_path.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "keys": [
                        {
                            "keyId": "map-prod-1",
                            "publicKeyX963Hex": trust_public_key,
                            "state": "trusted",
                            "createdAt": "2026-07-13",
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )
        self.rollout_approvals_path = Path(self.tmp.name) / "rollout-approvals.json"
        self.rollout_approvals_path.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "approvals": [
                        {
                            "promotionId": "msr-20260713-api-tests",
                            "candidateGitSha": "1" * 40,
                            "producerBuildSha256": "6" * 64,
                            "workerImageDigest": self.worker_image_digest,
                            "firmwareVersion": "0.3.0",
                            "firmwareBuild": 42,
                            "firmwareGitSha": "7" * 40,
                            "iosBuild": "100",
                            "iosGitSha": self.ios_git_sha,
                            "iosBuildSha256": self.ios_build_sha256,
                            "reportSha256": "2" * 64,
                            "requirementsSha256": requirements_sha256,
                            "approvedAt": "2026-07-13T00:00:00Z",
                            "approvedBy": "backend-tests",
                            "targets": [
                                "WAVESHARE_AMOLED_175",
                                "WAVESHARE_AMOLED_206",
                            ],
                            "signingKeys": [
                                {
                                    "keyId": "map-prod-1",
                                    "publicKeySha256": self.trust_key_sha256,
                                }
                            ],
                        }
                    ],
                }
            )
        )
        self.environment = patch.dict(
            os.environ,
            {
                "MAP_PLATFORM_REPO_ROOT": str(self.repo_root),
                "MAP_PLATFORM_DATA_ROOT": self.tmp.name,
                "MAP_PLATFORM_SOURCE_INDEX": str(self.repo_root / "backend" / "config" / "source-regions.json"),
                "MAP_PLATFORM_ADMIN_TOKEN": "admin-secret",
                "MAP_PLATFORM_DOWNLOAD_SECRET": "test-secret",
                "MAP_PLATFORM_INSTALLATION_SECRET": "test-installation-secret-32-bytes-minimum",
                "MAP_PLATFORM_PUBLIC_REQUEST_LIMIT_PER_MINUTE": "10000",
                "MAP_PLATFORM_INSTALLATION_ISSUE_LIMIT_PER_DAY": "10000",
                "MAP_PLATFORM_MAP_CREATE_LIMIT_PER_HOUR": "10000",
                "MAP_PLATFORM_MAP_CREATE_IP_LIMIT_PER_DAY": "10000",
                "MAP_PLATFORM_DOWNLOAD_URL_LIMIT_PER_HOUR": "10000",
                "MAP_PLATFORM_DOWNLOAD_URL_IP_LIMIT_PER_HOUR": "10000",
                "MAP_PLATFORM_ARTIFACT_STORE": "filesystem",
                "MAP_PLATFORM_ARTIFACT_ROOT": str(Path(self.tmp.name) / "artifacts"),
                "MAP_PLATFORM_MAP_STREAM_ENABLED": "0",
                "MAP_PLATFORM_MAP_STREAM_ROLLOUT_MODE": "all",
                "MAP_PLATFORM_MAP_STREAM_ROLLOUT_ALLOWLIST": "",
                "MAP_PLATFORM_MAP_STREAM_ROLLOUT_BASIS_POINTS": "0",
                "MAP_PLATFORM_MAP_STREAM_ROLLOUT_SECRET": "",
                "MAP_PLATFORM_MAP_STREAM_PROMOTION_ID": "msr-20260713-api-tests",
                "MAP_PLATFORM_WORKER_IMAGE_REFERENCE": (
                    "registry.invalid/map-worker@" + self.worker_image_digest
                ),
                "MAP_PLATFORM_MAP_STREAM_ROLLOUT_APPROVALS": str(
                    self.rollout_approvals_path
                ),
                "MAP_PLATFORM_MAP_STREAM_TRUST_REGISTRY": str(
                    self.trust_registry_path
                ),
                "MAP_PLATFORM_MAP_STREAM_HARDWARE_REQUIREMENTS": str(
                    self.hardware_requirements_path
                ),
                "MAP_PLATFORM_INLINE_WORKER_ENABLED": "1",
            },
            clear=False,
        )
        self.environment.start()
        self.client = TestClient(create_app())
        self.client.headers["X-Map-Stream-Trust"] = self.stream_trust_header
        self.client.headers["X-Map-Stream-App-Build"] = "100"
        self.client.headers["X-Map-Stream-App-Git-Sha"] = self.ios_git_sha
        self.client.headers["X-Map-Stream-App-Build-Sha256"] = self.ios_build_sha256

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
        self.client.app.state.job_store.save(MapJob.from_dict(job))

    def test_installation_issuance_is_public_but_rate_limited(self):
        limited_root = Path(self.tmp.name) / "installation-limit"
        with patch.dict(
            os.environ,
            {
                "MAP_PLATFORM_DATA_ROOT": str(limited_root),
                "MAP_PLATFORM_INSTALLATION_ISSUE_LIMIT_PER_DAY": "1",
            },
            clear=False,
        ):
            client = TestClient(create_app())
            try:
                first = client.post("/v1/installations")
                blocked = client.post("/v1/installations")
            finally:
                client.close()

        self.assertEqual(first.status_code, 200)
        self.assertEqual(blocked.status_code, 429)
        self.assertEqual(blocked.json()["detail"], "request rate limit exceeded")
        self.assertGreater(int(blocked.headers["Retry-After"]), 0)

    def test_installation_token_refresh_preserves_identity_across_rotation(self):
        from map_platform.installations import InstallationCredentialStore

        old_secret = "old-installation-secret-at-least-32-bytes"
        new_secret = "new-installation-secret-at-least-32-bytes"
        installation_id, old_token = InstallationCredentialStore(old_secret).issue()
        rotated_root = Path(self.tmp.name) / "installation-rotation"
        with patch.dict(
            os.environ,
            {
                "MAP_PLATFORM_DATA_ROOT": str(rotated_root),
                "MAP_PLATFORM_INSTALLATION_SECRET": new_secret,
                "MAP_PLATFORM_INSTALLATION_PREVIOUS_SECRETS": old_secret,
                "MAP_PLATFORM_INSTALLATION_ISSUE_LIMIT_PER_DAY": "1",
            },
            clear=False,
        ):
            client = TestClient(create_app())
            try:
                refreshed = client.post(
                    "/v1/installations",
                    params={"clientInstallationId": installation_id},
                    headers={"X-Installation-Token": old_token},
                )
                newly_issued = client.post("/v1/installations")
                blocked_new_issue = client.post("/v1/installations")
            finally:
                client.close()

        self.assertEqual(refreshed.status_code, 200)
        self.assertEqual(refreshed.json()["clientInstallationId"], installation_id)
        refreshed_token = refreshed.json()["clientInstallationToken"]
        self.assertNotEqual(refreshed_token, old_token)
        InstallationCredentialStore(new_secret).verify(installation_id, refreshed_token)
        self.assertEqual(newly_issued.status_code, 200)
        self.assertEqual(blocked_new_issue.status_code, 429)

    def test_map_creation_is_limited_by_installation(self):
        limited_root = Path(self.tmp.name) / "map-create-limit"
        with patch.dict(
            os.environ,
            {
                "MAP_PLATFORM_DATA_ROOT": str(limited_root),
                "MAP_PLATFORM_MAP_CREATE_LIMIT_PER_HOUR": "1",
            },
            clear=False,
        ):
            client = TestClient(create_app())
            try:
                credential = client.post("/v1/installations").json()
                headers = {
                    "X-Installation-Token": credential["clientInstallationToken"]
                }
                payload = {
                    "mode": "custom_bbox",
                    "bbox": [103.75, 1.24, 103.93, 1.37],
                    "clientInstallationId": credential["clientInstallationId"],
                    "clientRequestId": "rate-limit-request-1",
                }
                first = client.post("/v1/map-jobs", headers=headers, json=payload)
                replay = client.post("/v1/map-jobs", headers=headers, json=payload)
                payload["clientRequestId"] = "rate-limit-request-2"
                blocked = client.post("/v1/map-jobs", headers=headers, json=payload)
            finally:
                client.close()

        self.assertEqual(first.status_code, 200)
        self.assertEqual(replay.status_code, 200)
        self.assertEqual(replay.json()["jobId"], first.json()["jobId"])
        self.assertEqual(blocked.status_code, 429)
        self.assertGreater(int(blocked.headers["Retry-After"]), 0)

    def test_concurrent_idempotent_replay_consumes_quota_once(self):
        limited_root = Path(self.tmp.name) / "concurrent-idempotency-limit"
        with patch.dict(
            os.environ,
            {
                "MAP_PLATFORM_DATA_ROOT": str(limited_root),
                "MAP_PLATFORM_MAP_CREATE_LIMIT_PER_HOUR": "1",
                "MAP_PLATFORM_MAP_CREATE_IP_LIMIT_PER_DAY": "1",
            },
            clear=False,
        ):
            app = create_app()
            clients = [TestClient(app), TestClient(app)]
            try:
                credential = clients[0].post("/v1/installations").json()
                headers = {
                    "X-Installation-Token": credential["clientInstallationToken"]
                }
                payload = {
                    "mode": "custom_bbox",
                    "bbox": [103.75, 1.24, 103.93, 1.37],
                    "clientInstallationId": credential["clientInstallationId"],
                    "clientRequestId": "concurrent-rate-request",
                }
                barrier = Barrier(2)

                def create(client):
                    barrier.wait(timeout=5)
                    return client.post("/v1/map-jobs", headers=headers, json=payload)

                with ThreadPoolExecutor(max_workers=2) as executor:
                    responses = list(executor.map(create, clients))
                blocked = clients[0].post(
                    "/v1/map-jobs",
                    headers=headers,
                    json={**payload, "clientRequestId": "new-rate-request"},
                )
            finally:
                for client in clients:
                    client.close()

        self.assertEqual([response.status_code for response in responses], [200, 200])
        self.assertEqual(len({response.json()["jobId"] for response in responses}), 1)
        self.assertEqual(blocked.status_code, 429)
        with sqlite3.connect(limited_root / "rate-limits.sqlite3") as connection:
            counts = dict(
                connection.execute(
                    "SELECT scope, request_count FROM rate_limits "
                    "WHERE scope LIKE 'map-create-%'"
                ).fetchall()
            )
        self.assertEqual(counts["map-create-installation"], 1)
        self.assertEqual(counts["map-create-ip"], 1)

    def test_download_url_is_limited_by_installation(self):
        limited_root = Path(self.tmp.name) / "download-url-limit"
        with patch.dict(
            os.environ,
            {
                "MAP_PLATFORM_DATA_ROOT": str(limited_root),
                "MAP_PLATFORM_DOWNLOAD_URL_LIMIT_PER_HOUR": "1",
            },
            clear=False,
        ):
            client = TestClient(create_app())
            try:
                credential = client.post("/v1/installations").json()
                headers = {
                    "X-Installation-Token": credential["clientInstallationToken"]
                }
                created = client.post(
                    "/v1/map-jobs",
                    headers=headers,
                    json={
                        "mode": "custom_bbox",
                        "bbox": [103.75, 1.24, 103.93, 1.37],
                        "clientInstallationId": credential["clientInstallationId"],
                        "clientRequestId": "download-limit-request",
                    },
                ).json()
                job_path = limited_root / "jobs" / f"{created['jobId']}.json"
                job = json.loads(job_path.read_text())
                pack_path = limited_root / "download-limit-map.zip"
                pack_path.write_bytes(b"download-limit-map")
                job.update(
                    status="ready",
                    mapId="download-limit-map",
                    packPath=str(pack_path),
                )
                client.app.state.job_store.save(MapJob.from_dict(job))
                params = {
                    "clientInstallationId": credential["clientInstallationId"],
                    "jobId": created["jobId"],
                }
                first = client.post(
                    "/v1/map-packs/download-limit-map/download-url",
                    headers=headers,
                    params=params,
                )
                blocked = client.post(
                    "/v1/map-packs/download-limit-map/download-url",
                    headers=headers,
                    params=params,
                )
            finally:
                client.close()

        self.assertEqual(first.status_code, 200)
        self.assertEqual(blocked.status_code, 429)
        self.assertGreater(int(blocked.headers["Retry-After"]), 0)

    def test_anonymous_map_creation_is_limited_by_client_address(self):
        limited_root = Path(self.tmp.name) / "anonymous-map-create-limit"
        with patch.dict(
            os.environ,
            {
                "MAP_PLATFORM_DATA_ROOT": str(limited_root),
                "MAP_PLATFORM_MAP_CREATE_IP_LIMIT_PER_DAY": "1",
            },
            clear=False,
        ):
            client = TestClient(create_app())
            try:
                payload = {
                    "mode": "custom_bbox",
                    "bbox": [103.75, 1.24, 103.93, 1.37],
                }
                first = client.post("/v1/map-jobs", json=payload)
                blocked = client.post("/v1/map-jobs", json=payload)
            finally:
                client.close()

        self.assertEqual(first.status_code, 200)
        self.assertEqual(blocked.status_code, 429)
        self.assertGreater(int(blocked.headers["Retry-After"]), 0)

    def test_map_creation_rejects_unknown_fields_and_oversized_bodies(self):
        unknown = self.client.post(
            "/v1/map-jobs",
            json={
                "mode": "custom_bbox",
                "bbox": [103.75, 1.24, 103.93, 1.37],
                "padding": "not persisted",
            },
        )
        self.assertEqual(unknown.status_code, 400)
        self.assertIn("invalid fields", unknown.json()["detail"])

        limited_root = Path(self.tmp.name) / "request-body-limit"
        with patch.dict(
            os.environ,
            {
                "MAP_PLATFORM_DATA_ROOT": str(limited_root),
                "MAP_PLATFORM_MAX_REQUEST_BODY_BYTES": "128",
            },
            clear=False,
        ):
            client = TestClient(create_app())
            try:
                oversized = client.post(
                    "/v1/map-jobs",
                    content=json.dumps(
                        {
                            "mode": "custom_bbox",
                            "bbox": [103.75, 1.24, 103.93, 1.37],
                            "displayName": "x" * 256,
                        }
                    ),
                    headers={"Content-Type": "application/json"},
                )
            finally:
                client.close()
        self.assertEqual(oversized.status_code, 413)
        self.assertEqual(oversized.json()["detail"], "request body is too large")

    def test_default_body_limit_accepts_maximum_route_corridor(self):
        route = [
            [103.8 + index / 10_000_000, 1.3 + index / 10_000_000]
            for index in range(25_000)
        ]
        response = self.client.post(
            "/v1/map-jobs",
            json={
                "mode": "route_corridor",
                "route": route,
                "corridorWidthM": 100,
            },
        )

        self.assertEqual(response.status_code, 200)

    def test_public_limit_does_not_interfere_with_admin_authentication(self):
        limited_root = Path(self.tmp.name) / "public-route-limit"
        with patch.dict(
            os.environ,
            {
                "MAP_PLATFORM_DATA_ROOT": str(limited_root),
                "MAP_PLATFORM_PUBLIC_REQUEST_LIMIT_PER_MINUTE": "1",
            },
            clear=False,
        ):
            client = TestClient(create_app())
            try:
                public = client.get("/v1/source-regions")
                run = client.post("/v1/map-jobs/missing-job/run")
                cache = client.post("/v1/source-regions/sg/cache")
            finally:
                client.close()

        self.assertEqual(public.status_code, 200)
        self.assertEqual(run.status_code, 401)
        self.assertEqual(cache.status_code, 401)

    def test_legacy_global_bearer_does_not_replace_installation_credential(self):
        credential = self.client.post("/v1/installations").json()
        response = self.client.post(
            "/v1/map-jobs",
            headers={"Authorization": "Bearer previously-embedded-token"},
            json={
                "mode": "custom_bbox",
                "bbox": [103.75, 1.24, 103.93, 1.37],
                "clientInstallationId": credential["clientInstallationId"],
                "clientRequestId": "missing-installation-proof",
            },
        )
        self.assertEqual(response.status_code, 401)
        self.assertEqual(response.json()["detail"], "installation credential is required")

    def test_download_inventory_records_real_receipts_names_and_redacts_installations(self):
        credential = self.client.post("/v1/installations").json()
        installation_id = credential["clientInstallationId"]
        installation_headers = {
            "X-Installation-Token": credential["clientInstallationToken"]
        }
        created = self.client.post(
            "/v1/map-jobs",
            headers=installation_headers,
            json={
                "mode": "custom_bbox",
                "bbox": [103.75, 1.24, 103.93, 1.37],
                "clientInstallationId": installation_id,
                "clientRequestId": "inventory-request-1",
            },
        )
        self.assertEqual(created.status_code, 200)
        job_id = created.json()["jobId"]
        source_name = created.json()["sourceRegion"]["name"]
        pack_path = Path(self.tmp.name) / "inventory-map.zip"
        pack_path.write_bytes(b"inventory-map")
        artifact_sha256 = hashlib.sha256(pack_path.read_bytes()).hexdigest()
        self.update_job(
            job_id,
            status="ready",
            mapId="inventory-map",
            packPath=str(pack_path),
            packBytes=pack_path.stat().st_size,
            finishedAt="2026-07-15T10:00:00.000000Z",
            artifacts=[
                {
                    "format": "zip-stored-v1",
                    "mediaType": "application/zip",
                    "filename": "inventory-map.zip",
                    "objectKey": "maps/inventory-map.zip",
                    "bytes": pack_path.stat().st_size,
                    "sha256": artifact_sha256,
                }
            ],
        )

        renamed = self.client.patch(
            f"/v1/map-jobs/{job_id}/display-name",
            params={"clientInstallationId": installation_id},
            headers=installation_headers,
            json={"displayName": "  Marina Bay rides  "},
        )
        self.assertEqual(renamed.status_code, 200)
        self.assertEqual(renamed.json()["userLabel"], "Marina Bay rides")

        receipt = {
            "receiptId": "download-receipt-0001",
            "artifactFormat": "zip-stored-v1",
            "sha256": artifact_sha256,
            "bytes": pack_path.stat().st_size,
        }
        first = self.client.post(
            f"/v1/map-jobs/{job_id}/downloads",
            params={"clientInstallationId": installation_id},
            headers=installation_headers,
            json=receipt,
        )
        repeated = self.client.post(
            f"/v1/map-jobs/{job_id}/downloads",
            params={"clientInstallationId": installation_id},
            headers=installation_headers,
            json=receipt,
        )
        self.assertEqual(first.status_code, 200)
        self.assertEqual(repeated.status_code, 200)
        self.assertEqual(first.json()["downloadCount"], 1)
        self.assertEqual(repeated.json()["downloadCount"], 1)

        unauthorized = self.client.get("/v1/admin/maps")
        inventory = self.client.get(
            "/v1/admin/maps",
            headers={"Authorization": "Bearer admin-secret"},
        )
        self.assertEqual(unauthorized.status_code, 401)
        self.assertEqual(inventory.status_code, 200)
        document = inventory.json()
        self.assertEqual(document["summary"]["mapJobs"], 1)
        self.assertEqual(document["summary"]["downloads"], 1)
        self.assertEqual(document["maps"][0]["userLabel"], "Marina Bay rides")
        self.assertEqual(document["maps"][0]["geofabrik"]["name"], source_name)
        self.assertTrue(document["maps"][0]["installationRef"].startswith("install_"))
        self.assertNotIn(installation_id, inventory.text)
        self.assertNotIn("download-receipt-0001", inventory.text)

    def test_inventory_mutations_require_the_owning_registered_installation(self):
        owner = self.client.post("/v1/installations").json()
        stranger = self.client.post("/v1/installations").json()
        created = self.client.post(
            "/v1/map-jobs",
            headers={"X-Installation-Token": owner["clientInstallationToken"]},
            json={
                "mode": "custom_bbox",
                "bbox": [103.75, 1.24, 103.93, 1.37],
                "clientInstallationId": owner["clientInstallationId"],
                "clientRequestId": "inventory-owner-1",
            },
        )
        job_id = created.json()["jobId"]

        response = self.client.patch(
            f"/v1/map-jobs/{job_id}/display-name",
            params={"clientInstallationId": stranger["clientInstallationId"]},
            headers={"X-Installation-Token": stranger["clientInstallationToken"]},
            json={"displayName": "Not mine"},
        )
        invalid_name = self.client.patch(
            f"/v1/map-jobs/{job_id}/display-name",
            params={"clientInstallationId": owner["clientInstallationId"]},
            headers={"X-Installation-Token": owner["clientInstallationToken"]},
            json={"displayName": "bad\u0007name"},
        )

        self.assertEqual(response.status_code, 404)
        self.assertEqual(invalid_name.status_code, 400)

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

    def test_stream_rollout_keeps_signing_out_of_inline_api_worker(self):
        with patch.dict(
            os.environ,
            {
                "MAP_PLATFORM_MAP_STREAM_ENABLED": "1",
                "MAP_PLATFORM_MAP_SIGNING_KEY_ID": "",
                "MAP_PLATFORM_MAP_SIGNING_PRIVATE_KEY_BASE64": "",
            },
            clear=False,
        ):
            client = TestClient(create_app())
            try:
                created = client.post(
                    "/v1/map-jobs",
                    json={"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]},
                )
                response = client.post(
                    f"/v1/map-jobs/{created.json()['jobId']}/run",
                    headers={"Authorization": "Bearer admin-secret"},
                )
                self.assertEqual(response.status_code, 503)
                self.assertEqual(response.json()["detail"], "inline map workers are disabled")
            finally:
                client.close()

    def test_disabled_and_allowlist_modes_do_not_depend_on_promotion_files(self):
        missing = str(Path(self.tmp.name) / "missing-rollout-control.json")
        modes = [
            {
                "MAP_PLATFORM_MAP_STREAM_ROLLOUT_MODE": "disabled",
                "MAP_PLATFORM_MAP_STREAM_ROLLOUT_ALLOWLIST": "",
            },
            {
                "MAP_PLATFORM_MAP_STREAM_ROLLOUT_MODE": "allowlist",
                "MAP_PLATFORM_MAP_STREAM_ROLLOUT_ALLOWLIST": (
                    "inst_v2_00000000000000000000000000000001"
                ),
            },
        ]
        for mode in modes:
            with self.subTest(mode=mode["MAP_PLATFORM_MAP_STREAM_ROLLOUT_MODE"]):
                with patch.dict(
                    os.environ,
                    {
                        **mode,
                        "MAP_PLATFORM_MAP_STREAM_PROMOTION_ID": "",
                        "MAP_PLATFORM_MAP_STREAM_ROLLOUT_APPROVALS": missing,
                        "MAP_PLATFORM_MAP_STREAM_TRUST_REGISTRY": missing,
                        "MAP_PLATFORM_MAP_STREAM_HARDWARE_REQUIREMENTS": missing,
                    },
                    clear=False,
                ):
                    client = TestClient(create_app())
                    try:
                        self.assertEqual(client.get("/healthz").status_code, 200)
                    finally:
                        client.close()

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

    def test_artifact_url_refresh_is_identity_bound_and_downloads_immutable_object(self):
        installation = self.client.post("/v1/installations").json()
        installation_id = installation["clientInstallationId"]
        installation_token = installation["clientInstallationToken"]
        installation_headers = {"X-Installation-Token": installation_token}
        response = self.client.post(
            "/v1/map-jobs",
            json={
                "mode": "custom_bbox",
                "bbox": [103.75, 1.24, 103.93, 1.37],
                "clientInstallationId": installation_id,
                "clientRequestId": "request-artifact-123",
            },
            headers=installation_headers,
        )
        self.assertEqual(response.status_code, 200)
        job_id = response.json()["jobId"]
        source = Path(self.tmp.name) / "built.bmap"
        source.write_bytes(b"immutable-bike-map-stream")
        sha256 = hashlib.sha256(source.read_bytes()).hexdigest()
        receipt = "4" * 64
        object_key = (
            "maps/map-artifact/bike-map-stream-v1/map-prod-1/"
            f"{self.trust_key_sha256}/{'6' * 64}/{'8' * 64}/{receipt}.bmap"
        )
        self.client.app.state.artifact_store.put(
            source,
            object_key,
            sha256=sha256,
            media_type="application/vnd.openbikecomputer.map-stream",
        )
        self.update_job(
            job_id,
            status="ready",
            mapId="map-artifact",
            artifacts=[
                {
                    "format": "bike-map-stream-v1",
                    "mediaType": "application/vnd.openbikecomputer.map-stream",
                    "filename": "map-artifact.bmap",
                    "objectKey": object_key,
                    "bytes": source.stat().st_size,
                    "sha256": sha256,
                    "manifestReceipt": "3" * 64,
                    "signedManifestReceipt": receipt,
                    "signatureKeyId": "map-prod-1",
                    "signatureKeySha256": self.trust_key_sha256,
                    "producerBuildSha256": "6" * 64,
                    "producerImageDigest": self.worker_image_digest,
                }
            ],
        )
        self.assertEqual(
            self.client.get(
                "/v1/map-jobs",
                params={"clientInstallationId": installation_id},
            ).status_code,
            401,
        )
        self.assertEqual(
            self.client.get(
                "/v1/map-packs/map-artifact",
                params={"clientInstallationId": installation_id},
            ).status_code,
            401,
        )

        signed = self.client.post(
            "/v1/map-packs/map-artifact/artifacts/bike-map-stream-v1/download-url",
            params={
                "clientInstallationId": installation_id,
                "jobId": job_id,
                "signedManifestReceipt": receipt,
            },
            headers=installation_headers,
        )
        self.assertEqual(signed.status_code, 200)
        self.assertEqual(signed.json()["signedManifestReceipt"], receipt)
        self.assertEqual(signed.json()["sha256"], sha256)
        self.assertEqual(signed.json()["requiredIosBuild"], "100")
        self.assertEqual(signed.json()["requiredIosGitSha"], self.ios_git_sha)
        self.assertEqual(
            signed.json()["requiredIosBuildSha256"], self.ios_build_sha256
        )
        self.assertEqual(signed.json()["requiredFirmwareVersion"], "0.3.0")
        self.assertEqual(signed.json()["requiredFirmwareBuild"], 42)
        self.assertEqual(signed.json()["requiredFirmwareGitSha"], "7" * 40)
        downloaded = self.client.get(signed.json()["url"])
        self.assertEqual(downloaded.status_code, 200)
        self.assertEqual(downloaded.content, source.read_bytes())
        tampered_url = signed.json()["url"].replace("signature=", "signature=0", 1)
        self.assertEqual(self.client.get(tampered_url).status_code, 403)

        wrong_identity = self.client.post(
            "/v1/map-packs/map-artifact/artifacts/bike-map-stream-v1/download-url",
            params={
                "clientInstallationId": installation_id,
                "jobId": job_id,
                "signedManifestReceipt": "5" * 64,
            },
            headers=installation_headers,
        )
        wrong_app_build = self.client.post(
            "/v1/map-packs/map-artifact/artifacts/bike-map-stream-v1/download-url",
            params={
                "clientInstallationId": installation_id,
                "jobId": job_id,
                "signedManifestReceipt": receipt,
            },
            headers={
                **installation_headers,
                "X-Map-Stream-App-Build": "101",
            },
        )
        wrong_app_binary = self.client.post(
            "/v1/map-packs/map-artifact/artifacts/bike-map-stream-v1/download-url",
            params={
                "clientInstallationId": installation_id,
                "jobId": job_id,
                "signedManifestReceipt": receipt,
            },
            headers={
                **installation_headers,
                "X-Map-Stream-App-Build-Sha256": "b" * 64,
            },
        )
        other_installation = self.client.post(
            "/v1/map-packs/map-artifact/artifacts/bike-map-stream-v1/download-url",
            params={
                "clientInstallationId": installation_id,
                "jobId": job_id,
            },
            headers={"X-Installation-Token": "wrong-installation-token"},
        )
        missing_identity = self.client.post(
            "/v1/map-packs/map-artifact/artifacts/bike-map-stream-v1/download-url",
            params={
                "clientInstallationId": installation_id,
                "jobId": job_id,
            },
            headers=installation_headers,
        )
        self.assertEqual(wrong_identity.status_code, 404)
        self.assertEqual(wrong_app_build.status_code, 404)
        self.assertEqual(wrong_app_binary.status_code, 404)
        self.assertEqual(other_installation.status_code, 401)
        self.assertEqual(missing_identity.status_code, 400)

    def test_stream_artifacts_are_hidden_outside_the_rollout_cohort(self):
        allowed = self.client.post("/v1/installations").json()
        blocked = self.client.post("/v1/installations").json()
        with patch.dict(
            os.environ,
            {
                "MAP_PLATFORM_MAP_STREAM_ROLLOUT_MODE": "allowlist",
                "MAP_PLATFORM_MAP_STREAM_ROLLOUT_ALLOWLIST": allowed[
                    "clientInstallationId"
                ],
                "MAP_PLATFORM_MAP_STREAM_ROLLOUT_BASIS_POINTS": "0",
                "MAP_PLATFORM_MAP_STREAM_ROLLOUT_SECRET": "",
                "MAP_PLATFORM_MAP_STREAM_PROMOTION_ID": "",
            },
            clear=False,
        ):
            rollout_client = TestClient(create_app())
            rollout_client.headers["X-Map-Stream-Trust"] = self.stream_trust_header
            rollout_client.headers["X-Map-Stream-App-Build"] = "100"
            rollout_client.headers["X-Map-Stream-App-Git-Sha"] = self.ios_git_sha
            rollout_client.headers["X-Map-Stream-App-Build-Sha256"] = (
                self.ios_build_sha256
            )
        try:
            jobs = []
            for owner, request_id in (
                (allowed, "request-rollout-allowed"),
                (blocked, "request-rollout-blocked"),
            ):
                response = rollout_client.post(
                    "/v1/map-jobs",
                    json={
                        "mode": "custom_bbox",
                        "bbox": [103.75, 1.24, 103.93, 1.37],
                        "clientInstallationId": owner["clientInstallationId"],
                        "clientRequestId": request_id,
                    },
                    headers={
                        "X-Installation-Token": owner["clientInstallationToken"]
                    },
                )
                self.assertEqual(response.status_code, 200)
                jobs.append((owner, response.json()["jobId"]))

            receipt = "9" * 64
            artifacts = [
                {
                    "format": "bike-map-stream-v1",
                    "mediaType": "application/vnd.openbikecomputer.map-stream",
                    "filename": "map-rollout.bmap",
                    "objectKey": (
                        "maps/map-rollout/bike-map-stream-v1/"
                        f"map-prod-1/{self.trust_key_sha256}/"
                        f"{'6' * 64}/{'8' * 64}/{receipt}.bmap"
                    ),
                    "bytes": 123,
                    "sha256": "a" * 64,
                    "manifestReceipt": "b" * 64,
                    "signedManifestReceipt": receipt,
                    "signatureKeyId": "map-prod-1",
                    "signatureKeySha256": self.trust_key_sha256,
                    "producerBuildSha256": "6" * 64,
                    "producerImageDigest": self.worker_image_digest,
                },
                {
                    "format": "zip-stored-v1",
                    "mediaType": "application/zip",
                    "filename": "map-rollout.zip",
                    "objectKey": "maps/map-rollout/zip-stored-v1/archive.zip",
                    "bytes": 456,
                    "sha256": "c" * 64,
                },
            ]
            for _, job_id in jobs:
                self.update_job(
                    job_id,
                    status="ready",
                    mapId="map-rollout",
                    artifacts=artifacts,
                    artifactMetrics={
                        "streamPayloadBytes": 123,
                        "streamSignatureKeyId": "map-prod-1",
                        "zipHashingSeconds": 1.5,
                    },
                )

            responses = []
            for owner, job_id in jobs:
                responses.append(
                    rollout_client.get(
                        f"/v1/map-jobs/{job_id}",
                        params={
                            "clientInstallationId": owner["clientInstallationId"]
                        },
                        headers={
                            "X-Installation-Token": owner[
                                "clientInstallationToken"
                            ]
                        },
                    )
                )
            self.assertEqual(
                [value["format"] for value in responses[0].json()["artifacts"]],
                ["bike-map-stream-v1", "zip-stored-v1"],
            )
            self.assertNotIn(
                "requiredFirmwareVersion",
                responses[0].json()["artifacts"][0],
            )
            self.assertEqual(
                [value["format"] for value in responses[1].json()["artifacts"]],
                ["zip-stored-v1"],
            )
            no_capability = rollout_client.get(
                f"/v1/map-jobs/{jobs[0][1]}",
                params={
                    "clientInstallationId": allowed["clientInstallationId"]
                },
                headers={
                    "X-Installation-Token": allowed["clientInstallationToken"],
                    "X-Map-Stream-Trust": "",
                },
            )
            self.assertEqual(no_capability.status_code, 200)
            self.assertEqual(
                [
                    value["format"]
                    for value in no_capability.json()["artifacts"]
                ],
                ["zip-stored-v1"],
            )
            invalid_capability = rollout_client.get(
                f"/v1/map-jobs/{jobs[0][1]}",
                params={
                    "clientInstallationId": allowed["clientInstallationId"]
                },
                headers={
                    "X-Installation-Token": allowed["clientInstallationToken"],
                    "X-Map-Stream-Trust": "malformed",
                },
            )
            self.assertEqual(invalid_capability.status_code, 400)
            self.assertEqual(
                responses[1].json()["artifactMetrics"],
                {"zipHashingSeconds": 1.5},
            )

            blocked_refresh = rollout_client.post(
                "/v1/map-packs/map-rollout/artifacts/"
                "bike-map-stream-v1/download-url",
                params={
                    "clientInstallationId": blocked["clientInstallationId"],
                    "jobId": jobs[1][1],
                    "signedManifestReceipt": receipt,
                },
                headers={
                    "X-Installation-Token": blocked["clientInstallationToken"]
                },
            )
            self.assertEqual(blocked_refresh.status_code, 404)
            self.assertEqual(
                rollout_client.get("/healthz").json()["mapStreamRollout"],
                {"mode": "allowlist", "allowlistCount": 1},
            )
        finally:
            rollout_client.close()

    def test_malformed_stream_headers_are_rejected_before_reads_or_mutations(self):
        jobs_root = Path(self.tmp.name) / "jobs"
        before = len(list(jobs_root.glob("*.json"))) if jobs_root.exists() else 0
        malformed_create = self.client.post(
            "/v1/map-jobs",
            json={"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]},
            headers={"X-Map-Stream-Trust": "malformed"},
        )
        self.assertEqual(malformed_create.status_code, 400)
        after = len(list(jobs_root.glob("*.json"))) if jobs_root.exists() else 0
        self.assertEqual(after, before)

        job_id = self.create_job()
        malformed_cancel = self.client.post(
            f"/v1/map-jobs/{job_id}/cancel",
            headers={"X-Map-Stream-App-Build": "not-a-build"},
        )
        self.assertEqual(malformed_cancel.status_code, 400)
        self.assertEqual(
            self.client.get(f"/v1/map-jobs/{job_id}").json()["status"],
            "queued",
        )

        incomplete_identity = self.client.post(
            f"/v1/map-jobs/{job_id}/cancel",
            headers={
                "X-Map-Stream-App-Build": "100",
                "X-Map-Stream-App-Git-Sha": "",
                "X-Map-Stream-App-Build-Sha256": "",
            },
        )
        self.assertEqual(incomplete_identity.status_code, 400)
        self.assertEqual(
            self.client.get(f"/v1/map-jobs/{job_id}").json()["status"],
            "queued",
        )

        installation = self.client.post("/v1/installations").json()
        malformed_empty_list = self.client.get(
            "/v1/map-jobs",
            params={"clientInstallationId": installation["clientInstallationId"]},
            headers={
                "X-Installation-Token": installation["clientInstallationToken"],
                "X-Map-Stream-Trust": "malformed",
            },
        )
        self.assertEqual(malformed_empty_list.status_code, 400)

    def test_artifact_url_refresh_returns_object_store_presigned_url(self):
        class PresigningStore:
            def create_download_url(self, object_key, **options):
                return f"https://objects.invalid/{object_key}?ttl={options['expires_in_seconds']}"

            def local_path(self, object_key):
                return None

        with patch(
            "map_platform.api.create_artifact_store_from_environment",
            return_value=PresigningStore(),
        ):
            client = TestClient(create_app())
            client.headers["X-Map-Stream-Trust"] = self.stream_trust_header
            client.headers["X-Map-Stream-App-Build"] = "100"
            client.headers["X-Map-Stream-App-Git-Sha"] = self.ios_git_sha
            client.headers["X-Map-Stream-App-Build-Sha256"] = self.ios_build_sha256
        try:
            installation = client.post("/v1/installations").json()
            headers = {
                "X-Installation-Token": installation["clientInstallationToken"]
            }
            created = client.post(
                "/v1/map-jobs",
                json={
                    "mode": "custom_bbox",
                    "bbox": [103.75, 1.24, 103.93, 1.37],
                    "clientInstallationId": installation["clientInstallationId"],
                    "clientRequestId": "request-presign-123",
                },
                headers=headers,
            ).json()
            receipt = "6" * 64
            self.update_job(
                created["jobId"],
                status="ready",
                mapId="map-presigned",
                artifacts=[
                    {
                        "format": "bike-map-stream-v1",
                        "mediaType": "application/vnd.openbikecomputer.map-stream",
                        "filename": "map-presigned.bmap",
                        "objectKey": (
                            "maps/map-presigned/bike-map-stream-v1/"
                            f"map-prod-1/{self.trust_key_sha256}/"
                            f"{'6' * 64}/{'8' * 64}/{receipt}.bmap"
                        ),
                        "bytes": 123,
                        "sha256": "7" * 64,
                        "manifestReceipt": "8" * 64,
                        "signedManifestReceipt": receipt,
                        "signatureKeyId": "map-prod-1",
                        "signatureKeySha256": self.trust_key_sha256,
                        "producerBuildSha256": "6" * 64,
                        "producerImageDigest": self.worker_image_digest,
                    }
                ],
            )

            response = client.post(
                "/v1/map-packs/map-presigned/artifacts/bike-map-stream-v1/download-url",
                params={
                    "jobId": created["jobId"],
                    "clientInstallationId": installation["clientInstallationId"],
                    "signedManifestReceipt": receipt,
                },
                headers=headers,
            )
            self.assertEqual(response.status_code, 200)
            self.assertTrue(response.json()["url"].startswith("https://objects.invalid/"))
            self.assertIn("ttl=900", response.json()["url"])
        finally:
            client.close()

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
