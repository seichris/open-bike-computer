#!/usr/bin/env python3

import hashlib
import io
import json
import os
import struct
import subprocess
import tarfile
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path
from unittest.mock import patch

from build_firmware import (
    BuildError,
    WAVESHARE_PLATFORM_URL,
    _resolved_device_port,
    _verified_platformio_project_config,
    _seed_pinned_scons_package,
    _print_provenance,
    build_firmware,
    main,
    upload_firmware,
)
from firmware_build_identity import (
    build_timestamp_from_source_date_epoch,
    firmware_git_identity,
)
from generated_sdkconfig import (
    FLASH_PLAN_APP_OFFSET_PLACEHOLDER,
    FLASH_PLAN_FILENAME,
    FLASH_PLAN_PORT_PLACEHOLDER,
    FLASH_PLAN_SCHEMA,
    GeneratedSdkconfigError,
    WAVESHARE_PLATFORM_PACKAGES,
    record_generated_sdkconfig_defaults,
    recognized_generated_sdkconfigs,
)
from record_flash_plan import record_flash_plan


DUMMY_FILES = {
    "CMakeLists.txt": (
        'idf_component_register(SRCS "sketch.cpp" "arduino-lib-builder-gcc.c" '
        '"arduino-lib-builder-cpp.cpp" "arduino-lib-builder-as.S" '
        'INCLUDE_DIRS ".")\n'
    ),
    "idf_component.yml": "dependencies:\n  idf: \">=5.1\"\n",
    "sketch.cpp": "#include \"Arduino.h\"\nvoid setup() {}\nvoid loop() {}\n",
    "arduino-lib-builder-gcc.c": "",
    "arduino-lib-builder-cpp.cpp": "",
    "arduino-lib-builder-as.S": "",
}

GENERATED_CONFIG = """# Automatically generated file. DO NOT EDIT.
# Espressif IoT Development Framework (ESP-IDF) Project Configuration
#
CONFIG_PM_ENABLE=y
"""


