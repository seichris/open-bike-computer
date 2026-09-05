#!/usr/bin/env python3

import hashlib
import unittest
from pathlib import Path

from pioarduino_custom_core import (
    CORRECTED_FREERTOS_TICKLESS_LITERAL_MAPPING,
    CORRECTED_FREERTOS_TICKLESS_TEXT_MAPPING,
    CORRECTED_PM_LITERAL_MAPPING,
    CORRECTED_PM_TEXT_MAPPING,
    CORRECTED_PENV_URLLIB3_REQUIREMENT,
    IDF_EXACT_REQUIREMENTS,
    UPSTREAM_AMBIENT_UV_FALLBACK,
    UPSTREAM_COMPONENT_ARCHIVE_COPY,
    UPSTREAM_ESPTOOL_MATCH,
    UPSTREAM_EXTERNAL_UV_INSTALL,
    UPSTREAM_IDF_INSTALL_COMMAND,
    UPSTREAM_INTERNET_INSTALL_GATE,
    UPSTREAM_GENERATED_PROJECT_CLEANUP,
    UPSTREAM_PENV_INSTALL_GUARD,
    UPSTREAM_PLATFORMIO_REQUIREMENT,
    UPSTREAM_ROOT_INSTALL_COMMAND,
    VERIFIED_LOCKED_UV_FALLBACK,
    VERIFIED_COMPONENT_ARCHIVE_COPY,
    UPSTREAM_EDITABLE_ESPTOOL,
    VERIFIED_ESPTOOL_MATCH,
    VERIFIED_EXTERNAL_UV_INSTALL,
    VERIFIED_IDF_INSTALL_COMMAND,
    VERIFIED_GENERATED_PROJECT_CLEANUP,
    VERIFIED_OFFLINE_INSTALL_GATE,
    VERIFIED_PENV_INSTALL_GUARD,
    VERIFIED_PLATFORMIO_REQUIREMENT,
    VERIFIED_ROOT_INSTALL_COMMAND,
    VERIFIED_WHEEL_ESPTOOL,
    PHASE_7A_PM_LITERAL_MAPPING,
    PHASE_9_ISR_PM_LITERAL_MAPPING,
    PHASE_9_ISR_PM_TEXT_MAPPING,
    STALE_FREERTOS_TICKLESS_LITERAL_MAPPING,
    STALE_FREERTOS_TICKLESS_TEXT_MAPPING,
    STALE_PM_TEXT_MAPPING,
    UPSTREAM_PM_LITERAL_MAPPING,
    UPSTREAM_PENV_URLLIB3_REQUIREMENT,
    UPSTREAM_NESTED_PIO_BLOCK,
    VERIFIED_NESTED_PIO_BLOCK,
    correct_nested_pio_command,
    correct_component_archive_copy,
    correct_generated_project_cleanup,
    correct_espidf_setup_text,
    correct_penv_setup_text,
    correct_sections_text,
    pioarduino_transform_source_sha256,
    verified_transform_marker_matches,
)


