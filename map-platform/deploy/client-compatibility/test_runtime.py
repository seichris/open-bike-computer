import importlib.util
import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


class ClientCompatibilityRuntimeTests(unittest.TestCase):
    def test_only_approved_registry_changes(self):
        base = Path("/opt/client-compatibility-base-app")
        runtime = Path("/app")
        allowed = {"map-platform/config/map-stream-rollout-approvals.json"}
        before = {p.relative_to(base).as_posix(): p.read_bytes() for p in base.rglob("*") if p.is_file()}
        after = {p.relative_to(runtime).as_posix(): p.read_bytes() for p in runtime.rglob("*") if p.is_file()}
        self.assertEqual(before.keys(), after.keys())
        changed = {name for name in before if before[name] != after[name]}
        self.assertTrue(changed.issubset(allowed), changed)
        self.assertEqual(after["map-platform/backend/map_platform/api.py"], before["map-platform/backend/map_platform/api.py"])
        self.assertEqual(after["map-platform/backend/map_platform/map_stream_rollout.py"], before["map-platform/backend/map_platform/map_stream_rollout.py"])

    def test_exact_app_upgrade_preserves_client_and_artifact_gates(self):
        from map_platform.map_stream_rollout import (
            MapStreamRolloutPolicy,
            load_approved_promotions,
        )

        approvals = load_approved_promotions(
            Path("/app/map-platform/config/map-stream-rollout-approvals.json")
        )
        active = approvals["msr-20261022-worker-social-ios28"]
        environment = {
            "MAP_PLATFORM_MAP_STREAM_ROLLOUT_MODE": "all",
            "MAP_PLATFORM_MAP_STREAM_PROMOTION_ID": active.promotion_id,
            "MAP_PLATFORM_WORKER_IMAGE_REFERENCE":
                "ghcr.io/seichris/open-bike-computer-map-platform@" + active.worker_image_digest,
        }
        with patch.dict(os.environ, environment, clear=True):
            policy = MapStreamRolloutPolicy.from_environment(
                approved_promotions_by_id=approvals,
                trusted_signing_keys=dict(active.approved_signing_keys),
                current_requirements_sha256=active.requirements_sha256,
            )
        self.assertEqual({item[0] for item in policy.approved_ios_identities}, {"24", "25", "28", "29", "30"})
        installation = "inst_v2_00000000000000000000000000000001"
        key_id, key_hash = next(iter(active.approved_signing_keys))

        def allowed(identity, *, producer=active.producer_build_sha256,
                    worker=active.worker_image_digest, trust=active.approved_signing_keys):
            return policy.allows_artifact(
                installation, key_id, key_hash, producer, worker, trust, *identity
            )

        for identity in policy.approved_ios_identities:
            self.assertTrue(allowed(identity))
            response = policy.artifact_identity_requirements(*identity)
            self.assertEqual(response["requiredIosBuild"], identity[0])
            self.assertEqual(response["requiredIosGitSha"], identity[1])
            self.assertEqual(response["requiredIosBuildSha256"], identity[2])
            self.assertEqual(response["requiredFirmwareBuild"], active.firmware_build)
            self.assertFalse(allowed(identity, producer="0" * 64))
            self.assertFalse(allowed(identity, worker="sha256:" + "0" * 64))
            self.assertFalse(allowed(identity, trust=frozenset()))
        upgraded = next(identity for identity in policy.approved_ios_identities if identity[0] == "30")
        for identity in (("31", *upgraded[1:]), ("30", "0" * 40, upgraded[2]),
                         ("30", upgraded[1], "0" * 64), (None, None, None)):
            self.assertFalse(allowed(identity))
            with self.assertRaises(ValueError):
                policy.artifact_identity_requirements(*identity)

    def test_generation_commands_and_inline_workers_are_rejected(self):
        guard = "/opt/bicino-client-compatibility/role_guard.py"
        spec = importlib.util.spec_from_file_location("client_guard", guard)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertTrue(module.allowed(["map-platform", "maintenance-loop"], {}))
        self.assertTrue(module.allowed(["uvicorn", "--factory", "map_platform.api:create_app", "--host", "0.0.0.0", "--port", "8080"], {}))
        for command in (["map-platform", "worker-loop"], ["map-platform", "run-job"], ["python", "-c", "pass"]):
            self.assertFalse(module.allowed(command, {}))
            result = subprocess.run(["python", guard, *command], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
        self.assertFalse(module.allowed(["map-platform", "maintenance-loop"], {"MAP_PLATFORM_INLINE_WORKER_ENABLED": "1"}))