class FirmwareBuildTests(unittest.TestCase):
    environment = "WAVESHARE_AMOLED_175"
    other_environment = "WAVESHARE_AMOLED_206"

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.project_dir = Path(self.temp_dir.name)
        (self.project_dir / "platformio.ini").write_text(
            f"[env:{self.environment}]\nplatform = test\n"
            f"[env:{self.other_environment}]\nplatform = test\n",
            encoding="utf-8",
        )
        self.platform_archive = self.project_dir / ".pio/test-platform.zip"
        self.platform_archive.parent.mkdir()
        self.platform_archive.write_bytes(b"unit-test verified platform")
        self.platform_config_patch = patch(
            "build_firmware._verified_platformio_project_config",
            return_value=(
                self.project_dir / "platformio.ini",
                self.platform_archive,
            ),
        )
        self.platform_config_patch.start()
        self.addCleanup(self.platform_config_patch.stop)
        self.scons_seed_patch = patch(
            "build_firmware._seed_pinned_scons_package"
        )
        self.scons_seed_patch.start()
        self.addCleanup(self.scons_seed_patch.stop)
        self.initialize_git_repo()

    def tearDown(self):
        self.temp_dir.cleanup()

    def write_dummy(self):
        dummy_dir = self.project_dir / ".dummy"
        dummy_dir.mkdir()
        for name, contents in DUMMY_FILES.items():
            (dummy_dir / name).write_text(contents, encoding="utf-8")

    def write_firmware(self, environment=None):
        environment = environment or self.environment
        firmware = (
            self.project_dir
            / ".pio"
            / "build"
            / environment
            / "firmware.elf"
        )
        firmware.parent.mkdir(parents=True, exist_ok=True)
        firmware.write_bytes(b"real firmware")
        firmware.with_suffix(".bin").write_bytes(b"real flash image")
        (firmware.parent / "bootloader.bin").write_bytes(b"real bootloader")
        self.write_partition_table(environment)
        self.write_flash_plan(environment)
        if os.environ.get("OPEN_BIKE_DETERMINISTIC_BUILD") == "1":
            defaults = self.project_dir / "sdkconfig.defaults"
            if not defaults.exists():
                defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
            self.write_core_attestation(environment)

    def write_flash_plan(
        self,
        environment=None,
        *,
        ota_data_offset="0xe000",
        app_offset="0x10000",
        flash_mode="qio",
        extra_images=(),
    ):
        environment = environment or self.environment
        project_dir = self.project_dir.resolve()
        build_dir = project_dir / ".pio/build" / environment
        core = (
            project_dir
            / ".pio/open-bike-build/platformio"
            / environment
        )
        uploader = core / "penv/bin/esptool"
        images = [
            {"offset": "0x0", "path": str(build_dir / "bootloader.bin")},
            {"offset": "0x8000", "path": str(build_dir / "partitions.bin")},
            {
                "offset": ota_data_offset,
                "path": str(
                    core
                    / "packages/framework-arduinoespressif32/tools/partitions"
                    / "boot_app0.bin"
                ),
            },
        ]
        for offset, path, contents in extra_images:
            path = Path(path).resolve()
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(contents)
            images.append({"offset": offset, "path": str(path)})
        images.append(
            {
                "offset": FLASH_PLAN_APP_OFFSET_PLACEHOLDER,
                "path": str(build_dir / "firmware.bin"),
            }
        )
        command = [
            str(uploader),
            "--chip",
            "esp32s3",
            "--port",
            FLASH_PLAN_PORT_PLACEHOLDER,
            "--baud",
            "460800",
            "--before",
            "default-reset",
            "--after",
            "hard-reset",
            "write-flash",
            "-z",
            "--flash-mode",
            "keep",
            "--flash-freq",
            "keep",
            "--flash-size",
            "keep",
        ]
        command.extend(
            value
            for image in images
            for value in (image["offset"], image["path"])
        )
        plan = {
            "schema": FLASH_PLAN_SCHEMA,
            "environment": environment,
            "uploadPortPlaceholder": FLASH_PLAN_PORT_PLACEHOLDER,
            "uploader": str(uploader),
            "command": command,
            "platformioFlashParameters": {
                "mode": flash_mode,
                "frequency": "80m",
                "size": "detect",
            },
            "platformioAppOffset": app_offset,
            "images": images,
        }
        (build_dir / FLASH_PLAN_FILENAME).write_text(
            json.dumps(plan) + "\n", encoding="utf-8"
        )
        return plan

    def write_partition_table(
        self,
        environment=None,
        *,
        ota_data_offset=0xE000,
        app_offset=0x10000,
        app_size=0x300000,
    ):
        environment = environment or self.environment
        build_dir = self.project_dir / ".pio/build" / environment
        build_dir.mkdir(parents=True, exist_ok=True)
        partition_entry = struct.Struct("<HBBII16sI")
        partition_table = b"".join(
            (
                partition_entry.pack(
                    0x50AA, 0x01, 0x02, 0x9000, 0x5000, b"nvs", 0
                ),
                partition_entry.pack(
                    0x50AA,
                    0x01,
                    0x00,
                    ota_data_offset,
                    0x2000,
                    b"otadata",
                    0,
                ),
                partition_entry.pack(
                    0x50AA,
                    0x00,
                    0x10,
                    app_offset,
                    app_size,
                    b"app0",
                    0,
                ),
                b"\xff" * partition_entry.size,
            )
        )
        (build_dir / "partitions.bin").write_bytes(partition_table)

    def write_core_attestation(self, environment=None):
        environment = environment or self.environment
        core = (
            self.project_dir
            / ".pio"
            / "open-bike-build"
            / "platformio"
            / environment
        )
        package_root = core / "packages"
        platform_root = core / "platforms/espressif32"
        files = (
            package_root / "framework-arduinoespressif32/package.json",
            package_root / "framework-arduinoespressif32-libs/package.json",
            package_root / "framework-arduinoespressif32-libs/esp32s3/sdkconfig",
            platform_root / "platform.json",
            platform_root / ".piopm",
            platform_root / "builder/frameworks/arduino.py",
            platform_root / "builder/frameworks/espidf.py",
            platform_root / "boards/esp32-s3-devkitc-1.json",
            package_root / (
                "framework-arduinoespressif32-libs/esp32s3/qio_opi/"
                "include/sdkconfig.h"
            ),
            package_root / (
                "framework-arduinoespressif32-libs/esp32s3/qio_opi/libcore.a"
            ),
            package_root / (
                "framework-arduinoespressif32-libs/esp32s3/lib/libgeneric.a"
            ),
            package_root / "framework-arduinoespressif32/cores/esp32/core.cpp",
            package_root / (
                "framework-arduinoespressif32/tools/partitions/boot_app0.bin"
            ),
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
        (core / "lib").mkdir(exist_ok=True)
        (core / "globallib").mkdir(exist_ok=True)
        (core / "boards").mkdir(exist_ok=True)
        return core

    def write_bootstrapped_toolchain(self):
        package = (
            self.project_dir
            / ".pio"
            / "open-bike-build"
            / "platformio"
            / self.environment
            / "packages"
            / "toolchain-xtensa-esp-elf"
        )
        compiler = package / "bin" / "xtensa-esp-elf-gcc"
        compiler.parent.mkdir(parents=True, exist_ok=True)
        compiler.write_text("#!/bin/sh\n", encoding="utf-8")
        compiler.chmod(0o755)
        (package / "package.json").write_text("{}\n", encoding="utf-8")
        (package / ".piopm").write_text("{}\n", encoding="utf-8")

    def initialize_git_repo(self):
        if not (self.project_dir / ".git").is_dir():
            subprocess.run(
                ["git", "init", "-q"], cwd=self.project_dir, check=True
            )
            subprocess.run(
                ["git", "config", "user.email", "test@example.invalid"],
                cwd=self.project_dir,
                check=True,
            )
            subprocess.run(
                ["git", "config", "user.name", "Test"],
                cwd=self.project_dir,
                check=True,
            )
        (self.project_dir / ".gitignore").write_text(
            ".pio/\n.dummy/\nmanaged_components/\nsdkconfig.*\n",
            encoding="utf-8",
        )
        subprocess.run(
            ["git", "add", "platformio.ini", ".gitignore"],
            cwd=self.project_dir,
            check=True,
        )
        if subprocess.run(
            ["git", "diff", "--cached", "--quiet"], cwd=self.project_dir
        ).returncode != 0:
            subprocess.run(
                ["git", "commit", "-qm", "candidate"],
                cwd=self.project_dir,
                check=True,
            )
        return subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=self.project_dir, text=True
        ).strip()

    def test_records_resolved_arguments_without_shell_quote_leakage(self):
        class FakeEnvironment:
            def __init__(self, values):
                self.values = values

            def Clone(self):
                return FakeEnvironment(dict(self.values))

            def Replace(self, **values):
                self.values.update(values)

            def get(self, key, default=None):
                return self.values.get(key, default)

            def subst(self, expression):
                result = expression
                for key, value in self.values.items():
                    if isinstance(value, str):
                        result = result.replace(f"${{{key}}}", value)
                        result = result.replace(f"${key}", value)
                return result

        build_dir = self.project_dir / "build with spaces"
        uploader = self.project_dir / "core with spaces/penv/bin/esptool"
        environment = FakeEnvironment(
            {
                "PIOENV": self.environment,
                "BUILD_DIR": str(build_dir),
                "PROGNAME": "firmware",
                "UPLOADER": f'"{uploader}"',
                "UPLOAD_PORT": "/dev/ignored",
                "ESP32_APP_OFFSET": "",
                "FLASH_EXTRA_IMAGES": [
                    ("0x0", "$BUILD_DIR/bootloader.bin")
                ],
                "UPLOADERFLAGS": [
                    "--chip",
                    "esp32s3",
                    "--port",
                    '"$UPLOAD_PORT"',
                    "--baud",
                    "460800",
                    "--before",
                    "default-reset",
                    "--after",
                    "hard-reset",
                    "write-flash",
                    "-z",
                    "--flash-mode",
                    "qio",
                    "--flash-freq",
                    "80m",
                    "--flash-size",
                    "detect",
                    "0x0",
                    "$BUILD_DIR/bootloader.bin",
                ],
            }
        )

        record_flash_plan(environment)

        plan = json.loads(
            (build_dir / FLASH_PLAN_FILENAME).read_text(encoding="utf-8")
        )
        self.assertEqual(plan["command"][0], str(uploader.resolve()))
        self.assertIn(FLASH_PLAN_PORT_PLACEHOLDER, plan["command"])
        self.assertNotIn(
            f'"{FLASH_PLAN_PORT_PLACEHOLDER}"', plan["command"]
        )
        self.assertEqual(
            plan["platformioFlashParameters"],
            {"mode": "qio", "frequency": "80m", "size": "detect"},
        )
        self.assertEqual(plan["platformioAppOffset"], "")
        self.assertEqual(
            plan["images"][-1]["offset"],
            FLASH_PLAN_APP_OFFSET_PLACEHOLDER,
        )
        for option in ("--flash-mode", "--flash-freq", "--flash-size"):
            self.assertEqual(
                plan["command"][plan["command"].index(option) + 1], "keep"
            )
        self.assertEqual(
            plan["command"][-1], str((build_dir / "firmware.bin").resolve())
        )

    def test_rebuilds_after_successful_custom_core_dummy_bootstrap(self):
        return_codes = iter((0, 0))
        calls = []

        def runner(command, cwd):
            calls.append((tuple(command), cwd))
            if len(calls) == 1:
                self.write_dummy()
            else:
                self.write_firmware()
            return subprocess.CompletedProcess(command, next(return_codes))

        firmware = build_firmware(self.project_dir, self.environment, runner=runner)

        self.assertEqual(len(calls), 2)
        self.assertTrue(firmware.is_file())
        self.assertFalse((self.project_dir / ".dummy").exists())

    def test_rebuilds_after_failed_speaker_profile_dummy_bootstrap(self):
        return_codes = iter((1, 0))
        calls = []

        def runner(command, cwd):
            calls.append((tuple(command), cwd))
            if len(calls) == 1:
                self.write_dummy()
            else:
                self.write_firmware()
            return subprocess.CompletedProcess(command, next(return_codes))

        build_firmware(self.project_dir, self.environment, runner=runner)

        self.assertEqual(len(calls), 2)

    def test_rebuilds_after_fresh_pioarduino_toolchain_bootstrap(self):
        calls = []

        def runner(command, cwd):
            calls.append((tuple(command), cwd))
            if len(calls) == 1:
                self.write_bootstrapped_toolchain()
                return subprocess.CompletedProcess(command, 1)
            self.write_firmware()
            return subprocess.CompletedProcess(command, 0)

        build_firmware(self.project_dir, self.environment, runner=runner)

        self.assertEqual(len(calls), 2)

    def test_rejects_failed_build_with_incomplete_toolchain_bootstrap(self):
        def runner(command, cwd):
            package = (
                self.project_dir
                / ".pio/open-bike-build/platformio"
                / self.environment
                / "packages/toolchain-xtensa-esp-elf"
            )
            package.mkdir(parents=True)
            (package / "package.json").write_text("{}\n", encoding="utf-8")
            return subprocess.CompletedProcess(command, 2)

        with self.assertRaisesRegex(BuildError, "status 2"):
            build_firmware(self.project_dir, self.environment, runner=runner)

    def test_propagates_a_real_build_failure_without_dummy_source(self):
        def runner(command, cwd):
            return subprocess.CompletedProcess(command, 2)

        with self.assertRaisesRegex(BuildError, "status 2"):
            build_firmware(self.project_dir, self.environment, runner=runner)

    def test_rejects_success_without_firmware_elf(self):
        def runner(command, cwd):
            return subprocess.CompletedProcess(command, 0)

        with self.assertRaisesRegex(BuildError, "without the expected"):
            build_firmware(self.project_dir, self.environment, runner=runner)

    def test_rejects_success_without_flash_binary(self):
        def runner(command, cwd):
            firmware = (
                self.project_dir
                / ".pio/build"
                / self.environment
                / "firmware.elf"
            )
            firmware.parent.mkdir(parents=True, exist_ok=True)
            firmware.write_bytes(b"elf without flash image")
            return subprocess.CompletedProcess(command, 0)

        with self.assertRaisesRegex(BuildError, "firmware.bin"):
            build_firmware(self.project_dir, self.environment, runner=runner)

    def test_clean_waveshare_build_requires_upload_eligible_attestation(self):
        def runner(command, cwd):
            self.write_firmware()
            return subprocess.CompletedProcess(command, 0)

        with patch(
            "build_firmware.record_generated_sdkconfig_defaults",
            return_value=None,
        ):
            with self.assertRaisesRegex(
                BuildError, "did not produce upload-eligible"
            ):
                build_firmware(
                    self.project_dir,
                    self.environment,
                    runner=runner,
                )

    def test_dirty_diagnostic_build_may_remain_upload_ineligible(self):
        with (self.project_dir / "platformio.ini").open(
            "a", encoding="utf-8"
        ) as stream:
            stream.write("; intentional local diagnostic change\n")

        def runner(command, cwd):
            self.write_firmware()
            return subprocess.CompletedProcess(command, 0)

        output = StringIO()
        with (
            patch(
                "build_firmware.record_generated_sdkconfig_defaults",
                return_value=None,
            ),
            redirect_stdout(output),
        ):
            firmware = build_firmware(
                self.project_dir,
                self.environment,
                runner=runner,
            )

        self.assertTrue(firmware.is_file())
        self.assertIn("uploadEligible=0", output.getvalue())

    def test_removes_a_stale_target_artifact_before_building(self):
        self.write_firmware()
        stale_firmware = (
            self.project_dir
            / ".pio"
            / "build"
            / self.environment
            / "firmware.elf"
        )

        def runner(command, cwd):
            self.assertFalse(stale_firmware.exists())
            self.write_firmware()
            return subprocess.CompletedProcess(command, 0)

        build_firmware(self.project_dir, self.environment, runner=runner)

    def test_removes_generated_sdkconfigs_once_and_marks_nested_build(self):
        defaults = self.project_dir / "sdkconfig.defaults"
        environment = self.project_dir / f"sdkconfig.{self.environment}"
        other = self.project_dir / f"sdkconfig.{self.other_environment}"
        defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
        environment.write_text(GENERATED_CONFIG, encoding="utf-8")
        other.write_text(GENERATED_CONFIG, encoding="utf-8")
        calls = 0
        expected_source_date_epoch = subprocess.check_output(
            ["git", "show", "--no-patch", "--format=%ct", "HEAD"],
            cwd=self.project_dir,
            text=True,
        ).strip()
        observed_build_clocks = []

        def runner(command, cwd):
            nonlocal calls
            calls += 1
            self.assertEqual(os.environ.get("OPEN_BIKE_DETERMINISTIC_BUILD"), "1")
            isolated_git_config = Path(os.environ["GIT_CONFIG_GLOBAL"])
            self.assertEqual(isolated_git_config.read_text(encoding="utf-8"), "")
            self.assertEqual(os.environ.get("GIT_CONFIG_NOSYSTEM"), "1")
            self.assertEqual(os.environ.get("GIT_TERMINAL_PROMPT"), "0")
            observed_build_clocks.append(
                (
                    os.environ.get("SOURCE_DATE_EPOCH"),
                    os.environ.get("OPEN_BIKE_BUILD_TIMESTAMP"),
                )
            )
            if calls == 1:
                self.assertFalse(defaults.exists())
                self.assertFalse(environment.exists())
                self.assertFalse(other.exists())
                defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
                environment.write_text(GENERATED_CONFIG, encoding="utf-8")
                self.write_dummy()
            else:
                self.assertTrue(defaults.exists())
                self.assertTrue(environment.exists())
                self.write_firmware()
            return subprocess.CompletedProcess(command, 0)

        original = os.environ.get("OPEN_BIKE_DETERMINISTIC_BUILD")
        original_source_date_epoch = os.environ.get("SOURCE_DATE_EPOCH")
        os.environ["OPEN_BIKE_DETERMINISTIC_BUILD"] = "original"
        os.environ["SOURCE_DATE_EPOCH"] = "999"
        try:
            build_firmware(self.project_dir, self.environment, runner=runner)
        finally:
            self.assertEqual(
                os.environ.get("OPEN_BIKE_DETERMINISTIC_BUILD"), "original"
            )
            if original is None:
                os.environ.pop("OPEN_BIKE_DETERMINISTIC_BUILD", None)
            else:
                os.environ["OPEN_BIKE_DETERMINISTIC_BUILD"] = original
            self.assertEqual(os.environ.get("SOURCE_DATE_EPOCH"), "999")
            if original_source_date_epoch is None:
                os.environ.pop("SOURCE_DATE_EPOCH", None)
            else:
                os.environ["SOURCE_DATE_EPOCH"] = original_source_date_epoch

        self.assertEqual(calls, 2)
        self.assertEqual(
            observed_build_clocks,
            [
                (
                    expected_source_date_epoch,
                    build_timestamp_from_source_date_epoch(
                        expected_source_date_epoch
                    ),
                )
            ]
            * 2,
        )

    def test_sequential_profiles_keep_second_build_identity_exact(self):
        full_sha = self.initialize_git_repo()
        defaults = self.project_dir / "sdkconfig.defaults"
        first = self.project_dir / f"sdkconfig.{self.environment}"
        second = self.project_dir / f"sdkconfig.{self.other_environment}"

        def first_runner(command, cwd):
            defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
            first.write_text(GENERATED_CONFIG, encoding="utf-8")
            self.write_firmware(self.environment)
            return subprocess.CompletedProcess(command, 0)

        build_firmware(self.project_dir, self.environment, runner=first_runner)
        self.assertTrue(first.is_file())

        def second_runner(command, cwd):
            self.assertFalse(defaults.exists())
            self.assertFalse(first.exists())
            defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
            second.write_text(GENERATED_CONFIG, encoding="utf-8")
            allowed = recognized_generated_sdkconfigs(
                self.project_dir, self.other_environment
            )
            self.assertEqual(
                firmware_git_identity(
                    self.project_dir,
                    allowed_untracked_paths=allowed,
                ),
                full_sha,
            )
            self.write_firmware(self.other_environment)
            return subprocess.CompletedProcess(command, 0)

        build_firmware(
            self.project_dir,
            self.other_environment,
            runner=second_runner,
        )
        self.assertTrue(second.is_file())

    def test_repeated_build_preserves_validated_custom_core_cache(self):
        defaults = self.project_dir / "sdkconfig.defaults"
        current = self.project_dir / f"sdkconfig.{self.environment}"
        core = self.write_core_attestation()

        def first_runner(command, cwd):
            self.assertFalse(defaults.exists())
            self.write_core_attestation()
            defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
            current.write_text(GENERATED_CONFIG, encoding="utf-8")
            self.write_firmware()
            return subprocess.CompletedProcess(command, 0)

        with patch.dict(os.environ, {"PLATFORMIO_CORE_DIR": str(core)}):
            build_firmware(self.project_dir, self.environment, runner=first_runner)

        def second_runner(command, cwd):
            self.assertTrue(defaults.exists())
            self.assertFalse(current.exists())
            self.assertFalse((self.project_dir / ".dummy").exists())
            current.write_text(GENERATED_CONFIG, encoding="utf-8")
            self.write_firmware()
            return subprocess.CompletedProcess(command, 0)

        with patch.dict(os.environ, {"PLATFORMIO_CORE_DIR": str(core)}):
            build_firmware(self.project_dir, self.environment, runner=second_runner)

    def test_upload_preserves_exact_identity_through_direct_flash(self):
        full_sha = self.initialize_git_repo()
        core = self.write_core_attestation().resolve()
        project_dir = self.project_dir.resolve()
        defaults = self.project_dir / "sdkconfig.defaults"
        current = self.project_dir / f"sdkconfig.{self.environment}"
        defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
        current.write_text(GENERATED_CONFIG, encoding="utf-8")
        self.write_firmware()

        def runner(command, cwd):
            self.assertEqual(os.environ.get("OPEN_BIKE_DETERMINISTIC_BUILD"), "1")
            self.assertEqual(
                os.environ.get("OPEN_BIKE_EXPECTED_GIT_SHA"), full_sha
            )
            self.assertEqual(
                Path(os.environ["PLATFORMIO_PACKAGES_DIR"]),
                (core / "packages").resolve(),
            )
            self.assertEqual(
                tuple(command),
                (
                    str(core / "penv/bin/esptool"),
                    "--chip",
                    "esp32s3",
                    "--port",
                    "/dev/cu.test",
                    "--baud",
                    "460800",
                    "--before",
                    "default-reset",
                    "--after",
                    "hard-reset",
                    "write-flash",
                    "-z",
                    "--flash-mode",
                    "keep",
                    "--flash-freq",
                    "keep",
                    "--flash-size",
                    "keep",
                    "0x0",
                    str(
                        project_dir
                        / ".pio/build"
                        / self.environment
                        / "bootloader.bin"
                    ),
                    "0x8000",
                    str(
                        project_dir
                        / ".pio/build"
                        / self.environment
                        / "partitions.bin"
                    ),
                    "0xe000",
                    str(
                        core
                        / "packages/framework-arduinoespressif32/tools/partitions"
                        / "boot_app0.bin"
                    ),
                    "0x10000",
                    str(
                        project_dir
                        / ".pio/build"
                        / self.environment
                        / "firmware.bin"
                    ),
                ),
            )
            allowed = recognized_generated_sdkconfigs(
                self.project_dir, self.environment
            )
            self.assertEqual(
                firmware_git_identity(
                    self.project_dir,
                    allowed_untracked_paths=allowed,
                ),
                full_sha,
            )
            return subprocess.CompletedProcess(command, 0)

        with patch.dict(os.environ, {"PLATFORMIO_CORE_DIR": str(core)}):
            record_generated_sdkconfig_defaults(
                self.project_dir, self.environment
            )
            upload_firmware(
                self.project_dir,
                self.environment,
                "/dev/cu.test",
                runner=runner,
            )
        self.assertNotIn("OPEN_BIKE_DETERMINISTIC_BUILD", os.environ)

    def test_upload_requires_verified_artifact_and_propagates_failure(self):
        with self.assertRaisesRegex(BuildError, "verified real-target artifact"):
            upload_firmware(
                self.project_dir,
                self.environment,
                "/dev/cu.test",
                runner=lambda command, cwd: self.fail("runner must not be called"),
            )

        self.write_firmware()
        defaults = self.project_dir / "sdkconfig.defaults"
        current = self.project_dir / f"sdkconfig.{self.environment}"
        defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
        current.write_text(GENERATED_CONFIG, encoding="utf-8")
        core = self.write_core_attestation()
        with patch.dict(os.environ, {"PLATFORMIO_CORE_DIR": str(core)}):
            record_generated_sdkconfig_defaults(
                self.project_dir, self.environment
            )
            with self.assertRaisesRegex(BuildError, "status 2"):
                upload_firmware(
                    self.project_dir,
                    self.environment,
                    "/dev/cu.test",
                    runner=lambda command, cwd: subprocess.CompletedProcess(
                        command, 2
                    ),
                )

    def test_upload_derives_app_offset_from_verified_partition_table(self):
        core = self.write_core_attestation().resolve()
        project_dir = self.project_dir.resolve()
        defaults = self.project_dir / "sdkconfig.defaults"
        defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
        self.write_firmware()
        self.write_flash_plan(
            ota_data_offset="0xf000",
            app_offset="",
            flash_mode="dio",
        )
        self.write_partition_table(
            ota_data_offset=0xF000,
            app_offset=0x20000,
        )
        calls = []

        with patch.dict(os.environ, {"PLATFORMIO_CORE_DIR": str(core)}):
            manifest_path = record_generated_sdkconfig_defaults(
                self.project_dir, self.environment
            )
            upload_firmware(
                self.project_dir,
                self.environment,
                "/dev/cu.test",
                runner=lambda command, cwd: (
                    calls.append(tuple(command))
                    or subprocess.CompletedProcess(command, 0)
                ),
            )

        self.assertEqual(len(calls), 1)
        command = calls[0]
        boot_app0 = str(
            core
            / "packages/framework-arduinoespressif32/tools/partitions"
            / "boot_app0.bin"
        )
        firmware = str(
            project_dir
            / ".pio/build"
            / self.environment
            / "firmware.bin"
        )
        self.assertEqual(command[command.index(boot_app0) - 1], "0xf000")
        self.assertEqual(command[command.index(firmware) - 1], "0x20000")
        self.assertEqual(command[command.index("--flash-mode") + 1], "keep")
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        self.assertEqual(
            manifest["flashPlan"]["platformioFlashParameters"]["mode"],
            "dio",
        )
        self.assertEqual(manifest["flashPlan"]["platformioAppOffset"], "")
        self.assertEqual(
            manifest["flashPlan"]["applicationOffsetSource"],
            "partition-table",
        )
        self.assertNotIn("nobuild", command)
        self.assertNotIn("upload", command)

    def test_attestation_rejects_platformio_app_offset_mismatch(self):
        core = self.write_core_attestation()
        defaults = self.project_dir / "sdkconfig.defaults"
        defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
        self.write_firmware()
        self.write_flash_plan(app_offset="0x20000")

        with patch.dict(
            os.environ, {"PLATFORMIO_CORE_DIR": str(core)}
        ), self.assertRaisesRegex(
            GeneratedSdkconfigError, "does not match the verified partition table"
        ):
            record_generated_sdkconfig_defaults(
                self.project_dir, self.environment
            )

    def test_attestation_rejects_firmware_larger_than_app_partition(self):
        core = self.write_core_attestation()
        defaults = self.project_dir / "sdkconfig.defaults"
        defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
        self.write_firmware()
        self.write_partition_table(app_size=1)

        with patch.dict(
            os.environ, {"PLATFORMIO_CORE_DIR": str(core)}
        ), self.assertRaisesRegex(
            GeneratedSdkconfigError, "exceeds its application partition"
        ):
            record_generated_sdkconfig_defaults(
                self.project_dir, self.environment
            )

    def test_upload_replays_and_attests_additional_platformio_images(self):
        core = self.write_core_attestation().resolve()
        defaults = self.project_dir / "sdkconfig.defaults"
        defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
        self.write_firmware()
        extra_image = (
            self.project_dir.resolve()
            / ".pio/build"
            / self.environment
            / "recovery.bin"
        )
        self.write_flash_plan(
            extra_images=(("0x310000", extra_image, b"recovery image"),)
        )
        calls = []

        with patch.dict(os.environ, {"PLATFORMIO_CORE_DIR": str(core)}):
            record_generated_sdkconfig_defaults(
                self.project_dir, self.environment
            )
            upload_firmware(
                self.project_dir,
                self.environment,
                "/dev/cu.test",
                runner=lambda command, cwd: (
                    calls.append(tuple(command))
                    or subprocess.CompletedProcess(command, 0)
                ),
            )
            extra_image.write_bytes(b"changed recovery image")
            with self.assertRaisesRegex(BuildError, "flash plan changed"):
                upload_firmware(
                    self.project_dir,
                    self.environment,
                    "/dev/cu.test",
                    runner=lambda command, cwd: self.fail(
                        "runner must not be called"
                    ),
                )

        self.assertEqual(len(calls), 1)
        self.assertIn("0x310000", calls[0])
        self.assertIn(str(extra_image), calls[0])

    def test_upload_refuses_a_flash_plan_changed_after_attestation(self):
        core = self.write_core_attestation()
        defaults = self.project_dir / "sdkconfig.defaults"
        defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
        self.write_firmware()

        with patch.dict(os.environ, {"PLATFORMIO_CORE_DIR": str(core)}):
            record_generated_sdkconfig_defaults(
                self.project_dir, self.environment
            )
            self.write_flash_plan(flash_mode="dio")
            output = StringIO()
            with self.assertRaisesRegex(BuildError, "flash plan changed"), redirect_stdout(
                output
            ):
                upload_firmware(
                    self.project_dir,
                    self.environment,
                    "/dev/cu.test",
                    runner=lambda command, cwd: self.fail(
                        "runner must not be called"
                    ),
                )
        self.assertNotIn("FIRMWARE_UPLOAD_PROVENANCE", output.getvalue())

    def test_attestation_rejects_duplicate_or_overlapping_flash_ranges(self):
        core = self.write_core_attestation()
        defaults = self.project_dir / "sdkconfig.defaults"
        defaults.write_text(GENERATED_CONFIG, encoding="utf-8")

        for offset, expected_error in (
            ("0x0", "duplicate or out-of-range"),
            ("0x1", "overlapping images"),
        ):
            with self.subTest(offset=offset):
                self.write_firmware()
                plan_path = (
                    self.project_dir
                    / ".pio/build"
                    / self.environment
                    / FLASH_PLAN_FILENAME
                )
                plan = json.loads(plan_path.read_text(encoding="utf-8"))
                plan["images"][1]["offset"] = offset
                image_tail = [
                    value
                    for image in plan["images"]
                    for value in (image["offset"], image["path"])
                ]
                plan["command"][-len(image_tail) :] = image_tail
                plan_path.write_text(json.dumps(plan) + "\n", encoding="utf-8")

                with patch.dict(
                    os.environ, {"PLATFORMIO_CORE_DIR": str(core)}
                ), self.assertRaisesRegex(
                    GeneratedSdkconfigError, expected_error
                ):
                    record_generated_sdkconfig_defaults(
                        self.project_dir, self.environment
                    )

    def test_attestation_rejects_a_command_not_matching_its_image_set(self):
        core = self.write_core_attestation()
        defaults = self.project_dir / "sdkconfig.defaults"
        defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
        self.write_firmware()
        plan_path = (
            self.project_dir
            / ".pio/build"
            / self.environment
            / FLASH_PLAN_FILENAME
        )
        plan = json.loads(plan_path.read_text(encoding="utf-8"))
        plan["command"][-1] = str(self.project_dir / "unattested.bin")
        plan_path.write_text(json.dumps(plan) + "\n", encoding="utf-8")

        with patch.dict(
            os.environ, {"PLATFORMIO_CORE_DIR": str(core)}
        ), self.assertRaisesRegex(GeneratedSdkconfigError, "exactly match"):
            record_generated_sdkconfig_defaults(
                self.project_dir, self.environment
            )

    def test_attestation_rejects_unattested_or_mutating_command_arguments(self):
        core = self.write_core_attestation()
        defaults = self.project_dir / "sdkconfig.defaults"
        defaults.write_text(GENERATED_CONFIG, encoding="utf-8")

        for mutation, expected_error in (
            ("undeclared-image", "unsupported argument"),
            ("header-rewrite", "may rewrite"),
        ):
            with self.subTest(mutation=mutation):
                self.write_firmware()
                plan_path = (
                    self.project_dir
                    / ".pio/build"
                    / self.environment
                    / FLASH_PLAN_FILENAME
                )
                plan = json.loads(plan_path.read_text(encoding="utf-8"))
                if mutation == "undeclared-image":
                    image_tail_size = len(plan["images"]) * 2
                    plan["command"][-image_tail_size:-image_tail_size] = [
                        "0x700000",
                        "/definitely/not/attested.bin",
                    ]
                else:
                    mode_index = plan["command"].index("--flash-mode")
                    plan["command"][mode_index + 1] = "qio"
                plan_path.write_text(
                    json.dumps(plan) + "\n", encoding="utf-8"
                )

                with patch.dict(
                    os.environ, {"PLATFORMIO_CORE_DIR": str(core)}
                ), self.assertRaisesRegex(
                    GeneratedSdkconfigError, expected_error
                ):
                    record_generated_sdkconfig_defaults(
                        self.project_dir, self.environment
                    )

    def test_upload_allows_environment_config_absent_in_verified_build(self):
        core = self.write_core_attestation()
        defaults = self.project_dir / "sdkconfig.defaults"
        defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
        self.write_firmware()
        calls = []

        with patch.dict(os.environ, {"PLATFORMIO_CORE_DIR": str(core)}):
            record_generated_sdkconfig_defaults(
                self.project_dir, self.environment
            )
            upload_firmware(
                self.project_dir,
                self.environment,
                "/dev/cu.test",
                runner=lambda command, cwd: (
                    calls.append((tuple(command), cwd))
                    or subprocess.CompletedProcess(command, 0)
                ),
            )

        self.assertEqual(len(calls), 1)

    def test_upload_clears_private_global_library_and_board_overrides(self):
        core = self.write_core_attestation()
        defaults = self.project_dir / "sdkconfig.defaults"
        defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
        self.write_firmware()
        calls = []

        with patch.dict(os.environ, {"PLATFORMIO_CORE_DIR": str(core)}):
            record_generated_sdkconfig_defaults(
                self.project_dir, self.environment
            )
            injected_global = core / "lib/Injected/src/injected.cpp"
            injected_global.parent.mkdir(parents=True)
            injected_global.write_text("unattested source\n", encoding="utf-8")
            injected_board = core / "boards/esp32-s3-devkitc-1.json"
            injected_board.write_text("{}\n", encoding="utf-8")

            upload_firmware(
                self.project_dir,
                self.environment,
                "/dev/cu.test",
                runner=lambda command, cwd: (
                    self.assertFalse(injected_global.exists())
                    or self.assertFalse(injected_board.exists())
                    or calls.append((tuple(command), cwd))
                    or subprocess.CompletedProcess(command, 0)
                ),
            )

        self.assertEqual(len(calls), 1)

    def test_upload_refuses_environment_config_appearing_after_build(self):
        core = self.write_core_attestation()
        defaults = self.project_dir / "sdkconfig.defaults"
        current = self.project_dir / f"sdkconfig.{self.environment}"
        defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
        self.write_firmware()

        with patch.dict(os.environ, {"PLATFORMIO_CORE_DIR": str(core)}):
            record_generated_sdkconfig_defaults(
                self.project_dir, self.environment
            )
            current.write_text(GENERATED_CONFIG, encoding="utf-8")
            with self.assertRaisesRegex(BuildError, "appeared after"):
                upload_firmware(
                    self.project_dir,
                    self.environment,
                    "/dev/cu.test",
                    runner=lambda command, cwd: self.fail(
                        "runner must not be called"
                    ),
                )

    def test_upload_refuses_generated_config_changed_after_build(self):
        core = self.write_core_attestation()
        defaults = self.project_dir / "sdkconfig.defaults"
        current = self.project_dir / f"sdkconfig.{self.environment}"
        defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
        current.write_text(GENERATED_CONFIG, encoding="utf-8")
        self.write_firmware()

        with patch.dict(os.environ, {"PLATFORMIO_CORE_DIR": str(core)}):
            record_generated_sdkconfig_defaults(
                self.project_dir, self.environment
            )
            defaults.write_text(
                GENERATED_CONFIG + "CONFIG_CHANGED_AFTER_BUILD=y\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(BuildError, "changed after the verified"):
                upload_firmware(
                    self.project_dir,
                    self.environment,
                    "/dev/cu.test",
                    runner=lambda command, cwd: self.fail(
                        "runner must not be called"
                    ),
                )

    def test_upload_refuses_modified_flash_artifacts(self):
        core = self.write_core_attestation()
        defaults = self.project_dir / "sdkconfig.defaults"
        defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
        with patch.dict(os.environ, {"PLATFORMIO_CORE_DIR": str(core)}):
            for artifact in ("firmware.bin", "bootloader.bin", "partitions.bin"):
                with self.subTest(artifact=artifact):
                    self.write_firmware()
                    record_generated_sdkconfig_defaults(
                        self.project_dir, self.environment
                    )
                    artifact_path = (
                        self.project_dir / ".pio/build" / self.environment / artifact
                    )
                    artifact_path.write_bytes(b"replaced flash image")
                    with self.assertRaisesRegex(BuildError, "artifact changed"):
                        upload_firmware(
                            self.project_dir,
                            self.environment,
                            "/dev/cu.test",
                            runner=lambda command, cwd: self.fail(
                                "runner must not be called"
                            ),
                        )

    def test_upload_refuses_environment_config_changed_after_build(self):
        core = self.write_core_attestation()
        defaults = self.project_dir / "sdkconfig.defaults"
        current = self.project_dir / f"sdkconfig.{self.environment}"
        defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
        current.write_text(GENERATED_CONFIG, encoding="utf-8")
        self.write_firmware()

        with patch.dict(os.environ, {"PLATFORMIO_CORE_DIR": str(core)}):
            record_generated_sdkconfig_defaults(
                self.project_dir, self.environment
            )
            current.write_text(
                GENERATED_CONFIG + "CONFIG_CHANGED_AFTER_BUILD=y\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(BuildError, "environment SDK.*changed"):
                upload_firmware(
                    self.project_dir,
                    self.environment,
                    "/dev/cu.test",
                    runner=lambda command, cwd: self.fail(
                        "runner must not be called"
                    ),
                )

    def test_cli_rejects_an_explicit_empty_upload_port(self):
        errors = StringIO()
        with patch("build_firmware.build_firmware") as mocked_build:
            with redirect_stderr(errors):
                result = main(
                    [
                        self.environment,
                        "--project-dir",
                        str(self.project_dir),
                        "--upload-port=",
                    ]
                )

        self.assertEqual(result, 1)
        mocked_build.assert_called_once()
        self.assertIn("upload port must not be empty", errors.getvalue())

    def test_cli_upload_only_skips_build_and_resolves_device_serial_late(self):
        with patch("build_firmware.build_firmware") as mocked_build, patch(
            "build_firmware.upload_firmware"
        ) as mocked_upload:
            result = main(
                [
                    self.environment,
                    "--project-dir",
                    str(self.project_dir),
                    "--upload-only",
                    "--device-serial",
                    "3C:DC:75:6E:F0:10",
                    "--device-timeout",
                    "12.5",
                ]
            )

        self.assertEqual(result, 0)
        mocked_build.assert_not_called()
        mocked_upload.assert_called_once_with(
            self.project_dir,
            self.environment,
            None,
            device_serial="3C:DC:75:6E:F0:10",
            device_timeout=12.5,
        )

    def test_cli_upload_only_requires_a_device_selector(self):
        errors = StringIO()
        with patch("build_firmware.build_firmware") as mocked_build, patch(
            "build_firmware.upload_firmware"
        ) as mocked_upload, redirect_stderr(errors):
            result = main(
                [
                    self.environment,
                    "--project-dir",
                    str(self.project_dir),
                    "--upload-only",
                ]
            )

        self.assertEqual(result, 1)
        mocked_build.assert_not_called()
        mocked_upload.assert_not_called()
        self.assertIn("requires --upload-port or --device-serial", errors.getvalue())

    def test_upload_device_serial_binds_the_resolved_port(self):
        core = self.write_core_attestation()
        defaults = self.project_dir / "sdkconfig.defaults"
        defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
        self.write_firmware()
        calls = []

        with patch.dict(os.environ, {"PLATFORMIO_CORE_DIR": str(core)}):
            record_generated_sdkconfig_defaults(
                self.project_dir, self.environment
            )
            with patch(
                "build_firmware._resolved_device_port",
                return_value="/dev/cu.renumbered",
            ) as mocked_resolver:
                upload_firmware(
                    self.project_dir,
                    self.environment,
                    device_serial="3C:DC:75:6E:F0:10",
                    device_timeout=7,
                    runner=lambda command, cwd: (
                        calls.append(tuple(command))
                        or subprocess.CompletedProcess(command, 0)
                    ),
                )

        mocked_resolver.assert_called_once()
        self.assertEqual(
            mocked_resolver.call_args.args[1]["environment"], self.environment
        )
        self.assertEqual(len(calls), 1)
        self.assertIn("/dev/cu.renumbered", calls[0])
        self.assertNotIn(FLASH_PLAN_PORT_PLACEHOLDER, calls[0])

    def test_failed_upload_keeps_attested_environment_retryable(self):
        core = self.write_core_attestation()
        defaults = self.project_dir / "sdkconfig.defaults"
        defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
        self.write_firmware()
        results = iter((2, 0))

        def runner(command, cwd):
            self.assertEqual(os.environ.get("PYTHONDONTWRITEBYTECODE"), "1")
            return subprocess.CompletedProcess(command, next(results))

        os.environ.pop("PYTHONDONTWRITEBYTECODE", None)
        with patch.dict(os.environ, {"PLATFORMIO_CORE_DIR": str(core)}):
            record_generated_sdkconfig_defaults(
                self.project_dir, self.environment
            )
            with self.assertRaisesRegex(BuildError, "status 2"):
                upload_firmware(
                    self.project_dir,
                    self.environment,
                    "/dev/cu.missing",
                    runner=runner,
                )
            upload_firmware(
                self.project_dir,
                self.environment,
                "/dev/cu.returned",
                runner=runner,
            )

        self.assertNotIn("PYTHONDONTWRITEBYTECODE", os.environ)

    def test_private_device_resolver_output_is_validated(self):
        core = self.write_core_attestation()
        private_python = core / "penv/bin/python"
        private_python.write_text("#!/bin/sh\n", encoding="utf-8")
        private_python.chmod(0o755)
        resolver = self.project_dir / "tools/resolve_upload_port.py"
        resolver.parent.mkdir()
        resolver.write_text("# resolver\n", encoding="utf-8")
        manifest = {
            "environment": self.environment,
            "coreAttestation": {"coreDir": str(core.resolve())},
        }
        calls = []

        def runner(command, **kwargs):
            calls.append((tuple(command), kwargs))
            return subprocess.CompletedProcess(
                command,
                0,
                stdout=json.dumps(
                    {
                        "schema": 1,
                        "port": "/dev/cu.current",
                        "serialNumber": "3c:dc:75:6e:f0:10",
                    }
                ),
                stderr="",
            )

        port = _resolved_device_port(
            self.project_dir,
            manifest,
            "3C:DC:75:6E:F0:10",
            9,
            runner=runner,
        )

        self.assertEqual(port, "/dev/cu.current")
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0][0], str(private_python.resolve()))
        self.assertEqual(calls[0][0][-1], "9")
        self.assertTrue(calls[0][1]["capture_output"])
        self.assertTrue(calls[0][1]["text"])

    def test_refuses_unrecognized_sdkconfig_before_running_platformio(self):
        config = self.project_dir / f"sdkconfig.{self.environment}"
        config.write_text("CONFIG_PM_ENABLE=n\n", encoding="utf-8")

        with self.assertRaisesRegex(BuildError, "unrecognized SDK configuration"):
            build_firmware(
                self.project_dir,
                self.environment,
                runner=lambda command, cwd: self.fail("runner must not be called"),
            )

        self.assertEqual(config.read_text(encoding="utf-8"), "CONFIG_PM_ENABLE=n\n")

    def test_restores_deterministic_marker_after_build_failure(self):
        os.environ.pop("OPEN_BIKE_DETERMINISTIC_BUILD", None)

        with self.assertRaises(BuildError):
            build_firmware(
                self.project_dir,
                self.environment,
                runner=lambda command, cwd: subprocess.CompletedProcess(command, 2),
            )

        self.assertNotIn("OPEN_BIKE_DETERMINISTIC_BUILD", os.environ)

    def test_failed_build_does_not_record_a_custom_core_cache(self):
        defaults = self.project_dir / "sdkconfig.defaults"
        core = self.write_core_attestation()

        def runner(command, cwd):
            defaults.write_text(GENERATED_CONFIG, encoding="utf-8")
            return subprocess.CompletedProcess(command, 2)

        with patch.dict(os.environ, {"PLATFORMIO_CORE_DIR": str(core)}):
            with self.assertRaises(BuildError):
                build_firmware(
                    self.project_dir,
                    self.environment,
                    runner=runner,
                )

        self.assertFalse(
            (
                self.project_dir
                / ".pio/open-bike-build/sdkconfig-defaults.json"
            ).exists()
        )

    def test_stops_when_custom_core_bootstrap_does_not_converge(self):
        calls = []

        def runner(command, cwd):
            calls.append(tuple(command))
            self.write_dummy()
            return subprocess.CompletedProcess(command, 0)

        with self.assertRaisesRegex(BuildError, "did not converge"):
            build_firmware(
                self.project_dir,
                self.environment,
                max_passes=2,
                runner=runner,
            )

        self.assertEqual(len(calls), 2)

    def test_refuses_to_remove_an_unrecognized_dummy_directory(self):
        dummy_dir = self.project_dir / ".dummy"
        dummy_dir.mkdir()
        (dummy_dir / "important.txt").write_text("keep me", encoding="utf-8")

        with self.assertRaisesRegex(BuildError, "refusing to remove"):
            build_firmware(
                self.project_dir,
                self.environment,
                runner=lambda command, cwd: self.fail("runner must not be called"),
            )

        self.assertEqual(
            (dummy_dir / "important.txt").read_text(encoding="utf-8"), "keep me"
        )

    def test_rejects_unknown_or_unsafe_environment_names(self):
        with self.assertRaisesRegex(BuildError, "invalid PlatformIO environment"):
            build_firmware(
                self.project_dir,
                "../outside",
                runner=lambda command, cwd: self.fail("runner must not be called"),
            )
        with self.assertRaisesRegex(BuildError, "unknown PlatformIO environment"):
            build_firmware(
                self.project_dir,
                "UNKNOWN",
                runner=lambda command, cwd: self.fail("runner must not be called"),
            )

    def test_rejects_ambient_source_and_build_overrides(self):
        for key, value in (
            ("PLATFORMIO_SRC_DIR", "/tmp/external-source"),
            ("PLATFORMIO_EXTRA_SCRIPTS", "pre:/tmp/external.py"),
            ("PLATFORMIO_BUILD_FLAGS", "-DINJECTED=1"),
            ("PLATFORMIO_PACKAGES_DIR", "/tmp/shared-packages"),
            ("IDF_COMPONENT_REGISTRY_URL", "https://attacker.invalid"),
            ("IDF_COMPONENT_CONSTRAINTS", "attacker/component=*"),
            ("DEFAULT_COMPONENT_SERVICE_URL", "https://attacker.invalid"),
            ("IDF_TOOLS_PATH", "/tmp/shared-idf-tools"),
            ("CI_TESTING_IDF_VERSION", "4.4.0"),
            ("IDF_TARGET", "esp32"),
            ("SDKCONFIG_DEFAULTS", "/tmp/injected-sdkconfig"),
            ("CFLAGS", "-DINJECTED_BEHAVIOR=1"),
            ("CXXFLAGS", "-DINJECTED_BEHAVIOR=1"),
            ("CMAKE_TOOLCHAIN_FILE", "/tmp/injected-toolchain.cmake"),
            ("ICENAV3_LAT", "1.25"),
        ):
            with self.subTest(key=key), patch.dict(os.environ, {key: value}):
                with self.assertRaisesRegex(BuildError, key):
                    build_firmware(
                        self.project_dir,
                        self.environment,
                        runner=lambda command, cwd: self.fail(
                            "runner must not be called"
                        ),
                    )

    def test_build_uses_profile_private_platformio_stores(self):
        expected_root = (
            self.project_dir
            / ".pio/open-bike-build/platformio"
            / self.environment
        ).resolve()
        stale = expected_root / "packages" / "stale-unrecorded-core.txt"
        stale.parent.mkdir(parents=True)
        stale.write_text("must not seed the build\n")

        def runner(command, cwd):
            self.assertFalse(stale.exists())
            self.assertEqual(
                Path(os.environ["PLATFORMIO_PACKAGES_DIR"]),
                expected_root / "packages",
            )
            self.assertEqual(
                Path(os.environ["PLATFORMIO_CORE_DIR"]),
                expected_root,
            )
            self.assertEqual(
                Path(os.environ["PLATFORMIO_PLATFORMS_DIR"]),
                expected_root / "platforms",
            )
            self.assertEqual(
                Path(os.environ["PLATFORMIO_GLOBALLIB_DIR"]),
                expected_root / "lib",
            )
            self.assertEqual(
                Path(os.environ["PLATFORMIO_LIBDEPS_DIR"]),
                expected_root / "libdeps",
            )
            self.assertEqual(
                Path(os.environ["IDF_COMPONENT_CACHE_PATH"]),
                expected_root / "component-cache",
            )
            self.assertEqual(os.environ["IDF_COMPONENT_STRICT_CHECKSUM"], "1")
            self.assertEqual(os.environ["IDF_COMPONENT_VERIFY_SSL"], "1")
            self.assertEqual(os.environ["IDF_COMPONENT_CHECK_NEW_VERSION"], "0")
            nested_scons = json.loads(
                os.environ["OPEN_BIKE_PINNED_SCONS_PIOPM"]
            )
            expected_scons_url = next(
                url
                for name, url, _, _ in WAVESHARE_PLATFORM_PACKAGES
                if name == "tool-scons"
            )
            self.assertEqual(nested_scons["spec"]["owner"], "platformio")
            self.assertIsNone(nested_scons["spec"]["id"])
            self.assertEqual(nested_scons["spec"]["uri"], expected_scons_url)
            self.assertNotIn("PYTHONPATH", os.environ)
            self.assertEqual(
                Path(os.environ["IDF_TOOLS_PATH"]), expected_root
            )
            self.write_firmware()
            return subprocess.CompletedProcess(command, 0)

        build_firmware(self.project_dir, self.environment, runner=runner)

    def test_steady_build_discards_unattested_compiler_cache(self):
        expected_root = (
            self.project_dir
            / ".pio/open-bike-build/platformio"
            / self.environment
        ).resolve()
        stale_cache = expected_root / "build-cache" / "injected-object.o"
        stale_cache.parent.mkdir(parents=True)
        stale_cache.write_bytes(b"unattested compiler output")
        injected_global = expected_root / "lib/Injected/src/injected.cpp"
        injected_global.parent.mkdir(parents=True)
        injected_global.write_text("unattested source\n", encoding="utf-8")
        injected_board = expected_root / "boards/esp32-s3-devkitc-1.json"
        injected_board.parent.mkdir(parents=True)
        injected_board.write_text("{}\n", encoding="utf-8")
        retained_package = expected_root / "packages" / "retained-package.txt"
        retained_package.parent.mkdir(parents=True)
        retained_package.write_text("steady core state\n", encoding="utf-8")

        def runner(command, cwd):
            self.assertFalse(stale_cache.exists())
            self.assertFalse(injected_global.exists())
            self.assertFalse(injected_board.exists())
            self.assertTrue((expected_root / "build-cache").is_dir())
            self.assertTrue((expected_root / "lib").is_dir())
            self.assertTrue((expected_root / "boards").is_dir())
            self.assertTrue(retained_package.is_file())
            self.write_firmware()
            return subprocess.CompletedProcess(command, 0)

        with patch(
            "build_firmware.prepare_generated_sdkconfigs",
            return_value=(self.project_dir / "sdkconfig.defaults",),
        ):
            build_firmware(self.project_dir, self.environment, runner=runner)

    def test_provenance_emits_canonical_core_attestation_digest(self):
        output = StringIO()
        digest = "c" * 64
        with redirect_stdout(output):
            _print_provenance(
                "FIRMWARE_BUILD_PROVENANCE",
                self.environment,
                "a" * 40,
                {"coreAttestationSha256": digest},
            )

        self.assertIn(f"coreAttestationSha256={digest}", output.getvalue())

    def test_downloads_and_content_pins_platform_project_config(self):
        self.platform_config_patch.stop()
        payload = b"trusted platform archive"
        expected_sha = hashlib.sha256(payload).hexdigest()
        package_payload = b"trusted package archive"
        package_sha = hashlib.sha256(package_payload).hexdigest()
        package_url = "https://example.invalid/tool.zip"
        (self.project_dir / "platformio.ini").write_text(
            f"[env:{self.environment}]\nplatform = {WAVESHARE_PLATFORM_URL}\n",
            encoding="utf-8",
        )
        with (
            patch(
                "build_firmware.WAVESHARE_PLATFORM_ARCHIVE_SHA256",
                expected_sha,
            ),
            patch(
                "build_firmware.WAVESHARE_PLATFORM_ARCHIVE_SIZE",
                len(payload),
            ),
            patch(
                "build_firmware.WAVESHARE_PLATFORM_PACKAGES",
                (("tool-test", package_url, package_sha, len(package_payload)),),
            ),
            patch(
                "build_firmware.urllib.request.urlopen",
                side_effect=lambda url, timeout: io.BytesIO(
                    payload if url == WAVESHARE_PLATFORM_URL else package_payload
                ),
            ) as download,
        ):
            config, archive = _verified_platformio_project_config(
                self.project_dir
            )
            self.assertEqual(archive.read_bytes(), payload)
            verified = config.read_text(encoding="utf-8")
            self.assertIn(archive.as_uri(), verified)
            self.assertIn("tool-test @ file://", verified)
            self.assertNotIn(WAVESHARE_PLATFORM_URL, verified)
            _verified_platformio_project_config(self.project_dir)
            self.assertEqual(download.call_count, 2)
        self.platform_config_patch.start()

    def test_bootstrap_wrappers_are_absent_from_steady_build_config(self):
        self.platform_config_patch.stop()
        payload = b"trusted platform archive"
        expected_sha = hashlib.sha256(payload).hexdigest()
        package_payload = b"trusted wrapper archive"
        package_sha = hashlib.sha256(package_payload).hexdigest()
        package_url = "https://example.invalid/toolchain.zip"
        scons_payload = b"trusted scons archive"
        scons_sha = hashlib.sha256(scons_payload).hexdigest()
        scons_url = "https://example.invalid/scons.tar.gz"
        (self.project_dir / "platformio.ini").write_text(
            f"[env:{self.environment}]\nplatform = {WAVESHARE_PLATFORM_URL}\n",
            encoding="utf-8",
        )
        with (
            patch("build_firmware.WAVESHARE_PLATFORM_ARCHIVE_SHA256", expected_sha),
            patch("build_firmware.WAVESHARE_PLATFORM_ARCHIVE_SIZE", len(payload)),
            patch(
                "build_firmware.WAVESHARE_PLATFORM_PACKAGES",
                (
                    (
                        "toolchain-xtensa-esp-elf",
                        package_url,
                        package_sha,
                        len(package_payload),
                    ),
                    (
                        "tool-scons",
                        scons_url,
                        scons_sha,
                        len(scons_payload),
                    ),
                ),
            ),
            patch(
                "build_firmware.urllib.request.urlopen",
                side_effect=lambda url, timeout: io.BytesIO({
                    WAVESHARE_PLATFORM_URL: payload,
                    package_url: package_payload,
                    scons_url: scons_payload,
                }[url]),
            ),
        ):
            steady, _ = _verified_platformio_project_config(self.project_dir)
        bootstrap = steady.with_name("platformio-bootstrap.ini")
        self.assertNotIn(
            "toolchain-xtensa-esp-elf @ file://",
            steady.read_text(encoding="utf-8"),
        )
        self.assertIn(
            "toolchain-xtensa-esp-elf @ file://",
            bootstrap.read_text(encoding="utf-8"),
        )
        self.assertNotIn(
            "tool-scons @ file://",
            steady.read_text(encoding="utf-8"),
        )
        self.assertNotIn(
            "tool-scons @ file://",
            bootstrap.read_text(encoding="utf-8"),
        )
        self.platform_config_patch.start()

    def test_platformio_core_scons_is_seeded_from_pinned_archive(self):
        self.scons_seed_patch.stop()
        archive = self.project_dir / "scons.tar.gz"
        source = self.project_dir / "scons-source"
        runtime = source / "scons-local-4.8.1/SCons/Script/__init__.py"
        runtime.parent.mkdir(parents=True)
        runtime.write_text("# pinned runtime\n", encoding="utf-8")
        (source / "package.json").write_text(
            '{"name":"tool-scons","version":"4.40801.0"}\n',
            encoding="utf-8",
        )
        with tarfile.open(archive, mode="w:gz") as bundle:
            bundle.add(source / "package.json", arcname="package.json")
            bundle.add(
                source / "scons-local-4.8.1",
                arcname="scons-local-4.8.1",
            )

        (
            self.project_dir
            / ".pio/open-bike-build/platformio"
            / self.environment
            / "packages"
        ).mkdir(parents=True)

        _seed_pinned_scons_package(
            self.project_dir, self.environment, archive
        )

        package = (
            self.project_dir
            / ".pio/open-bike-build/platformio"
            / self.environment
            / "packages/tool-scons"
        )
        self.assertEqual((package / "package.json").read_text(encoding="utf-8"),
                         '{"name":"tool-scons","version":"4.40801.0"}\n')
        marker = json.loads((package / ".piopm").read_text(encoding="utf-8"))
        self.assertEqual(marker["spec"]["owner"], "platformio")
        self.assertEqual(marker["spec"]["id"], 8192)
        self.assertEqual(marker["spec"]["name"], "tool-scons")
        self.assertIsNone(marker["spec"]["uri"])
        self.scons_seed_patch.start()

    def test_rejects_platform_download_with_wrong_content_digest(self):
        self.platform_config_patch.stop()
        (self.project_dir / "platformio.ini").write_text(
            f"[env:{self.environment}]\nplatform = {WAVESHARE_PLATFORM_URL}\n",
            encoding="utf-8",
        )
        replaced = b"replaced release asset"
        with (
            patch(
                "build_firmware.WAVESHARE_PLATFORM_ARCHIVE_SIZE",
                len(replaced),
            ),
            patch("build_firmware.WAVESHARE_PLATFORM_PACKAGES", ()),
            patch(
                "build_firmware.urllib.request.urlopen",
                return_value=io.BytesIO(replaced),
            ),
        ):
            with self.assertRaisesRegex(BuildError, "does not match"):
                _verified_platformio_project_config(self.project_dir)
        self.platform_config_patch.start()

    def test_scrubs_unrecognized_ambient_values_from_platformio(self):
        sentinel = "OPEN_BIKE_UNTRACKED_INPUT"

        def runner(command, cwd):
            self.assertNotIn(sentinel, os.environ)
            self.write_firmware()
            return subprocess.CompletedProcess(command, 0)

        with patch.dict(os.environ, {sentinel: "must-not-cross"}):
            build_firmware(self.project_dir, self.environment, runner=runner)
            self.assertEqual(os.environ[sentinel], "must-not-cross")

    def test_upload_rejects_non_amoled_profiles(self):
        with (self.project_dir / "platformio.ini").open("a", encoding="utf-8") as stream:
            stream.write("[env:WAVESHARE_TEST]\nplatform = test\n")
        with self.assertRaisesRegex(BuildError, "limited to attested"):
            upload_firmware(
                self.project_dir,
                "WAVESHARE_TEST",
                "/dev/cu.test",
                runner=lambda command, cwd: self.fail("runner must not be called"),
            )

    def test_project_wide_lock_serializes_every_profile(self):
        lock = (
            self.project_dir
            / ".pio/open-bike-build/locks/deterministic-build.lock"
        )
        lock.mkdir(parents=True)
        for environment in (self.environment, self.other_environment):
            with self.subTest(environment=environment):
                with self.assertRaisesRegex(BuildError, "project lock"):
                    build_firmware(
                        self.project_dir,
                        environment,
                        runner=lambda command, cwd: self.fail(
                            "runner must not be called"
                        ),
                    )

    def test_source_change_during_build_is_rejected(self):
        def runner(command, cwd):
            (self.project_dir / "platformio.ini").write_text(
                f"[env:{self.environment}]\nplatform = changed\n",
                encoding="utf-8",
            )
            self.write_firmware()
            return subprocess.CompletedProcess(command, 0)

        with self.assertRaisesRegex(BuildError, "identity changed during"):
            build_firmware(self.project_dir, self.environment, runner=runner)

    def test_unrecorded_managed_components_are_removed_before_build(self):
        component = self.project_dir / "managed_components/vendor__component"
        component.mkdir(parents=True)
        (component / ".component_hash").write_text("stale registry hash\n")
        (component / "component.cpp").write_text("injected source\n")

        def runner(command, cwd):
            self.assertFalse((self.project_dir / "managed_components").exists())
            self.write_firmware()
            return subprocess.CompletedProcess(command, 0)

        build_firmware(self.project_dir, self.environment, runner=runner)

    def test_dirty_source_cannot_cross_upload_boundary(self):
        self.write_firmware()
        (self.project_dir / "platformio.ini").write_text(
            f"[env:{self.environment}]\nplatform = dirty\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(BuildError, "exact clean Git"):
            upload_firmware(
                self.project_dir,
                self.environment,
                "/dev/cu.test",
                runner=lambda command, cwd: self.fail("runner must not be called"),
            )


if __name__ == "__main__":
    unittest.main()
