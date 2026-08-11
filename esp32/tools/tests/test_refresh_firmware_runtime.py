from __future__ import annotations

import hashlib
import json
import os
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

from firmware_runtime import FirmwareRuntimeError, extract_verified_bundle
from refresh_firmware_runtime import (
    _bundle,
    _inventory,
    _isolated_command_environment,
    _normalize_name,
    _normalize_wheel,
    _reject_path_leaks,
    _remove_generated_python_state,
    _run,
    _wheel_identity,
    assemble_lock,
    inspect_inputs,
)


class RuntimeRefreshTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def make_wheel(self) -> Path:
        path = self.root / "Example_Package-1.2.3-py3-none-any.whl"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr(
                "example_package-1.2.3.dist-info/METADATA",
                "Metadata-Version: 2.1\nName: Example_Package\nVersion: 1.2.3\nLicense-Expression: MIT\n\n",
            )
            archive.writestr(
                "example_package-1.2.3.dist-info/WHEEL",
                "Wheel-Version: 1.0\nTag: py3-none-any\n\n",
            )
            archive.writestr(
                "example/_vendor/vendored-9.9.dist-info/METADATA",
                "Metadata-Version: 2.1\nName: vendored\nVersion: 9.9\n\n",
            )
        return path

    def test_wheel_normalization_is_deterministic_and_metadata_driven(self) -> None:
        wheel = self.make_wheel()
        _normalize_wheel(wheel)
        first = hashlib.sha256(wheel.read_bytes()).hexdigest()
        _normalize_wheel(wheel)
        self.assertEqual(hashlib.sha256(wheel.read_bytes()).hexdigest(), first)
        self.assertEqual(
            _wheel_identity(wheel),
            ("example-package", "1.2.3", ["py3-none-any"], "MIT"),
        )
        self.assertEqual(_normalize_name("Example_Package"), "example-package")

    def test_bundle_has_canonical_inventory_and_no_links(self) -> None:
        runtime = self.root / "runtime"
        (runtime / "bin").mkdir(parents=True)
        executable = runtime / "bin/pio"
        executable.write_text("#!/bin/sh\nexit 0\n")
        executable.chmod(0o755)
        archive = self.root / "runtime.tar.gz"
        _bundle(runtime, archive)
        destination = self.root / "out"
        extract_verified_bundle(archive, destination)
        inventory = json.loads((destination / "inventory.json").read_bytes())
        self.assertEqual(inventory["files"][0]["path"], "bin/pio")
        self.assertTrue(inventory["files"][0]["executable"])

    def test_inventory_rejects_links(self) -> None:
        runtime = self.root / "runtime"
        runtime.mkdir()
        (runtime / "target").write_text("x")
        (runtime / "link").symlink_to("target")
        with self.assertRaisesRegex(FirmwareRuntimeError, "unsafe member"):
            _inventory(runtime)

    def test_generated_python_state_and_refresh_paths_are_removed(self) -> None:
        runtime = self.root / "runtime"
        python_bin = runtime / "python/bin"
        cache = runtime / "python/lib/example/__pycache__"
        python_bin.mkdir(parents=True)
        cache.mkdir(parents=True)
        (python_bin / "python3").write_text("runtime")
        (python_bin / "uv").write_text("native uv")
        (python_bin / "generated-console-script").write_text(str(self.root))
        (cache / "module.pyc").write_bytes(b"bytecode")
        terminfo = runtime / "python/share/terminfo/2"
        terminfo.mkdir(parents=True)
        (terminfo / "2621A").write_text("upper")
        (terminfo / "2621a").write_text("lower")
        record = runtime / "python/lib/example-1.dist-info/RECORD"
        record.parent.mkdir()
        record.write_text(
            "../../../bin/generated-console-script,sha256=temporary,1\n"
            "../../../bin/uv,sha256=stable-uv,3\n"
            "example/__init__.py,sha256=stable,2\n"
            "example-1.dist-info/RECORD,,\n"
        )
        _remove_generated_python_state(runtime, {"python3"})
        self.assertEqual({path.name for path in python_bin.iterdir()}, {"python3", "uv"})
        self.assertFalse(cache.exists())
        self.assertFalse((runtime / "python/share/terminfo").exists())
        self.assertEqual(
            record.read_text(),
            "../../../bin/uv,sha256=stable-uv,3\n"
            "example-1.dist-info/RECORD,,\n"
            "example/__init__.py,sha256=stable,2\n",
        )
        _reject_path_leaks(runtime, (self.root,))
        (runtime / "leak.txt").write_text(f"prefix {self.root} suffix")
        with self.assertRaisesRegex(FirmwareRuntimeError, "leaks a refresh path"):
            _reject_path_leaks(runtime, (self.root,))

    def test_checked_in_inputs_are_exact_and_dual_host(self) -> None:
        project = Path(__file__).resolve().parents[2]
        evidence = inspect_inputs(project)
        self.assertEqual(evidence["schema"], 2)
        self.assertEqual(set(evidence["distributionCounts"]), {
            "topLevel", "pioarduinoRoot", "espIdf", "uv", "esptool"
        })
        with self.assertRaisesRegex(FirmwareRuntimeError, "exactly both"):
            assemble_lock(project, (), self.root / "lock.json", "unit-test-lock")

    def test_candidate_commands_do_not_inherit_or_accept_ambient_injection(self) -> None:
        command_root = self.root / "command-environment"
        environment = _isolated_command_environment(command_root)
        with mock.patch.dict(
            os.environ,
            {
                "HTTPS_PROXY": "https://attacker.invalid",
                "LD_PRELOAD": "/attacker/library.so",
                "PIP_CONFIG_FILE": "/attacker/pip.conf",
                "PIP_INDEX_URL": "https://attacker.invalid/simple",
                "PYTHONPATH": "/attacker/python",
                "UV_CONFIG_FILE": "/attacker/uv.toml",
            },
            clear=False,
        ):
            values = dict(
                line.split("=", 1)
                for line in _run(("/usr/bin/env",), environment=environment).splitlines()
            )
        self.assertEqual(values["HOME"], str(command_root / "home"))
        self.assertEqual(values["TMPDIR"], str(command_root / "tmp"))
        self.assertEqual(values["XDG_CACHE_HOME"], str(command_root / "cache"))
        self.assertEqual(values["UV_CACHE_DIR"], str(command_root / "cache/uv"))
        for rejected in (
            "HTTPS_PROXY",
            "LD_PRELOAD",
            "PIP_INDEX_URL",
            "PYTHONPATH",
            "UV_CONFIG_FILE",
        ):
            self.assertNotIn(rejected, values)
        self.assertEqual(values["PIP_CONFIG_FILE"], os.devnull)
        with self.assertRaisesRegex(FirmwareRuntimeError, "unsupported names: LD_PRELOAD"):
            _run(("/usr/bin/env",), environment={"LD_PRELOAD": "/attacker/library.so"})


if __name__ == "__main__":
    unittest.main()
