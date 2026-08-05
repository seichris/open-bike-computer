from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import struct
import unicodedata
import zlib

from .map_labels import normalize_language_tag


MAX_FMB_BYTES = 2 * 1024 * 1024
MAX_FMA_BYTES = 16 * 1024 * 1024
MAX_STRINGS = 4096
MAX_STRING_BYTES = 256 * 1024
MAX_RUNS = 12288
MAX_LABELS = 8192
MAX_CANDIDATES = 16384
MAX_GLYPHS_PER_RUN = 192
MAX_GLYPH_RECORDS = 24576
MAX_GLYPH_DIMENSION = 96
MAX_BUILDINGS = 8192
MAX_BUILDING_RINGS = 32
MAX_BUILDING_POINTS = 131072

_FMA_HEADER = struct.Struct("<4sBBBBIIIIII")
_FMA_FACE_PREFIX = struct.Struct("<BBH32s")
_FMA_GLYPH = struct.Struct("<HBBhhhHHHIIII")


@dataclass(frozen=True)
class FontMetadata:
    profile_fingerprint: int
    glyph_count: int
    language_count: int


@dataclass(frozen=True)
class BlockMetadata:
    profile_fingerprint: int
    maximum_glyph_id: int
    maximum_language_id: int
    building_records: int = 0
    building_provenance: tuple[int, int, int, int, int] = (0, 0, 0, 0, 0)


def _take(data: bytes, offset: int, amount: int, context: str) -> tuple[bytes, int]:
    if amount < 0 or offset < 0 or amount > len(data) - offset:
        raise ValueError(f"{context} is truncated")
    return data[offset:offset + amount], offset + amount


