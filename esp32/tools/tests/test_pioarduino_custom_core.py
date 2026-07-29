#!/usr/bin/env python3

import unittest

from pioarduino_custom_core import (
    CORRECTED_FREERTOS_TICKLESS_LITERAL_MAPPING,
    CORRECTED_FREERTOS_TICKLESS_TEXT_MAPPING,
    CORRECTED_PM_LITERAL_MAPPING,
    CORRECTED_PM_TEXT_MAPPING,
    PHASE_7A_PM_LITERAL_MAPPING,
    STALE_FREERTOS_TICKLESS_LITERAL_MAPPING,
    STALE_FREERTOS_TICKLESS_TEXT_MAPPING,
    STALE_PM_TEXT_MAPPING,
    UPSTREAM_PM_LITERAL_MAPPING,
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

    def test_rejects_missing_tickless_mapping(self):
        source = self.source().replace(STALE_FREERTOS_TICKLESS_TEXT_MAPPING, "")

        with self.assertRaisesRegex(ValueError, "FreeRTOS tickless text"):
            correct_sections_text(source)


if __name__ == "__main__":
    unittest.main()
