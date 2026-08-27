from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "run-workout-platform-tests.sh"


class WorkoutPlatformScriptTests(unittest.TestCase):
    def run_script(self, root: Path, *, shared: Path | None) -> Path:
        bin_dir = root / "bin"
        bin_dir.mkdir(parents=True)
        args_log = root / "xcodebuild-args.json"
        simulator_payload = json.dumps(
            {
                "devices": {
                    "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                        {
                            "udid": "00000000-0000-0000-0000-000000000001",
                            "state": "Booted",
                            "isAvailable": True,
                        }
                    ]
                }
            },
            separators=(",", ":"),
        )
        xcrun = bin_dir / "xcrun"
        xcrun.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "if [[ \"$*\" == \"simctl list devices available --json\" ]]; then\n"
            f"  printf '%s\\n' '{simulator_payload}'\n"
            "  exit 0\n"
            "fi\n"
            "if [[ \"${1:-}\" == \"simctl\" ]]; then exit 0; fi\n"
            "exit 64\n",
            encoding="utf-8",
        )
        xcrun.chmod(0o755)
        xcodebuild = bin_dir / "xcodebuild"
        xcodebuild.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "/usr/bin/python3 - \"$XCODEBUILD_ARGS_LOG\" \"$@\" <<'PY'\n"
            "import json, sys\n"
            "from pathlib import Path\n"
            "Path(sys.argv[1]).write_text(json.dumps(sys.argv[2:]), encoding='utf-8')\n"
            "PY\n",
            encoding="utf-8",
        )
        xcodebuild.chmod(0o755)

        temp_root = root / "tmp"
        temp_root.mkdir()
        environment = os.environ.copy()
        environment.update(
            {
                "PATH": f"{bin_dir}:{environment['PATH']}",
                "TMPDIR": f"{temp_root}/",
                "XCODEBUILD_ARGS_LOG": str(args_log),
            }
        )
        if shared is None:
            environment.pop("CI_DERIVED_DATA_PATH", None)
        else:
            environment["CI_DERIVED_DATA_PATH"] = str(shared)

        subprocess.run(
            ["bash", str(SCRIPT), "ios"],
            cwd=SCRIPT.parents[1],
            env=environment,
            check=True,
            capture_output=True,
            text=True,
        )
        return args_log

    def test_external_derived_data_is_reused_across_invocations_and_preserved(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            shared = root / "shared-derived-data"
            shared.mkdir()
            sentinel = shared / "preserve-me"
            sentinel.write_text("shared", encoding="utf-8")

            first_log = self.run_script(root / "first", shared=shared)
            second_log = self.run_script(root / "second", shared=shared)
            first_arguments = json.loads(first_log.read_text(encoding="utf-8"))
            second_arguments = json.loads(second_log.read_text(encoding="utf-8"))

            self.assertTrue(shared.is_dir())
            self.assertEqual("shared", sentinel.read_text(encoding="utf-8"))
            self.assertEqual(
                str(shared),
                first_arguments[first_arguments.index("-derivedDataPath") + 1],
            )
            self.assertEqual(
                str(shared),
                second_arguments[second_arguments.index("-derivedDataPath") + 1],
            )

    def test_script_owned_derived_data_is_removed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            args_log = self.run_script(root, shared=None)
            arguments = json.loads(args_log.read_text(encoding="utf-8"))
            derived_data = Path(arguments[arguments.index("-derivedDataPath") + 1])

            self.assertFalse(derived_data.exists())

    def test_external_derived_data_rejects_root_and_relative_paths(self) -> None:
        for value in ("/", "relative/path"):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as temporary:
                environment = os.environ.copy()
                environment["CI_DERIVED_DATA_PATH"] = value
                result = subprocess.run(
                    ["bash", str(SCRIPT), "ios"],
                    cwd=SCRIPT.parents[1],
                    env=environment,
                    capture_output=True,
                    text=True,
                )

                self.assertEqual(64, result.returncode)
                self.assertIn("non-root absolute path", result.stderr)

    def test_external_derived_data_rejects_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "target"
            target.mkdir()
            link = root / "derived-data-link"
            link.symlink_to(target, target_is_directory=True)
            environment = os.environ.copy()
            environment["CI_DERIVED_DATA_PATH"] = str(link)

            result = subprocess.run(
                ["bash", str(SCRIPT), "ios"],
                cwd=SCRIPT.parents[1],
                env=environment,
                capture_output=True,
                text=True,
            )

            self.assertEqual(64, result.returncode)
            self.assertIn("must not be a symlink", result.stderr)


if __name__ == "__main__":
    unittest.main()
