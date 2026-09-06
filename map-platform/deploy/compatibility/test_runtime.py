"""Tests run against the generated compatibility image, not current main API."""
import importlib.util
import hashlib
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient
from app_attest_support import AppAttestTestClient
from map_platform.api import create_app


class CompatibilityRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        environment = patch.dict(os.environ, {
            "MAP_PLATFORM_DATA_ROOT": self.temp.name,
            "MAP_PLATFORM_INSTALLATION_SECRET": "compatibility-test-installation-secret-32-bytes",
            "MAP_PLATFORM_DOWNLOAD_SECRET": "compatibility-test-download-secret-32-bytes",
            "MAP_PLATFORM_DEPLOYMENT_CHANNEL": "production",
            "MAP_PLATFORM_INLINE_WORKER_ENABLED": "0",
            "MAP_PLATFORM_PREPARATION_ESTIMATES_MODE": "off",
            "MAP_PLATFORM_MAP_STREAM_ENABLED": "0",
            "MAP_PLATFORM_CATALOG_URL": "",
        })
        environment.start()
        self.addCleanup(environment.stop)
        self.attest = AppAttestTestClient()
        self.app = create_app(app_attest_verifier=self.attest.verifier)
        self.client = TestClient(self.app)
        self.addCleanup(self.client.close)

    def test_enrollment_health_refresh_and_owner_isolation(self):
        health = self.client.get("/healthz").json()
        self.assertTrue(health["appAttest"]["requiredForInstallation"])
        self.assertNotIn("admissionPolicyVersion", health)
        self.assertNotIn("stravaIntegration", health)
        self.assertEqual(self.client.post("/v1/installations").status_code, 401)
        credential = self.attest.issue_installation(self.client)
        self.assertIsInstance(credential, dict)
        params = {"clientInstallationId": credential["clientInstallationId"]}
        headers = {"X-Installation-Token": credential["clientInstallationToken"]}
        refresh = self.client.post("/v1/installations", params=params, headers=headers)
        self.assertEqual(refresh.status_code, 200, refresh.text)
        self.assertEqual(refresh.json()["clientInstallationId"], credential["clientInstallationId"])
        self.assertEqual(self.client.get("/v1/map-jobs", params=params, headers=headers).status_code, 200)
        self.assertEqual(self.client.get("/v1/map-jobs", params=params).status_code, 401)

    def test_old_owner_token_still_reads_but_enrollment_does_not_inherit_it(self):
        old_id, old_token = self.app.state.installation_store.issue()
        params = {"clientInstallationId": old_id}
        headers = {"X-Installation-Token": old_token}
        self.assertEqual(self.client.get("/v1/map-jobs", params=params, headers=headers).status_code, 200)
        credential = self.attest.issue_installation(self.client)
        self.assertIsInstance(credential, dict)
        self.assertNotEqual(credential["clientInstallationId"], old_id)
        self.assertEqual(self.client.get("/v1/map-jobs", params=params, headers={
            "X-Installation-Token": credential["clientInstallationToken"],
        }).status_code, 401)

    def test_missing_assertion_cannot_create_a_map(self):
        credential = self.attest.issue_installation(self.client)
        payload = {
            "mode": "custom_bbox", "bbox": [103.85, 1.29, 103.86, 1.30],
            "clientInstallationId": credential["clientInstallationId"],
            "clientRequestId": "compatibility-map-request",
        }
        response = self.client.post("/v1/map-jobs", json=payload, headers={
            "X-Installation-Token": credential["clientInstallationToken"],
        })
        self.assertEqual(response.status_code, 401, response.text)
        self.assertEqual(response.json()["detail"]["code"], "app_attest_assertion_required")

    def test_signed_request_creates_a_job_and_replays_idempotently(self):
        credential = self.attest.issue_installation(self.client)
        payload = {
            "mode": "custom_bbox", "bbox": [103.85, 1.29, 103.86, 1.30],
            "clientInstallationId": credential["clientInstallationId"],
            "clientRequestId": "compatibility-signed-request",
        }
        response = self.attest.post_map_job(self.client, credential=credential, payload=payload)
        self.assertEqual(response.status_code, 200, response.text)
        job_id = response.json()["jobId"]
        replay = self.client.post("/v1/map-jobs", json=payload, headers={
            "X-Installation-Token": credential["clientInstallationToken"],
        })
        self.assertEqual(replay.status_code, 200, replay.text)
        self.assertEqual(replay.json()["jobId"], job_id)
        restarted = TestClient(create_app(app_attest_verifier=self.attest.verifier))
        self.addCleanup(restarted.close)
        listing = restarted.get("/v1/map-jobs", params={
            "clientInstallationId": credential["clientInstallationId"],
        }, headers={"X-Installation-Token": credential["clientInstallationToken"]})
        self.assertEqual(listing.status_code, 200, listing.text)
        self.assertIn(job_id, listing.text)

    def test_role_guard_rejects_generation_and_inline_worker(self):
        spec = importlib.util.spec_from_file_location("role_guard", "/opt/bicino-auth-source/role_guard.py")
        guard = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(guard)
        self.assertTrue(guard.allowed(["map-platform", "maintenance-loop"], {}))
        self.assertFalse(guard.allowed(["map-platform", "worker-loop"], {}))
        self.assertFalse(guard.allowed(["map-platform", "maintenance-loop"], {"MAP_PLATFORM_INLINE_WORKER_ENABLED": "1"}))

    def test_all_other_base_image_files_are_unchanged(self):
        def inventory(root):
            return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                    for p in root.rglob("*") if p.is_file() and "__pycache__" not in p.parts}
        before = inventory(Path("/opt/compatibility-base-app"))
        after = inventory(Path("/app"))
        differences = {key for key in before.keys() | after.keys() if before.get(key) != after.get(key)}
        self.assertEqual(differences, {
            "map-platform/backend/map_platform/api.py",
            "map-platform/backend/map_platform/app_attest.py",
            "map-platform/backend/map_platform/data/Apple_App_Attestation_Root_CA.pem",
        })

    def test_backport_refuses_a_different_base(self):
        spec = importlib.util.spec_from_file_location("builder", "/opt/bicino-auth-source/prepare_auth_backport.py")
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
        baseline = Path("/opt/compatibility-base-app/map-platform/backend/map_platform/api.py").read_text()
        current = Path("/opt/bicino-auth-source/api.py").read_text()
        with self.assertRaisesRegex(ValueError, "base does not match"):
            builder.backport_api(baseline + "\n", current)


if __name__ == "__main__":
    unittest.main()
