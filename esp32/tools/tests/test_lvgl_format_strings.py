"""LVGL formats every firmware label without floating-point support.

lv_conf.h selects LVGL's built-in printf with LV_USE_FLOAT 0, which compiles
the f/e/g/a conversions out of lv_sprintf_builtin.c. Such a conversion prints
its letter and consumes no argument, so every later conversion reads the wrong
one: a later %s dereferences half of a double (PR378: Nearby results reboot).
Format numbers as integers, or pre-format them with snprintf.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
# LVGL formatting calls and the zero-based position of their format argument.
FORMATTERS = {
    "lv_label_set_text_fmt": 1,
    "lv_table_set_cell_value_fmt": 3,
    "lv_snprintf": 2,
    "lv_vsnprintf": 2,
}
CALL = re.compile(r"\b(%s)\s*\(" % "|".join(FORMATTERS))
CONVERSION = re.compile(
    r"%[-+ #0]*(?:\d+|\*)?(?:\.(?:\d+|\*)?)?(?:hh|h|ll|l|j|z|t|L)?(.)")
FLOAT_CONVERSIONS = set("fFeEgGaA")
# A checkable format is string literals, optionally joined with LVGL symbols.
LITERAL_FORMAT = re.compile(r'(?:\s*(?:"(?:[^"\\]|\\.)*"|LV_SYMBOL_\w+))+\s*')
STRING = re.compile(r'"((?:[^"\\]|\\.)*)"')


def without_comments(text):
    """Blank C/C++ comments, keeping string literals and line numbers."""
    output = []
    index = 0
    quote = None
    while index < len(text):
        char = text[index]
        if quote:
            output.append(char)
            if char == "\\":
                output.append(text[index + 1])
                index += 2
                continue
            if char == quote:
                quote = None
        elif char in "\"'":
            quote = char
            output.append(char)
        elif text.startswith("//", index):
            end = text.find("\n", index)
            index = len(text) if end < 0 else end
            continue
        elif text.startswith("/*", index):
            end = text.index("*/", index) + 2
            output.append("\n" * text.count("\n", index, end))
            index = end
            continue
        else:
            output.append(char)
        index += 1
    return "".join(output)


def arguments(text, opening):
    """Top-level arguments of the call whose '(' is text[opening]."""
    found = []
    current = []
    depth = 0
    quote = None
    index = opening
    while index < len(text):
        char = text[index]
        if quote:
            current.append(char)
            if char == "\\":
                current.append(text[index + 1])
                index += 2
                continue
            if char == quote:
                quote = None
        elif char in "\"'":
            quote = char
            current.append(char)
        elif char in "([{":
            depth += 1
            if depth > 1:
                current.append(char)
        elif char in ")]}":
            depth -= 1
            if depth == 0:
                found.append("".join(current).strip())
                return found
            current.append(char)
        elif char == "," and depth == 1:
            found.append("".join(current).strip())
            current = []
        else:
            current.append(char)
        index += 1
    raise AssertionError("unterminated call at offset %d" % opening)


def lvgl_format_calls():
    """Yield (location, function, format argument) for each LVGL format call."""
    for directory in ("lib", "src", "include"):
        for path in sorted((ROOT / directory).rglob("*")):
            if path.suffix not in {".c", ".cpp", ".h", ".hpp"}:
                continue
            text = without_comments(path.read_text(errors="replace"))
            for match in CALL.finditer(text):
                line = text.count("\n", 0, match.start()) + 1
                found = arguments(text, match.end() - 1)
                position = FORMATTERS[match.group(1)]
                argument = found[position] if len(found) > position else ""
                yield ("%s:%d" % (path.relative_to(ROOT), line),
                       match.group(1), argument)


def has_float_conversion(format_string):
    return any(match.group(1) in FLOAT_CONVERSIONS
               for match in CONVERSION.finditer(format_string))


class LvglFormatStringTests(unittest.TestCase):
    def test_lvgl_is_configured_without_float_formatting(self):
        # The guard below is only needed while this premise holds.
        config = (ROOT / "lib/lvgl/lv_conf.h").read_text()
        self.assertRegex(
            config, r"(?m)^#define\s+LV_USE_STDLIB_SPRINTF\s+LV_STDLIB_BUILTIN\b")
        self.assertRegex(config, r"(?m)^#define\s+LV_USE_FLOAT\s+0\b")

    def test_float_conversion_detection(self):
        for format_string in ("%f", "%.0f", "%5.1f", "%-8.3e", "%lf", "%Lg",
                              "%G", "%a", "%u km%.0f"):
            self.assertTrue(has_float_conversion(format_string), format_string)
        for format_string in ("%%f", "%d", "%5d", "%u%%", "%s", "%ld", "%.3s",
                              "%x", "100%% full", "%4dm."):
            self.assertFalse(has_float_conversion(format_string), format_string)

    def test_lvgl_formats_have_no_float_conversion(self):
        checked = []
        offending = []
        for location, function, argument in lvgl_format_calls():
            if not LITERAL_FORMAT.fullmatch(argument):
                offending.append("%s: %s format is not a literal: %s"
                                 % (location, function, argument))
                continue
            format_string = "".join(STRING.findall(argument))
            checked.append(format_string)
            if has_float_conversion(format_string):
                offending.append("%s: %s(%r)" % (location, function, format_string))
        # Not vacuous: the Nearby results status is among the checked calls.
        self.assertTrue(any("places - " in value for value in checked), checked)
        self.assertEqual(offending, [], "\n" + "\n".join(offending))


if __name__ == "__main__":
    unittest.main()