class CorrectSectionsTextTests(unittest.TestCase):
    def source(self, pm_literal=UPSTREAM_PM_LITERAL_MAPPING):
        return "\n".join(
            (
                "before",
                f"{pm_literal} trailing",
                STALE_PM_TEXT_MAPPING,
                STALE_FREERTOS_TICKLESS_LITERAL_MAPPING,
                STALE_FREERTOS_TICKLESS_TEXT_MAPPING,
                "after",
            )
        )

    def test_adds_missing_esp_pm_configure_literal(self):
        source = self.source()

        corrected = correct_sections_text(source)

        self.assertIn(CORRECTED_PM_LITERAL_MAPPING, corrected)
        self.assertIn(CORRECTED_PM_TEXT_MAPPING, corrected)
        self.assertIn(CORRECTED_FREERTOS_TICKLESS_LITERAL_MAPPING, corrected)
        self.assertIn(CORRECTED_FREERTOS_TICKLESS_TEXT_MAPPING, corrected)

    def test_upgrades_phase_7a_mapping(self):
        corrected = correct_sections_text(self.source(PHASE_7A_PM_LITERAL_MAPPING))

        self.assertIn(CORRECTED_PM_LITERAL_MAPPING, corrected)

    def test_upgrades_phase_9_isr_mapping(self):
        source = self.source(PHASE_9_ISR_PM_LITERAL_MAPPING).replace(
            STALE_PM_TEXT_MAPPING, PHASE_9_ISR_PM_TEXT_MAPPING
        )

        corrected = correct_sections_text(source)

        self.assertIn(CORRECTED_PM_LITERAL_MAPPING, corrected)
        self.assertIn(CORRECTED_PM_TEXT_MAPPING, corrected)

    def test_is_idempotent_when_installed_script_is_already_corrected(self):
        source = self.source()
        source = correct_sections_text(source)

        self.assertEqual(correct_sections_text(source), source)

    def test_rejects_an_unknown_linker_script_shape(self):
        with self.assertRaisesRegex(ValueError, "esp_pm literal.*unexpected format"):
            correct_sections_text("no esp_pm mapping")

    def test_rejects_multiple_stale_mappings(self):
        source = self.source().replace(
            UPSTREAM_PM_LITERAL_MAPPING,
            f"{UPSTREAM_PM_LITERAL_MAPPING}\n{UPSTREAM_PM_LITERAL_MAPPING}",
        )

        with self.assertRaisesRegex(ValueError, "unexpected format"):
            correct_sections_text(source)

    def test_rejects_mixed_corrected_and_stale_mappings(self):
        source = self.source().replace(
            UPSTREAM_PM_LITERAL_MAPPING,
            f"{CORRECTED_PM_LITERAL_MAPPING}\n{UPSTREAM_PM_LITERAL_MAPPING}",
        )

        with self.assertRaisesRegex(ValueError, "unexpected format"):
            correct_sections_text(source)

    def test_rejects_mixed_corrected_and_stale_text_mappings(self):
        source = correct_sections_text(self.source()).replace(
            CORRECTED_PM_TEXT_MAPPING,
            f"{CORRECTED_PM_TEXT_MAPPING}\n{STALE_PM_TEXT_MAPPING}",
        )

        with self.assertRaisesRegex(ValueError, "esp_pm text.*unexpected format"):
            correct_sections_text(source)

    def test_rejects_missing_tickless_mapping(self):
        source = self.source().replace(STALE_FREERTOS_TICKLESS_TEXT_MAPPING, "")

        with self.assertRaisesRegex(ValueError, "FreeRTOS tickless text"):
            correct_sections_text(source)


class CorrectNestedPioCommandTests(unittest.TestCase):
    def test_routes_recursive_build_through_verified_config(self):
        corrected = correct_nested_pio_command(
            f"before\n{UPSTREAM_NESTED_PIO_BLOCK}\nafter"
        )

        self.assertIn(VERIFIED_NESTED_PIO_BLOCK, corrected)
        self.assertNotIn(UPSTREAM_NESTED_PIO_BLOCK, corrected)

    def test_is_idempotent(self):
        source = f"before\n{VERIFIED_NESTED_PIO_BLOCK}\nafter"

        self.assertEqual(correct_nested_pio_command(source), source)

    def test_rejects_unknown_or_ambiguous_nested_commands(self):
        with self.assertRaisesRegex(ValueError, "nested PlatformIO command"):
            correct_nested_pio_command("no recursive command")
        with self.assertRaisesRegex(ValueError, "nested PlatformIO command"):
            correct_nested_pio_command(
                f"{UPSTREAM_NESTED_PIO_BLOCK}\n{UPSTREAM_NESTED_PIO_BLOCK}"
            )


