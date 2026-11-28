"""A single Latin and CJK face for binary map-format and glyph tests."""

from pathlib import Path

from font_asset import FontFaceSpec


def host_label_face():
    for path, index in (
        (Path("/System/Library/Fonts/Supplemental/Arial Unicode.ttf"), 0),
        (Path("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"), 3),
    ):
        if path.is_file():
            return FontFaceSpec(0, path, index, "latin-cjk")
    return None


HOST_LABEL_FACE = host_label_face()
