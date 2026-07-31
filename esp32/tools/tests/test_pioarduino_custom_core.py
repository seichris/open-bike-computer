#!/usr/bin/env python3

import unittest

from pioarduino_custom_core import (
    CORRECTED_PM_LITERAL_MAPPING,
    STALE_PM_LITERAL_MAPPING,
    correct_sections_text,
)


class CorrectSectionsTextTests(unittest.TestCase):
    def test_adds_missing_esp_pm_configure_literal(self):
        source = f"before\n{STALE_PM_LITERAL_MAPPING} trailing\nafter\n"

        corrected = correct_sections_text(source)

        self.assertIn(CORRECTED_PM_LITERAL_MAPPING, corrected)
        self.assertNotIn(
            f"{STALE_PM_LITERAL_MAPPING} trailing",
            corrected,
        )

    def test_is_idempotent_when_installed_script_is_already_corrected(self):
        source = f"before\n{CORRECTED_PM_LITERAL_MAPPING} trailing\nafter\n"

        self.assertEqual(correct_sections_text(source), source)

    def test_rejects_an_unknown_linker_script_shape(self):
        with self.assertRaisesRegex(ValueError, "unexpected format"):
            correct_sections_text("no esp_pm mapping")

    def test_rejects_multiple_stale_mappings(self):
        source = f"{STALE_PM_LITERAL_MAPPING}\n{STALE_PM_LITERAL_MAPPING}\n"

        with self.assertRaisesRegex(ValueError, "unexpected format"):
            correct_sections_text(source)

    def test_rejects_mixed_corrected_and_stale_mappings(self):
        source = f"{CORRECTED_PM_LITERAL_MAPPING}\n{STALE_PM_LITERAL_MAPPING}\n"

        with self.assertRaisesRegex(ValueError, "unexpected format"):
            correct_sections_text(source)


if __name__ == "__main__":
    unittest.main()
