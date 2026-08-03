import struct
import zlib

from feature_types import get_type_id
from label_pipeline import label_max_zoom


FMB_V3_SECTION_STRINGS = 1
FMB_V3_SECTION_RUNS = 2
FMB_V3_SECTION_ROAD_LABELS = 3
FMB_V3_CRITICAL_SECTION = 1
MAX_BLOCK_STRINGS = 4096
MAX_BLOCK_STRING_BYTES = 256 * 1024
MAX_BLOCK_RUNS = 12288
MAX_BLOCK_LABELS = 8192
MAX_BLOCK_CANDIDATES = 16384
MAX_LABEL_VARIANTS = 8

_DIRECTORY_HEADER = struct.Struct("<4sB3x")
_DIRECTORY_ENTRY = struct.Struct("<BBHIII")
_RUN_GLYPH = struct.Struct("<Hhhh")
_LABEL_FIXED = struct.Struct("<HBBBHBB")
_LABEL_VARIANT = struct.Struct("<BBHHHH")
_LABEL_CANDIDATE = struct.Struct("<hhhhBB")

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


def write_fmb(path, polygons, polylines, min_x, min_y, font_builder=None):
    """Write one v2 block, or a label-aware v3 block with ``font_builder``."""

    version = 3 if font_builder is not None else 2
    data = bytearray(b"FMB" + bytes((version,)))
    data.extend(struct.pack("<H", len(polygons)))
    for feature in polygons:
        _append_polygon(data, feature, min_x, min_y)
    data.extend(struct.pack("<H", len(polylines)))
    for feature in polylines:
        _append_polyline(data, feature, min_x, min_y)

    metadata = {"strings": 0, "stringBytes": 0, "runs": 0, "labels": 0, "candidates": 0}
    if font_builder is not None:
        sections, metadata = _label_sections(
            polylines, min_x, min_y, font_builder
        )
        directory_offset = len(data)
        data.extend(_DIRECTORY_HEADER.pack(b"EXT3", len(sections)))
        section_offset = directory_offset + _DIRECTORY_HEADER.size + len(sections) * _DIRECTORY_ENTRY.size
        entries = bytearray()
        payload = bytearray()
        for section_type, section in sections:
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

    if len(data) > 2 * 1024 * 1024:
        raise MapFormatError("FMB block exceeds the 2 MiB renderer limit")
    with open(path, "wb") as file:
        file.write(data)
    return {"bytes": len(data), "version": version, **metadata}
