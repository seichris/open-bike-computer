"""Nonshipping target coverage must not broaden production or release policy."""
import configparser
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


class LifecycleQualificationTests(unittest.TestCase):
    def test_profiles_only_add_lifecycle_gates_to_production_behavior(self):
        config = configparser.ConfigParser(interpolation=None)
        config.read(ROOT / "esp32/platformio.ini")
        for board in ("175", "206"):
            production = f"env:WAVESHARE_AMOLED_{board}_PRODUCTION"
            qualifier = f"env:WAVESHARE_AMOLED_{board}_LIFECYCLE_QUALIFICATION"
            self.assertEqual(config[qualifier]["extends"], production)
            self.assertEqual(config[qualifier]["build_flags"].split(), [
                "${" + production + ".build_flags}",
                "-DMAP_OPERATIONS_V1_ENABLED=1", "-DFIRMWARE_OPERATIONS_V1_ENABLED=1",
            ])
            # No partition, renderer, trust, debug or upload overrides allowed.
            self.assertEqual(set(config[qualifier]), {"extends", "build_flags"})
            self.assertIn("-DFIRMWARE_DIAGNOSTICS=0", config[production]["build_flags"])
            self.assertNotIn("OPERATIONS_V1_ENABLED=1", config[production]["build_flags"])
        for name in config.sections():
            if not name.endswith("_LIFECYCLE_QUALIFICATION"):
                self.assertNotIn("-DMAP_OPERATIONS_V1_ENABLED=1", config[name].get("build_flags", ""))
                self.assertNotIn("-DFIRMWARE_OPERATIONS_V1_ENABLED=1", config[name].get("build_flags", ""))
        base = config["waveshare_amoled_common"]
        self.assertEqual(base["board_build.partitions"], "partitions.csv")
        partitions = (ROOT / "esp32/partitions.csv").read_text()
        self.assertIn("ota_0", partitions)
        self.assertIn("ota_1", partitions)

    def test_only_ci_builds_qualifiers_never_release_packaging(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn("needs.changes.outputs.heavy_ci == 'true'", ci)
        self.assertIn("Verify nonshipping lifecycle adapter coverage", ci)
        self.assertIn("fresh durable admission and operation identity required", ci)
        self.assertIn("durable OTA acceptance could not be confirmed", ci)
        self.assertIn('python3 tools/build_firmware.py', ci)
        self.assertIn('if [[ "${BUILD_ENVIRONMENT}" == *_PRODUCTION ]]; then', ci)
        self.assertNotRegex(ci, r"build_firmware\.py[^\n]*(?:--upload|--device-serial)")
        for workflow in ("firmware-release.yml", "firmware-release-candidate.yml"):
            self.assertNotIn("LIFECYCLE_QUALIFICATION", (ROOT / ".github/workflows" / workflow).read_text())


if __name__ == "__main__":
    unittest.main()
