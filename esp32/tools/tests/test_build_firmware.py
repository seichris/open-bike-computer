#!/usr/bin/env python3

import subprocess
import tempfile
import unittest
from pathlib import Path

from build_firmware import BuildError, build_firmware


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


class FirmwareBuildTests(unittest.TestCase):
    environment = "WAVESHARE_AMOLED_175"

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.project_dir = Path(self.temp_dir.name)
        (self.project_dir / "platformio.ini").write_text(
            f"[env:{self.environment}]\nplatform = test\n", encoding="utf-8"
        )

    def tearDown(self):
        self.temp_dir.cleanup()

    def write_dummy(self):
        dummy_dir = self.project_dir / ".dummy"
        dummy_dir.mkdir()
        for name, contents in DUMMY_FILES.items():
            (dummy_dir / name).write_text(contents, encoding="utf-8")

    def write_firmware(self):
        firmware = (
            self.project_dir
            / ".pio"
            / "build"
            / self.environment
            / "firmware.elf"
        )
        firmware.parent.mkdir(parents=True, exist_ok=True)
        firmware.write_bytes(b"real firmware")

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


if __name__ == "__main__":
    unittest.main()
