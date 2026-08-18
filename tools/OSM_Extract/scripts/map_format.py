import struct
import zlib

from feature_types import get_type_id
from label_pipeline import label_max_zoom


FMB_V3_SECTION_STRINGS = 1
FMB_V3_SECTION_RUNS = 2
FMB_V3_SECTION_ROAD_LABELS = 3
FMB_V4_SECTION_BUILDINGS = 4
FMB_V3_CRITICAL_SECTION = 1
MAX_BLOCK_STRINGS = 4096
MAX_BLOCK_STRING_BYTES = 256 * 1024
MAX_BLOCK_RUNS = 12288
MAX_BLOCK_LABELS = 8192
MAX_BLOCK_CANDIDATES = 16384
MAX_LABEL_VARIANTS = 8
MAX_BLOCK_BUILDINGS = 8192
MAX_BUILDING_RINGS = 32
MAX_BUILDING_POINTS = 131072

_DIRECTORY_HEADER = struct.Struct("<4sB3x")
_DIRECTORY_ENTRY = struct.Struct("<BBHIII")
_RUN_GLYPH = struct.Struct("<Hhhh")
_LABEL_FIXED = struct.Struct("<HBBBHBB")
_LABEL_VARIANT = struct.Struct("<BBHHHH")
_LABEL_CANDIDATE = struct.Struct("<hhhhBB")
_BUILDING_SECTION_HEADER = struct.Struct("<HHI")
_BUILDING_FIXED = struct.Struct("<BBBBHHhhhhH")
_BUILDING_RING = struct.Struct("<HBB")

_VARIANT_KIND = {
    "local": 0,
    "preferred": 1,
    "international": 2,
    "ref": 3,
}


class MapFormatError(ValueError):
    pass


def _append_polygon(file, feature, min_x, min_y):
    color = (
        int(feature["color"], 16)
        if isinstance(feature["color"], str)
        else int(feature["color"])
    )
    max_zoom = (
        int(feature["maxzoom"])
        if feature["maxzoom"] not in ("", None)
        else 15
    )
    file.extend(struct.pack("<HBB", color, max_zoom, get_type_id(feature["type"])))
    file.extend(
        struct.pack(
            "<hhhh",
            int(round(feature["bbox"][0] - min_x)),
            int(round(feature["bbox"][1] - min_y)),
            int(round(feature["bbox"][2] - min_x)),
            int(round(feature["bbox"][3] - min_y)),
        )
    )
    coordinates = list(feature["geom"].exterior.coords)
    file.extend(struct.pack("<H", len(coordinates)))
    for x, y in coordinates:
        file.extend(struct.pack("<hh", int(round(x - min_x)), int(round(y - min_y))))


def _append_polyline(file, feature, min_x, min_y):
    color = (
        int(feature["color"], 16)
        if isinstance(feature["color"], str)
        else int(feature["color"])
    )
    width = int(feature["width"]) if feature["width"] is not None else 1
    max_zoom = (
        int(feature["maxzoom"])
        if feature["maxzoom"] not in ("", None)
        else 15
    )
    file.extend(
        struct.pack(
            "<HBBB",
            color,
            width,
            max_zoom,
            get_type_id(feature["type"]),
        )
    )
    file.extend(
        struct.pack(
            "<hhhh",
            int(round(feature["bbox"][0] - min_x)),
            int(round(feature["bbox"][1] - min_y)),
            int(round(feature["bbox"][2] - min_x)),
            int(round(feature["bbox"][3] - min_y)),
        )
    )
    coordinates = list(feature["geom"].coords)
    file.extend(struct.pack("<H", len(coordinates)))
    for x, y in coordinates:
        file.extend(struct.pack("<hh", int(round(x - min_x)), int(round(y - min_y))))


def _language_id(language, font_builder):
    if not language:
        return 0
    try:
        return font_builder.languages.index(language) + 1
    except ValueError:
        return 255


