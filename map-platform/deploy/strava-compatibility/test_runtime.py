import hashlib
from pathlib import Path
import subprocess
import sys
import unittest


def inventory(root: Path) -> dict[str, str]:
    result = {}
    for path in root.rglob("*"):
        name = path.relative_to(root).as_posix()
        if path.is_symlink():
            result[name] = "symlink:" + str(path.readlink())
        elif path.is_file():
            result[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


class StravaCompatibilityRuntimeTests(unittest.TestCase):
    def test_only_strava_control_plane_files_are_overlaid(self):
        base = inventory(Path("/opt/strava-base-app"))
        runtime = inventory(Path("/app"))
        package = "map-platform/backend/map_platform/"
        self.assertEqual(base.keys() - runtime.keys(), set())
        self.assertEqual(runtime.keys() - base.keys(), {package + "strava_development.py"})
        self.assertEqual(
            {name for name in base if runtime[name] != base[name]},
            {package + "api.py", package + "strava_client.py", package + "strava_integrations.py"},
        )

    def test_runtime_rejects_worker_commands(self):
        guard = "/opt/bicino-strava/role_guard.py"
        for command in ("worker-loop", "run-job"):
            result = subprocess.run(
                [sys.executable, guard, "map-platform", command],
                capture_output=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"keep the generation worker pinned", result.stderr)
