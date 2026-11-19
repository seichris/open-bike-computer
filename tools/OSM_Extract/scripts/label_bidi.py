"""Bidirectional run ordering for single-line map labels."""

from ctypes import CDLL, POINTER, byref, c_byte, c_int, c_uint32
from ctypes.util import find_library
from functools import lru_cache
from itertools import groupby
from pathlib import Path
import unicodedata


@lru_cache(maxsize=1)
def _fribidi():
    library_path = find_library("fribidi")
    if library_path is None:
        library_path = next(
            (str(path) for path in (
                Path("/opt/homebrew/lib/libfribidi.dylib"),
                Path("/usr/local/lib/libfribidi.dylib"),
            ) if path.is_file()),
            None,
        )
    if library_path is None:
        raise RuntimeError("FriBidi is required for right-to-left map labels")
    library = CDLL(library_path)
    library.fribidi_get_bidi_type.argtypes = [c_uint32]
    library.fribidi_get_bidi_type.restype = c_uint32
    library.fribidi_log2vis.argtypes = [
        POINTER(c_uint32), c_int, POINTER(c_uint32), POINTER(c_uint32),
        POINTER(c_int), POINTER(c_int), POINTER(c_byte),
    ]
    library.fribidi_log2vis.restype = c_byte
    return library


def visual_runs(text: str, codepoints: list[int]) -> list[tuple[int, int, str]]:
    """Return logical ranges in visual left-to-right order, with direction."""
    if not any(unicodedata.bidirectional(char) in {
        "R", "AL", "AN", "RLE", "RLO", "RLI", "FSI"
    } for char in text):
        return [(0, len(text), "ltr")]

    library = _fribidi()
    char_count = len(codepoints)
    logical = (c_uint32 * char_count)(*codepoints)
    # A neutral paragraph type lets FriBidi use the first strong character.
    base_direction = c_uint32(library.fribidi_get_bidi_type(ord("!")))
    positions = (c_int * char_count)()
    levels = (c_byte * char_count)()
    if not library.fribidi_log2vis(
        logical, char_count, byref(base_direction), None, positions, None, levels
    ):
        raise RuntimeError("FriBidi could not resolve map label direction")

    runs = []
    start = 0
    for level, characters in groupby(levels):
        end = start + sum(1 for _ in characters)
        visual_start = min(positions[start:end])
        runs.append((visual_start, start, end, "rtl" if level % 2 else "ltr"))
        start = end
    return [(start, end, direction) for _, start, end, direction in sorted(runs)]