def _label_sections(polylines, min_x, min_y, font_builder):
    strings: list[str] = []
    string_ids: dict[str, int] = {}
    string_bytes = 0
    runs: list[dict] = []
    run_ids: dict[tuple[int, str | None, int], int] = {}
    labels: list[dict] = []
    candidate_total = 0

    def string_id(text):
        nonlocal string_bytes
        existing = string_ids.get(text)
        if existing is not None:
            return existing
        encoded = text.encode("utf-8")
        if not encoded or len(encoded) > 255:
            raise MapFormatError("label string length is outside FMB v3 limits")
        if len(strings) >= MAX_BLOCK_STRINGS or string_bytes + len(encoded) > MAX_BLOCK_STRING_BYTES:
            raise MapFormatError("label string table exceeds FMB v3 limits")
        strings.append(text)
        identifier = len(strings)
        string_ids[text] = identifier
        string_bytes += len(encoded)
        return identifier

    def shaped_run_ids(text_id, text, language):
        shaped = font_builder.shape(text, language)
        identifiers = []
        for shaped_run in shaped:
            # The same Unicode spelling can require different glyph forms or
            # shaping rules in different languages (notably CJK). Keep the
            # semantic string deduplicated, but do not alias its language-
            # specific shaped runs.
            key = (text_id, language, shaped_run.size_id)
            identifier = run_ids.get(key)
            if identifier is None:
                if len(runs) >= MAX_BLOCK_RUNS:
                    raise MapFormatError("shaped-run table exceeds FMB v3 limits")
                runs.append(
                    {
                        "string_id": text_id,
                        "size_id": shaped_run.size_id,
                        "glyphs": shaped_run.glyphs,
                    }
                )
                identifier = len(runs)
                run_ids[key] = identifier
            identifiers.append(identifier)
        if len(identifiers) != 3:
            raise MapFormatError("every FMB v3 string requires three shaped runs")
        return tuple(identifiers)

    for polyline_index, feature in enumerate(polylines):
        variants = feature.get("label_variants") or []
        candidates = feature.get("label_candidates") or []
        if not variants or not candidates:
            continue
        if len(labels) >= MAX_BLOCK_LABELS or len(variants) > MAX_LABEL_VARIANTS:
            raise MapFormatError("road-label table exceeds FMB v3 limits")
        candidate_total += len(candidates)
        if candidate_total > MAX_BLOCK_CANDIDATES or len(candidates) > 255:
            raise MapFormatError("label candidate count exceeds FMB v3 limits")

        encoded_variants = []
        for variant in variants:
            kind = _VARIANT_KIND.get(variant.get("kind"))
            if kind is None:
                raise MapFormatError("unknown road-label variant kind")
            text = variant["text"]
            language = variant.get("language")
            text_id = string_id(text)
            encoded_variants.append(
                {
                    "kind": kind,
                    "language_id": _language_id(language, font_builder),
                    "string_id": text_id,
                    "run_ids": shaped_run_ids(text_id, text, language),
                }
            )

        primary = variants[0]["text"].encode("utf-8")
        repeat_group = zlib.crc32(primary) & 0xFFFF or 1
        rank = int(feature.get("label_rank", 6))
        max_zoom = label_max_zoom(rank)
        encoded_candidates = []
        for candidate in candidates:
            coordinates = (*candidate["start"], *candidate["end"])
            local = (
                int(round(coordinates[0] - min_x)),
                int(round(coordinates[1] - min_y)),
                int(round(coordinates[2] - min_x)),
                int(round(coordinates[3] - min_y)),
            )
            if any(value < -32768 or value > 32767 for value in local):
                raise MapFormatError("label candidate coordinate exceeds int16")
            encoded_candidates.append(
                (*local, int(candidate["quality"]), int(candidate.get("flags", 0)))
            )
        labels.append(
            {
                "polyline_index": polyline_index,
                "rank": rank,
                "min_zoom": 0,
                "max_zoom": max_zoom,
                "repeat_group": repeat_group,
                "variants": encoded_variants,
                "candidates": encoded_candidates,
            }
        )

    string_section = bytearray(struct.pack("<H", len(strings)))
    for text in strings:
        encoded = text.encode("utf-8")
        string_section.extend(struct.pack("<H", len(encoded)))
        string_section.extend(encoded)

    run_section = bytearray(struct.pack("<H", len(runs)))
    for run in runs:
        glyphs = run["glyphs"]
        run_section.extend(
            struct.pack("<HBB", run["string_id"], run["size_id"], len(glyphs))
        )
        for glyph in glyphs:
            run_section.extend(
                _RUN_GLYPH.pack(
                    glyph.glyph_id,
                    glyph.x_offset,
                    glyph.y_offset,
                    glyph.x_advance,
                )
            )

    label_section = bytearray(struct.pack("<IH", font_builder.profile_fingerprint, len(labels)))
    for label in labels:
        label_section.extend(
            _LABEL_FIXED.pack(
                label["polyline_index"],
                label["rank"],
                label["min_zoom"],
                label["max_zoom"],
                label["repeat_group"],
                len(label["variants"]),
                len(label["candidates"]),
            )
        )
        for variant in label["variants"]:
            label_section.extend(
                _LABEL_VARIANT.pack(
                    variant["kind"],
                    variant["language_id"],
                    variant["string_id"],
                    *variant["run_ids"],
                )
            )
        for candidate in label["candidates"]:
            label_section.extend(_LABEL_CANDIDATE.pack(*candidate))

    return (
        (FMB_V3_SECTION_STRINGS, bytes(string_section)),
        (FMB_V3_SECTION_RUNS, bytes(run_section)),
        (FMB_V3_SECTION_ROAD_LABELS, bytes(label_section)),
    ), {
        "strings": len(strings),
        "stringBytes": string_bytes,
        "runs": len(runs),
        "labels": len(labels),
        "candidates": candidate_total,
    }


