"""Coverage guard for the bundled radio font, without downloading fonts in CI."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[3]


class WorldRadioFontTests(unittest.TestCase):
    def test_metadata_glyphs_are_bundled(self):
        source = (ROOT / "esp32/lib/gui/src/worldRadioFont20.c").read_text()
        glyphs = {int(value, 16) for value in re.findall(r"U\+([0-9A-Fa-f]+)", source)}
        for character in "España中文电台廣播電臺北京上海東京éüç":
            self.assertIn(ord(character), glyphs, character)
        self.assertGreater(len(glyphs), 27000)
        for config in ["esp32/lib/lvgl/lv_conf.h", "esp32/tools/lv_conf_template.h"]:
            self.assertIn("#define LV_FONT_FMT_TXT_LARGE 1", (ROOT / config).read_text())


if __name__ == "__main__":
    unittest.main()
