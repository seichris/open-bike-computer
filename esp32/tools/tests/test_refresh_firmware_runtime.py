from __future__ import annotations

import hashlib
import json
import os
import shutil
import stat
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

from firmware_runtime import FirmwareRuntimeError, extract_verified_bundle
from refresh_firmware_runtime import (
    _bundle,
    _clean_generator_commit,
    _inventory,
    _isolated_command_environment,
    _load_inputs,
    _load_candidate_contract,
    _normalize_name,
    _normalize_wheel,
    _pypi_wheel_source,
    _reject_path_leaks,
    _refresh_work_root,
    _remove_generated_python_state,
    _reviewed_wheel_license,
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

    def make_wheel(self, *, license_expression: str | None = "MIT") -> Path:
        path = self.root / "Example_Package-1.2.3-py3-none-any.whl"
        license_metadata = (
            f"License-Expression: {license_expression}\n"
            if license_expression is not None
            else "License-File: LICENSE.txt\n"
        )
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr(
                "example_package-1.2.3.dist-info/METADATA",
                "Metadata-Version: 2.1\nName: Example_Package\nVersion: 1.2.3\n"
                + license_metadata
                + "\n",
            )
            archive.writestr(
                "example_package-1.2.3.dist-info/WHEEL",
                "Wheel-Version: 1.0\nTag: py3-none-any\n\n",
            )
            archive.writestr(
                "example/_vendor/vendored-9.9.dist-info/METADATA",
                "Metadata-Version: 2.1\nName: vendored\nVersion: 9.9\n\n",
            )
            if license_expression is None:
                archive.writestr(
                    "example_package-1.2.3.dist-info/licenses/LICENSE.txt",
                    "reviewed license text\n",
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

    def test_wheel_validation_rejects_unsafe_zip_members(self) -> None:
        attacks = {
            "traversal": [("../escape.py", None)],
            "backslash": [("example\\escape.py", None)],
            "non-nfc": [("example/cafe\u0301.py", None)],
            "case-collision": [
                ("EXAMPLE/_VENDOR/VENDORED-9.9.DIST-INFO/METADATA", None)
            ],
            "symlink": [("example/link", stat.S_IFLNK | 0o777)],
        }
        for label, members in attacks.items():
            with self.subTest(label=label):
                wheel = self.make_wheel()
                with zipfile.ZipFile(wheel, "a") as archive:
                    for name, mode in members:
                        if mode is None:
                            archive.writestr(name, "unsafe\n")
                        else:
                            info = zipfile.ZipInfo(name)
                            info.create_system = 3
                            info.external_attr = mode << 16
                            archive.writestr(info, "target")
                with self.assertRaisesRegex(
                    FirmwareRuntimeError, "unsafe or colliding member"
                ):
                    _normalize_wheel(wheel)

    def test_pypi_provenance_uses_os_https_and_requires_a_strict_digest(self) -> None:
        digest = "a" * 64
        response = json.dumps(
            {
                "urls": [
                    {
                        "filename": "example-1.2.3-py3-none-any.whl",
                        "url": "https://files.pythonhosted.org/packages/example.whl",
                        "digests": {"sha256": digest},
                    }
                ]
            }
        )
        environment = {"HOME": "/isolated"}
        with mock.patch(
            "refresh_firmware_runtime._run", return_value=response
        ) as runner:
            self.assertEqual(
                _pypi_wheel_source(
                    "example", "1.2.3+local", "example-1.2.3-py3-none-any.whl", environment
                ),
                ("https://files.pythonhosted.org/packages/example.whl", digest),
            )
        command = runner.call_args.args[0]
        self.assertEqual(command[0], "/usr/bin/curl")
        self.assertEqual(command[1], "--disable")
        self.assertEqual(command.count("=https"), 2)
        self.assertTrue(command[-1].endswith("/1.2.3%2Blocal/json"))
        self.assertEqual(runner.call_args.kwargs["environment"], environment)

        unsafe = response.replace(
            "https://files.pythonhosted.org/", "https://example.invalid/"
        )
        with mock.patch("refresh_firmware_runtime._run", return_value=unsafe):
            with self.assertRaisesRegex(FirmwareRuntimeError, "provenance is invalid"):
                _pypi_wheel_source(
                    "example", "1.2.3", "example-1.2.3-py3-none-any.whl", environment
                )

    def test_candidate_generator_requires_a_clean_exact_git_identity(self) -> None:
        commit = "a" * 40
        with mock.patch(
            "refresh_firmware_runtime._run", side_effect=[commit, ""]
        ) as runner:
            self.assertEqual(_clean_generator_commit(self.root), commit)
        self.assertEqual(
            runner.call_args_list[1].args[0],
            ("git", "status", "--porcelain=v1", "--untracked-files=no"),
        )

        with mock.patch(
            "refresh_firmware_runtime._run",
            side_effect=[commit, " M tools/refresh_firmware_runtime.py"],
        ):
            with self.assertRaisesRegex(FirmwareRuntimeError, "clean tracked Git"):
                _clean_generator_commit(self.root)

    def test_wheel_license_without_metadata_requires_exact_reviewed_evidence(self) -> None:
        wheel = self.make_wheel(license_expression=None)
        evidence_path = "example_package-1.2.3.dist-info/licenses/LICENSE.txt"
        overrides = {
            ("example-package", "1.2.3"): {
                "name": "example-package",
                "version": "1.2.3",
                "license": "BSD-3-Clause",
                "evidenceFiles": [evidence_path],
            }
        }

        license_expression, evidence, used_override = _reviewed_wheel_license(
            wheel,
            "example-package",
            "1.2.3",
            None,
            overrides,
        )

        self.assertEqual(license_expression, "BSD-3-Clause")
        self.assertTrue(used_override)
        self.assertEqual(evidence["kind"], "tracked-override")
        self.assertEqual(evidence["files"][0]["path"], evidence_path)
        self.assertEqual(len(evidence["files"][0]["sha256"]), 64)
        with self.assertRaisesRegex(FirmwareRuntimeError, "not reviewed"):
            _reviewed_wheel_license(
                wheel, "example-package", "1.2.3", None, {}
            )
        overrides[("example-package", "1.2.3")]["evidenceFiles"] = [
            "missing-license.txt"
        ]
        with self.assertRaisesRegex(FirmwareRuntimeError, "missing or ambiguous"):
            _reviewed_wheel_license(
                wheel,
                "example-package",
                "1.2.3",
                None,
                overrides,
            )

    def test_license_inventory_rejects_noncanonical_evidence_entries(self) -> None:
        project = Path(__file__).resolve().parents[2]
        runtime = self.root / "tools/firmware-runtime"
        runtime.parent.mkdir()
        shutil.copytree(project / "tools/firmware-runtime", runtime)
        licenses_path = runtime / "licenses.json"
        licenses = json.loads(licenses_path.read_bytes())
        licenses["wheelOverrides"][0]["evidenceFiles"] = [{}]
        licenses_path.write_bytes(
            (
                json.dumps(licenses, sort_keys=True, separators=(",", ":"))
                + "\n"
            ).encode()
        )

        with self.assertRaisesRegex(
            FirmwareRuntimeError, "wheel license override is invalid"
        ):
            _load_inputs(self.root)

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
        inputs = json.loads(
            (project / "tools/firmware-runtime/refresh-inputs.json").read_bytes()
        )
        self.assertEqual(inputs["pythonSource"]["license"], "Python-2.0")
        self.assertEqual(len(inputs["pythonSource"]["sha256"]), 64)
        self.assertEqual(len(inputs["pythonBuilder"]["commit"]), 40)
        licenses = json.loads(
            (project / "tools/firmware-runtime/licenses.json").read_bytes()
        )
        self.assertEqual(licenses["schema"], 2)
        self.assertEqual(evidence["wheelLicenseOverrideCount"], 4)
        with self.assertRaisesRegex(FirmwareRuntimeError, "exactly both"):
            assemble_lock(project, (), self.root / "lock.json", "unit-test-lock")

    def test_candidate_contract_pins_one_exact_generator(self) -> None:
        project = Path(__file__).resolve().parents[2]
        evidence = inspect_inputs(project)
        generator = {
            "version": "2",
            "commit": "a" * 40,
            "refreshInputsSha256": evidence["refreshInputsSha256"],
            "licensesSha256": evidence["licensesSha256"],
        }
        contracts = []
        for target_id in ("linux-x86_64-cp313", "macos-arm64-cp313"):
            path = self.root / f"contract-{target_id}.json"
            path.write_bytes(
                (json.dumps(
                    {"schema": 1, "generator": generator, "target": {"id": target_id}},
                    sort_keys=True,
                    separators=(",", ":"),
                ) + "\n").encode()
            )
            self.assertEqual(
                _load_candidate_contract(project, path, expected_target=target_id)["generator"],
                generator,
            )
            contracts.append(path)

        changed = json.loads(contracts[1].read_bytes())
        changed["generator"]["commit"] = "b" * 40
        contracts[1].write_bytes(
            (json.dumps(changed, sort_keys=True, separators=(",", ":")) + "\n").encode()
        )
        with self.assertRaisesRegex(FirmwareRuntimeError, "different generators"):
            assemble_lock(project, contracts, self.root / "lock.json", "unit-test-lock")

        contracts[1].write_bytes(contracts[0].read_bytes().replace(
            b"linux-x86_64-cp313", b"macos-arm64-cp313"
        ))
        output = self.root / "preserved-lock.json"
        output.write_text("preserve me\n")
        with self.assertRaises(FirmwareRuntimeError):
            assemble_lock(project, contracts, output, "unit-test-lock")
        self.assertEqual(output.read_text(), "preserve me\n")

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

    def test_executable_refresh_staging_is_project_private_and_symlink_free(self) -> None:
        project = self.root / "project"
        project.mkdir()
        expected = project.resolve() / ".pio/open-bike-build/runtime-refresh"
        self.assertEqual(_refresh_work_root(project), expected)
        self.assertTrue(expected.is_dir())

        shutil.rmtree(project / ".pio")
        external = self.root / "external"
        external.mkdir()
        (project / ".pio").symlink_to(external, target_is_directory=True)
        with self.assertRaisesRegex(
            FirmwareRuntimeError, "runtime refresh work directory is unsafe"
        ):
            _refresh_work_root(project)


if __name__ == "__main__":
    unittest.main()