class CorrectGeneratedProjectCleanupTests(unittest.TestCase):
    def test_removes_generated_paths_independently_and_fails_closed(self):
        corrected = correct_generated_project_cleanup(
            f"before\n{UPSTREAM_GENERATED_PROJECT_CLEANUP}\nafter"
        )

        self.assertIn(VERIFIED_GENERATED_PROJECT_CLEANUP, corrected)
        self.assertNotIn(UPSTREAM_GENERATED_PROJECT_CLEANUP, corrected)
        self.assertIn(
            'for generated_project_name in ("dependencies.lock", "CMakeLists.txt")',
            corrected,
        )
        self.assertIn("raise RuntimeError(", corrected)

    def test_is_idempotent(self):
        source = f"before\n{VERIFIED_GENERATED_PROJECT_CLEANUP}\nafter"

        self.assertEqual(correct_generated_project_cleanup(source), source)

    def test_rejects_unknown_or_ambiguous_cleanup(self):
        with self.assertRaisesRegex(ValueError, "generated project cleanup"):
            correct_generated_project_cleanup("no generated cleanup")
        with self.assertRaisesRegex(ValueError, "generated project cleanup"):
            correct_generated_project_cleanup(
                f"{UPSTREAM_GENERATED_PROJECT_CLEANUP}\n"
                f"{UPSTREAM_GENERATED_PROJECT_CLEANUP}"
            )

    def test_transform_source_identity_matches_repository_file(self):
        source = Path(__file__).resolve().parents[1] / "pioarduino_custom_core.py"

        self.assertEqual(
            pioarduino_transform_source_sha256(),
            hashlib.sha256(source.read_bytes()).hexdigest(),
        )

    def test_transform_marker_binds_schema_source_and_complete_shape(self):
        runtime = {"lockSetId": "test"}
        marker = {
            "schema": 2,
            "platformArchiveSha256": "a" * 64,
            "runtimeProvenance": runtime,
            "transformSourceSha256": "b" * 64,
            "platformTreeSha256": "c" * 64,
        }

        self.assertTrue(
            verified_transform_marker_matches(
                marker, "a" * 64, runtime, "b" * 64
            )
        )
        for field, value in (
            ("schema", 1),
            ("transformSourceSha256", "d" * 64),
            ("platformTreeSha256", "not-a-digest"),
        ):
            tampered = dict(marker)
            tampered[field] = value
            self.assertFalse(
                verified_transform_marker_matches(
                    tampered, "a" * 64, runtime, "b" * 64
                )
            )
        self.assertFalse(
            verified_transform_marker_matches(
                {**marker, "unexpected": True},
                "a" * 64,
                runtime,
                "b" * 64,
            )
        )


class CorrectComponentArchiveCopyTests(unittest.TestCase):
    def test_copies_nested_mbedtls_products_with_package_names(self):
        corrected = correct_component_archive_copy(
            f"before\n{UPSTREAM_COMPONENT_ARCHIVE_COPY}\nafter"
        )

        self.assertIn(VERIFIED_COMPONENT_ARCHIVE_COPY, corrected)
        self.assertNotIn(UPSTREAM_COMPONENT_ARCHIVE_COPY, corrected)
        self.assertIn('("libmbedtls.a", "libmbedtls_2.a")', corrected)
        self.assertIn("archive.is_symlink()", corrected)
        self.assertIn("raise RuntimeError(", corrected)

    def test_is_idempotent(self):
        source = f"before\n{VERIFIED_COMPONENT_ARCHIVE_COPY}\nafter"

        self.assertEqual(correct_component_archive_copy(source), source)

    def test_rejects_unknown_or_ambiguous_copy_logic(self):
        with self.assertRaisesRegex(ValueError, "component archive copy"):
            correct_component_archive_copy("no component archive copy")
        with self.assertRaisesRegex(ValueError, "component archive copy"):
            correct_component_archive_copy(
                f"{UPSTREAM_COMPONENT_ARCHIVE_COPY}\n"
                f"{UPSTREAM_COMPONENT_ARCHIVE_COPY}"
            )