def _u16(data: bytes, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def _u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def _validate_rle(encoded: bytes, expected_pixels: int) -> None:
    cursor = 0
    pixels = 0
    while cursor < len(encoded):
        control = encoded[cursor]
        cursor += 1
        count = (control & 0x7F) + 1
        if count > expected_pixels - pixels:
            raise ValueError("FMA1 bitmap RLE expands past its dimensions")
        if control & 0x80:
            if cursor >= len(encoded) or encoded[cursor] > 15:
                raise ValueError("FMA1 repeat run is invalid")
            cursor += 1
        else:
            literals, cursor = _take(encoded, cursor, count, "FMA1 literal run")
            if any(value > 15 for value in literals):
                raise ValueError("FMA1 literal run contains non-4-bit alpha")
        pixels += count
    if pixels != expected_pixels:
        raise ValueError("FMA1 bitmap RLE has the wrong decoded length")


def validate_fma1(path: Path) -> FontMetadata:
    data = path.read_bytes()
    if len(data) > MAX_FMA_BYTES or len(data) < _FMA_HEADER.size:
        raise ValueError("street-labels.fma has an invalid byte length")
    (
        magic,
        version,
        size_count,
        language_count,
        face_count,
        fingerprint,
        record_count,
        language_bytes,
        face_bytes,
        index_bytes,
        payload_bytes,
    ) = _FMA_HEADER.unpack_from(data)
    if magic != b"FMA1" or version != 1 or size_count != 3:
        raise ValueError("street-labels.fma has an invalid FMA1 header")
    if language_count > 3 or face_count == 0 or face_count > 16:
        raise ValueError("street-labels.fma has invalid language/face counts")
    if record_count > MAX_GLYPH_RECORDS or record_count % 3:
        raise ValueError("street-labels.fma has an invalid glyph record count")
    if index_bytes != record_count * _FMA_GLYPH.size:
        raise ValueError("street-labels.fma has an invalid glyph index length")
    expected_size = (
        _FMA_HEADER.size + language_bytes + face_bytes + index_bytes + payload_bytes
    )
    if expected_size != len(data):
        raise ValueError("street-labels.fma has trailing or missing bytes")

    offset = _FMA_HEADER.size
    language_table, offset = _take(data, offset, language_bytes, "FMA1 languages")
    language_offset = 0
    languages: list[str] = []
    while language_offset < len(language_table):
        length = language_table[language_offset]
        language_offset += 1
        raw, language_offset = _take(
            language_table, language_offset, length, "FMA1 language"
        )
        try:
            tag = raw.decode("ascii")
        except UnicodeDecodeError as exc:
            raise ValueError("FMA1 language is not ASCII") from exc
        if not tag or normalize_language_tag(tag) != tag or tag in languages:
            raise ValueError("FMA1 language is not unique canonical BCP-47")
        languages.append(tag)
    if len(languages) != language_count:
        raise ValueError("FMA1 language count does not match its table")

    face_table, offset = _take(data, offset, face_bytes, "FMA1 faces")
    face_offset = 0
    face_ids: set[int] = set()
    for _ in range(face_count):
        prefix, face_offset = _take(
            face_table, face_offset, _FMA_FACE_PREFIX.size, "FMA1 face"
        )
        face_id, _collection_index, name_bytes, _font_hash = _FMA_FACE_PREFIX.unpack(prefix)
        name, face_offset = _take(face_table, face_offset, name_bytes, "FMA1 face name")
        if face_id in face_ids or not name or any(value < 0x20 or value > 0x7E for value in name):
            raise ValueError("FMA1 face metadata is invalid")
        face_ids.add(face_id)
    if face_offset != len(face_table):
        raise ValueError("FMA1 face table has trailing bytes")

    index, offset = _take(data, offset, index_bytes, "FMA1 glyph index")
    payload, offset = _take(data, offset, payload_bytes, "FMA1 bitmap payload")
    if offset != len(data):
        raise ValueError("street-labels.fma has trailing bytes")
    expected_payload_offset = 0
    bitmap_ranges: list[tuple[int, int, int]] = []
    for record_index in range(record_count):
        values = _FMA_GLYPH.unpack_from(index, record_index * _FMA_GLYPH.size)
        (
            glyph_id,
            face_id,
            size_id,
            _bearing_x,
            _bearing_y,
            _advance,
            width,
            height,
            reserved,
            fill_offset,
            fill_length,
            distance_offset,
            distance_length,
        ) = values
        if glyph_id != record_index // 3 + 1 or size_id != record_index % 3:
            raise ValueError("FMA1 glyph records are not canonically ordered")
        if face_id not in face_ids or not 1 <= width <= MAX_GLYPH_DIMENSION or not 1 <= height <= MAX_GLYPH_DIMENSION:
            raise ValueError("FMA1 glyph metadata is invalid")
        if reserved != 0 or fill_length == 0 or distance_length == 0:
            raise ValueError("FMA1 glyph bitmap ranges are invalid")
        if fill_offset != expected_payload_offset or distance_offset != fill_offset + fill_length:
            raise ValueError("FMA1 bitmap ranges are not canonical")
        if distance_offset > len(payload) or distance_length > len(payload) - distance_offset:
            raise ValueError("FMA1 bitmap range is out of bounds")
        pixels = width * height
        bitmap_ranges.append((fill_offset, fill_length, pixels))
        bitmap_ranges.append((distance_offset, distance_length, pixels))
        expected_payload_offset = distance_offset + distance_length
    if expected_payload_offset != len(payload):
        raise ValueError("FMA1 bitmap payload has unreferenced bytes")
    for start, length, pixels in bitmap_ranges:
        _validate_rle(payload[start:start + length], pixels)
    return FontMetadata(fingerprint, record_count // 3, language_count)


def _parse_base_geometry(data: bytes) -> tuple[int, int]:
    offset = 4
    counts, offset = _take(data, offset, 2, "FMB polygon count")
    polygon_count = _u16(counts, 0)
    if polygon_count > 16384:
        raise ValueError("FMB polygon count exceeds its bound")
    for _ in range(polygon_count):
        _fixed, offset = _take(data, offset, 12, "FMB polygon")
        count_bytes, offset = _take(data, offset, 2, "FMB polygon point count")
        point_count = _u16(count_bytes, 0)
        _points, offset = _take(data, offset, point_count * 4, "FMB polygon points")
    counts, offset = _take(data, offset, 2, "FMB polyline count")
    polyline_count = _u16(counts, 0)
    if polyline_count > 16384:
        raise ValueError("FMB polyline count exceeds its bound")
    for _ in range(polyline_count):
        _fixed, offset = _take(data, offset, 13, "FMB polyline")
        count_bytes, offset = _take(data, offset, 2, "FMB polyline point count")
        point_count = _u16(count_bytes, 0)
        _points, offset = _take(data, offset, point_count * 4, "FMB polyline points")
    return offset, polyline_count


def _validate_label_text(raw: bytes) -> str:
    try:
        text = raw.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise ValueError("FMB v3 string is not valid UTF-8") from exc
    if unicodedata.normalize("NFC", text) != text:
        raise ValueError("FMB v3 string is not NFC-normalized")
    if any(
        ord(character) == 0
        or ord(character) < 0x20
        or 0x7F <= ord(character) <= 0x9F
        or 0x202A <= ord(character) <= 0x202E
        for character in text
    ):
        raise ValueError("FMB v3 string contains an unsafe control")
    return text


def _validate_fmb_label_block(path: Path, version: int) -> BlockMetadata:
    if version not in {3, 4}:
        raise ValueError("label block version is unsupported")
    data = path.read_bytes()
    expected_header = b"FMB" + bytes((version,))
    if len(data) > MAX_FMB_BYTES or len(data) < 4 or data[:4] != expected_header:
        raise ValueError(f"{path.name} is not a bounded FMB v{version} block")
    directory_offset, polyline_count = _parse_base_geometry(data)
    section_count = version
    directory_bytes = 8 + section_count * 16
    directory, _ = _take(
        data, directory_offset, directory_bytes, f"FMB v{version} directory"
    )
    expected_magic = b"EXT" + bytes((ord("0") + version,))
    if (
        directory[:4] != expected_magic
        or directory[4] != section_count
        or directory[5:8] != b"\0\0\0"
    ):
        raise ValueError(f"FMB v{version} extension directory is invalid")
    sections: list[bytes] = []
    expected_offset = directory_offset + directory_bytes
    for index in range(section_count):
        entry_offset = 8 + index * 16
        section_type, flags, reserved, offset, length, checksum = struct.unpack_from(
            "<BBHIII", directory, entry_offset
        )
        if section_type != index + 1 or flags != 1 or reserved != 0 or length == 0:
            raise ValueError(f"FMB v{version} section entry is invalid")
        if offset != expected_offset or length > len(data) - offset:
            raise ValueError(f"FMB v{version} sections are not contiguous and bounded")
        section = data[offset:offset + length]
        if zlib.crc32(section) & 0xFFFFFFFF != checksum:
            raise ValueError(f"FMB v{version} section CRC does not match")
        sections.append(section)
        expected_offset += length
    if expected_offset != len(data):
        raise ValueError(f"FMB v{version} block has trailing bytes")

    strings_section = sections[0]
    cursor = 0
    count_bytes, cursor = _take(strings_section, cursor, 2, "FMB v3 string count")
    string_count = _u16(count_bytes, 0)
    if string_count > MAX_STRINGS:
        raise ValueError("FMB v3 string count exceeds its bound")
    strings: list[str] = []
    body_bytes = 0
    for _ in range(string_count):
        length_bytes, cursor = _take(strings_section, cursor, 2, "FMB v3 string length")
        length = _u16(length_bytes, 0)
        if not 1 <= length <= 255:
            raise ValueError("FMB v3 string length is invalid")
        raw, cursor = _take(strings_section, cursor, length, "FMB v3 string")
        body_bytes += length
        if body_bytes > MAX_STRING_BYTES:
            raise ValueError("FMB v3 string bytes exceed their bound")
        strings.append(_validate_label_text(raw))
    if cursor != len(strings_section) or len(set(strings)) != len(strings):
        raise ValueError("FMB v3 string table is not canonical")

    runs_section = sections[1]
    cursor = 0
    count_bytes, cursor = _take(runs_section, cursor, 2, "FMB v3 run count")
    run_count = _u16(count_bytes, 0)
    if run_count > MAX_RUNS:
        raise ValueError("FMB v3 shaped-run count exceeds its bound")
    runs: list[tuple[int, int]] = []
    maximum_glyph_id = 0
    for _ in range(run_count):
        header, cursor = _take(runs_section, cursor, 4, "FMB v3 shaped run")
        string_id, size_id, glyph_count = struct.unpack("<HBB", header)
        if not 1 <= string_id <= string_count or size_id > 2 or not 1 <= glyph_count <= MAX_GLYPHS_PER_RUN:
            raise ValueError("FMB v3 shaped-run header is invalid")
        runs.append((string_id, size_id))
        for _ in range(glyph_count):
            glyph, cursor = _take(runs_section, cursor, 8, "FMB v3 shaped glyph")
            glyph_id = _u16(glyph, 0)
            if glyph_id == 0:
                raise ValueError("FMB v3 shaped run references glyph zero")
            maximum_glyph_id = max(maximum_glyph_id, glyph_id)
    if cursor != len(runs_section):
        raise ValueError("FMB v3 shaped-run table has trailing bytes")

    labels_section = sections[2]
    header, cursor = _take(labels_section, 0, 6, "FMB v3 label header")
    fingerprint, label_count = struct.unpack("<IH", header)
    if label_count > MAX_LABELS:
        raise ValueError("FMB v3 label count exceeds its bound")
    candidate_total = 0
    maximum_language_id = 0
    for _ in range(label_count):
        fixed, cursor = _take(labels_section, cursor, 9, "FMB v3 road label")
        polyline_index, rank, minimum_zoom, maximum_zoom, repeat_group, variant_count, candidate_count = struct.unpack(
            "<HBBBHBB", fixed
        )
        if polyline_index >= polyline_count or rank > 6 or minimum_zoom > maximum_zoom or repeat_group == 0:
            raise ValueError("FMB v3 road-label metadata is invalid")
        if not 1 <= variant_count <= 8 or candidate_count == 0:
            raise ValueError("FMB v3 road-label counts are invalid")
        candidate_total += candidate_count
        if candidate_total > MAX_CANDIDATES:
            raise ValueError("FMB v3 candidate count exceeds its bound")
        for _ in range(variant_count):
            variant, cursor = _take(labels_section, cursor, 10, "FMB v3 variant")
            kind, language_id, string_id, small, standard, large = struct.unpack(
                "<BBHHHH", variant
            )
            if kind > 3 or not 1 <= string_id <= string_count:
                raise ValueError("FMB v3 label variant is invalid")
            if language_id not in {0, 255}:
                maximum_language_id = max(maximum_language_id, language_id)
            for size_id, run_id in enumerate((small, standard, large)):
                if not 1 <= run_id <= run_count or runs[run_id - 1] != (string_id, size_id):
                    raise ValueError("FMB v3 label variant has an invalid run reference")
        for _ in range(candidate_count):
            candidate, cursor = _take(labels_section, cursor, 10, "FMB v3 candidate")
            if candidate[9] != 0:
                raise ValueError("FMB v3 candidate flags are invalid")
    if cursor != len(labels_section):
        raise ValueError("FMB v3 label table has trailing bytes")
    building_records, building_provenance = (
        _validate_building_section(sections[3])
        if version == 4
        else (0, (0, 0, 0, 0, 0))
    )
    return BlockMetadata(
        fingerprint,
        maximum_glyph_id,
        maximum_language_id,
        building_records,
        building_provenance,
    )


def validate_fmb3(path: Path) -> BlockMetadata:
    return _validate_fmb_label_block(path, 3)


def validate_fmb4(path: Path) -> BlockMetadata:
    return _validate_fmb_label_block(path, 4)


def _validate_building_section(
    section: bytes,
) -> tuple[int, tuple[int, int, int, int, int]]:
    header, cursor = _take(section, 0, 8, "FMB v4 building header")
    record_count, reserved, declared_points = struct.unpack("<HHI", header)
    if reserved != 0 or record_count > MAX_BUILDINGS or declared_points > MAX_BUILDING_POINTS:
        raise ValueError("FMB v4 building header is invalid")
    actual_points = 0
    provenance_counts = [0, 0, 0, 0, 0]
    for _ in range(record_count):
        fixed, cursor = _take(section, cursor, 18, "FMB v4 building record")
        (
            type_id,
            flags,
            provenance,
            record_reserved,
            height_dm,
            minimum_height_dm,
            minimum_x,
            minimum_y,
            maximum_x,
            maximum_y,
            ring_count,
        ) = struct.unpack("<BBBBHHhhhhH", fixed)
        if (
            type_id != 100
            or flags not in {0, 1, 2}
            or provenance > 4
            or record_reserved != 0
            or not 0 <= minimum_height_dm < height_dm
            or minimum_x > maximum_x
            or minimum_y > maximum_y
            or not 1 <= ring_count <= MAX_BUILDING_RINGS
        ):
            raise ValueError("FMB v4 building record is invalid")
        provenance_counts[provenance] += 1
        record_bounds = [32767, 32767, -32768, -32768]
        for ring_index in range(ring_count):
            ring_header, cursor = _take(section, cursor, 4, "FMB v4 building ring")
            point_count, ring_flags, ring_reserved = struct.unpack("<HBB", ring_header)
            if (
                not 3 <= point_count
                or ring_flags & ~1
                or ring_reserved != 0
                or (ring_index == 0 and ring_flags != 0)
                or (ring_index > 0 and ring_flags != 1)
                or point_count > MAX_BUILDING_POINTS - actual_points
            ):
                raise ValueError("FMB v4 building ring is invalid")
            point_bytes, cursor = _take(
                section, cursor, point_count * 4, "FMB v4 building points"
            )
            actual_points += point_count
            for point_index in range(point_count):
                x, y = struct.unpack_from("<hh", point_bytes, point_index * 4)
                record_bounds[0] = min(record_bounds[0], x)
                record_bounds[1] = min(record_bounds[1], y)
                record_bounds[2] = max(record_bounds[2], x)
                record_bounds[3] = max(record_bounds[3], y)
            mask_bytes = (point_count + 7) // 8
            wall_mask, cursor = _take(
                section, cursor, mask_bytes, "FMB v4 building wall mask"
            )
            if flags & 2 and any(wall_mask):
                raise ValueError("FMB v4 flat base contains wall bits")
            used_bits = point_count % 8
            if used_bits and wall_mask[-1] & ~((1 << used_bits) - 1):
                raise ValueError("FMB v4 wall mask has non-canonical padding")
        if tuple(record_bounds) != (minimum_x, minimum_y, maximum_x, maximum_y):
            raise ValueError("FMB v4 building bounds do not match its rings")
    if cursor != len(section) or actual_points != declared_points:
        raise ValueError("FMB v4 building section has trailing or missing data")
    return record_count, tuple(provenance_counts)


def summarize_fmb4_buildings(paths: list[Path]) -> dict[str, int]:
    counts = [0, 0, 0, 0, 0]
    records = 0
    for path in paths:
        metadata = validate_fmb4(path)
        records += metadata.building_records
        for index, value in enumerate(metadata.building_provenance):
            counts[index] += value
    return {
        "recordCount": records,
        "explicitHeightCount": counts[0],
        "levelsHeightCount": counts[1],
        "inheritedHeightCount": counts[2],
        "localMedianHeightCount": counts[3],
        "classDefaultHeightCount": counts[4],
    }


def validate_renderer_artifacts(
    map_root: Path,
    map_id: str,
    files: list[dict],
    format_version: int,
) -> None:
    paths = [entry["path"] for entry in files]
    fmb_paths = [path for path in paths if path.endswith(".fmb")]
    fmp_paths = [path for path in paths if path.endswith(".fmp")]
    font_relative = f"VECTMAP/{map_id}/assets/street-labels.fma"
    if not fmb_paths:
        raise ValueError("map pack contains no binary map blocks")
    if format_version in {2, 3}:
        if fmp_paths or paths.count(font_relative) != 1:
            raise ValueError(f"renderer target {format_version} has invalid block/font roles")
        font = validate_fma1(map_root / font_relative)
        for relative in fmb_paths:
            block = (
                validate_fmb4(map_root / relative)
                if format_version == 3
                else validate_fmb3(map_root / relative)
            )
            if block.profile_fingerprint != font.profile_fingerprint:
                raise ValueError("FMB/FMA1 profile fingerprint mismatch")
            if block.maximum_glyph_id > font.glyph_count:
                raise ValueError("FMB v3 references a missing FMA1 glyph")
            if block.maximum_language_id > font.language_count:
                raise ValueError("FMB v3 references a missing FMA1 language")
    elif format_version == 1:
        if font_relative in paths:
            raise ValueError("renderer target 1 contains a label font asset")
        for relative in fmb_paths:
            header = (map_root / relative).read_bytes()[:4]
            if header not in {b"FMB\x01", b"FMB\x02"}:
                raise ValueError("renderer target 1 contains a non-legacy FMB block")
    else:
        raise ValueError("renderer target is unsupported")
