from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path
from unittest.mock import patch

from generated_sdkconfig import (
    GeneratedSdkconfigError,
    WAVESHARE_PLATFORM_ARCHIVE_SHA256,
    WAVESHARE_PLATFORM_PACKAGES_SHA256,
    _default_platformio_core_dir,
    _runtime_provenance,
    core_input_key,
    prepare_generated_sdkconfigs,
    record_generated_sdkconfig_defaults,
    recognized_generated_sdkconfigs,
    remove_generated_sdkconfigs,
    require_validated_generated_sdkconfig_defaults,
)


GENERATED_CONFIG = """# generated prefix may precede the banner
# Automatically generated file. DO NOT EDIT.
# Espressif IoT Development Framework (ESP-IDF) Project Configuration
#
CONFIG_PM_ENABLE=y
"""

RUNTIME_PROVENANCE = json.dumps(
    {
        "lockSetId": "unit-test-lock",
        "manifestSha256": "1" * 64,
        "target": "macos-arm64-cp313",
        "bundleSha256": "2" * 64,
        "pythonVersion": "3.13.15",
        "pythonExecutableSha256": "3" * 64,
        "runtimeTreeSha256": "4" * 64,
        "pioSha256": "5" * 64,
        "uvSha256": "6" * 64,
        "platformioVersion": "6.1.18",
        "topLevelDistributionSha256": "7" * 64,
        "pioarduinoRootDistributionSha256": "8" * 64,
        "espIdfDistributionSha256": "9" * 64,
        "uvDistributionSha256": "a" * 64,
        "esptoolDistributionSha256": "b" * 64,
        "platformArchiveSha256": WAVESHARE_PLATFORM_ARCHIVE_SHA256,
        "platformPackagesSha256": WAVESHARE_PLATFORM_PACKAGES_SHA256,
    },
    sort_keys=True,
)


@contextmanager
def _file_change(path: Path, contents: str):
    original = path.read_bytes()
    try:
        path.write_text(contents, encoding="utf-8")
        yield
    finally:
        path.write_bytes(original)


@contextmanager
def _platform_pin_change():
    changed = json.loads(RUNTIME_PROVENANCE)
    changed["platformArchiveSha256"] = "d" * 64
    with (
        patch(
            "generated_sdkconfig.WAVESHARE_PLATFORM_ARCHIVE_SHA256",
            "d" * 64,
        ),
        patch.dict(
            os.environ,
            {
                "OPEN_BIKE_FIRMWARE_RUNTIME_PROVENANCE": json.dumps(
                    changed, sort_keys=True
                )
            },
        ),
    ):
        yield


