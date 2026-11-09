#!/usr/bin/env python3
"""Pin the project-owned Montserrat fonts to the symbols the GUI draws.

lib/gui/src/fonts/ replaces LVGL's built-in lv_font_montserrat_* fonts with
copies that carry only the FontAwesome symbols the firmware renders. These
tests keep lv_conf.h, the generated files, the generator tables in
tools/generate_montserrat_fonts.py and the GUI sources in agreement, so a
new LV_SYMBOL_* use fails here instead of drawing a placeholder box.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ESP32_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ESP32_ROOT / "tools"))
import generate_montserrat_fonts as fonts  # noqa: E402

FONT_DIR = fonts.DEFAULT_OUT_DIR
LV_CONF = (ESP32_ROOT / "lib/lvgl/lv_conf.h").read_text(encoding="utf-8")
GLOBAL_GUI_DEF = (ESP32_ROOT / "lib/gui/src/globalGuiDef.h").read_text(
    encoding="utf-8")
PLATFORMIO_INI = (ESP32_ROOT / "platformio.ini").read_text(encoding="utf-8")
SOURCE_SUFFIXES = {".c", ".cpp", ".h", ".hpp"}
SYMBOL_USE = re.compile(r"\bLV_SYMBOL_([A-Z_0-9]+)\b")
DIRECT_FONT_USE = re.compile(r"\blv_font_montserrat_(\d+)\b")
LARGE_SIZES = tuple(sorted(fonts.LARGE_FONT_SYMBOLS))

# Symbols a source file uses at a smaller size although the same file also
# references one of the large fonts. Each entry names the label that carries
# the symbol; the test checks that the file still uses both the size and the
# symbol so stale exclusions are noticed.
LARGE_FONT_EXCLUSIONS = {
    # The 38 px glyph is the Wi-Fi mark of the "waiting for iPhone" artwork;
    # the check mark is drawn at 24 px and 48 px.
    ("preConnectionIcons.cpp", 38): {"OK"},
    # The 48 px glyph is the check mark; the Wi-Fi mark is 38 px.
    ("preConnectionIcons.cpp", 48): {"WIFI"},
    # The battery line is the 24 px label; 38 px and 48 px carry the
    # headline and the pairing code.
    ("waitingScr.cpp", 38): {"BATTERY_EMPTY", "BATTERY_1", "BATTERY_2",
                             "BATTERY_3", "BATTERY_FULL", "CHARGE"},
    ("waitingScr.cpp", 48): {"BATTERY_EMPTY", "BATTERY_1", "BATTERY_2",
                             "BATTERY_3", "BATTERY_FULL", "CHARGE"},
}


def own_sources() -> list[Path]:
    paths = []
    for root in (ESP32_ROOT / "lib", ESP32_ROOT / "src"):
        for path in sorted(root.rglob("*")):
            if path.suffix in SOURCE_SUFFIXES and FONT_DIR not in path.parents:
                paths.append(path)
    return paths


SOURCES = {path: path.read_text(encoding="utf-8", errors="replace")
           for path in own_sources()}


def glyph_symbols(source: str) -> set[str]:
    return set(SYMBOL_USE.findall(source)) - set(fonts.NON_GLYPH_SYMBOLS)


def font_aliases() -> dict[str, int]:
    """globalGuiDef.h font aliases; the Waveshare build has one set of them."""
    assert "LARGE_SCREEN" not in GLOBAL_GUI_DEF, "font aliases gained a second branch"
    aliases = {
        match.group(1): int(match.group(2))
        for match in re.finditer(
            r"static const lv_font_t \*(\w+) = &lv_font_montserrat_(\d+);",
            GLOBAL_GUI_DEF)
    }
    assert aliases, "no font aliases found in globalGuiDef.h"
    return aliases


ALIASES = font_aliases()


def font_sizes_used(source: str) -> set[int]:
    sizes = {int(size) for size in DIRECT_FONT_USE.findall(source)}
    for alias, size in ALIASES.items():
        if re.search(rf"\b{alias}\b", source):
            sizes.add(size)
    return sizes


def parse_code_points(font_source: str) -> set[int]:
    """Code points covered by the cmaps of an lv_font_conv LVGL font."""
    cmaps = re.search(r"cmaps\[\]\s*=\s*\{(.*?)\n\};", font_source, re.S)
    assert cmaps, "cmaps[] not found"
    entry = re.compile(
        r"\.range_start\s*=\s*(\d+),\s*\.range_length\s*=\s*(\d+),\s*"
        r"\.glyph_id_start\s*=\s*\d+,\s*\.unicode_list\s*=\s*(\w+),\s*"
        r"\.glyph_id_ofs_list\s*=\s*\w+,\s*\.list_length\s*=\s*(\d+),\s*"
        r"\.type\s*=\s*(\w+)")
    code_points: set[int] = set()
    for start, length, unicode_list, list_length, kind in entry.findall(
            cmaps.group(1)):
        start, length, list_length = int(start), int(length), int(list_length)
        if kind.endswith("FORMAT0_TINY") or kind.endswith("FORMAT0_FULL"):
            code_points.update(range(start, start + length))
        elif kind.endswith("SPARSE_TINY") or kind.endswith("SPARSE_FULL"):
            array = re.search(rf"{unicode_list}\[\]\s*=\s*\{{(.*?)\}}",
                              font_source, re.S)
            assert array, f"{unicode_list}[] not found"
            offsets = [int(value, 0) for value in
                       re.findall(r"0x[0-9A-Fa-f]+|\d+", array.group(1))]
            assert len(offsets) == list_length, (unicode_list, len(offsets))
            code_points.update(start + offset for offset in offsets)
        else:
            raise AssertionError(f"unknown cmap type {kind}")
    return code_points


class LvConfTests(unittest.TestCase):
    def test_built_in_montserrat_fonts_are_disabled(self):
        for size in fonts.SIZES:
            self.assertRegex(
                LV_CONF, rf"(?m)^#define LV_FONT_MONTSERRAT_{size}\s+0\s*$",
                f"LVGL's built-in Montserrat {size} must stay off; the "
                "project copy in lib/gui/src/fonts/ defines the same symbol")

    def test_project_fonts_are_declared(self):
        for size in fonts.SIZES:
            self.assertIn(f"LV_FONT_DECLARE({fonts.font_name(size)})", LV_CONF)
        self.assertIn("#define LV_FONT_DEFAULT &lv_font_montserrat_14", LV_CONF)

    def test_shipped_fonts_are_compressed(self):
        self.assertRegex(LV_CONF, r"(?m)^#define LV_USE_FONT_COMPRESSED 1\s*$")

    def test_waveshare_builds_use_the_small_screen_aliases(self):
        self.assertNotRegex(PLATFORMIO_INI, r"-D\s*LARGE_SCREEN\b")
        for path, source in SOURCES.items():
            self.assertNotRegex(source, r"#\s*define\s+LARGE_SCREEN\b",
                                f"{path} defines LARGE_SCREEN")


class GeneratedFontTests(unittest.TestCase):
    def font_source(self, size: int) -> str:
        path = fonts.output_path(FONT_DIR, size)
        self.assertTrue(path.is_file(), f"{path} is missing")
        return path.read_text(encoding="utf-8")

    def test_every_size_is_generated_with_the_recorded_options(self):
        for size in fonts.SIZES:
            source = self.font_source(size)
            self.assertIn(f" * Size: {size} px\n", source)
            self.assertIn(f" * Bpp: {fonts.BPP}\n", source)
            options = re.search(r"^ \* Opts: (.*)$", source, re.M)
            self.assertIsNotNone(options, f"{size}: Opts line missing")
            expected = " ".join(fonts.conversion_arguments(size, compressed=True))
            self.assertEqual(options.group(1), expected,
                             f"{size}: regenerate with the generator")
            self.assertIn(f"tools/generate_montserrat_fonts.py with lv_font_conv "
                          f"{fonts.LV_FONT_CONV_VERSION}", source)

    def test_project_guard_replaces_the_lvgl_switch(self):
        for size in fonts.SIZES:
            source = self.font_source(size)
            guard = fonts.guard_macro(size)
            self.assertIn(f"#ifndef {guard}\n#define {guard} 1\n#endif", source)
            self.assertIn(f"#if {guard}\n", source)
            self.assertNotRegex(source, rf"\bLV_FONT_MONTSERRAT_{size}\b",
                                f"{size}: lv_conf.h's 0 would compile it away")
            self.assertRegex(
                source, rf"const lv_font_t {fonts.font_name(size)} = \{{")

    def test_glyph_sets_match_the_generator_tables(self):
        for size in fonts.SIZES:
            covered = parse_code_points(self.font_source(size))
            expected = set(fonts.BASE_CODE_POINTS) | set(fonts.code_points_for(size))
            self.assertEqual(covered, expected, (
                f"{size}: glyphs {sorted(map(hex, covered ^ expected))} differ "
                "from generate_montserrat_fonts.py"))


class SymbolInventoryTests(unittest.TestCase):
    def test_gui_symbol_table_matches_the_sources(self):
        used = set().union(*(glyph_symbols(source) for source in SOURCES.values()))
        self.assertEqual(used, set(fonts.GUI_SYMBOLS), (
            "LV_SYMBOL_* uses in lib/ and src/ differ from GUI_SYMBOLS; update "
            "the table, rerun tools/generate_montserrat_fonts.py and check the "
            "large-font sets"))

    def test_small_fonts_carry_every_symbol(self):
        expected = set(fonts.GUI_SYMBOLS) | set(fonts.WIDGET_SYMBOLS)
        self.assertEqual(set(fonts.SMALL_FONT_SYMBOLS), expected)
        for size in fonts.SIZES:
            if size not in fonts.LARGE_FONT_SYMBOLS:
                self.assertEqual(set(fonts.symbols_for(size)), expected)

    def test_symbol_names_are_known(self):
        for name in (*fonts.GUI_SYMBOLS, *fonts.WIDGET_SYMBOLS,
                     *(n for names in fonts.LARGE_FONT_SYMBOLS.values()
                       for n in names)):
            self.assertIn(name, fonts.LV_SYMBOLS)

    def test_large_fonts_cover_the_symbols_drawn_at_their_size(self):
        required_by_size = {size: set() for size in LARGE_SIZES}
        for path, source in SOURCES.items():
            symbols = glyph_symbols(source)
            if not symbols:
                continue
            for size in font_sizes_used(source) & set(LARGE_SIZES):
                excluded = LARGE_FONT_EXCLUSIONS.get((path.name, size), set())
                required = symbols - excluded
                self.assertLessEqual(required, set(fonts.LARGE_FONT_SYMBOLS[size]), (
                    f"{path.name} draws {sorted(required)} and uses Montserrat "
                    f"{size}; add them to LARGE_FONT_SYMBOLS[{size}] and "
                    "regenerate, or document a LARGE_FONT_EXCLUSIONS entry"))
                required_by_size[size] |= required
        for size in LARGE_SIZES:
            self.assertEqual(set(fonts.LARGE_FONT_SYMBOLS[size]),
                             required_by_size[size],
                             f"{size}: large-font symbol set has stale entries")

    def test_large_font_exclusions_are_still_live(self):
        for (name, size), excluded in LARGE_FONT_EXCLUSIONS.items():
            matches = [path for path in SOURCES if path.name == name]
            self.assertEqual(len(matches), 1, name)
            source = SOURCES[matches[0]]
            self.assertIn(size, font_sizes_used(source),
                          f"{name} no longer uses Montserrat {size}")
            self.assertLessEqual(excluded, glyph_symbols(source),
                                 f"{name} no longer uses all excluded symbols")

    def test_widgets_that_draw_symbols_stay_on_small_fonts(self):
        # Keyboards, dropdowns, checkboxes and message boxes draw
        # WIDGET_SYMBOLS with their own text font; the large fonts omit them.
        for path, source in SOURCES.items():
            if not any(creator in source for creator in fonts.WIDGET_CREATORS):
                continue
            large = font_sizes_used(source) & set(LARGE_SIZES)
            self.assertFalse(large, (
                f"{path.name} creates a symbol-drawing widget and uses "
                f"Montserrat {sorted(large)}; those fonts omit WIDGET_SYMBOLS"))


if __name__ == "__main__":
    unittest.main()