def encode_building_section(records):
    if len(records) > MAX_BLOCK_BUILDINGS:
        raise MapFormatError("building record count exceeds FMB v4 limits")
    total_points = 0
    section = bytearray(_BUILDING_SECTION_HEADER.pack(len(records), 0, 0))
    for record in records:
        rings = record["rings"]
        if not 1 <= len(rings) <= MAX_BUILDING_RINGS:
            raise MapFormatError("building ring count exceeds FMB v4 limits")
        height_dm = int(record["height_dm"])
        minimum_height_dm = int(record["minimum_height_dm"])
        provenance = int(record["provenance"])
        bbox = tuple(int(value) for value in record["bbox"])
        if (
            int(record["type_id"]) != 100
            or int(record["flags"]) not in {0, 1, 2}
            or not 0 <= provenance <= 4
            or not 0 <= minimum_height_dm < height_dm <= 65535
            or len(bbox) != 4
            or any(value < -32768 or value > 32767 for value in bbox)
            or bbox[0] > bbox[2]
            or bbox[1] > bbox[3]
        ):
            raise MapFormatError("building record metadata is invalid")
        section.extend(
            _BUILDING_FIXED.pack(
                int(record["type_id"]),
                int(record["flags"]),
                provenance,
                0,
                height_dm,
                minimum_height_dm,
                *bbox,
                len(rings),
            )
        )
        for ring in rings:
            points = list(ring["points"])
            walls = list(ring["walls"])
            flags = int(ring.get("flags", 0))
            if (
                not 3 <= len(points) <= 65535
                or len(walls) != len(points)
                or flags not in {0, 1}
                or (int(record["flags"]) & 2 and any(walls))
                or any(
                    value < -32768 or value > 32767
                    for point in points
                    for value in point
                )
            ):
                raise MapFormatError("building ring is invalid")
            total_points += len(points)
            if total_points > MAX_BUILDING_POINTS:
                raise MapFormatError("building point count exceeds FMB v4 limits")
            section.extend(_BUILDING_RING.pack(len(points), flags, 0))
            for x, y in points:
                section.extend(struct.pack("<hh", x, y))
            mask = bytearray((len(points) + 7) // 8)
            for index, enabled in enumerate(walls):
                if enabled:
                    mask[index // 8] |= 1 << (index % 8)
            section.extend(mask)
    _BUILDING_SECTION_HEADER.pack_into(section, 0, len(records), 0, total_points)
    return bytes(section), {
        "buildings": len(records),
        "buildingPoints": total_points,
        "buildingBytes": len(section),
    }


def _validated_building_section(section, metadata):
    if not isinstance(section, bytes) or len(section) < _BUILDING_SECTION_HEADER.size:
        raise MapFormatError("preencoded building section is invalid")
    if not isinstance(metadata, dict) or set(metadata) != {
        "buildings",
        "buildingPoints",
        "buildingBytes",
    }:
        raise MapFormatError("preencoded building metadata is invalid")
    record_count, reserved, point_count = _BUILDING_SECTION_HEADER.unpack_from(section)
    if (
        reserved != 0
        or metadata["buildings"] != record_count
        or metadata["buildingPoints"] != point_count
        or metadata["buildingBytes"] != len(section)
        or any(
            isinstance(value, bool) or not isinstance(value, int) or value < 0
            for value in metadata.values()
        )
    ):
        raise MapFormatError("preencoded building section does not match metadata")
    return section, dict(metadata)


# Retain the private name for existing fixture and compatibility imports.
_building_section = encode_building_section


def _append_directory(data, magic, sections):
    if len(magic) != 4 or not 1 <= len(sections) <= 255:
        raise MapFormatError("extension directory header is invalid")
    directory_offset = len(data)
    data.extend(_DIRECTORY_HEADER.pack(magic, len(sections)))
    section_offset = (
        directory_offset
        + _DIRECTORY_HEADER.size
        + len(sections) * _DIRECTORY_ENTRY.size
    )
    entries = bytearray()
    payload = bytearray()
    for expected_type, (section_type, section) in enumerate(sections, start=1):
        if section_type != expected_type or not section:
            raise MapFormatError("extension sections are not canonical")
        entries.extend(
            _DIRECTORY_ENTRY.pack(
                section_type,
                FMB_V3_CRITICAL_SECTION,
                0,
                section_offset,
                len(section),
                zlib.crc32(section) & 0xFFFFFFFF,
            )
        )
        payload.extend(section)
        section_offset += len(section)
    data.extend(entries)
    data.extend(payload)


def write_fmb(
    path,
    polygons,
    polylines,
    min_x,
    min_y,
    font_builder=None,
    building_records=None,
    building_section=None,
    building_metadata=None,
):
    """Write a renderer-format-specific FMB v2, v3, or v4 block."""

    if building_records is not None and building_section is not None:
        raise MapFormatError("building records and preencoded section are mutually exclusive")
    has_buildings = building_records is not None or building_section is not None
    if has_buildings and font_builder is None:
        raise MapFormatError("FMB v4 requires the street-label font/profile")
    if building_section is None and building_metadata is not None:
        raise MapFormatError("preencoded building metadata requires a section")
    version = 4 if has_buildings else (3 if font_builder is not None else 2)
    data = bytearray(b"FMB" + bytes((version,)))
    data.extend(struct.pack("<H", len(polygons)))
    for feature in polygons:
        _append_polygon(data, feature, min_x, min_y)
    data.extend(struct.pack("<H", len(polylines)))
    for feature in polylines:
        _append_polyline(data, feature, min_x, min_y)

    metadata = {
        "strings": 0,
        "stringBytes": 0,
        "runs": 0,
        "labels": 0,
        "candidates": 0,
        "buildings": 0,
        "buildingPoints": 0,
        "buildingBytes": 0,
    }
    if font_builder is not None:
        sections, metadata = _label_sections(
            polylines, min_x, min_y, font_builder
        )
        metadata.update({"buildings": 0, "buildingPoints": 0, "buildingBytes": 0})
        if has_buildings:
            if building_section is None:
                encoded_section, encoded_metadata = encode_building_section(
                    building_records
                )
            else:
                encoded_section, encoded_metadata = _validated_building_section(
                    building_section,
                    building_metadata,
                )
            sections = (*sections, (FMB_V4_SECTION_BUILDINGS, encoded_section))
            metadata.update(encoded_metadata)
            _append_directory(data, b"EXT4", sections)
        else:
            _append_directory(data, b"EXT3", sections)

    if len(data) > 2 * 1024 * 1024:
        raise MapFormatError("FMB block exceeds the 2 MiB renderer limit")
    with open(path, "wb") as file:
        file.write(data)
    return {"bytes": len(data), "version": version, **metadata}
