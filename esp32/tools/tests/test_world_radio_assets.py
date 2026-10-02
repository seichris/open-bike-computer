"""Keep World Radio's development-only UI free of heavyweight embedded assets."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[3]


class WorldRadioAssetTests(unittest.TestCase):
    def test_removed_raster_font_and_flags_stay_removed(self):
        for relative in (
            "esp32/lib/gui/src/worldRadioFont20.c",
            "esp32/lib/gui/src/worldRadioFlags.cpp",
            "esp32/lib/gui/src/worldRadioFlags.hpp",
            "esp32/lib/world_radio/world_radio_map_data.inc",
            "esp32/tools/world-radio-map/natural-earth.png",
        ):
            self.assertFalse((ROOT / relative).exists(), relative)

    def test_screen_uses_vector_geometry_and_builtin_fonts(self):
        source = (ROOT / "esp32/lib/gui/src/worldRadioScr.cpp").read_text()
        self.assertIn("void drawGlobe", source)
        self.assertIn("lv_draw_rect", source)
        self.assertIn("lv_draw_line", source)
        self.assertIn("lv_font_montserrat_18", source)
        for removed_symbol in (
            "worldRadioFont20",
            "world_radio_flags",
            "world_radio_map",
            "world_radio_raster",
        ):
            self.assertNotIn(removed_symbol, source)

    def test_capability_remains_development_only(self):
        config = (
            ROOT / "esp32/lib/world_radio/world_radio_config.hpp"
        ).read_text()
        self.assertIn("#if defined(FIRMWARE_DIAGNOSTICS) && FIRMWARE_DIAGNOSTICS", config)
        self.assertIn("inline constexpr bool ENABLED = false;", config)


if __name__ == "__main__":
    unittest.main()
