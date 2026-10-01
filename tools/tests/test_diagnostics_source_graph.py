"""Check each Swift compiler invocation, not mere file presence in a script.

A script may build several independent modules. PR #553 added live diagnostics
references to BLEManager but omitted their sources from the Catalyst preview
module, even though the first compiler invocation already included them.
"""
from pathlib import Path
import re
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]
PREFIX = "ios-app/BikeComputer/BikeComputer/"


class DiagnosticsSourceGraphTests(unittest.TestCase):
    def test_every_ble_harness_has_its_diagnostics_dependencies(self):
        checked = 0
        for path in (ROOT / "ios-app/scripts").glob("*.sh"):
            # Join shell continuations so each compiler command is inspected
            # independently; do not let another module hide a missing source.
            commands = path.read_text().replace("\\\n", " ").splitlines()
            for command in commands:
                sources = set(re.findall(r"ios-app/[^\s\\\"]+\.swift", command))
                if PREFIX + "Managers/BLEManager.swift" not in sources:
                    continue
                checked += 1
                for relative in (
                    "Managers/DeviceDiagnosticsTransferManager.swift",
                    "Managers/DiagnosticsAcquisitionStore.swift",
                    "Utilities/RideDiagnostics.swift",
                    "Utilities/DiagnosticsSchema.generated.swift",
                    "Utilities/DiagnosticsCapturePolicy.swift",
                ):
                    self.assertIn(PREFIX + relative, sources,
                                  f"{path.name}: BLE module missing {relative}")
        self.assertGreaterEqual(checked, 3)

    def test_fast_ci_local_scripts_resolve_from_effective_directory(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/ci.yml").read_text())
        job = workflow["jobs"]["ios-fast"]
        default = job.get("defaults", {}).get("run", {}).get("working-directory", ".")
        checked = 0
        for step in job["steps"]:
            command = step.get("run", "")
            for script in re.findall(r"(?:^|\s)(\./scripts/[A-Za-z0-9_-]+\.sh)", command):
                directory = step.get("working-directory", default)
                self.assertTrue((ROOT / directory / script).is_file(),
                                f"{step['name']}: {script} does not exist from {directory}")
                checked += 1
        self.assertGreaterEqual(checked, 8)


if __name__ == "__main__":
    unittest.main()