class GeneratedSdkconfigTests(unittest.TestCase):
    def setUp(self) -> None:
        self.runtime_patch = patch.dict(
            os.environ,
            {"OPEN_BIKE_FIRMWARE_RUNTIME_PROVENANCE": RUNTIME_PROVENANCE},
        )
        self.runtime_patch.start()
        self.addCleanup(self.runtime_patch.stop)
        self.source_identity_patch = patch(
            "generated_sdkconfig.current_source_identity",
            return_value="a" * 40,
        )
        self.source_identity_patch.start()
        self.addCleanup(self.source_identity_patch.stop)
        self.source_date_epoch_patch = patch(
            "generated_sdkconfig.git_commit_source_date_epoch",
            return_value="1712345678",
        )
        self.source_date_epoch_mock = self.source_date_epoch_patch.start()
        self.addCleanup(self.source_date_epoch_patch.stop)
        self.tracked_patch = patch(
            "generated_sdkconfig._is_tracked", return_value=False
        )
        self.tracked_patch.start()
        self.addCleanup(self.tracked_patch.stop)
        self.artifact_patch = patch(
            "generated_sdkconfig._firmware_artifact_hashes",
            return_value={
                "firmwareElfSha256": "e" * 64,
                "firmwareBinSha256": "b" * 64,
                "bootloaderBinSha256": "l" * 64,
                "partitionTableBinSha256": "p" * 64,
            },
        )
        self.artifact_patch.start()
        self.addCleanup(self.artifact_patch.stop)
        self.flash_plan = {
            "schema": 1,
            "environment": "WAVESHARE_AMOLED_175",
            "uploadPortPlaceholder": "__OPEN_BIKE_UPLOAD_PORT__",
            "uploader": "/attested/esptool",
            "command": ["/attested/esptool", "write-flash"],
            "images": [],
        }
        self.flash_plan_patch = patch(
            "generated_sdkconfig._validated_flash_plan",
            return_value=self.flash_plan,
        )
        self.flash_plan_patch.start()
        self.addCleanup(self.flash_plan_patch.stop)

    def test_matches_platformio_windows_legacy_default_core(self) -> None:
        with (
            patch("generated_sdkconfig.sys.platform", "win32"),
            patch(
                "generated_sdkconfig.os.path.expanduser",
                return_value="C:\\Users\\tester",
            ),
            patch(
                "generated_sdkconfig.os.path.isdir",
                side_effect=lambda path: str(path) == "C:\\.platformio",
            ),
        ):
            self.assertEqual(
                str(_default_platformio_core_dir()), "C:\\.platformio"
            )

    def test_duplicate_runtime_provenance_key_fails_closed(self) -> None:
        duplicate = RUNTIME_PROVENANCE.rstrip("}") + ',"lockSetId":"other"}'
        with patch.dict(
            os.environ,
            {"OPEN_BIKE_FIRMWARE_RUNTIME_PROVENANCE": duplicate},
        ):
            self.assertIsNone(_runtime_provenance())

    @contextmanager
    def fake_core(self, project: Path):
        for relative in (
            "prebuild.py",
            "tools/build_firmware.py",
            "tools/generated_sdkconfig.py",
            "tools/pioarduino_custom_core.py",
            "tools/firmware_runtime.py",
        ):
            path = project / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"unit test {relative}\n", encoding="utf-8")
        core = project / "platformio-core"
        package_root = core / "packages"
        platform_root = core / "platforms/espressif32"
        framework_root = package_root / "framework-arduinoespressif32"
        libs_root = package_root / "framework-arduinoespressif32-libs"
        files = (
            framework_root / "package.json",
            libs_root / "package.json",
            libs_root / "esp32s3/sdkconfig",
            platform_root / "platform.json",
            platform_root / ".piopm",
            platform_root / "builder/frameworks/arduino.py",
            platform_root / "builder/frameworks/espidf.py",
            platform_root / "boards/esp32-s3-devkitc-1.json",
            libs_root / "esp32s3/qio_opi/include/sdkconfig.h",
            libs_root / "esp32s3/qio_opi/libcore.a",
            libs_root / "esp32s3/lib/libgeneric.a",
            framework_root / "cores/esp32/core.cpp",
            framework_root / "tools/partitions/boot_app0.bin",
        )
        for path in files:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"attested {path.name}\n", encoding="utf-8")
        for path in (
            core / "tools/toolchain-xtensa-esp-elf/bin/xtensa-esp-elf-gcc",
            core / "penv/bin/platformio-runtime.py",
            core / "penv/bin/esptool",
            core / "penv/.espidf-5.5.1/bin/python",
        ):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"attested {path.name}\n", encoding="utf-8")
            path.chmod(0o755)
        (core / "lib").mkdir()
        (core / "boards").mkdir()
        with patch.dict(
            os.environ,
            {
                "PLATFORMIO_CORE_DIR": str(core),
                "PLATFORMIO_PACKAGES_DIR": str(package_root),
                "PLATFORMIO_PLATFORMS_DIR": str(core / "platforms"),
            },
        ):
            yield core

    def test_requires_a_safe_executable_esptool_in_core_attestation(self) -> None:
        for state in ("missing", "symlink", "not-executable"):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as directory:
                project = Path(directory)
                defaults = project / "sdkconfig.defaults"
                (project / "platformio.ini").write_text(
                    "[env:WAVESHARE_AMOLED_175]\nplatform = test\n",
                    encoding="utf-8",
                )
                defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
                with self.fake_core(project) as core:
                    uploader = core / "penv/bin/esptool"
                    if state == "missing":
                        uploader.unlink()
                    elif state == "symlink":
                        external = project / "external-esptool"
                        external.write_text("external\n", encoding="utf-8")
                        external.chmod(0o755)
                        uploader.unlink()
                        uploader.symlink_to(external)
                    else:
                        uploader.chmod(0o644)
                    self.assertIsNone(
                        record_generated_sdkconfig_defaults(
                            project, "WAVESHARE_AMOLED_175"
                        )
                    )

    def test_requires_one_executable_esp_idf_python_environment(self) -> None:
        for state in ("missing", "multiple", "not-executable"):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as directory:
                project = Path(directory)
                defaults = project / "sdkconfig.defaults"
                (project / "platformio.ini").write_text(
                    "[env:WAVESHARE_AMOLED_175]\nplatform = test\n",
                    encoding="utf-8",
                )
                defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
                with self.fake_core(project) as core:
                    python = core / "penv/.espidf-5.5.1/bin/python"
                    if state == "missing":
                        python.unlink()
                    elif state == "multiple":
                        other = core / "penv/.espidf-other/bin/python"
                        other.parent.mkdir(parents=True)
                        other.write_text("attested python\n", encoding="utf-8")
                        other.chmod(0o755)
                    else:
                        python.chmod(0o644)
                    self.assertIsNone(
                        record_generated_sdkconfig_defaults(
                            project, "WAVESHARE_AMOLED_175"
                        )
                    )

    def test_manifest_attests_the_git_derived_build_clock(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            defaults = project / "sdkconfig.defaults"
            (project / "platformio.ini").write_text(
                "[env:WAVESHARE_AMOLED_175]\nplatform = test\n",
                encoding="utf-8",
            )
            defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
            with self.fake_core(project):
                manifest_path = record_generated_sdkconfig_defaults(
                    project, "WAVESHARE_AMOLED_175"
                )
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

                self.assertEqual(manifest["schema"], 20)
                self.assertEqual(
                    manifest["runtimeProvenance"], json.loads(RUNTIME_PROVENANCE)
                )
                self.assertEqual(manifest["sourceDateEpoch"], "1712345678")
                self.assertEqual(
                    manifest["buildTimestamp"], "2024-04-05T19:34:38Z"
                )

                self.source_date_epoch_mock.return_value = "1712345679"
                with self.assertRaisesRegex(
                    GeneratedSdkconfigError, "firmware build identity changed"
                ):
                    require_validated_generated_sdkconfig_defaults(
                        project, "WAVESHARE_AMOLED_175"
                    )

    def test_runtime_identity_is_required_and_invalidates_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            defaults = project / "sdkconfig.defaults"
            (project / "platformio.ini").write_text(
                "[env:WAVESHARE_AMOLED_175]\nplatform = test\n",
                encoding="utf-8",
            )
            defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
            with self.fake_core(project):
                self.assertIsNotNone(
                    record_generated_sdkconfig_defaults(
                        project, "WAVESHARE_AMOLED_175"
                    )
                )
                changed = json.loads(RUNTIME_PROVENANCE)
                changed["bundleSha256"] = "c" * 64
                with patch.dict(
                    os.environ,
                    {
                        "OPEN_BIKE_FIRMWARE_RUNTIME_PROVENANCE": json.dumps(
                            changed, sort_keys=True
                        )
                    },
                ):
                    self.assertEqual(
                        prepare_generated_sdkconfigs(
                            project, "WAVESHARE_AMOLED_175"
                        ),
                        (),
                    )
            self.assertFalse(defaults.exists())

        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            defaults = project / "sdkconfig.defaults"
            (project / "platformio.ini").write_text(
                "[env:WAVESHARE_AMOLED_175]\nplatform = test\n",
                encoding="utf-8",
            )
            defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
            with self.fake_core(project), patch.dict(
                os.environ,
                {"OPEN_BIKE_FIRMWARE_RUNTIME_PROVENANCE": "{}"},
            ):
                self.assertIsNone(
                    record_generated_sdkconfig_defaults(
                        project, "WAVESHARE_AMOLED_175"
                    )
                )

    def test_uploader_mode_change_invalidates_recorded_core(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            defaults = project / "sdkconfig.defaults"
            (project / "platformio.ini").write_text(
                "[env:WAVESHARE_AMOLED_175]\nplatform = test\n",
                encoding="utf-8",
            )
            defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
            with self.fake_core(project) as core:
                record_generated_sdkconfig_defaults(
                    project, "WAVESHARE_AMOLED_175"
                )
                (core / "penv/bin/esptool").chmod(0o644)
                with self.assertRaisesRegex(
                    GeneratedSdkconfigError, "custom-core state changed"
                ):
                    require_validated_generated_sdkconfig_defaults(
                        project, "WAVESHARE_AMOLED_175"
                    )

    def test_preserves_successfully_recorded_custom_core_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            defaults = project / "sdkconfig.defaults"
            current = project / "sdkconfig.WAVESHARE_AMOLED_175"
            other = project / "sdkconfig.WAVESHARE_AMOLED_206"
            (project / "platformio.ini").write_text(
                "[env:WAVESHARE_AMOLED_175]\nplatform = test\n",
                encoding="utf-8",
            )
            for path in (defaults, current, other):
                path.write_text(GENERATED_CONFIG, encoding="utf-8")

            with self.fake_core(project):
                selected_core_key = core_input_key(
                    project, "WAVESHARE_AMOLED_175"
                )
                self.assertIsNotNone(selected_core_key)
                record_generated_sdkconfig_defaults(
                    project, "WAVESHARE_AMOLED_175"
                )
                self.assertEqual(
                    prepare_generated_sdkconfigs(
                        project, "WAVESHARE_AMOLED_175"
                    ),
                    (defaults, current),
                )
                self.assertEqual(
                    core_input_key(project, "WAVESHARE_AMOLED_175"),
                    selected_core_key,
                )
                self.assertIsNotNone(
                    record_generated_sdkconfig_defaults(
                        project,
                        "WAVESHARE_AMOLED_175",
                        core_cache_status="hit",
                        expected_core_input_key=selected_core_key,
                    )
                )
            self.assertTrue(defaults.is_file())
            self.assertTrue(current.is_file())
            self.assertFalse(other.exists())

    def test_invalidates_cached_defaults_after_content_or_config_change(self) -> None:
        for change_platformio in (False, True):
            with self.subTest(change_platformio=change_platformio):
                with tempfile.TemporaryDirectory() as directory:
                    project = Path(directory)
                    defaults = project / "sdkconfig.defaults"
                    platformio_ini = project / "platformio.ini"
                    platformio_ini.write_text(
                        "[env:WAVESHARE_AMOLED_175]\nplatform = test\n",
                        encoding="utf-8",
                    )
                    defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
                    with self.fake_core(project):
                        record_generated_sdkconfig_defaults(
                            project, "WAVESHARE_AMOLED_175"
                        )
                        if change_platformio:
                            platformio_ini.write_text(
                                "[env:WAVESHARE_AMOLED_175]\nplatform = changed\n",
                                encoding="utf-8",
                            )
                        else:
                            defaults.write_text(
                                GENERATED_CONFIG + "CONFIG_UNRECORDED=y\n",
                                encoding="utf-8",
                            )

                        self.assertEqual(
                            prepare_generated_sdkconfigs(
                                project, "WAVESHARE_AMOLED_175"
                            ),
                            (),
                        )
                    self.assertFalse(defaults.exists())

    def test_core_reuse_ignores_stale_exact_build_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            defaults = project / "sdkconfig.defaults"
            environment = project / "sdkconfig.WAVESHARE_AMOLED_175"
            (project / "platformio.ini").write_text(
                "[env:WAVESHARE_AMOLED_175]\nplatform = test\n",
                encoding="utf-8",
            )
            defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
            environment.write_text(GENERATED_CONFIG, encoding="utf-8")
            with self.fake_core(project):
                manifest_path = record_generated_sdkconfig_defaults(
                    project, "WAVESHARE_AMOLED_175"
                )
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                self.assertEqual(
                    manifest["environment"], "WAVESHARE_AMOLED_175"
                )
                manifest.pop("environmentSdkconfigSha256")
                manifest_path.write_text(
                    json.dumps(manifest) + "\n", encoding="utf-8"
                )
                with self.assertRaises(GeneratedSdkconfigError):
                    require_validated_generated_sdkconfig_defaults(
                        project, "WAVESHARE_AMOLED_175"
                    )

                self.assertEqual(
                    prepare_generated_sdkconfigs(
                        project, "WAVESHARE_AMOLED_175"
                    ),
                    (defaults, environment),
                )
            self.assertTrue(defaults.exists())
            self.assertTrue(environment.exists())

    def test_non_object_manifest_fails_closed_for_prepare_and_upload(self) -> None:
        for malformed in ([], None, "cache"):
            with self.subTest(malformed=malformed):
                with tempfile.TemporaryDirectory() as directory:
                    project = Path(directory)
                    defaults = project / "sdkconfig.defaults"
                    (project / "platformio.ini").write_text(
                        "[env:WAVESHARE_AMOLED_175]\nplatform = test\n",
                        encoding="utf-8",
                    )
                    defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
                    with self.fake_core(project):
                        manifest_path = record_generated_sdkconfig_defaults(
                            project, "WAVESHARE_AMOLED_175"
                        )
                        manifest_path.write_text(
                            json.dumps(malformed) + "\n", encoding="utf-8"
                        )
                        with self.assertRaises(GeneratedSdkconfigError):
                            require_validated_generated_sdkconfig_defaults(
                                project, "WAVESHARE_AMOLED_175"
                            )
                        self.assertEqual(
                            prepare_generated_sdkconfigs(
                                project, "WAVESHARE_AMOLED_175"
                            ),
                            (defaults,),
                        )
                    self.assertTrue(defaults.exists())

    def test_core_cache_is_independent_of_exact_source_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            defaults = project / "sdkconfig.defaults"
            (project / "platformio.ini").write_text(
                "[env:WAVESHARE_AMOLED_175]\nplatform = test\n",
                encoding="utf-8",
            )
            defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
            with self.fake_core(project):
                record_generated_sdkconfig_defaults(
                    project, "WAVESHARE_AMOLED_175"
                )
                with patch(
                    "generated_sdkconfig.current_source_identity",
                    return_value="b" * 40,
                ):
                    self.assertEqual(
                        prepare_generated_sdkconfigs(
                            project, "WAVESHARE_AMOLED_175"
                        ),
                        (defaults,),
                    )
            self.assertTrue(defaults.exists())

    def test_core_input_key_covers_every_declared_input_class(self) -> None:
        changes = {
            "runtime": lambda project: patch.dict(
                os.environ,
                {
                    "OPEN_BIKE_FIRMWARE_RUNTIME_PROVENANCE": RUNTIME_PROVENANCE.replace(
                        '"bundleSha256": "' + "2" * 64 + '"',
                        '"bundleSha256": "' + "c" * 64 + '"',
                    )
                },
            ),
            "platform-pin": lambda project: _platform_pin_change(),
            "platformio": lambda project: _file_change(
                project / "platformio.ini",
                "[env:WAVESHARE_AMOLED_175]\nplatform = changed\n",
            ),
            "generated-sdkconfig": lambda project: _file_change(
                project / "sdkconfig.defaults",
                GENERATED_CONFIG + "CONFIG_CHANGED=y\n",
            ),
            "core-tool": lambda project: _file_change(
                project / "tools/pioarduino_custom_core.py",
                "changed core tool\n",
            ),
            "component-input": lambda project: _file_change(
                project / "components/example/idf_component.yml",
                "dependencies:\n  vendor/example: 2.0.0\n",
            ),
        }

        for label, change in changes.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                project = Path(directory)
                (project / "platformio.ini").write_text(
                    "[env:WAVESHARE_AMOLED_175]\nplatform = test\n",
                    encoding="utf-8",
                )
                (project / "sdkconfig.defaults").write_text(
                    GENERATED_CONFIG, encoding="utf-8"
                )
                component_input = project / "components/example/idf_component.yml"
                component_input.parent.mkdir(parents=True)
                component_input.write_text(
                    "dependencies:\n  vendor/example: 1.0.0\n",
                    encoding="utf-8",
                )
                with self.fake_core(project):
                    original = core_input_key(project, "WAVESHARE_AMOLED_175")
                    self.assertRegex(original or "", r"^[0-9a-f]{64}$")
                    with change(project):
                        changed = core_input_key(project, "WAVESHARE_AMOLED_175")
                    self.assertRegex(changed or "", r"^[0-9a-f]{64}$")
                    self.assertNotEqual(original, changed)

    def test_legacy_combined_manifest_cannot_authorize_core_reuse(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            defaults = project / "sdkconfig.defaults"
            (project / "platformio.ini").write_text(
                "[env:WAVESHARE_AMOLED_175]\nplatform = test\n",
                encoding="utf-8",
            )
            defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
            legacy = project / ".pio/open-bike-build/sdkconfig-defaults.json"
            legacy.parent.mkdir(parents=True)
            legacy.write_text(
                json.dumps(
                    {
                        "schema": 18,
                        "sourceIdentity": "a" * 40,
                        "sdkconfigDefaultsSha256": "b" * 64,
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            with self.fake_core(project):
                self.assertEqual(
                    prepare_generated_sdkconfigs(
                        project, "WAVESHARE_AMOLED_175"
                    ),
                    (),
                )
            self.assertFalse(defaults.exists())
            self.assertTrue(legacy.is_file())

    def test_publishes_and_hydrates_an_immutable_core_archive(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            defaults = project / "sdkconfig.defaults"
            (project / "platformio.ini").write_text(
                "[env:WAVESHARE_AMOLED_175]\nplatform = test\n",
                encoding="utf-8",
            )
            defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
            with self.fake_core(project) as core:
                manifest_path = record_generated_sdkconfig_defaults(
                    project, "WAVESHARE_AMOLED_175"
                )
                build_manifest = json.loads(
                    manifest_path.read_text(encoding="utf-8")
                )
                entry = (
                    project
                    / ".pio/open-bike-build/core-cache/WAVESHARE_AMOLED_175"
                    / build_manifest["coreInputKey"]
                )
                archive = entry / "core-artifacts.tar"
                self.assertTrue(archive.is_file())
                self.assertEqual(
                    build_manifest["coreArchiveSize"], archive.stat().st_size
                )
                self.assertRegex(
                    build_manifest["coreArchiveSha256"], r"^[0-9a-f]{64}$"
                )
                self.assertEqual(entry.stat().st_mode & 0o777, 0o555)
                self.assertTrue(
                    all(
                        child.stat().st_mode & 0o777 == 0o444
                        for child in entry.iterdir()
                    )
                )

                for child in (
                    "packages",
                    "platforms",
                    "tools",
                    "penv",
                    "lib",
                    "boards",
                ):
                    shutil.rmtree(core / child)

                self.assertEqual(
                    prepare_generated_sdkconfigs(
                        project, "WAVESHARE_AMOLED_175"
                    ),
                    (defaults,),
                )
                self.assertTrue((core / "penv/bin/esptool").is_file())
                self.assertTrue(
                    (core / "packages/framework-arduinoespressif32/cores/esp32/core.cpp").is_file()
                )

    def test_interrupted_publication_preserves_the_previous_entry(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            defaults = project / "sdkconfig.defaults"
            platformio_ini = project / "platformio.ini"
            platformio_ini.write_text(
                "[env:WAVESHARE_AMOLED_175]\nplatform = test\n",
                encoding="utf-8",
            )
            defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
            with self.fake_core(project):
                first_path = record_generated_sdkconfig_defaults(
                    project, "WAVESHARE_AMOLED_175"
                )
                first = json.loads(first_path.read_text(encoding="utf-8"))
                environment_root = (
                    project
                    / ".pio/open-bike-build/core-cache/WAVESHARE_AMOLED_175"
                )
                first_entry = environment_root / first["coreInputKey"]
                self.assertTrue(first_entry.is_dir())

                platformio_ini.write_text(
                    "[env:WAVESHARE_AMOLED_175]\nplatform = changed\n",
                    encoding="utf-8",
                )
                real_replace = os.replace

                def interrupt_final_publish(source, destination):
                    destination_path = Path(destination)
                    if (
                        destination_path.parent == environment_root
                        and destination_path != first_entry
                    ):
                        raise OSError("injected publication interruption")
                    return real_replace(source, destination)

                with patch(
                    "generated_sdkconfig.os.replace",
                    side_effect=interrupt_final_publish,
                ):
                    with self.assertRaisesRegex(
                        GeneratedSdkconfigError, "could not publish"
                    ):
                        record_generated_sdkconfig_defaults(
                            project, "WAVESHARE_AMOLED_175"
                        )

                self.assertTrue(first_entry.is_dir())
                self.assertEqual(
                    sorted(
                        child.name
                        for child in environment_root.iterdir()
                        if child.is_dir() and not child.name.startswith(".")
                    ),
                    [first["coreInputKey"]],
                )
                self.assertFalse(
                    any(child.name.startswith(".") for child in environment_root.iterdir())
                )

    def test_corrupt_archive_is_quarantined_and_forces_a_miss(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            defaults = project / "sdkconfig.defaults"
            (project / "platformio.ini").write_text(
                "[env:WAVESHARE_AMOLED_175]\nplatform = test\n",
                encoding="utf-8",
            )
            defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
            with self.fake_core(project):
                manifest_path = record_generated_sdkconfig_defaults(
                    project, "WAVESHARE_AMOLED_175"
                )
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                environment_root = (
                    project
                    / ".pio/open-bike-build/core-cache/WAVESHARE_AMOLED_175"
                )
                entry = environment_root / manifest["coreInputKey"]
                archive = entry / "core-artifacts.tar"
                archive.chmod(0o644)
                archive.write_bytes(archive.read_bytes()[:-512])

                self.assertEqual(
                    prepare_generated_sdkconfigs(
                        project, "WAVESHARE_AMOLED_175"
                    ),
                    (),
                )
                self.assertFalse(entry.exists())
                self.assertEqual(
                    len(list((environment_root / "quarantine").iterdir())), 1
                )
            self.assertFalse(defaults.exists())

    def test_duplicate_core_manifest_key_is_quarantined(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            defaults = project / "sdkconfig.defaults"
            (project / "platformio.ini").write_text(
                "[env:WAVESHARE_AMOLED_175]\nplatform = test\n",
                encoding="utf-8",
            )
            defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
            with self.fake_core(project):
                build_manifest_path = record_generated_sdkconfig_defaults(
                    project, "WAVESHARE_AMOLED_175"
                )
                build_manifest = json.loads(
                    build_manifest_path.read_text(encoding="utf-8")
                )
                environment_root = (
                    project
                    / ".pio/open-bike-build/core-cache/WAVESHARE_AMOLED_175"
                )
                entry = environment_root / build_manifest["coreInputKey"]
                core_manifest_path = entry / "manifest.json"
                original = core_manifest_path.read_text(encoding="utf-8").rstrip()
                core_manifest_path.chmod(0o644)
                core_manifest_path.write_text(
                    original[:-1] + ',"schema":2}\n', encoding="utf-8"
                )

                self.assertEqual(
                    prepare_generated_sdkconfigs(
                        project, "WAVESHARE_AMOLED_175"
                    ),
                    (),
                )
                self.assertFalse(entry.exists())
                self.assertEqual(
                    len(list((environment_root / "quarantine").iterdir())), 1
                )
            self.assertFalse(defaults.exists())

    def test_extra_symlinked_and_wrong_owner_entries_fail_closed(self) -> None:
        for attack in (
            "extra-file",
            "symlink-archive",
            "hardlinked-archive",
            "writable-entry",
            "wrong-owner",
        ):
            with self.subTest(attack=attack), tempfile.TemporaryDirectory() as directory:
                project = Path(directory)
                defaults = project / "sdkconfig.defaults"
                (project / "platformio.ini").write_text(
                    "[env:WAVESHARE_AMOLED_175]\nplatform = test\n",
                    encoding="utf-8",
                )
                defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
                with self.fake_core(project):
                    manifest_path = record_generated_sdkconfig_defaults(
                        project, "WAVESHARE_AMOLED_175"
                    )
                    manifest = json.loads(
                        manifest_path.read_text(encoding="utf-8")
                    )
                    entry = (
                        project
                        / ".pio/open-bike-build/core-cache/WAVESHARE_AMOLED_175"
                        / manifest["coreInputKey"]
                    )
                    if attack == "extra-file":
                        entry.chmod(0o755)
                        (entry / "injected").write_text("untrusted\n")
                        owner_context = patch(
                            "generated_sdkconfig.os.getuid",
                            wraps=os.getuid,
                        )
                    elif attack == "symlink-archive":
                        archive = entry / "core-artifacts.tar"
                        external = project / "external-core-artifacts.tar"
                        shutil.copyfile(archive, external)
                        entry.chmod(0o755)
                        archive.chmod(0o644)
                        archive.unlink()
                        archive.symlink_to(external)
                        owner_context = patch(
                            "generated_sdkconfig.os.getuid",
                            wraps=os.getuid,
                        )
                    elif attack == "hardlinked-archive":
                        archive = entry / "core-artifacts.tar"
                        external = project / "external-core-artifacts.tar"
                        entry.chmod(0o755)
                        archive.chmod(0o644)
                        archive.rename(external)
                        os.link(external, archive)
                        archive.chmod(0o444)
                        owner_context = patch(
                            "generated_sdkconfig.os.getuid",
                            wraps=os.getuid,
                        )
                    elif attack == "writable-entry":
                        (entry / "manifest.json").chmod(0o644)
                        owner_context = patch(
                            "generated_sdkconfig.os.getuid",
                            wraps=os.getuid,
                        )
                    else:
                        owner_context = patch(
                            "generated_sdkconfig.os.getuid",
                            return_value=os.getuid() + 1,
                        )
                    with owner_context:
                        self.assertEqual(
                            prepare_generated_sdkconfigs(
                                project, "WAVESHARE_AMOLED_175"
                            ),
                            (),
                        )
                    self.assertFalse(entry.exists())

    def test_rejects_symlinked_core_cache_ancestor_without_quarantine(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            defaults = project / "sdkconfig.defaults"
            (project / "platformio.ini").write_text(
                "[env:WAVESHARE_AMOLED_175]\nplatform = test\n",
                encoding="utf-8",
            )
            defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
            with self.fake_core(project):
                manifest_path = record_generated_sdkconfig_defaults(
                    project, "WAVESHARE_AMOLED_175"
                )
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                cache_root = project / ".pio/open-bike-build/core-cache"
                external = project / "external-core-cache"
                cache_root.rename(external)
                cache_root.symlink_to(external, target_is_directory=True)

                with self.assertRaisesRegex(
                    GeneratedSdkconfigError, "symlinked ancestor"
                ):
                    prepare_generated_sdkconfigs(
                        project, "WAVESHARE_AMOLED_175"
                    )

                preserved_entry = (
                    external
                    / "WAVESHARE_AMOLED_175"
                    / manifest["coreInputKey"]
                )
                self.assertTrue(preserved_entry.is_dir())
                self.assertFalse(
                    (external / "WAVESHARE_AMOLED_175/quarantine").exists()
                )

    def test_dirty_build_consumes_but_cannot_publish_a_core_entry(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            defaults = project / "sdkconfig.defaults"
            platformio_ini = project / "platformio.ini"
            platformio_ini.write_text(
                "[env:WAVESHARE_AMOLED_175]\nplatform = test\n",
                encoding="utf-8",
            )
            defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
            with self.fake_core(project):
                record_generated_sdkconfig_defaults(
                    project, "WAVESHARE_AMOLED_175"
                )
                with patch(
                    "generated_sdkconfig.current_source_identity",
                    return_value="dirty-diagnostic",
                ):
                    self.assertEqual(
                        prepare_generated_sdkconfigs(
                            project, "WAVESHARE_AMOLED_175"
                        ),
                        (defaults,),
                    )
                    platformio_ini.write_text(
                        "[env:WAVESHARE_AMOLED_175]\nplatform = changed\n",
                        encoding="utf-8",
                    )
                    self.assertIsNone(
                        record_generated_sdkconfig_defaults(
                            project, "WAVESHARE_AMOLED_175"
                        )
                    )
            cache_entries = list(
                (
                    project
                    / ".pio/open-bike-build/core-cache/WAVESHARE_AMOLED_175"
                ).glob("[0-9a-f]*")
            )
            self.assertEqual(len(cache_entries), 1)

    def test_modified_managed_component_invalidates_and_is_regenerated(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            defaults = project / "sdkconfig.defaults"
            component = project / "managed_components/vendor__component"
            component.mkdir(parents=True)
            (component / ".component_hash").write_text("registry hash\n")
            source = component / "component.cpp"
            source.write_text("trusted\n")
            (project / "platformio.ini").write_text(
                "[env:WAVESHARE_AMOLED_175]\nplatform = test\n",
                encoding="utf-8",
            )
            defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
            with self.fake_core(project):
                record_generated_sdkconfig_defaults(
                    project, "WAVESHARE_AMOLED_175"
                )
                source.write_text("modified but stale component hash\n")
                self.assertEqual(
                    prepare_generated_sdkconfigs(
                        project, "WAVESHARE_AMOLED_175"
                    ),
                    (defaults,),
                )
                self.assertEqual(source.read_text(), "trusted\n")
            self.assertTrue(defaults.exists())

    def test_modified_library_dependency_invalidates_and_is_regenerated(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            defaults = project / "sdkconfig.defaults"
            library = (
                project
                / ".pio/libdeps/WAVESHARE_AMOLED_175/Dependency/src/library.cpp"
            )
            library.parent.mkdir(parents=True)
            library.write_text("trusted\n")
            (project / "platformio.ini").write_text(
                "[env:WAVESHARE_AMOLED_175]\nplatform = test\n",
                encoding="utf-8",
            )
            defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
            with self.fake_core(project):
                record_generated_sdkconfig_defaults(
                    project, "WAVESHARE_AMOLED_175"
                )
                library.write_text("modified ignored dependency\n")
                self.assertEqual(
                    prepare_generated_sdkconfigs(
                        project, "WAVESHARE_AMOLED_175"
                    ),
                    (defaults,),
                )
                self.assertEqual(library.read_text(), "trusted\n")
            self.assertTrue(defaults.exists())

    def test_invalidates_cache_after_global_custom_core_change(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            defaults = project / "sdkconfig.defaults"
            (project / "platformio.ini").write_text(
                "[env:WAVESHARE_AMOLED_175]\nplatform = test\n",
                encoding="utf-8",
            )
            defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
            with self.fake_core(project) as core:
                record_generated_sdkconfig_defaults(
                    project, "WAVESHARE_AMOLED_175"
                )
                (core / "packages/framework-arduinoespressif32-libs/esp32s3/"
                 "lib/libgeneric.a").write_text(
                    "mutated by another project\n", encoding="utf-8"
                )
                self.assertEqual(
                    prepare_generated_sdkconfigs(
                        project, "WAVESHARE_AMOLED_175"
                    ),
                    (defaults,),
                )
                self.assertEqual(
                    (core / "packages/framework-arduinoespressif32-libs/esp32s3/"
                     "lib/libgeneric.a").read_text(),
                    "attested libgeneric.a\n",
                )
            self.assertTrue(defaults.exists())

    def test_invalidates_cache_after_compiler_or_runtime_change(self) -> None:
        for relative in (
            "packages/tool-esptoolpy/esptool.py",
            "tools/toolchain-xtensa-esp-elf/bin/xtensa-esp-elf-gcc",
            "penv/bin/platformio-runtime.py",
            "penv/.espidf-5.5.1/bin/python",
        ):
            with self.subTest(relative=relative):
                with tempfile.TemporaryDirectory() as directory:
                    project = Path(directory)
                    defaults = project / "sdkconfig.defaults"
                    (project / "platformio.ini").write_text(
                        "[env:WAVESHARE_AMOLED_175]\nplatform = test\n",
                        encoding="utf-8",
                    )
                    defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
                    with self.fake_core(project) as core:
                        target = core / relative
                        target.parent.mkdir(parents=True, exist_ok=True)
                        target.write_text("trusted tool\n", encoding="utf-8")
                        record_generated_sdkconfig_defaults(
                            project, "WAVESHARE_AMOLED_175"
                        )
                        target.write_text("modified tool\n", encoding="utf-8")
                        self.assertEqual(
                            prepare_generated_sdkconfigs(
                                project, "WAVESHARE_AMOLED_175"
                            ),
                            (defaults,),
                        )
                        self.assertEqual(target.read_text(), "trusted tool\n")
                    self.assertTrue(defaults.exists())

    def test_core_digest_changes_with_attested_runtime_state(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            defaults = project / "sdkconfig.defaults"
            (project / "platformio.ini").write_text(
                "[env:WAVESHARE_AMOLED_175]\nplatform = test\n",
                encoding="utf-8",
            )
            defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
            with self.fake_core(project) as core:
                first_path = record_generated_sdkconfig_defaults(
                    project, "WAVESHARE_AMOLED_175"
                )
                first = json.loads(first_path.read_text(encoding="utf-8"))
                runtime = core / "penv/bin/platformio-runtime.py"
                runtime.write_text("changed runtime\n", encoding="utf-8")
                with self.assertRaisesRegex(
                    GeneratedSdkconfigError, "changed during the application build"
                ):
                    record_generated_sdkconfig_defaults(
                        project, "WAVESHARE_AMOLED_175"
                    )

            self.assertRegex(first["coreAttestationSha256"], r"^[0-9a-f]{64}$")

    def test_global_libraries_and_core_boards_invalidate_attestation(self) -> None:
        for relative in (
            "lib/Injected/src/injected.cpp",
            "boards/esp32-s3-devkitc-1.json",
        ):
            with self.subTest(relative=relative):
                with tempfile.TemporaryDirectory() as directory:
                    project = Path(directory)
                    defaults = project / "sdkconfig.defaults"
                    (project / "platformio.ini").write_text(
                        "[env:WAVESHARE_AMOLED_175]\nplatform = test\n",
                        encoding="utf-8",
                    )
                    defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
                    with self.fake_core(project) as core:
                        record_generated_sdkconfig_defaults(
                            project, "WAVESHARE_AMOLED_175"
                        )
                        injected = core / relative
                        injected.parent.mkdir(parents=True, exist_ok=True)
                        injected.write_text("unattested override\n", encoding="utf-8")
                        self.assertEqual(
                            prepare_generated_sdkconfigs(
                                project, "WAVESHARE_AMOLED_175"
                            ),
                            (defaults,),
                        )
                        self.assertFalse(injected.exists())
                    self.assertTrue(defaults.exists())

    def test_rejects_tampered_top_level_bootstrap_hash(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            defaults = project / "sdkconfig.defaults"
            (project / "platformio.ini").write_text(
                "[env:WAVESHARE_AMOLED_175]\nplatform = test\n",
                encoding="utf-8",
            )
            defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
            with self.fake_core(project):
                manifest_path = record_generated_sdkconfig_defaults(
                    project, "WAVESHARE_AMOLED_175"
                )
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                manifest["bootApp0Sha256"] = "0" * 64
                manifest_path.write_text(
                    json.dumps(manifest) + "\n", encoding="utf-8"
                )
                with self.assertRaisesRegex(
                    GeneratedSdkconfigError, "core reference changed"
                ):
                    require_validated_generated_sdkconfig_defaults(
                        project, "WAVESHARE_AMOLED_175"
                    )

    def test_invalidates_cache_for_symlinked_core_subtree(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            defaults = project / "sdkconfig.defaults"
            (project / "platformio.ini").write_text(
                "[env:WAVESHARE_AMOLED_175]\nplatform = test\n",
                encoding="utf-8",
            )
            defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
            with self.fake_core(project) as core:
                record_generated_sdkconfig_defaults(
                    project, "WAVESHARE_AMOLED_175"
                )
                external = project / "external-library"
                external.mkdir()
                (external / "injected.a").write_text(
                    "unattested code\n", encoding="utf-8"
                )
                injected = (
                    core
                    / "packages/framework-arduinoespressif32-libs/esp32s3/injected"
                )
                injected.symlink_to(external, target_is_directory=True)

                self.assertEqual(
                    prepare_generated_sdkconfigs(
                        project, "WAVESHARE_AMOLED_175"
                    ),
                    (defaults,),
                )
                self.assertFalse(injected.exists())
            self.assertTrue(defaults.exists())

    def test_invalidates_cache_for_symlinked_framework_libs_root(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            defaults = project / "sdkconfig.defaults"
            (project / "platformio.ini").write_text(
                "[env:WAVESHARE_AMOLED_175]\nplatform = test\n",
                encoding="utf-8",
            )
            defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
            with self.fake_core(project) as core:
                record_generated_sdkconfig_defaults(
                    project, "WAVESHARE_AMOLED_175"
                )
                libs = (
                    core / "packages/framework-arduinoespressif32-libs"
                )
                external = project / "external-framework-libs"
                libs.rename(external)
                libs.symlink_to(external, target_is_directory=True)
                self.assertEqual(
                    prepare_generated_sdkconfigs(
                        project, "WAVESHARE_AMOLED_175"
                    ),
                    (defaults,),
                )
                self.assertFalse(libs.is_symlink())
            self.assertTrue(defaults.exists())

    def test_honors_independent_package_and_platform_overrides(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            defaults = project / "sdkconfig.defaults"
            (project / "platformio.ini").write_text(
                "[platformio]\ndescription = test\n",
                encoding="utf-8",
            )
            defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
            with self.fake_core(project) as core:
                packages = project / "custom-packages"
                platforms = project / "custom-platforms"
                shutil.copytree(core / "packages", packages)
                shutil.copytree(core / "platforms", platforms)
                overrides = {
                    "PLATFORMIO_CORE_DIR": str(core),
                    "PLATFORMIO_PACKAGES_DIR": str(packages),
                    "PLATFORMIO_PLATFORMS_DIR": str(platforms),
                }
                with patch.dict(os.environ, overrides):
                    record_generated_sdkconfig_defaults(
                        project, "WAVESHARE_AMOLED_175"
                    )
                    manifest = record_generated_sdkconfig_defaults(
                        project, "WAVESHARE_AMOLED_175"
                    ).read_text(encoding="utf-8")
                    self.assertIn(str(packages.resolve()), manifest)
                    self.assertIn(str(platforms.resolve()), manifest)
                    (packages / "framework-arduinoespressif32-libs/esp32s3/"
                     "lib/libgeneric.a").write_text(
                        "mutated override\n", encoding="utf-8"
                    )
                    self.assertEqual(
                        prepare_generated_sdkconfigs(
                            project, "WAVESHARE_AMOLED_175"
                        ),
                        (defaults,),
                    )
                    self.assertEqual(
                        (packages / "framework-arduinoespressif32-libs/esp32s3/"
                         "lib/libgeneric.a").read_text(),
                        "attested libgeneric.a\n",
                    )
            self.assertTrue(defaults.exists())

    def test_relative_env_store_overrides_resolve_from_project(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            defaults = project / "sdkconfig.defaults"
            (project / "platformio.ini").write_text(
                "[platformio]\ndescription = test\n",
                encoding="utf-8",
            )
            defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
            with self.fake_core(project) as core:
                packages = project / "relative-packages"
                platforms = project / "relative-platforms"
                shutil.copytree(core / "packages", packages)
                shutil.copytree(core / "platforms", platforms)
                overrides = {
                    "PLATFORMIO_CORE_DIR": "platformio-core",
                    "PLATFORMIO_PACKAGES_DIR": "relative-packages",
                    "PLATFORMIO_PLATFORMS_DIR": "relative-platforms",
                }
                with patch.dict(os.environ, overrides):
                    manifest_path = record_generated_sdkconfig_defaults(
                        project, "WAVESHARE_AMOLED_175"
                    )
                    self.assertIsNotNone(manifest_path)
                    manifest = manifest_path.read_text(encoding="utf-8")
                    self.assertIn(str(packages.resolve()), manifest)
                    self.assertIn(str(platforms.resolve()), manifest)

    def test_honors_legacy_platformio_home_dir_environment_alias(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            defaults = project / "sdkconfig.defaults"
            (project / "platformio.ini").write_text(
                "[platformio]\ndescription = test\n",
                encoding="utf-8",
            )
            defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
            with self.fake_core(project) as core:
                legacy_environment = {
                    "PLATFORMIO_CORE_DIR": "",
                    "PLATFORMIO_HOME_DIR": str(core),
                    "PLATFORMIO_PACKAGES_DIR": "",
                    "PLATFORMIO_PLATFORMS_DIR": "",
                }
                with patch.dict(os.environ, legacy_environment):
                    manifest_path = record_generated_sdkconfig_defaults(
                        project, "WAVESHARE_AMOLED_175"
                    )
                    manifest = manifest_path.read_text(encoding="utf-8")
                    self.assertIn(str(core.resolve()), manifest)
                    (core / "packages/framework-arduinoespressif32-libs/esp32s3/"
                     "lib/libgeneric.a").write_text(
                        "mutated legacy core\n", encoding="utf-8"
                    )
                    self.assertEqual(
                        prepare_generated_sdkconfigs(
                            project, "WAVESHARE_AMOLED_175"
                        ),
                        (defaults,),
                    )
                    self.assertEqual(
                        (core / "packages/framework-arduinoespressif32-libs/esp32s3/"
                         "lib/libgeneric.a").read_text(),
                        "attested libgeneric.a\n",
                    )

    def test_modern_core_environment_takes_priority_over_legacy_alias(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            defaults = project / "sdkconfig.defaults"
            (project / "platformio.ini").write_text(
                "[platformio]\ndescription = test\n",
                encoding="utf-8",
            )
            defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
            with self.fake_core(project) as core:
                legacy_core = project / "legacy-core"
                shutil.copytree(core, legacy_core)
                overrides = {
                    "PLATFORMIO_CORE_DIR": str(core),
                    "PLATFORMIO_HOME_DIR": str(legacy_core),
                    "PLATFORMIO_PACKAGES_DIR": "",
                    "PLATFORMIO_PLATFORMS_DIR": "",
                }
                with patch.dict(os.environ, overrides):
                    manifest_path = record_generated_sdkconfig_defaults(
                        project, "WAVESHARE_AMOLED_175"
                    )
                    manifest = manifest_path.read_text(encoding="utf-8")
                    self.assertIn(str(core.resolve()), manifest)
                    self.assertNotIn(str(legacy_core.resolve()), manifest)

    def test_project_directory_or_extra_config_overrides_disable_cache(self) -> None:
        for option in (
            "core_dir = custom-core",
            "home_dir = custom-core",
            "packages_dir = custom-packages",
            "platforms_dir = custom-platforms",
            "src_dir = external-src",
            "lib_dir = external-lib",
            "globallib_dir = external-global-lib",
            "build_cache_dir = external-build-cache",
            "extra_configs = extra.ini",
        ):
            with self.subTest(option=option):
                with tempfile.TemporaryDirectory() as directory:
                    project = Path(directory)
                    defaults = project / "sdkconfig.defaults"
                    (project / "platformio.ini").write_text(
                        f"[platformio]\n{option}\n",
                        encoding="utf-8",
                    )
                    defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
                    with self.fake_core(project):
                        self.assertIsNone(
                            record_generated_sdkconfig_defaults(
                                project, "WAVESHARE_AMOLED_175"
                            )
                        )
                    self.assertFalse(
                        (
                            project
                            / ".pio/open-bike-build/builds/WAVESHARE_AMOLED_175/current.json"
                        ).exists()
                    )

    def test_does_not_reuse_cache_across_environments(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            defaults = project / "sdkconfig.defaults"
            (project / "platformio.ini").write_text(
                "[env:WAVESHARE_AMOLED_175]\nplatform = test\n",
                encoding="utf-8",
            )
            defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
            with self.fake_core(project):
                record_generated_sdkconfig_defaults(
                    project, "WAVESHARE_AMOLED_175"
                )
                self.assertEqual(
                    prepare_generated_sdkconfigs(
                        project, "WAVESHARE_AMOLED_206"
                    ),
                    (),
                )
            self.assertFalse(defaults.exists())

    def test_removes_recognized_artifacts_from_every_environment(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            defaults = project / "sdkconfig.defaults"
            environment = project / "sdkconfig.WAVESHARE_AMOLED_175"
            unrelated = project / "sdkconfig.WAVESHARE_AMOLED_206"
            for path in (defaults, environment, unrelated):
                path.write_text(GENERATED_CONFIG, encoding="utf-8")

            self.assertEqual(
                recognized_generated_sdkconfigs(
                    project, "WAVESHARE_AMOLED_175"
                ),
                (defaults, environment, unrelated),
            )
            self.assertEqual(
                remove_generated_sdkconfigs(project, "WAVESHARE_AMOLED_175"),
                (defaults, environment, unrelated),
            )
            self.assertFalse(defaults.exists())
            self.assertFalse(environment.exists())
            self.assertFalse(unrelated.exists())

    def test_preserves_unrecognized_unrelated_profile_as_visible_dirt(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            defaults = project / "sdkconfig.defaults"
            current = project / "sdkconfig.WAVESHARE_AMOLED_175"
            manual_other = project / "sdkconfig.WAVESHARE_AMOLED_206"
            defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
            current.write_text(GENERATED_CONFIG, encoding="utf-8")
            manual_other.write_text("CONFIG_PM_ENABLE=n\n", encoding="utf-8")

            self.assertEqual(
                remove_generated_sdkconfigs(project, "WAVESHARE_AMOLED_175"),
                (defaults, current),
            )
            self.assertTrue(manual_other.is_file())

    def test_refuses_manual_file_directory_and_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            target = project / "sdkconfig.WAVESHARE_AMOLED_175"

            target.write_text("CONFIG_PM_ENABLE=n\n", encoding="utf-8")
            with self.assertRaises(GeneratedSdkconfigError):
                remove_generated_sdkconfigs(project, "WAVESHARE_AMOLED_175")
            self.assertTrue(target.exists())

            target.unlink()
            target.mkdir()
            with self.assertRaises(GeneratedSdkconfigError):
                remove_generated_sdkconfigs(project, "WAVESHARE_AMOLED_175")
            target.rmdir()

            source = project / "manual-config"
            source.write_text(GENERATED_CONFIG, encoding="utf-8")
            target.symlink_to(source)
            with self.assertRaises(GeneratedSdkconfigError):
                remove_generated_sdkconfigs(project, "WAVESHARE_AMOLED_175")
            self.assertTrue(target.is_symlink())

    def test_rejects_invalid_environment_before_resolving_paths(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(GeneratedSdkconfigError):
                remove_generated_sdkconfigs(Path(directory), "../outside")

    def test_refuses_to_remove_a_tracked_generated_config(self) -> None:
        self.tracked_patch.stop()
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            subprocess.run(["git", "init", "-q"], cwd=project, check=True)
            target = project / "sdkconfig.defaults"
            target.write_text(GENERATED_CONFIG, encoding="utf-8")
            subprocess.run(["git", "add", target.name], cwd=project, check=True)

            with self.assertRaisesRegex(
                GeneratedSdkconfigError, "tracked SDK configuration"
            ):
                remove_generated_sdkconfigs(project, "WAVESHARE_AMOLED_175")

            self.assertTrue(target.is_file())

    def test_git_ownership_failure_preserves_generated_config(self) -> None:
        self.tracked_patch.stop()
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            target = project / "sdkconfig.defaults"
            target.write_text(GENERATED_CONFIG, encoding="utf-8")
            with patch(
                "generated_sdkconfig.subprocess.run",
                return_value=subprocess.CompletedProcess([], 128),
            ):
                with self.assertRaisesRegex(
                    GeneratedSdkconfigError, "ownership.*status 128"
                ):
                    remove_generated_sdkconfigs(
                        project, "WAVESHARE_AMOLED_175"
                    )
            self.assertTrue(target.is_file())

    def test_refuses_to_remove_tracked_managed_components(self) -> None:
        self.tracked_patch.stop()
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            subprocess.run(["git", "init", "-q"], cwd=project, check=True)
            component = project / "managed_components/vendor__component"
            component.mkdir(parents=True)
            (component / ".component_hash").write_text("hash\n")
            subprocess.run(
                ["git", "add", "-f", "managed_components"],
                cwd=project,
                check=True,
            )
            with self.assertRaisesRegex(
                GeneratedSdkconfigError, "tracked managed-components"
            ):
                prepare_generated_sdkconfigs(
                    project, "WAVESHARE_AMOLED_175"
                )
            self.assertTrue(component.is_dir())


if __name__ == "__main__":
    unittest.main()
