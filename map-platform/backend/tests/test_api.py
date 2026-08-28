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

from app_attest_support import AppAttestTestClient
import map_platform.api as api_module
from map_platform.api import create_app
from map_platform.downloads import DownloadSigner
from map_platform.building_tasks import BuildingTaskSpec
from map_platform.models import JobStatus, MapJob


class BackendDependencyHintTests(unittest.TestCase):
    def test_missing_api_extra_uses_documented_backend_working_directory(self):
        with patch.object(
            api_module,
            "_FASTAPI_IMPORT_ERROR",
            ImportError("missing FastAPI"),
        ):
            with self.assertRaises(RuntimeError) as raised:
                api_module.create_app()

        command = "python -m pip install -e '.[api]'"
        self.assertIn(command, str(raised.exception))
        editable_target = command.split("'")[1].split("[", 1)[0]
        documented_working_directory = Path(__file__).resolve().parents[1]
        self.assertTrue(
            (documented_working_directory / editable_target / "pyproject.toml").is_file()
        )


class BuildingProgressProjectionTests(unittest.TestCase):
    def test_projection_adds_coordinator_fields_without_rewriting_legacy_counters(self):
        result = {
            "progress": {
                "phase": "block_encoding",
                "completedBlocks": 4,
                "totalBlocks": 9,
            }
        }
        coordinator_progress = {
            "phase": "building_chunks",
            "unit": "blocks",
            "completed": 7,
            "total": 12,
            "completedBlocks": 7,
            "totalBlocks": 12,
            "activeChunks": 1,
            "readyChunks": 2,
            "totalChunks": 5,
            "indeterminate": False,
            "state": "building_chunks",
        }

        api_module._project_building_progress(result, coordinator_progress)

        self.assertEqual(result["progress"]["phase"], "block_encoding")
        self.assertEqual(result["progress"]["completedBlocks"], 4)
        self.assertEqual(result["progress"]["totalBlocks"], 9)
        self.assertEqual(result["progress"]["activeChunks"], 1)
        self.assertEqual(result["progress"]["readyChunks"], 2)
        self.assertEqual(result["buildingProgress"], coordinator_progress)

    def test_projection_is_noop_without_a_durable_plan(self):
        result = {"progress": None}

        api_module._project_building_progress(result, None)

        self.assertEqual(result, {"progress": None})

    def test_shadow_observation_is_not_projected_as_executable_progress(self):
        result = {"progress": {"phase": "block_encoding", "completed": 2}}
        observation = {
            "phase": "observed",
            "state": "observed",
            "completed": 0,
            "total": 442,
        }

        api_module._project_building_progress(result, observation)

        self.assertEqual(
            result["progress"], {"phase": "block_encoding", "completed": 2}
        )
        self.assertNotIn("buildingProgress", result)
        self.assertEqual(result["buildingPlanObservation"], observation)


