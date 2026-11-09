#!/usr/bin/env python3
"""Regenerate the project-owned Montserrat fonts under lib/gui/src/fonts/.

LVGL's built-in ``lv_font_montserrat_*`` fonts carry 60 FontAwesome symbol
glyphs at every size. The firmware draws 21 of them, LVGL's own widgets eight
more, and the three largest fonts render only a handful, so the built-in
fonts are disabled in ``lib/lvgl/lv_conf.h`` and the firmware ships its own
copies with the same font names, the same Montserrat and FontAwesome sources,
the same bpp and kerning as LVGL's ``scripts/built_in_font/built_in_font_gen.py``
and a smaller symbol list. ``tools/tests/test_montserrat_font_subset.py`` pins
the glyph sets to the symbol uses in the GUI sources and to the tables below.

Run from ``esp32/``::

    python3 tools/generate_montserrat_fonts.py [--lvgl-dir DIR] [--lv-font-conv PATH]

The TTF/WOFF sources are read from the LVGL 9.2.2 package PlatformIO already
downloaded (``.pio/open-bike-build/platformio/*/libdeps/*/lvgl``) unless
``--lvgl-dir`` names another copy. lv_font_conv 1.5.3 reproduces LVGL's
shipped fonts byte for byte from those sources; other versions may differ.
The shipped fonts are LVGL-compressed (``LV_USE_FONT_COMPRESSED 1``);
``--uncompressed`` writes uncompressed variants to ``--out-dir`` for measurement.
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ESP32_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUT_DIR = ESP32_ROOT / "lib" / "gui" / "src" / "fonts"
LV_FONT_CONV_VERSION = "1.5.3"
LVGL_VERSION = "9.2.2"
MONTSERRAT_TTF = "Montserrat-Medium.ttf"
FONTAWESOME_WOFF = "FontAwesome5-Solid+Brands+Regular.woff"

SIZES = (8, 10, 12, 14, 16, 18, 24, 32, 38, 48)
BPP = 4
# LVGL's built-in range: printable ASCII, the degree sign and the bullet.
# Montserrat has no glyph for U+007F, so the fonts end at U+007E.
BASE_RANGE = "0x20-0x7F,0xB0,0x2022"
BASE_CODE_POINTS = frozenset(range(0x20, 0x7F)) | {0xB0, 0x2022}

# Code points of the LV_SYMBOL_* macros in LVGL 9.2 lv_symbol_def.h, decoded
# from the UTF-8 strings (the header's hex comments are not all accurate;
# LV_SYMBOL_FILE is U+F15B, not the commented U+F158). verify_symbol_table()
# rechecks this table against the LVGL package before generating.
# LV_SYMBOL_BULLET is U+2022 and already part of BASE_RANGE; LV_SYMBOL_DUMMY
# (U+F8FF) has no glyph in any LVGL font.
LV_SYMBOLS = {
    "AUDIO": 0xF001, "VIDEO": 0xF008, "LIST": 0xF00B, "OK": 0xF00C,
    "CLOSE": 0xF00D, "POWER": 0xF011, "SETTINGS": 0xF013, "HOME": 0xF015,
    "DOWNLOAD": 0xF019, "DRIVE": 0xF01C, "REFRESH": 0xF021, "MUTE": 0xF026,
    "VOLUME_MID": 0xF027, "VOLUME_MAX": 0xF028, "IMAGE": 0xF03E, "TINT": 0xF043,
    "PREV": 0xF048, "PLAY": 0xF04B, "PAUSE": 0xF04C, "STOP": 0xF04D,
    "NEXT": 0xF051, "EJECT": 0xF052, "LEFT": 0xF053, "RIGHT": 0xF054,
    "PLUS": 0xF067, "MINUS": 0xF068, "EYE_OPEN": 0xF06E, "EYE_CLOSE": 0xF070,
    "WARNING": 0xF071, "SHUFFLE": 0xF074, "UP": 0xF077, "DOWN": 0xF078,
    "LOOP": 0xF079, "DIRECTORY": 0xF07B, "UPLOAD": 0xF093, "CALL": 0xF095,
    "CUT": 0xF0C4, "COPY": 0xF0C5, "SAVE": 0xF0C7, "BARS": 0xF0C9,
    "ENVELOPE": 0xF0E0, "CHARGE": 0xF0E7, "PASTE": 0xF0EA, "BELL": 0xF0F3,
    "KEYBOARD": 0xF11C, "GPS": 0xF124, "FILE": 0xF15B, "WIFI": 0xF1EB,
    "BATTERY_FULL": 0xF240, "BATTERY_3": 0xF241, "BATTERY_2": 0xF242,
    "BATTERY_1": 0xF243, "BATTERY_EMPTY": 0xF244, "USB": 0xF287,
    "BLUETOOTH": 0xF293, "TRASH": 0xF2ED, "EDIT": 0xF304, "BACKSPACE": 0xF55A,
    "SD_CARD": 0xF7C2, "NEW_LINE": 0xF8A2,
}
# Symbols without a FontAwesome glyph; they never select a font glyph.
NON_GLYPH_SYMBOLS = frozenset({"BULLET", "DUMMY"})

# Every LV_SYMBOL_* the firmware writes into labels, table cells, list
# buttons or background images (grep LV_SYMBOL_ in lib/ and src/).
GUI_SYMBOLS = (
    "BATTERY_EMPTY", "BATTERY_1", "BATTERY_2", "BATTERY_3", "BATTERY_FULL",
    "CHARGE",                       # notifyBar, waitingScr battery line
    "GPS", "WIFI", "SD_CARD",       # notifyBar, preConnectionIcons
    "LEFT", "FILE",                 # gpx screens, button bar
    "PLAY", "PAUSE", "SHUFFLE",     # worldRadioScr controls, gpx list
    "LOOP", "OK", "WARNING",        # gpxDetailScr, preConnectionIcons, upgrade
    "SETTINGS", "PLUS", "MINUS",    # device and map settings screens
)
# Symbols LVGL 9.2 widgets draw on their own: keyboard keys, the dropdown
# arrow, the message-box close button and the default theme's checkbox mark.
WIDGET_SYMBOLS = (
    "BACKSPACE", "CLOSE", "DOWN", "KEYBOARD", "LEFT", "NEW_LINE", "OK", "RIGHT",
)
WIDGET_CREATORS = ("lv_keyboard_create", "lv_dropdown_create",
                   "lv_checkbox_create", "lv_msgbox_create")

# Fonts up to 24 px carry the complete set: they are the theme default, the
# globalGuiDef.h aliases and the sizes every symbol-bearing screen uses.
SMALL_FONT_SYMBOLS = tuple(sorted(set(GUI_SYMBOLS) | set(WIDGET_SYMBOLS),
                                  key=LV_SYMBOLS.__getitem__))

# The three largest fonts draw headlines, ride values and distances. Only
# these symbols appear at those sizes; the test derives the same list from
# the sources and documents the exclusions.
LARGE_FONT_SYMBOLS = {
    32: ("PLAY", "PAUSE", "SHUFFLE"),  # worldRadioScr bottom controls
    38: ("WIFI",),                     # preConnectionIcons "waiting for iPhone"
    48: ("OK",),                       # preConnectionIcons check mark
}


def symbols_for(size: int) -> tuple[str, ...]:
    """Symbol names (without the LV_SYMBOL_ prefix) a font of `size` carries."""
    return LARGE_FONT_SYMBOLS.get(size, SMALL_FONT_SYMBOLS)


def code_points_for(size: int) -> frozenset[int]:
    return frozenset(LV_SYMBOLS[name] for name in symbols_for(size))


def font_name(size: int) -> str:
    return f"lv_font_montserrat_{size}"


def guard_macro(size: int) -> str:
    """lv_font_conv guards the file with the upper-cased font name, which is
    the LV_FONT_MONTSERRAT_* switch lv_conf.h turns off. Use our own guard."""
    return f"OPEN_BIKE_{font_name(size).upper()}"


def output_path(out_dir: Path, size: int) -> Path:
    return out_dir / f"{font_name(size)}.c"


def symbol_range_argument(size: int) -> str:
    return ",".join(str(cp) for cp in sorted(code_points_for(size)))


def find_lvgl_dir() -> Path:
    pattern = ".pio/open-bike-build/platformio/*/libdeps/*/lvgl"
    for candidate in sorted(ESP32_ROOT.glob(pattern)):
        if (candidate / "scripts" / "built_in_font" / MONTSERRAT_TTF).is_file():
            return candidate
    raise SystemExit(
        "no downloaded LVGL package with scripts/built_in_font found below "
        f"{ESP32_ROOT / '.pio/open-bike-build'}; build a profile first or pass "
        "--lvgl-dir")


def check_lvgl_version(lvgl_dir: Path) -> None:
    manifest = lvgl_dir / "library.json"
    match = re.search(r'"version"\s*:\s*"([^"]+)"', manifest.read_text())
    version = match.group(1) if match else "unknown"
    if version != LVGL_VERSION:
        raise SystemExit(
            f"{lvgl_dir} is LVGL {version}; the fonts are generated from "
            f"LVGL {LVGL_VERSION}'s font sources")


def decode_symbol_header(source: str) -> dict[str, int]:
    """Code points of the LV_SYMBOL_* string macros in lv_symbol_def.h."""
    decoded = {}
    for match in re.finditer(
            r'#define LV_SYMBOL_([A-Z_0-9]+)\s+"((?:\\x[0-9A-Fa-f]{2})+)"', source):
        raw = bytes(int(byte, 16)
                    for byte in re.findall(r"\\x([0-9A-Fa-f]{2})", match.group(2)))
        decoded[match.group(1)] = ord(raw.decode("utf-8"))
    return decoded


def verify_symbol_table(lvgl_dir: Path) -> None:
    header = lvgl_dir / "src" / "font" / "lv_symbol_def.h"
    actual = decode_symbol_header(header.read_text(encoding="utf-8"))
    actual = {name: cp for name, cp in actual.items()
              if name not in NON_GLYPH_SYMBOLS}
    if actual != LV_SYMBOLS:
        differences = sorted(set(actual.items()) ^ set(LV_SYMBOLS.items()))
        raise SystemExit(f"LV_SYMBOLS disagrees with {header}: {differences}")


def find_lv_font_conv(explicit: str | None) -> list[str]:
    if explicit:
        return [explicit]
    found = shutil.which("lv_font_conv")
    if found:
        return [found]
    return ["npx", "-y", f"lv_font_conv@{LV_FONT_CONV_VERSION}"]


def lv_font_conv_version(command: list[str]) -> str:
    result = subprocess.run(command + ["--version"], capture_output=True,
                            text=True, check=True)
    return result.stdout.strip() or result.stderr.strip()


def conversion_arguments(size: int, compressed: bool) -> list[str]:
    """Mirror built_in_font_gen.py: bpp, sources, ranges and kerning format."""
    arguments = ["--bpp", str(BPP), "--size", str(size)]
    if not compressed:
        arguments += ["--no-compress", "--no-prefilter"]
    arguments += [
        "--font", MONTSERRAT_TTF, "-r", BASE_RANGE,
        "--font", FONTAWESOME_WOFF, "-r", symbol_range_argument(size),
        "--format", "lvgl", "-o", f"{font_name(size)}.c",
        "--force-fast-kern-format",
        "--lv-include", "lvgl.h", "--lv-font-name", font_name(size),
    ]
    return arguments


def provenance_comment(size: int, converter_version: str) -> str:
    return (
        "/* Generated by tools/generate_montserrat_fonts.py with lv_font_conv "
        f"{converter_version}\n"
        f" * from LVGL {LVGL_VERSION}'s {MONTSERRAT_TTF} and {FONTAWESOME_WOFF}.\n"
        " * Do not edit; rerun the script to change the glyph set. "
        f"Symbols: {', '.join(symbols_for(size)) or 'none'}. */\n"
    )


def rewrite_generated_font(source: str, size: int, converter_version: str) -> str:
    """Swap lv_font_conv's guard for the project guard and add provenance."""
    original_guard = font_name(size).upper()
    guard_pattern = re.compile(rf"\b{original_guard}\b")
    if len(guard_pattern.findall(source)) < 3:
        raise SystemExit(f"unexpected lv_font_conv output for {font_name(size)}: "
                         f"guard {original_guard} not found")
    rewritten = guard_pattern.sub(guard_macro(size), source)
    header_end = rewritten.index("*/\n") + len("*/\n")
    return (rewritten[:header_end] + provenance_comment(size, converter_version)
            + rewritten[header_end:])


