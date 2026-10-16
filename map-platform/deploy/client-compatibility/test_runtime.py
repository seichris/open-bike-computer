import importlib.util
from pathlib import Path
import subprocess
import unittest


class ClientCompatibilityRuntimeTests(unittest.TestCase):
    def test_only_approved_policy_and_registry_change(self):
        base = Path("/opt/client-compatibility-base-app")
        runtime = Path("/app")
        allowed = {"map-platform/backend/map_platform/map_stream_rollout.py", "map-platform/config/map-stream-rollout-approvals.json"}
        before = {p.relative_to(base).as_posix(): p.read_bytes() for p in base.rglob("*") if p.is_file()}
        after = {p.relative_to(runtime).as_posix(): p.read_bytes() for p in runtime.rglob("*") if p.is_file()}
        self.assertEqual(before.keys(), after.keys())
        changed = {name for name in before if before[name] != after[name]}
        self.assertTrue(changed.issubset(allowed), changed)
        self.assertEqual(after["map-platform/backend/map_platform/api.py"], before["map-platform/backend/map_platform/api.py"])

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