class CorrectPenvSetupTextTests(unittest.TestCase):
    def source(self, requirement=UPSTREAM_PENV_URLLIB3_REQUIREMENT):
        return "\n".join(
            (
                "before",
                UPSTREAM_PLATFORMIO_REQUIREMENT,
                requirement,
                UPSTREAM_EXTERNAL_UV_INSTALL,
                UPSTREAM_PENV_INSTALL_GUARD,
                UPSTREAM_ROOT_INSTALL_COMMAND,
                UPSTREAM_INTERNET_INSTALL_GATE,
                UPSTREAM_AMBIENT_UV_FALLBACK,
                UPSTREAM_AMBIENT_UV_FALLBACK,
                UPSTREAM_ESPTOOL_MATCH,
                UPSTREAM_ESPTOOL_MATCH,
                UPSTREAM_EDITABLE_ESPTOOL,
                UPSTREAM_EDITABLE_ESPTOOL,
                "after",
            )
        )

    def test_aligns_urllib3_with_pinned_esptool(self):
        corrected = correct_penv_setup_text(self.source())

        self.assertIn(CORRECTED_PENV_URLLIB3_REQUIREMENT, corrected)
        self.assertNotIn(UPSTREAM_PENV_URLLIB3_REQUIREMENT, corrected)
        self.assertEqual(corrected.count(VERIFIED_LOCKED_UV_FALLBACK), 2)
        self.assertEqual(corrected.count(VERIFIED_WHEEL_ESPTOOL), 2)
        self.assertEqual(corrected.count(VERIFIED_ESPTOOL_MATCH), 2)
        self.assertIn(VERIFIED_PLATFORMIO_REQUIREMENT, corrected)
        self.assertIn(VERIFIED_EXTERNAL_UV_INSTALL, corrected)
        self.assertIn(VERIFIED_PENV_INSTALL_GUARD, corrected)
        self.assertIn(
            "external_uv_executable not in (None, locked_uv_executable)",
            corrected,
        )
        self.assertIn("external_uv_executable = locked_uv_executable", corrected)
        self.assertIn(VERIFIED_ROOT_INSTALL_COMMAND, corrected)
        self.assertIn(VERIFIED_OFFLINE_INSTALL_GATE, corrected)
        self.assertNotIn("https://github.com/pioarduino/platformio-core", corrected)

    def test_is_idempotent(self):
        source = self.source(CORRECTED_PENV_URLLIB3_REQUIREMENT).replace(
            UPSTREAM_AMBIENT_UV_FALLBACK, VERIFIED_LOCKED_UV_FALLBACK
        ).replace(UPSTREAM_EDITABLE_ESPTOOL, VERIFIED_WHEEL_ESPTOOL)
        for stale, final in (
            (UPSTREAM_PLATFORMIO_REQUIREMENT, VERIFIED_PLATFORMIO_REQUIREMENT),
            (UPSTREAM_EXTERNAL_UV_INSTALL, VERIFIED_EXTERNAL_UV_INSTALL),
            (UPSTREAM_PENV_INSTALL_GUARD, VERIFIED_PENV_INSTALL_GUARD),
            (UPSTREAM_ROOT_INSTALL_COMMAND, VERIFIED_ROOT_INSTALL_COMMAND),
            (UPSTREAM_INTERNET_INSTALL_GATE, VERIFIED_OFFLINE_INSTALL_GATE),
            (UPSTREAM_ESPTOOL_MATCH, VERIFIED_ESPTOOL_MATCH),
        ):
            source = source.replace(stale, final)

        self.assertEqual(correct_penv_setup_text(source), source)

    def test_rejects_unknown_or_ambiguous_requirements(self):
        with self.assertRaisesRegex(ValueError, "urllib3 requirement"):
            correct_penv_setup_text(self.source().replace(UPSTREAM_PENV_URLLIB3_REQUIREMENT, ""))
        with self.assertRaisesRegex(ValueError, "urllib3 requirement"):
            correct_penv_setup_text(self.source().replace(
                UPSTREAM_PENV_URLLIB3_REQUIREMENT,
                f"{UPSTREAM_PENV_URLLIB3_REQUIREMENT}\n{UPSTREAM_PENV_URLLIB3_REQUIREMENT}",
            ))
        with self.assertRaisesRegex(ValueError, "urllib3 requirement"):
            correct_penv_setup_text(self.source().replace(
                UPSTREAM_PENV_URLLIB3_REQUIREMENT,
                f"{UPSTREAM_PENV_URLLIB3_REQUIREMENT}\n{CORRECTED_PENV_URLLIB3_REQUIREMENT}",
            ))


class CorrectEspIdfSetupTextTests(unittest.TestCase):
    def source(self):
        return "\n".join(
            ["before", *(stale for stale, _ in IDF_EXACT_REQUIREMENTS), UPSTREAM_IDF_INSTALL_COMMAND, "after"]
        )

    def test_pins_and_routes_esp_idf_dependencies_offline(self):
        corrected = correct_espidf_setup_text(self.source())

        for stale, final in IDF_EXACT_REQUIREMENTS:
            self.assertNotIn(stale, corrected)
            self.assertIn(final, corrected)
        self.assertIn(VERIFIED_IDF_INSTALL_COMMAND, corrected)
        self.assertNotIn(UPSTREAM_IDF_INSTALL_COMMAND, corrected)

    def test_is_idempotent(self):
        corrected = correct_espidf_setup_text(self.source())

        self.assertEqual(correct_espidf_setup_text(corrected), corrected)

    def test_rejects_an_unknown_idf_dependency_shape(self):
        with self.assertRaisesRegex(ValueError, "ESP-IDF exact dependency"):
            correct_espidf_setup_text(self.source().replace(IDF_EXACT_REQUIREMENTS[0][0], ""))


if __name__ == "__main__":
    unittest.main()
