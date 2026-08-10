#!/usr/bin/env python3

import unittest

from pioarduino_custom_core import (
    CORRECTED_FREERTOS_TICKLESS_LITERAL_MAPPING,
    CORRECTED_FREERTOS_TICKLESS_TEXT_MAPPING,
    CORRECTED_PM_LITERAL_MAPPING,
    CORRECTED_PM_TEXT_MAPPING,
    CORRECTED_PENV_URLLIB3_REQUIREMENT,
    IDF_EXACT_REQUIREMENTS,
    UPSTREAM_AMBIENT_UV_FALLBACK,
    UPSTREAM_ESPTOOL_MATCH,
    UPSTREAM_EXTERNAL_UV_INSTALL,
    UPSTREAM_IDF_INSTALL_COMMAND,
    UPSTREAM_INTERNET_INSTALL_GATE,
    UPSTREAM_PENV_INSTALL_GUARD,
    UPSTREAM_PLATFORMIO_REQUIREMENT,
    UPSTREAM_ROOT_INSTALL_COMMAND,
    VERIFIED_LOCKED_UV_FALLBACK,
    UPSTREAM_EDITABLE_ESPTOOL,
    VERIFIED_ESPTOOL_MATCH,
    VERIFIED_EXTERNAL_UV_INSTALL,
    VERIFIED_IDF_INSTALL_COMMAND,
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
    correct_espidf_setup_text,
    correct_penv_setup_text,
    correct_sections_text,
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
