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
    _default_platformio_core_dir,
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


class GeneratedSdkconfigTests(unittest.TestCase):
    def setUp(self) -> None:
        self.source_identity_patch = patch(
            "generated_sdkconfig.current_source_identity",
            return_value="a" * 40,
        )
        self.source_identity_patch.start()
        self.addCleanup(self.source_identity_patch.stop)
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

    @contextmanager
    def fake_core(self, project: Path):
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
        ):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"attested {path.name}\n", encoding="utf-8")
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

    def test_preserves_only_a_successfully_recorded_defaults_cache(self) -> None:
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
                record_generated_sdkconfig_defaults(
                    project, "WAVESHARE_AMOLED_175"
                )
                self.assertEqual(
                    prepare_generated_sdkconfigs(
                        project, "WAVESHARE_AMOLED_175"
                    ),
                    (defaults,),
                )
            self.assertTrue(defaults.is_file())
            self.assertFalse(current.exists())
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

    def test_invalidates_cache_with_missing_environment_state(self) -> None:
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
                manifest.pop("environmentSdkconfigSha256")
                manifest_path.write_text(
                    json.dumps(manifest) + "\n", encoding="utf-8"
                )

                self.assertEqual(
                    prepare_generated_sdkconfigs(
                        project, "WAVESHARE_AMOLED_175"
                    ),
                    (),
                )
            self.assertFalse(defaults.exists())

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
                            (),
                        )
                    self.assertFalse(defaults.exists())

    def test_cache_is_bound_to_exact_source_identity(self) -> None:
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
                        (),
                    )
            self.assertFalse(defaults.exists())

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
                    (),
                )
            self.assertFalse(defaults.exists())
            self.assertFalse((project / "managed_components").exists())

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
                    (),
                )
            self.assertFalse(defaults.exists())
            self.assertFalse(
                (project / ".pio/libdeps/WAVESHARE_AMOLED_175").exists()
            )

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
                    (),
                )
            self.assertFalse(defaults.exists())

    def test_invalidates_cache_after_compiler_or_runtime_change(self) -> None:
        for relative in (
            "packages/tool-esptoolpy/esptool.py",
            "tools/toolchain-xtensa-esp-elf/bin/xtensa-esp-elf-gcc",
            "penv/bin/platformio-runtime.py",
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
                            (),
                        )
                    self.assertFalse(defaults.exists())

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
                second_path = record_generated_sdkconfig_defaults(
                    project, "WAVESHARE_AMOLED_175"
                )
                second = json.loads(second_path.read_text(encoding="utf-8"))

            self.assertRegex(first["coreAttestationSha256"], r"^[0-9a-f]{64}$")
            self.assertNotEqual(
                first["coreAttestationSha256"],
                second["coreAttestationSha256"],
            )

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
                            (),
                        )
                    self.assertFalse(defaults.exists())

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
                    GeneratedSdkconfigError, "custom-core state changed"
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
                    (),
                )
            self.assertFalse(defaults.exists())

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
                    (),
                )
            self.assertFalse(defaults.exists())

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
                    manifest = (
                        project / ".pio/open-bike-build/sdkconfig-defaults.json"
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
                        (),
                    )
            self.assertFalse(defaults.exists())

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
                        (),
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
                            / ".pio/open-bike-build/sdkconfig-defaults.json"
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