def generate(size: int, *, converter: list[str], converter_version: str,
             font_sources: Path, out_dir: Path, compressed: bool) -> Path:
    with tempfile.TemporaryDirectory(prefix="montserrat-font-") as scratch:
        scratch_dir = Path(scratch)
        # Copy the sources next to the output so the recorded command line
        # names plain file names instead of machine-specific paths.
        for name in (MONTSERRAT_TTF, FONTAWESOME_WOFF):
            shutil.copyfile(font_sources / name, scratch_dir / name)
        subprocess.run(converter + conversion_arguments(size, compressed),
                       cwd=scratch_dir, check=True)
        generated = (scratch_dir / f"{font_name(size)}.c").read_text()
    out_dir.mkdir(parents=True, exist_ok=True)
    destination = output_path(out_dir, size)
    destination.write_text(rewrite_generated_font(generated, size,
                                                  converter_version))
    return destination


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--lvgl-dir", type=Path,
                        help="LVGL package with scripts/built_in_font/")
    parser.add_argument("--lv-font-conv",
                        help="lv_font_conv executable (default: PATH, then npx)")
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    parser.add_argument("--uncompressed", action="store_true",
                        help="write uncompressed fonts (measurement only; the "
                             "shipped fonts are LVGL-compressed)")
    parser.add_argument("--size", type=int, action="append", choices=SIZES,
                        help="generate only these sizes (default: all)")
    args = parser.parse_args(argv)

    lvgl_dir = args.lvgl_dir or find_lvgl_dir()
    check_lvgl_version(lvgl_dir)
    verify_symbol_table(lvgl_dir)
    font_sources = lvgl_dir / "scripts" / "built_in_font"
    converter = find_lv_font_conv(args.lv_font_conv)
    converter_version = lv_font_conv_version(converter)
    if converter_version != LV_FONT_CONV_VERSION:
        print(f"warning: lv_font_conv {converter_version} differs from "
              f"{LV_FONT_CONV_VERSION}; output may not match the shipped fonts",
              file=sys.stderr)
    for size in args.size or SIZES:
        destination = generate(size, converter=converter,
                               converter_version=converter_version,
                               font_sources=font_sources, out_dir=args.out_dir,
                               compressed=not args.uncompressed)
        print(f"{destination}: {len(symbols_for(size))} symbols")
    return 0


if __name__ == "__main__":
    sys.exit(main())
