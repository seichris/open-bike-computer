"""Map-specific shaped text and FMA1 glyph-asset generation."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path
import struct
import time
import unicodedata

import freetype
import uharfbuzz as hb

from label_bidi import visual_runs
from label_pipeline import normalize_preferred_languages


FMA_MAGIC = b"FMA1"
FMA_VERSION = 1
FONT_SIZES = (18, 22, 26)
MAX_FONT_FACES = 16
MAX_DISTINCT_GLYPHS = 8192
MAX_GLYPH_RECORDS = MAX_DISTINCT_GLYPHS * len(FONT_SIZES)
MAX_FONT_ASSET_BYTES = 16 * 1024 * 1024
MAX_GLYPHS_PER_RUN = 192
MAX_GLYPH_DIMENSION = 96
HALO_RADIUS = 3

_HEADER = struct.Struct("<4sBBBBIIIIII")
_FACE_PREFIX = struct.Struct("<BBH32s")
_GLYPH_INDEX = struct.Struct("<HBBhhhHHHIIII")


class FontAssetError(ValueError):
    pass


class UnsupportedLabelError(FontAssetError):
    """A single label cannot be represented with the available fonts."""


@dataclass(frozen=True)
class FontFaceSpec:
    face_id: int
    path: Path
    collection_index: int
    name: str

    @property
    def sha256(self) -> bytes:
        return hashlib.sha256(self.path.read_bytes()).digest()


@dataclass(frozen=True)
class GlyphPlacement:
    glyph_id: int
    x_offset: int
    y_offset: int
    x_advance: int


@dataclass(frozen=True)
class ShapedRun:
    size_id: int
    glyphs: tuple[GlyphPlacement, ...]


def _first_existing(paths) -> Path | None:
    for value in paths:
        if value:
            path = Path(value)
            if path.is_file():
                return path
    return None


def default_font_faces() -> tuple[FontFaceSpec, ...]:
    latin = _first_existing(
        (
            os.environ.get("OBC_LABEL_LATIN_FONT"),
            "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
        )
    )
    cjk = _first_existing(
        (
            os.environ.get("OBC_LABEL_CJK_FONT"),
            "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
            "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
        )
    )
    if latin is None or cjk is None:
        raise FontAssetError("pinned Latin and CJK label fonts are unavailable")

    faces = [FontFaceSpec(0, latin, 0, "latin")]
    if cjk == latin or cjk.suffix.lower() != ".ttc":
        faces.append(FontFaceSpec(1, cjk, 0, "cjk"))
    else:
        # Noto Sans CJK collection order: JP, KR, SC, TC, HK.
        faces.extend(
            (
                FontFaceSpec(1, cjk, 0, "cjk-jp"),
                FontFaceSpec(2, cjk, 1, "cjk-kr"),
                FontFaceSpec(3, cjk, 2, "cjk-sc"),
                FontFaceSpec(4, cjk, 3, "cjk-tc"),
                FontFaceSpec(5, cjk, 4, "cjk-hk"),
            )
        )
    arabic = _first_existing(
        (
            os.environ.get("OBC_LABEL_ARABIC_FONT"),
            "/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf",
        )
    )
    if arabic is not None:
        faces.append(FontFaceSpec(6, arabic, 0, "arabic"))
    arabic_latin = _first_existing(
        ("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",)
    )
    if arabic_latin is not None and arabic_latin != latin:
        faces.append(FontFaceSpec(7, arabic_latin, 0, "arabic-latin"))

    # The worker already packages Noto's script-specific faces. Keep the
    # established IDs and use a stable order for the additional regular faces.
    # Only the faces used by the map are written to the bounded FMA1 table.
    existing = {face.path.resolve() for face in faces}
    noto_fonts = Path("/usr/share/fonts/truetype/noto")
    fallbacks = [
        path for path in sorted(noto_fonts.glob("NotoSans*-Regular.ttf"))
        if path.resolve() not in existing
    ]
    for face_id, path in enumerate(fallbacks[:248], start=8):
        faces.append(FontFaceSpec(face_id, path, 0, path.stem.removesuffix("-Regular")))
    return tuple(faces)


def _contains_cjk(text: str) -> bool:
    return any(
        0x2E80 <= ord(character) <= 0x9FFF
        or 0xF900 <= ord(character) <= 0xFAFF
        or 0x20000 <= ord(character) <= 0x3134F
        or 0x3040 <= ord(character) <= 0x30FF
        or 0xAC00 <= ord(character) <= 0xD7AF
        for character in text
    )


def _canonical_profile(languages, faces) -> bytes:
    digests = {}
    for face in faces:
        if face.path not in digests:
            digests[face.path] = face.sha256.hex()
    document = {
        "format": FMA_VERSION,
        "sizes": list(FONT_SIZES),
        "languages": list(languages),
        "faces": [
            {
                "id": face.face_id,
                "name": face.name,
                "collectionIndex": face.collection_index,
                "sha256": digests[face.path],
            }
            for face in faces
        ],
    }
    return json.dumps(
        document,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
    ).encode("ascii")


class FontPackBuilder:
    def __init__(self, preferred_languages=(), faces=None):
        self.languages = normalize_preferred_languages(preferred_languages)
        self.faces = tuple(faces or default_font_faces())
        if not self.faces or len({face.face_id for face in self.faces}) != len(self.faces):
            raise FontAssetError("font face IDs must be non-empty and unique")
        self._face_by_id = {face.face_id: face for face in self.faces}
        self._font_data: dict[Path, bytes] = {}
        # HarfBuzz faces/fonts are immutable after their scale is configured.
        # Reusing them avoids rebuilding three native font objects for every
        # uncached label while preserving the same per-label buffer and glyph
        # allocation order.
        self._hb_faces: dict[tuple[int, int], hb.Face] = {}
        self._hb_fonts: dict[tuple[int, int], hb.Font] = {}
        self._nominal_coverage: dict[tuple[int, int], bool] = {}
        profile = _canonical_profile(self.languages, self.faces)
        self.profile_fingerprint = int.from_bytes(
            hashlib.sha256(profile).digest()[:4], "little"
        )
        self._asset_id_by_key: dict[tuple[int, int], int] = {}
        self._used_face_ids: set[int] = set()
        self._shape_cache: dict[
            tuple[str, str | None], tuple[ShapedRun, ...] | None
        ] = {}
        self.shape_calls = 0
        self.shape_cache_hits = 0
        self.shaping_failures = 0
        self.fallback_selections = 0
        self.shaping_seconds = 0.0

    def _face_for(self, text: str, language: str | None) -> FontFaceSpec:
        if not _contains_cjk(text):
            return self._face_by_id[min(self._face_by_id)]
        language = (language or (self.languages[0] if self.languages else "")).lower()
        preferred_name = "cjk"
        if language.startswith("ja"):
            preferred_name = "cjk-jp"
        elif language.startswith("ko"):
            preferred_name = "cjk-kr"
        elif language.startswith("zh-hant-hk") or language.startswith("zh-hk"):
            preferred_name = "cjk-hk"
        elif language.startswith("zh-hant") or language.startswith("zh-tw"):
            preferred_name = "cjk-tc"
        elif language.startswith("zh"):
            preferred_name = "cjk-sc"
        exact = next((face for face in self.faces if face.name == preferred_name), None)
        if exact is not None:
            return exact
        self.fallback_selections += 1
        return next(
            (face for face in self.faces if face.name.startswith("cjk")),
            self.faces[0],
        )

    def _asset_glyph_id(self, face_id: int, source_glyph_id: int) -> int:
        key = (face_id, source_glyph_id)
        existing = self._asset_id_by_key.get(key)
        if existing is not None:
            return existing
        if len(self._asset_id_by_key) >= MAX_DISTINCT_GLYPHS:
            raise FontAssetError("map label glyph count exceeds FMA1 limit")
        asset_id = len(self._asset_id_by_key) + 1
        self._asset_id_by_key[key] = asset_id
        return asset_id

    def _harfbuzz_font(self, face: FontFaceSpec, pixel_size: int) -> hb.Font:
        key = (face.face_id, pixel_size)
        cached = self._hb_fonts.get(key)
        if cached is not None:
            return cached
        if face.path not in self._font_data:
            self._font_data[face.path] = face.path.read_bytes()
        hb_face = hb.Face(self._font_data[face.path], face.collection_index)
        font = hb.Font(hb_face)
        font.scale = (pixel_size * 64, pixel_size * 64)
        hb.ot_font_set_funcs(font)
        self._hb_faces[key] = hb_face
        self._hb_fonts[key] = font
        return font

    def _shape_glyphs(
        self,
        face: FontFaceSpec,
        codepoints: list[int],
        runs: list[tuple[int, int, str]],
        language: str | None,
    ) -> list[list[tuple[hb.GlyphInfo, hb.GlyphPosition]]] | None:
        sizes = []
        for pixel_size in FONT_SIZES:
            font = self._harfbuzz_font(face, pixel_size)
            glyphs = []
            for start, end, direction in runs:
                buffer = hb.Buffer()
                buffer.add_codepoints(codepoints, start, end - start)
                buffer.direction = direction
                if language:
                    buffer.language = language
                buffer.guess_segment_properties()
                hb.shape(font, buffer)
                glyphs.extend(zip(buffer.glyph_infos or (), buffer.glyph_positions or ()))
            if not glyphs or len(glyphs) > MAX_GLYPHS_PER_RUN or any(
                info.codepoint == 0
                or any(
                    not -32768 <= value <= 32767
                    for value in (position.x_offset, position.y_offset, position.x_advance)
                )
                for info, position in glyphs
            ):
                return None
            sizes.append(glyphs)
        return sizes

    def _candidate_faces(self, primary: FontFaceSpec):
        yield primary
        for face_id in sorted(self._used_face_ids - {primary.face_id}):
            yield self._face_by_id[face_id]
        if len(self._used_face_ids) < MAX_FONT_FACES and self.glyph_count < MAX_DISTINCT_GLYPHS:
            for face in self.faces:
                if face != primary and face.face_id not in self._used_face_ids:
                    yield face

    def _fallback_covers(self, face: FontFaceSpec, required_codepoints: tuple[int, ...]) -> bool:
        for codepoint in required_codepoints:
            key = (face.face_id, codepoint)
            if key not in self._nominal_coverage:
                font = self._harfbuzz_font(face, FONT_SIZES[0])
                self._nominal_coverage[key] = bool(font.get_nominal_glyph(codepoint))
            if not self._nominal_coverage[key]:
                return False
        return True

    def shape(self, text: str, language: str | None = None) -> tuple[ShapedRun, ...]:
        self.shape_calls += 1
        cache_key = (text, language)
        if cache_key in self._shape_cache:
            cached = self._shape_cache[cache_key]
            self.shape_cache_hits += 1
            if cached is None:
                raise UnsupportedLabelError("map label cannot be represented by the packaged fonts")
            return cached
        started = time.perf_counter()
        try:
            codepoints = list(map(ord, text))
            visual_order = visual_runs(text, codepoints)
            primary = self._face_for(text, language)
            required_codepoints = None
            for face in self._candidate_faces(primary):
                if (
                    face.face_id not in self._used_face_ids
                    and (
                        len(self._used_face_ids) == MAX_FONT_FACES
                        or self.glyph_count == MAX_DISTINCT_GLYPHS
                    )
                ):
                    continue
                if face != primary:
                    if required_codepoints is None:
                        # Leave marks, formatting controls and canonically
                        # decomposable characters to HarfBuzz's shaping.
                        required_codepoints = tuple(
                            ord(char)
                            for char in dict.fromkeys(unicodedata.normalize("NFC", text))
                            if (
                                unicodedata.category(char)[0] in "LNS"
                                or unicodedata.category(char) == "Co"
                            )
                            and unicodedata.normalize("NFD", char) == char
                        )
                    if not self._fallback_covers(face, required_codepoints):
                        continue
                sizes = self._shape_glyphs(face, codepoints, visual_order, language)
                if sizes is None:
                    continue
                new_glyphs = {
                    (face.face_id, info.codepoint) for glyphs in sizes for info, _ in glyphs
                }.difference(self._asset_id_by_key)
                if self.glyph_count + len(new_glyphs) <= MAX_DISTINCT_GLYPHS:
                    break
            else:
                raise UnsupportedLabelError("map label cannot be represented by the packaged fonts")

            runs: list[ShapedRun] = []
            for size_id, glyphs in enumerate(sizes):
                placements: list[GlyphPlacement] = []
                for info, position in glyphs:
                    asset_id = self._asset_glyph_id(face.face_id, info.codepoint)
                    values = (position.x_offset, position.y_offset, position.x_advance)
                    placements.append(GlyphPlacement(asset_id, *values))
                runs.append(ShapedRun(size_id, tuple(placements)))
            result = tuple(runs)
            self._used_face_ids.add(face.face_id)
            if face != primary:
                self.fallback_selections += 1
            self._shape_cache[cache_key] = result
            return result
        except Exception as exc:
            if isinstance(exc, UnsupportedLabelError):
                self._shape_cache[cache_key] = None
            self.shaping_failures += 1
            raise
        finally:
            self.shaping_seconds += time.perf_counter() - started

    def measure_widths(
        self, text: str, language: str | None = None
    ) -> tuple[float, ...]:
        """Return firmware-equivalent advance widths for every runtime size."""

        return tuple(
            abs(sum(glyph.x_advance for glyph in run.glyphs)) / 64.0
            for run in self.shape(text, language)
        )

    def measure_supported_widths(
        self, text: str, language: str | None = None
    ) -> tuple[float, ...] | None:
        """Let the road-label planner omit a variant the device cannot draw."""
        try:
            return self.measure_widths(text, language)
        except UnsupportedLabelError:
            return None

    @property
    def glyph_count(self) -> int:
        return len(self._asset_id_by_key)

    def _render_glyph(self, face: FontFaceSpec, source_glyph_id: int, pixel_size: int):
        ft_face = freetype.Face(str(face.path), index=face.collection_index)
        ft_face.set_pixel_sizes(0, pixel_size)
        ft_face.load_glyph(
            source_glyph_id,
            freetype.FT_LOAD_RENDER | freetype.FT_LOAD_TARGET_NORMAL,
        )
        slot = ft_face.glyph
        bitmap = slot.bitmap
        source_width = bitmap.width
        source_height = bitmap.rows
        width = source_width + HALO_RADIUS * 2
        height = source_height + HALO_RADIUS * 2
        if width <= 0 or height <= 0 or width > MAX_GLYPH_DIMENSION or height > MAX_GLYPH_DIMENSION:
            raise FontAssetError("rasterized glyph dimensions exceed FMA1 limits")

        fill = [0] * (width * height)
        pitch = abs(bitmap.pitch)
        raw = bytes(bitmap.buffer)
        for y in range(source_height):
            for x in range(source_width):
                alpha = raw[y * pitch + x]
                fill[(y + HALO_RADIUS) * width + x + HALO_RADIUS] = min(
                    15, (alpha + 8) // 17
                )

        distance = [15 if value else 0 for value in fill]
        frontier = {index for index, value in enumerate(fill) if value}
        visited = set(frontier)
        for radius in range(1, HALO_RADIUS + 1):
            next_frontier: set[int] = set()
            level = HALO_RADIUS - radius + 1
            for index in frontier:
                y, x = divmod(index, width)
                for ny in range(max(0, y - 1), min(height, y + 2)):
                    for nx in range(max(0, x - 1), min(width, x + 2)):
                        neighbor = ny * width + nx
                        if neighbor not in visited:
                            visited.add(neighbor)
                            next_frontier.add(neighbor)
                            distance[neighbor] = level
            frontier = next_frontier

        advance = int(slot.advance.x)
        if advance < -32768 or advance > 32767:
            raise FontAssetError("glyph advance exceeds FMA1 limits")
        return {
            "bearing_x": int(slot.bitmap_left) - HALO_RADIUS,
            "bearing_y": int(slot.bitmap_top) + HALO_RADIUS,
            "advance": advance,
            "width": width,
            "height": height,
            "fill": fill,
            "distance": distance,
        }

    def write(self, path) -> dict[str, int | float]:
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        face_bytes = bytearray()
        used_faces = [face for face in self.faces if face.face_id in self._used_face_ids]
        for face in sorted(used_faces or self.faces[:1], key=lambda item: item.face_id):
            name = face.name.encode("ascii")
            if not name or len(name) > 255:
                raise FontAssetError("font face name is invalid")
            face_bytes.extend(
                _FACE_PREFIX.pack(
                    face.face_id,
                    face.collection_index,
                    len(name),
                    face.sha256,
                )
            )
            face_bytes.extend(name)

        language_bytes = bytearray()
        for language in self.languages:
            encoded = language.encode("ascii")
            language_bytes.extend(struct.pack("<B", len(encoded)))
            language_bytes.extend(encoded)

        records = []
        payload = bytearray()
        uncompressed_bitmap_bytes = 0
        for (face_id, source_glyph_id), asset_id in sorted(
            self._asset_id_by_key.items(), key=lambda item: item[1]
        ):
            face = self._face_by_id[face_id]
            for size_id, pixel_size in enumerate(FONT_SIZES):
                glyph = self._render_glyph(face, source_glyph_id, pixel_size)
                fill_encoded = rle_encode(glyph["fill"])
                distance_encoded = rle_encode(glyph["distance"])
                uncompressed_bitmap_bytes += len(glyph["fill"]) + len(glyph["distance"])
                fill_offset = len(payload)
                payload.extend(fill_encoded)
                distance_offset = len(payload)
                payload.extend(distance_encoded)
                records.append(
                    _GLYPH_INDEX.pack(
                        asset_id,
                        face_id,
                        size_id,
                        glyph["bearing_x"],
                        glyph["bearing_y"],
                        glyph["advance"],
                        glyph["width"],
                        glyph["height"],
                        0,
                        fill_offset,
                        len(fill_encoded),
                        distance_offset,
                        len(distance_encoded),
                    )
                )

        if len(records) > MAX_GLYPH_RECORDS:
            raise FontAssetError("font asset record count exceeds FMA1 limit")
        index_bytes = b"".join(records)
        header = _HEADER.pack(
            FMA_MAGIC,
            FMA_VERSION,
            len(FONT_SIZES),
            len(self.languages),
            max(1, len(used_faces)),
            self.profile_fingerprint,
            len(records),
            len(language_bytes),
            len(face_bytes),
            len(index_bytes),
            len(payload),
        )
        data = header + language_bytes + face_bytes + index_bytes + payload
        if len(data) > MAX_FONT_ASSET_BYTES:
            raise FontAssetError("font asset exceeds FMA1 byte limit")
        path.write_bytes(data)
        return {
            "bytes": len(data),
            "glyphs": self.glyph_count,
            "records": len(records),
            "profileFingerprint": self.profile_fingerprint,
            "uncompressedBitmapBytes": uncompressed_bitmap_bytes,
            "compressedBitmapBytes": len(payload),
            "compressionRatio": round(
                len(payload) / max(1, uncompressed_bitmap_bytes), 6
            ),
            "shapeCalls": self.shape_calls,
            "shapeCacheHits": self.shape_cache_hits,
            "shapingFailures": self.shaping_failures,
            "fallbackSelections": self.fallback_selections,
        }


def rle_encode(values) -> bytes:
    values = [int(value) for value in values]
    if any(value < 0 or value > 15 for value in values):
        raise FontAssetError("FMA1 alpha values must be 4-bit")
    output = bytearray()
    index = 0
    while index < len(values):
        repeat = 1
        while (
            index + repeat < len(values)
            and values[index + repeat] == values[index]
            and repeat < 128
        ):
            repeat += 1
        if repeat >= 3:
            output.extend((0x80 | (repeat - 1), values[index]))
            index += repeat
            continue

        literal_start = index
        index += repeat
        while index < len(values) and index - literal_start < 128:
            next_repeat = 1
            while (
                index + next_repeat < len(values)
                and values[index + next_repeat] == values[index]
                and next_repeat < 128
            ):
                next_repeat += 1
            if next_repeat >= 3:
                break
            literal_capacity = 128 - (index - literal_start)
            if next_repeat > literal_capacity:
                index += literal_capacity
                break
            index += next_repeat
        literal = values[literal_start:index]
        output.append(len(literal) - 1)
        output.extend(literal)
    return bytes(output)


def rle_decode(data: bytes, expected_values: int) -> list[int]:
    output: list[int] = []
    offset = 0
    while offset < len(data):
        control = data[offset]
        offset += 1
        count = (control & 0x7F) + 1
        if control & 0x80:
            if offset >= len(data):
                raise FontAssetError("truncated repeated FMA1 RLE run")
            output.extend([data[offset]] * count)
            offset += 1
        else:
            if count > len(data) - offset:
                raise FontAssetError("truncated literal FMA1 RLE run")
            output.extend(data[offset : offset + count])
            offset += count
        if len(output) > expected_values:
            raise FontAssetError("FMA1 RLE expands past glyph dimensions")
    if len(output) != expected_values or any(value > 15 for value in output):
        raise FontAssetError("FMA1 RLE expansion length or value is invalid")
    return output