class MapJobRunAPITests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo_root = Path(__file__).resolve().parents[3]
        self.hardware_requirements_path = (
            self.repo_root
            / "map-platform"
            / "config"
            / "map-stream-hardware-gate.json"
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
                "MAP_PLATFORM_SOURCE_INDEX": str(
                    self.repo_root
                    / "map-platform"
                    / "backend"
                    / "config"
                    / "source-regions.json"
                ),
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
                "MAP_PLATFORM_DEPLOYMENT_CHANNEL": "production",
                "MAP_PLATFORM_LABEL_TARGET2_ENABLED": "0",
                "MAP_PLATFORM_BUILDING_TARGET3_ENABLED": "0",
                "MAP_PLATFORM_BUILDING_TARGET3_ALLOWLIST": "",
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
                "MAP_PLATFORM_PREPARATION_ESTIMATES_MODE": "off",
            },
            clear=False,
        )
        self.environment.start()
        self.app_attest = AppAttestTestClient()
        self.client = TestClient(
            create_app(app_attest_verifier=self.app_attest.verifier)
        )
        self.client.headers["X-Map-Stream-Trust"] = self.stream_trust_header
        self.client.headers["X-Map-Stream-App-Build"] = "100"
        self.client.headers["X-Map-Stream-App-Git-Sha"] = self.ios_git_sha
        self.client.headers["X-Map-Stream-App-Build-Sha256"] = self.ios_build_sha256
        self.installation = self.issue_installation(self.client)
        self.job_request_sequence = 0

    def tearDown(self):
        self.client.close()
        self.environment.stop()
        self.tmp.cleanup()

    def issue_installation(self, client: TestClient) -> dict[str, str]:
        response = self.app_attest.issue_installation(client)
        if not hasattr(response, "status_code"):
            return response
        self.assertEqual(response.status_code, 200)
        return response.json()

    @staticmethod
    def installation_headers(
        credential: dict[str, str],
        **extra: str,
    ) -> dict[str, str]:
        return {
            "X-Installation-Token": credential["clientInstallationToken"],
            **extra,
        }

    @staticmethod
    def installation_params(credential: dict[str, str]) -> dict[str, str]:
        return {"clientInstallationId": credential["clientInstallationId"]}

    def post_map_job(
        self,
        payload: dict | None = None,
        *,
        client: TestClient | None = None,
        credential: dict[str, str] | None = None,
        headers: dict[str, str] | None = None,
    ):
        self.job_request_sequence += 1
        request_payload = dict(
            payload
            or {
                "mode": "custom_bbox",
                "bbox": [103.75, 1.24, 103.93, 1.37],
            }
        )
        request_credential = credential or self.installation
        request_payload.setdefault(
            "clientInstallationId",
            request_credential["clientInstallationId"],
        )
        request_payload.setdefault(
            "clientRequestId",
            f"request-test-{self.job_request_sequence:08d}",
        )
        return self.app_attest.post_map_job(
            client or self.client,
            credential=request_credential,
            payload=request_payload,
            headers=headers,
        )

    def create_job(self) -> str:
        response = self.post_map_job()
        self.assertEqual(response.status_code, 200)
        return response.json()["jobId"]

    def test_admin_building_plan_alerts_is_authenticated_and_read_only(self):
        task_store = self.client.app.state.building_task_store
        task_store.create_plan(
            parent_job_id="job-admin-alerts",
            global_plan_sha256="b" * 64,
            input_identity={},
            expected_output_block_count=1,
            policy_version=1,
            resource_model_version="v1",
        )
        task_store.add_tasks(
            [
                BuildingTaskSpec(
                    task_id="task-admin-alerts",
                    parent_job_id="job-admin-alerts",
                    kind="building_chunk",
                    blocks=((1, 1),),
                    chunk_plan_sha256="b" * 64,
                )
            ]
        )
        reservation = task_store.acquire_parent_phase_reservation(
            parent_job_id="job-admin-alerts",
            phase="source_preparation",
            worker_id="worker-admin-alerts",
            worker_capability={
                "memoryLimitBytes": 12_000_000_000,
                "cpuCount": 1,
                "resourcePool": "admin-alerts",
                "maxConcurrentTasks": 1,
            },
            lease_seconds=1,
            now=1.0,
        )
        self.assertIsNotNone(reservation)

        denied = self.client.get("/v1/admin/building-plans/job-admin-alerts/alerts")
        self.assertEqual(denied.status_code, 401)
        response = self.client.get(
            "/v1/admin/building-plans/job-admin-alerts/alerts",
            headers={"Authorization": "Bearer admin-secret"},
        )
        self.assertEqual(response.status_code, 200)
        document = response.json()
        self.assertEqual(document["page"]["limit"], 100)
        self.assertIn(
            "parent_phase_lease_expired",
            {alert["code"] for alert in document["alerts"]},
        )
        self.assertEqual(task_store.get_plan("job-admin-alerts")["state"], "planning")

        rejected = self.client.get(
            "/v1/admin/building-plans/job-admin-alerts/alerts?limit=101",
            headers={"Authorization": "Bearer admin-secret"},
        )
        self.assertEqual(rejected.status_code, 400)

    def test_admin_building_plan_diagnostics_are_bounded_and_summarized(self):
        task_store = self.client.app.state.building_task_store
        task_store.create_plan(
            parent_job_id="job-admin-page",
            global_plan_sha256="b" * 64,
            input_identity={},
            expected_output_block_count=2,
            policy_version=1,
            resource_model_version="v1",
        )
        task_store.add_tasks(
            [
                BuildingTaskSpec(
                    task_id=f"task-admin-page-{index}",
                    parent_job_id="job-admin-page",
                    kind="building_chunk",
                    blocks=((index, 1),),
                    chunk_plan_sha256="b" * 64,
                )
                for index in range(2)
            ]
        )
        oversized_workload = json.dumps({"objectKeys": "x" * 2_000_000})
        connection = sqlite3.connect(task_store.path)
        connection.execute(
            """
            INSERT INTO map_build_workload_receipts(
                task_id, parent_job_id, closure_plan_sha256,
                source_index_identity_json, workload_json, recorded_at
            ) VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                "task-admin-page-0",
                "job-admin-page",
                "c" * 64,
                "{}",
                oversized_workload,
                1.0,
            ),
        )
        connection.commit()
        connection.close()
        capability = {
            "memoryLimitBytes": 12_000_000_000,
            "cpuCount": 1,
            "resourcePool": "admin-page",
            "maxConcurrentTasks": 1,
        }
        reservation = task_store.acquire_parent_phase_reservation(
            parent_job_id="job-admin-page",
            phase="source_preparation",
            worker_id="worker-admin-page",
            worker_capability=capability,
        )
        self.assertIsNotNone(reservation)

        response = self.client.get(
            "/v1/admin/building-plans/job-admin-page?limit=1&offset=0",
            headers={"Authorization": "Bearer admin-secret"},
        )

        self.assertEqual(response.status_code, 200)
        document = response.json()
        self.assertEqual(document["page"]["limit"], 1)
        self.assertEqual(document["page"]["counts"]["tasks"], 2)
        self.assertTrue(document["page"]["hasMore"])
        self.assertEqual(len(document["tasks"]), 1)
        self.assertEqual(len(document["attempts"]), 0)
        self.assertEqual(len(document["parentPhaseReservations"]), 1)
        self.assertEqual(
            document["parentPhaseReservations"][0]["phase"],
            "source_preparation",
        )
        self.assertNotIn(
            "lease_token", document["parentPhaseReservations"][0]
        )
        self.assertNotIn(reservation.lease_token, response.text)
        self.assertEqual(len(document["workloadReceipts"]), 1)
        self.assertGreater(
            document["workloadReceipts"][0]["workload_bytes"],
            2_000_000,
        )
        self.assertTrue(
            all("workload_json" not in row for row in document["workloadReceipts"])
        )
        self.assertLess(len(response.content), 50_000)

        task_store.release_parent_phase_reservation(
            parent_job_id="job-admin-page",
            phase="source_preparation",
            worker_id="worker-admin-page",
            lease_token=reservation.lease_token,
        )
        claimed = task_store.claim_next(
            worker_id="worker-admin-child",
            parent_job_id="job-admin-page",
            worker_capability=capability,
        )
        self.assertIsNotNone(claimed)
        assert claimed is not None

        active_response = self.client.get(
            "/v1/admin/building-plans/job-admin-page?limit=1&offset=0",
            headers={"Authorization": "Bearer admin-secret"},
        )

        self.assertEqual(active_response.status_code, 200)
        active_document = active_response.json()
        self.assertNotIn("lease_token", active_document["tasks"][0])
        self.assertEqual(len(active_document["resourceReservations"]), 1)
        self.assertNotIn(
            "lease_token", active_document["resourceReservations"][0]
        )
        self.assertNotIn(claimed.lease_token, active_response.text)
        self.assertEqual(
            task_store.get_task(claimed.task.task_id).lease_token,
            claimed.lease_token,
        )

        rejected = self.client.get(
            "/v1/admin/building-plans/job-admin-page?limit=101",
            headers={"Authorization": "Bearer admin-secret"},
        )
        self.assertEqual(rejected.status_code, 400)

    def test_preparation_estimate_rollout_modes_control_public_field(self):
        observations = {}
        for mode in ("off", "shadow", "public"):
            data_root = Path(self.tmp.name) / f"estimate-mode-{mode}"
            with patch.dict(
                os.environ,
                {
                    "MAP_PLATFORM_DATA_ROOT": str(data_root),
                    "MAP_PLATFORM_PREPARATION_ESTIMATES_MODE": mode,
                    "MAP_PLATFORM_ESTIMATOR_WORKER_CLASS": "api-test",
                },
                clear=False,
            ):
                client = TestClient(
                    create_app(app_attest_verifier=self.app_attest.verifier)
                )
                try:
                    credential = self.issue_installation(client)
                    response = self.post_map_job(
                        {
                            "mode": "custom_bbox",
                            "bbox": [103.75, 1.24, 103.93, 1.37],
                        },
                        client=client,
                        credential=credential,
                    )
                    self.assertEqual(response.status_code, 200)
                    payload = response.json()
                    stored = client.app.state.job_store.get(payload["jobId"])
                    observations[mode] = (
                        "preparationEstimate" in payload,
                        stored.preparation_estimate is not None,
                    )
                finally:
                    client.close()

        self.assertEqual(observations["off"], (False, False))
        self.assertEqual(observations["shadow"], (False, True))
        self.assertEqual(observations["public"], (True, True))

    def test_production_policy_enables_target_two_globally(self):
        payload = {
            "mode": "custom_bbox",
            "bbox": [103.75, 1.24, 103.93, 1.37],
            "target": {
                "renderer": "esp32-fmb",
                "rendererFormatVersion": 2,
                "firmwareVersion": "1.2.3",
            },
            "labels": {
                "profileVersion": 1,
                "preferredLanguages": ["en"],
                "internationalFallback": "en",
            },
        }
        enabled = self.post_map_job(payload)
        self.assertEqual(enabled.status_code, 200)

    def test_target_three_is_globally_available_after_production_promotion(self):
        credential = self.issue_installation(self.client)
        payload = {
            "mode": "custom_bbox",
            "bbox": [103.75, 1.24, 103.93, 1.37],
            "target": {
                "renderer": "esp32-fmb",
                "rendererFormatVersion": 3,
                "firmwareVersion": "1.2.3",
            },
            "labels": {
                "profileVersion": 1,
                "preferredLanguages": ["en"],
                "internationalFallback": "en",
            },
            "clientInstallationId": credential["clientInstallationId"],
            "clientRequestId": "request-target3-global",
        }
        response = self.app_attest.post_map_job(
            self.client,
            credential=credential,
            payload=payload,
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            self.client.app.state.job_store.get(response.json()["jobId"])
            .request["target"]["rendererFormatVersion"],
            3,
        )

    def test_capabilities_are_authenticated_and_channel_scoped(self):
        credential = self.issue_installation(self.client)
        params = {
            "clientInstallationId": credential["clientInstallationId"],
        }
        unauthenticated = self.client.get("/v1/capabilities", params=params)
        self.assertEqual(unauthenticated.status_code, 401)

        production = self.client.get(
            "/v1/capabilities",
            params=params,
            headers={
                "X-Installation-Token": credential["clientInstallationToken"],
            },
        )
        self.assertEqual(production.status_code, 200)
        self.assertEqual(production.headers["Cache-Control"], "private, no-store")
        payload = production.json()
        self.assertEqual(payload["schemaVersion"], 1)
        self.assertEqual(payload["deploymentChannel"], "production")
        self.assertRegex(payload["policySha256"], r"^[0-9a-f]{64}$")
        self.assertEqual(
            [
                profile["rendererFormatVersion"]
                for profile in payload["generationProfiles"]
            ],
            [3, 2, 1],
        )

        with patch.dict(
            os.environ,
            {
                "MAP_PLATFORM_BUILDING_TARGET3_ALLOWLIST": credential[
                    "clientInstallationId"
                ],
            },
            clear=False,
        ):
            canary_client = TestClient(
                create_app(app_attest_verifier=self.app_attest.verifier)
            )
            try:
                canary = canary_client.get(
                    "/v1/capabilities",
                    params=params,
                    headers={
                        "X-Installation-Token": credential[
                            "clientInstallationToken"
                        ],
                    },
                )
            finally:
                canary_client.close()
        self.assertEqual(canary.status_code, 200)
        self.assertEqual(
            [
                profile["rendererFormatVersion"]
                for profile in canary.json()["generationProfiles"]
            ],
            [3, 2, 1],
        )

        with patch.dict(
            os.environ,
            {
                "MAP_PLATFORM_DEPLOYMENT_CHANNEL": "development",
                "MAP_PLATFORM_DATA_ROOT": str(Path(self.tmp.name) / "development"),
            },
            clear=False,
        ):
            development_client = TestClient(
                create_app(app_attest_verifier=self.app_attest.verifier)
            )
            try:
                development_credential = self.issue_installation(
                    development_client
                )
                development = development_client.get(
                    "/v1/capabilities",
                    params={
                        "clientInstallationId": development_credential[
                            "clientInstallationId"
                        ],
                    },
                    headers={
                        "X-Installation-Token": development_credential[
                            "clientInstallationToken"
                        ],
                    },
                )
            finally:
                development_client.close()
        self.assertEqual(development.status_code, 200)
        self.assertEqual(development.json()["deploymentChannel"], "development")
        self.assertEqual(
            [
                profile["rendererFormatVersion"]
                for profile in development.json()["generationProfiles"]
            ],
            [3, 2, 1],
        )

    def update_job(self, job_id: str, **values) -> None:
        job_path = Path(self.tmp.name) / "jobs" / f"{job_id}.json"
        job = json.loads(job_path.read_text())
        job.update(values)
        self.client.app.state.job_store.save(MapJob.from_dict(job))

    def test_installation_attestation_challenge_is_public_but_rate_limited(self):
        limited_root = Path(self.tmp.name) / "installation-limit"
        with patch.dict(
            os.environ,
            {
                "MAP_PLATFORM_DATA_ROOT": str(limited_root),
                "MAP_PLATFORM_INSTALLATION_ISSUE_LIMIT_PER_DAY": "1",
            },
            clear=False,
        ):
            client = TestClient(
                create_app(app_attest_verifier=self.app_attest.verifier)
            )
            try:
                first = self.app_attest.issue_installation(client)
                blocked = self.app_attest.issue_installation(client)
            finally:
                client.close()

        self.assertIsInstance(first, dict)
        self.assertEqual(blocked.status_code, 429)
        self.assertEqual(blocked.json()["detail"], "request rate limit exceeded")
        self.assertGreater(int(blocked.headers["Retry-After"]), 0)

    def test_installation_issuance_requires_app_attest(self):
        response = self.client.post("/v1/installations")

        self.assertEqual(response.status_code, 401)
        self.assertEqual(
            response.json()["detail"]["code"],
            "installation_attestation_required",
        )
        self.assertEqual(response.headers["Cache-Control"], "private, no-store")

    def test_new_map_work_requires_assertion_but_idempotent_replay_does_not(self):
        payload = {
            "mode": "custom_bbox",
            "bbox": [103.75, 1.24, 103.93, 1.37],
            "clientInstallationId": self.installation["clientInstallationId"],
            "clientRequestId": "request-app-attest-gate",
        }
        missing_assertion = self.client.post(
            "/v1/map-jobs",
            headers=self.installation_headers(self.installation),
            json=payload,
        )
        created = self.app_attest.post_map_job(
            self.client,
            credential=self.installation,
            payload=payload,
        )
        replay = self.client.post(
            "/v1/map-jobs",
            headers=self.installation_headers(self.installation),
            json=payload,
        )

        self.assertEqual(missing_assertion.status_code, 401)
        self.assertEqual(
            missing_assertion.json()["detail"]["code"],
            "app_attest_assertion_required",
        )
        self.assertEqual(created.status_code, 200)
        self.assertEqual(replay.status_code, 200)
        self.assertEqual(replay.json()["jobId"], created.json()["jobId"])

    def test_unattested_stateless_credential_cannot_request_map_challenge(self):
        from map_platform.installations import InstallationCredentialStore

        installation_id, token = InstallationCredentialStore(
            "test-installation-secret-32-bytes-minimum"
        ).issue()
        response = self.client.post(
            "/v1/installations/app-attest/challenges",
            headers={"X-Installation-Token": token},
            json={
                "purpose": "map-create",
                "clientInstallationId": installation_id,
            },
        )

        self.assertEqual(response.status_code, 401)
        self.assertEqual(
            response.json()["detail"]["code"],
            "installation_attestation_required",
        )

    def test_installation_token_refresh_preserves_identity_across_rotation(self):
        from map_platform.installations import InstallationCredentialStore

        old_secret = "old-installation-secret-at-least-32-bytes"
        new_secret = "new-installation-secret-at-least-32-bytes"
        rotated_root = Path(self.tmp.name) / "installation-rotation"
        with patch.dict(
            os.environ,
            {
                "MAP_PLATFORM_DATA_ROOT": str(rotated_root),
                "MAP_PLATFORM_INSTALLATION_SECRET": old_secret,
                "MAP_PLATFORM_INSTALLATION_PREVIOUS_SECRETS": "",
                "MAP_PLATFORM_INSTALLATION_ISSUE_LIMIT_PER_DAY": "10000",
            },
            clear=False,
        ):
            old_client = TestClient(
                create_app(app_attest_verifier=self.app_attest.verifier)
            )
            try:
                original = self.issue_installation(old_client)
            finally:
                old_client.close()

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
            client = TestClient(
                create_app(app_attest_verifier=self.app_attest.verifier)
            )
            try:
                refreshed = client.post(
                    "/v1/installations",
                    params={
                        "clientInstallationId": original[
                            "clientInstallationId"
                        ]
                    },
                    headers={
                        "X-Installation-Token": original[
                            "clientInstallationToken"
                        ]
                    },
                )
                newly_issued = self.app_attest.issue_installation(client)
                blocked_new_issue = self.app_attest.issue_installation(client)
            finally:
                client.close()

        self.assertEqual(refreshed.status_code, 200)
        self.assertEqual(
            refreshed.json()["clientInstallationId"],
            original["clientInstallationId"],
        )
        refreshed_token = refreshed.json()["clientInstallationToken"]
        self.assertNotEqual(refreshed_token, original["clientInstallationToken"])
        InstallationCredentialStore(new_secret).verify(
            original["clientInstallationId"], refreshed_token
        )
        self.assertIsInstance(newly_issued, dict)
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
            client = TestClient(
                create_app(app_attest_verifier=self.app_attest.verifier)
            )
            try:
                credential = self.issue_installation(client)
                headers = {
                    "X-Installation-Token": credential["clientInstallationToken"]
                }
                payload = {
                    "mode": "custom_bbox",
                    "bbox": [103.75, 1.24, 103.93, 1.37],
                    "clientInstallationId": credential["clientInstallationId"],
                    "clientRequestId": "rate-limit-request-1",
                }
                first = self.app_attest.post_map_job(
                    client,
                    credential=credential,
                    payload=payload,
                )
                replay = client.post("/v1/map-jobs", headers=headers, json=payload)
                payload["clientRequestId"] = "rate-limit-request-2"
                blocked = self.app_attest.post_map_job(
                    client,
                    credential=credential,
                    payload=payload,
                )
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
            app = create_app(app_attest_verifier=self.app_attest.verifier)
            clients = [TestClient(app), TestClient(app)]
            try:
                credential = self.issue_installation(clients[0])
                payload = {
                    "mode": "custom_bbox",
                    "bbox": [103.75, 1.24, 103.93, 1.37],
                    "clientInstallationId": credential["clientInstallationId"],
                    "clientRequestId": "concurrent-rate-request",
                }
                barrier = Barrier(2)

                def create(client):
                    barrier.wait(timeout=5)
                    return self.app_attest.post_map_job(
                        client,
                        credential=credential,
                        payload=payload,
                    )

                with ThreadPoolExecutor(max_workers=2) as executor:
                    responses = list(executor.map(create, clients))
                blocked = self.app_attest.post_map_job(
                    clients[0],
                    credential=credential,
                    payload={
                        **payload,
                        "clientRequestId": "new-rate-request",
                    },
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
            client = TestClient(
                create_app(app_attest_verifier=self.app_attest.verifier)
            )
            try:
                credential = self.issue_installation(client)
                headers = {
                    "X-Installation-Token": credential["clientInstallationToken"]
                }
                created = self.app_attest.post_map_job(
                    client,
                    credential=credential,
                    payload={
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

    def test_anonymous_map_creation_is_rejected_before_quota_consumption(self):
        limited_root = Path(self.tmp.name) / "anonymous-map-create-limit"
        with patch.dict(
            os.environ,
            {
                "MAP_PLATFORM_DATA_ROOT": str(limited_root),
                "MAP_PLATFORM_MAP_CREATE_IP_LIMIT_PER_DAY": "1",
            },
            clear=False,
        ):
            client = TestClient(
                create_app(app_attest_verifier=self.app_attest.verifier)
            )
            try:
                payload = {
                    "mode": "custom_bbox",
                    "bbox": [103.75, 1.24, 103.93, 1.37],
                }
                first = client.post("/v1/map-jobs", json=payload)
                blocked = client.post("/v1/map-jobs", json=payload)
            finally:
                client.close()

        self.assertEqual(first.status_code, 401)
        self.assertEqual(blocked.status_code, 401)
        self.assertEqual(
            first.json()["detail"],
            "installation credential is required",
        )
        with sqlite3.connect(limited_root / "rate-limits.sqlite3") as connection:
            consumed = connection.execute(
                "SELECT COUNT(*) FROM rate_limits WHERE scope LIKE 'map-create-%'"
            ).fetchone()[0]
        self.assertEqual(consumed, 0)

    def test_map_creation_rejects_unknown_fields_and_oversized_bodies(self):
        unknown = self.post_map_job(
            {
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
            client = TestClient(
                create_app(app_attest_verifier=self.app_attest.verifier)
            )
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
        response = self.post_map_job(
            {
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
            client = TestClient(
                create_app(app_attest_verifier=self.app_attest.verifier)
            )
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
        credential = self.issue_installation(self.client)
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
        credential = self.issue_installation(self.client)
        installation_id = credential["clientInstallationId"]
        installation_headers = {
            "X-Installation-Token": credential["clientInstallationToken"]
        }
        created = self.app_attest.post_map_job(
            self.client,
            credential=credential,
            payload={
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

    def test_admin_map_monitoring_is_authenticated_and_restart_safe(self):
        job_id = self.create_job()
        job = self.client.app.state.job_store.get(job_id)
        job.status = JobStatus.READY
        job.started_at = job.created_at
        job.finished_at = job.created_at
        job.updated_at = job.created_at
        job.events = [
            {"at": job.created_at, "status": JobStatus.VALIDATING.value},
            {"at": job.created_at, "status": JobStatus.READY.value},
        ]
        self.client.app.state.job_store.save(job)
        self.client.app.state.monitoring_store.record_job(job)

        unauthorized = self.client.get("/v1/admin/map-monitoring")
        with patch.object(
            self.client.app.state.job_store,
            "list",
            side_effect=AssertionError("monitoring GET must not reconcile job files"),
        ):
            response = self.client.get(
                "/v1/admin/map-monitoring",
                headers={"Authorization": "Bearer admin-secret"},
            )

        self.assertEqual(unauthorized.status_code, 401)
        self.assertEqual(response.status_code, 200)
        document = response.json()
        self.assertEqual(document["runs"]["count"], 1)
        self.assertEqual(document["runs"]["byStatus"], {"ready": 1})
        self.assertEqual(document["serverTiming"]["processingSeconds"]["p50Seconds"], 0.0)
        self.assertEqual(document["byRendererFormat"]["1"]["runs"]["count"], 1)

    def test_inventory_mutations_require_the_owning_registered_installation(self):
        owner = self.issue_installation(self.client)
        stranger = self.issue_installation(self.client)
        created = self.app_attest.post_map_job(
            self.client,
            credential=owner,
            payload={
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
                params=self.installation_params(self.installation),
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
            client = TestClient(
                create_app(app_attest_verifier=self.app_attest.verifier)
            )
            try:
                created = self.post_map_job(
                    {
                        "mode": "custom_bbox",
                        "bbox": [103.75, 1.24, 103.93, 1.37],
                    },
                    client=client,
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
                    client = TestClient(
                        create_app(app_attest_verifier=self.app_attest.verifier)
                    )
                    try:
                        self.assertEqual(client.get("/healthz").status_code, 200)
                    finally:
                        client.close()

    def test_same_map_jobs_publish_and_download_exact_job_artifacts(self):
        def create_owned(request_id: str) -> str:
            response = self.post_map_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.75, 1.24, 103.93, 1.37],
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
                    "clientInstallationId": self.installation[
                        "clientInstallationId"
                    ],
                    "jobId": job_id,
                },
                headers=self.installation_headers(self.installation),
            )
            self.assertEqual(signed.status_code, 200)
            downloaded = self.client.get(signed.json()["url"])
            self.assertEqual(downloaded.status_code, 200)
            self.assertEqual(downloaded.content, expected)
        self.assertNotEqual(pack_paths[0], pack_paths[1])

    def test_artifact_url_refresh_is_identity_bound_and_downloads_immutable_object(self):
        installation = self.issue_installation(self.client)
        installation_id = installation["clientInstallationId"]
        installation_token = installation["clientInstallationToken"]
        installation_headers = {"X-Installation-Token": installation_token}
        response = self.app_attest.post_map_job(
            self.client,
            credential=installation,
            payload={
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
        allowed = self.issue_installation(self.client)
        blocked = self.issue_installation(self.client)
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
            rollout_client = TestClient(
                create_app(app_attest_verifier=self.app_attest.verifier)
            )
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
                response = self.app_attest.post_map_job(
                    rollout_client,
                    credential=owner,
                    payload={
                        "mode": "custom_bbox",
                        "bbox": [103.75, 1.24, 103.93, 1.37],
                        "clientInstallationId": owner["clientInstallationId"],
                        "clientRequestId": request_id,
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
        malformed_create = self.post_map_job(
            {"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]},
            headers={"X-Map-Stream-Trust": "malformed"},
        )
        self.assertEqual(malformed_create.status_code, 400)
        after = len(list(jobs_root.glob("*.json"))) if jobs_root.exists() else 0
        self.assertEqual(after, before)

        job_id = self.create_job()
        malformed_cancel = self.client.post(
            f"/v1/map-jobs/{job_id}/cancel",
            params=self.installation_params(self.installation),
            headers=self.installation_headers(
                self.installation,
                **{"X-Map-Stream-App-Build": "not-a-build"},
            ),
        )
        self.assertEqual(malformed_cancel.status_code, 400)
        self.assertEqual(
            self.client.get(
                f"/v1/map-jobs/{job_id}",
                params=self.installation_params(self.installation),
                headers=self.installation_headers(self.installation),
            ).json()["status"],
            "queued",
        )

        incomplete_identity = self.client.post(
            f"/v1/map-jobs/{job_id}/cancel",
            params=self.installation_params(self.installation),
            headers=self.installation_headers(
                self.installation,
                **{
                    "X-Map-Stream-App-Build": "100",
                    "X-Map-Stream-App-Git-Sha": "",
                    "X-Map-Stream-App-Build-Sha256": "",
                },
            ),
        )
        self.assertEqual(incomplete_identity.status_code, 400)
        self.assertEqual(
            self.client.get(
                f"/v1/map-jobs/{job_id}",
                params=self.installation_params(self.installation),
                headers=self.installation_headers(self.installation),
            ).json()["status"],
            "queued",
        )

        installation = self.issue_installation(self.client)
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
            client = TestClient(
                create_app(app_attest_verifier=self.app_attest.verifier)
            )
            client.headers["X-Map-Stream-Trust"] = self.stream_trust_header
            client.headers["X-Map-Stream-App-Build"] = "100"
            client.headers["X-Map-Stream-App-Git-Sha"] = self.ios_git_sha
            client.headers["X-Map-Stream-App-Build-Sha256"] = self.ios_build_sha256
        try:
            installation = self.issue_installation(client)
            headers = {
                "X-Installation-Token": installation["clientInstallationToken"]
            }
            created = self.app_attest.post_map_job(
                client,
                credential=installation,
                payload={
                    "mode": "custom_bbox",
                    "bbox": [103.75, 1.24, 103.93, 1.37],
                    "clientInstallationId": installation["clientInstallationId"],
                    "clientRequestId": "request-presign-123",
                },
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
            finishedAt="2020-01-01T00:00:00Z",
        )
        # Keep the artifact present after expiry so the signed-download
        # assertion below proves READY-state gating, not a missing file.
        self.update_job(protecting_job_id, packPath=str(pack_path))

        issued = self.client.post(
            "/v1/map-packs/map-expired/download-url",
            params={
                **self.installation_params(self.installation),
                "jobId": job_id,
            },
            headers=self.installation_headers(self.installation),
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
                **self.installation_params(self.installation),
                "jobId": job_id,
            },
            headers=self.installation_headers(self.installation),
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
            params=self.installation_params(self.installation),
            headers={"Authorization": "Bearer admin-secret"},
        )

        self.assertEqual(response.status_code, 409)
        self.assertIn("not queued", response.json()["detail"])

    def test_run_route_rejects_cancelled_job(self):
        job_id = self.create_job()
        self.assertEqual(
            self.client.post(
                f"/v1/map-jobs/{job_id}/cancel",
                params=self.installation_params(self.installation),
                headers=self.installation_headers(self.installation),
            ).status_code,
            200,
        )

        response = self.client.post(
            f"/v1/map-jobs/{job_id}/run",
            params=self.installation_params(self.installation),
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
        first_installation = self.issue_installation(self.client)
        second_installation = self.issue_installation(self.client)
        first = self.post_map_job(
            {
                "mode": "custom_bbox",
                "bbox": [103.75, 1.24, 103.93, 1.37],
                "clientRequestId": "request-first-123",
            },
            credential=first_installation,
        )
        self.assertEqual(first.status_code, 200)
        second = self.post_map_job(
            {
                "mode": "custom_bbox",
                "bbox": [103.76, 1.25, 103.94, 1.38],
                "clientRequestId": "request-second-123",
            },
            credential=second_installation,
        )
        self.assertEqual(second.status_code, 200)

        response = self.client.get(
            "/v1/map-jobs",
            params=self.installation_params(first_installation),
            headers=self.installation_headers(first_installation),
        )

        self.assertEqual(response.status_code, 200)
        jobs = response.json()["jobs"]
        self.assertEqual([job["jobId"] for job in jobs], [first.json()["jobId"]])

    def test_job_reads_require_matching_installation(self):
        owner = self.issue_installation(self.client)
        other_installation = self.issue_installation(self.client)
        owned = self.post_map_job(
            {
                "mode": "custom_bbox",
                "bbox": [103.75, 1.24, 103.93, 1.37],
                "clientRequestId": "request-owner-123",
            },
            credential=owner,
        ).json()

        missing_filter = self.client.get("/v1/map-jobs")
        matching = self.client.get(
            f"/v1/map-jobs/{owned['jobId']}",
            params=self.installation_params(owner),
            headers=self.installation_headers(owner),
        )
        other = self.client.get(
            f"/v1/map-jobs/{owned['jobId']}",
            params=self.installation_params(other_installation),
            headers=self.installation_headers(other_installation),
        )
        unscoped = self.client.get(f"/v1/map-jobs/{owned['jobId']}")

        self.assertEqual(missing_filter.status_code, 400)
        self.assertEqual(matching.status_code, 200)
        self.assertEqual(other.status_code, 404)
        self.assertEqual(unscoped.status_code, 401)

    def test_job_endpoints_reject_an_installation_id_without_its_token(self):
        owner = self.issue_installation(self.client)
        created = self.post_map_job(credential=owner)
        self.assertEqual(created.status_code, 200)
        job_id = created.json()["jobId"]
        params = self.installation_params(owner)

        attempts = [
            self.client.get("/v1/map-jobs", params=params),
            self.client.get(f"/v1/map-jobs/{job_id}", params=params),
            self.client.post(f"/v1/map-jobs/{job_id}/cancel", params=params),
        ]
        for response in attempts:
            with self.subTest(url=str(response.request.url)):
                self.assertEqual(response.status_code, 401)
                self.assertEqual(
                    response.json()["detail"],
                    "installation credential is required",
                )

        wrong_token = self.installation_headers(
            owner,
            **{"X-Installation-Token": "v1." + "A" * 43},
        )
        response = self.client.get(
            f"/v1/map-jobs/{job_id}",
            params=params,
            headers=wrong_token,
        )
        self.assertEqual(response.status_code, 401)
        self.assertEqual(
            response.json()["detail"],
            "installation credential is invalid",
        )

    def test_legacy_unowned_job_is_not_publicly_recoverable(self):
        legacy_job_id = self.create_job()
        job_path = Path(self.tmp.name) / "jobs" / f"{legacy_job_id}.json"
        legacy_job = json.loads(job_path.read_text())
        legacy_job["clientInstallationId"] = None
        legacy_job["clientRequestId"] = None
        legacy_job["request"].pop("clientInstallationId", None)
        legacy_job["request"].pop("clientRequestId", None)
        self.client.app.state.job_store.save(MapJob.from_dict(legacy_job))

        response = self.client.get(
            f"/v1/map-jobs/{legacy_job_id}",
            params=self.installation_params(self.installation),
            headers=self.installation_headers(self.installation),
        )
        legacy_unscoped = self.client.get(f"/v1/map-jobs/{legacy_job_id}")

        self.assertEqual(response.status_code, 404)
        self.assertEqual(legacy_unscoped.status_code, 401)

    def test_client_metadata_validation_returns_bad_request(self):
        valid = {
            "mode": "custom_bbox",
            "bbox": [103.75, 1.24, 103.93, 1.37],
        }
        invalid_payloads = [
            {
                **valid,
                "clientInstallationId": self.installation[
                    "clientInstallationId"
                ],
            },
            {
                **valid,
                "clientInstallationId": self.installation[
                    "clientInstallationId"
                ],
                "clientRequestId": "request-owner-123",
                "installOnDevice": "yes",
            },
        ]

        for payload in invalid_payloads:
            with self.subTest(payload=payload):
                if payload.get("clientRequestId"):
                    response = self.app_attest.post_map_job(
                        self.client,
                        credential=self.installation,
                        payload=payload,
                    )
                else:
                    response = self.client.post(
                        "/v1/map-jobs",
                        json=payload,
                        headers=self.installation_headers(self.installation),
                    )
                self.assertEqual(response.status_code, 400)
                self.assertTrue(response.json()["detail"])

        invalid_credentials = ["bad", 123]
        for invalid_id in invalid_credentials:
            with self.subTest(invalid_id=invalid_id):
                response = self.client.post(
                    "/v1/map-jobs",
                    json={
                        **valid,
                        "clientInstallationId": invalid_id,
                        "clientRequestId": "request-owner-123",
                    },
                    headers=self.installation_headers(self.installation),
                )
                self.assertEqual(response.status_code, 401)

        invalid_filter = self.client.get(
            "/v1/map-jobs",
            params={"clientInstallationId": "bad"},
            headers=self.installation_headers(self.installation),
        )
        self.assertEqual(invalid_filter.status_code, 401)

    def test_map_pack_reads_are_scoped_and_choose_newest_owned_job(self):
        owner = self.issue_installation(self.client)
        other_installation = self.issue_installation(self.client)
        unknown_installation = self.issue_installation(self.client)

        def create_owned(
            credential: dict[str, str],
            request_id: str,
            bbox: list[float],
        ) -> str:
            response = self.post_map_job(
                {
                    "mode": "custom_bbox",
                    "bbox": bbox,
                    "clientRequestId": request_id,
                },
                credential=credential,
            )
            self.assertEqual(response.status_code, 200)
            return response.json()["jobId"]

        older = create_owned(
            owner,
            "request-owner-old",
            [103.75, 1.24, 103.93, 1.37],
        )
        newer = create_owned(
            owner,
            "request-owner-new",
            [103.76, 1.25, 103.94, 1.38],
        )
        other = create_owned(
            other_installation,
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
            params=self.installation_params(owner),
            headers=self.installation_headers(owner),
        )
        unknown = self.client.get(
            "/v1/map-packs/map-shared",
            params=self.installation_params(unknown_installation),
            headers=self.installation_headers(unknown_installation),
        )
        unscoped = self.client.get("/v1/map-packs/map-shared")
        download = self.client.post(
            "/v1/map-packs/map-shared/download-url",
            params={
                **self.installation_params(owner),
                "jobId": newer,
            },
            headers=self.installation_headers(owner),
        )
        older_download = self.client.post(
            "/v1/map-packs/map-shared/download-url",
            params={
                **self.installation_params(owner),
                "jobId": older,
            },
            headers=self.installation_headers(owner),
        )
        cross_install_download = self.client.post(
            "/v1/map-packs/map-shared/download-url",
            params={
                **self.installation_params(owner),
                "jobId": other,
            },
            headers=self.installation_headers(owner),
        )

        self.assertEqual(matching.status_code, 200)
        self.assertEqual(matching.json()["jobId"], newer)
        self.assertEqual(unknown.status_code, 404)
        self.assertEqual(unscoped.status_code, 401)
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
            clientInstallationId=None,
            clientRequestId=None,
        )
        self.assertEqual(self.client.get("/v1/map-packs/map-legacy").status_code, 401)
        legacy_download = self.client.post(
            "/v1/map-packs/map-legacy/download-url",
            params={
                **self.installation_params(owner),
                "jobId": legacy,
            },
            headers=self.installation_headers(owner),
        )
        self.assertEqual(legacy_download.status_code, 404)

    def test_modern_job_mutations_require_matching_installation(self):
        owner = self.issue_installation(self.client)
        other_installation = self.issue_installation(self.client)
        response = self.post_map_job(
            {
                "mode": "custom_bbox",
                "bbox": [103.75, 1.24, 103.93, 1.37],
                "clientRequestId": "request-owner-123",
            },
            credential=owner,
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
                params=self.installation_params(other_installation),
                headers=self.installation_headers(other_installation),
            ).status_code,
            404,
        )
        cancelled = self.client.post(
            f"/v1/map-jobs/{job_id}/cancel",
            params=self.installation_params(owner),
            headers=self.installation_headers(owner),
        )
        self.assertEqual(cancelled.status_code, 200)
        self.assertEqual(cancelled.json()["status"], "cancelled")


if __name__ == "__main__":
    unittest.main()
