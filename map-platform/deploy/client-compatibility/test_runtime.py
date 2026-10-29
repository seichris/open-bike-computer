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

    def test_durable_maps_keep_trust_and_producer_gates_across_client_upgrades(self):
        from map_platform.map_stream_rollout import (
            MapStreamRolloutPolicy, load_approved_promotions,
        )
        approvals = load_approved_promotions(
            Path("/app/map-platform/config/map-stream-rollout-approvals.json")
        )
        active = approvals["msr-20261029-durable-contract1"]
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
        installation = "inst_v2_" + "0" * 32
        key_id, key_hash = next(iter(active.approved_signing_keys))

        def allowed(identity, *, producer=active.producer_build_sha256,
                    worker=active.worker_image_digest, trust=active.approved_signing_keys):
            return policy.allows_artifact(
                installation, key_id, key_hash, producer, worker, trust, *identity,
                compatibility_contract=1,
            )

        for identity in ((active.ios_build, active.ios_git_sha, active.ios_build_sha256),
                         ("33", "a" * 40, "b" * 64), ("999", "c" * 40, "d" * 64)):
            self.assertTrue(allowed(identity))
            self.assertEqual(policy.artifact_delivery_requirements(
                *identity, compatibility_contract=1), {})
            self.assertFalse(allowed(identity, producer="0" * 64))
            self.assertFalse(allowed(identity, worker="sha256:" + "0" * 64))
            self.assertFalse(allowed(identity, trust=frozenset()))
        # Legacy maps retain an explicit build-104 anchor. No old approval is removed.
        self.assertEqual(policy.artifact_delivery_requirements()["requiredFirmwareBuild"], 104)
        self.assertIn("msr-20261026-worker-social-ios30", approvals)
        self.assertFalse(policy.allows_artifact(
            "invalid-installation", key_id, key_hash, active.producer_build_sha256,
            active.worker_image_digest, active.approved_signing_keys,
            "33", "a" * 40, "b" * 64, compatibility_contract=1))

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
