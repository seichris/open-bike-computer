"""Deterministic road-label normalization and candidate generation.

The device map writer consumes the dictionaries produced here.  Keeping this
module independent from file encoding lets extraction tests exercise the
cartographic rules without requiring font or binary-format dependencies.
"""

from __future__ import annotations

from dataclasses import dataclass
import math
import re
import unicodedata

from shapely import LineString, MultiLineString
from shapely.ops import linemerge, unary_union

from feature_types import get_type_id


MAX_LABEL_BYTES = 255
MAX_PREFERRED_LANGUAGES = 3
MAX_LANGUAGE_TAG_BYTES = 35
LABEL_MAX_ZOOM_BY_RANK = (5, 5, 5, 5, 4, 3, 3)
# The renderer requires 12 px beyond the shaped advance. Two more pixels keep
# integer map-coordinate and screen-coordinate rounding from invalidating a
# candidate that only barely satisfies that runtime check.
LABEL_PADDING_PIXELS = 14.0
MIN_CANDIDATE_SPAN_METERS = 48.0

_LANGUAGE_TAG_RE = re.compile(
    r"^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8}){0,3}$"
)
_JOIN_METADATA_KEYS = ("bridge", "junction", "layer", "oneway", "tunnel")


@dataclass(frozen=True)
class LabelVariant:
    kind: str
    language: str | None
    text: str

    def to_dict(self) -> dict[str, str]:
        value = {"kind": self.kind, "text": self.text}
        if self.language is not None:
            value["language"] = self.language
        return value


def normalize_language_tag(value: str) -> str:
    if not isinstance(value, str):
        raise ValueError("label language must be a string")
    raw = value.strip().replace("_", "-")
    if (
        not raw
        or len(raw.encode("ascii", errors="ignore")) != len(raw)
        or len(raw) > MAX_LANGUAGE_TAG_BYTES
        or _LANGUAGE_TAG_RE.fullmatch(raw) is None
    ):
        raise ValueError("label language is not a supported BCP-47 tag")
    parts = raw.split("-")
    normalized = [parts[0].lower()]
    for part in parts[1:]:
        if len(part) == 4 and part.isalpha():
            normalized.append(part.title())
        elif len(part) == 2 and part.isalpha():
            normalized.append(part.upper())
        else:
            normalized.append(part.lower())
    return "-".join(normalized)


def normalize_preferred_languages(values) -> tuple[str, ...]:
    if values is None:
        return ()
    if not isinstance(values, (list, tuple)):
        raise ValueError("preferred label languages must be a list")
    normalized: list[str] = []
    for value in values:
        tag = normalize_language_tag(value)
        if tag not in normalized:
            normalized.append(tag)
    if len(normalized) > MAX_PREFERRED_LANGUAGES:
        raise ValueError("at most three preferred label languages are supported")
    return tuple(normalized)


def normalize_label_text(value) -> str | None:
    if not isinstance(value, str):
        return None
    text = unicodedata.normalize("NFC", value.strip())
    if not text:
        return None
    for character in text:
        codepoint = ord(character)
        category = unicodedata.category(character)
        if (
            codepoint == 0
            or codepoint in range(0x202A, 0x202F)
            or category in {"Cc", "Cs"}
        ):
            return None
    if len(text.encode("utf-8")) > MAX_LABEL_BYTES:
        return None
    return text


def _label_text_rejection_reason(value) -> str | None:
    if not isinstance(value, str):
        return "nonString"
    text = unicodedata.normalize("NFC", value.strip())
    if not text:
        return "empty"
    for character in text:
        codepoint = ord(character)
        category = unicodedata.category(character)
        if codepoint == 0 or codepoint in range(0x202A, 0x202F) or category in {"Cc", "Cs"}:
            return "unsafeControl"
    if len(text.encode("utf-8")) > MAX_LABEL_BYTES:
        return "tooLong"
    return None


def extract_label_tags(
    properties: dict,
    other_tags: dict,
    diagnostics: dict | None = None,
) -> dict[str, str]:
    """Return normalized name/name:*/int_name/ref values in stable order."""

    candidates: dict[str, object] = {}
    for source in (other_tags, properties):
        if not isinstance(source, dict):
            continue
        for key, value in source.items():
            if (
                key in {"name", "int_name", "ref"}
                or isinstance(key, str)
                and key.startswith("name:")
            ):
                candidates[key] = value

    normalized: dict[str, str] = {}
    for key in sorted(candidates):
        if diagnostics is not None:
            diagnostics["labelTagsRead"] = diagnostics.get("labelTagsRead", 0) + 1
        if key.startswith("name:"):
            raw_tag = key[5:]
            try:
                language = normalize_language_tag(raw_tag)
            except ValueError:
                if diagnostics is not None:
                    rejected = diagnostics.setdefault("rejectedText", {})
                    rejected["invalidLanguageTag"] = rejected.get("invalidLanguageTag", 0) + 1
                continue
            normalized_key = f"name:{language}"
        else:
            normalized_key = key
        text = normalize_label_text(candidates[key])
        if text is not None:
            normalized[normalized_key] = text
        elif diagnostics is not None:
            reason = _label_text_rejection_reason(candidates[key]) or "invalid"
            rejected = diagnostics.setdefault("rejectedText", {})
            rejected[reason] = rejected.get(reason, 0) + 1
    return normalized


def extract_join_metadata(properties: dict, other_tags: dict) -> dict[str, str]:
    metadata: dict[str, str] = {}
    for key in _JOIN_METADATA_KEYS:
        value = properties.get(key, other_tags.get(key))
        if isinstance(value, (str, int, float, bool)):
            metadata[key] = str(value)
    return metadata


def label_variants(
    label_tags: dict[str, str],
    preferred_languages=(),
    international_fallback: str | None = "en",
) -> tuple[LabelVariant, ...]:
    preferred = normalize_preferred_languages(preferred_languages)
    variants: list[LabelVariant] = []

    local = label_tags.get("name")
    if local:
        variants.append(LabelVariant("local", None, local))

    for language in preferred:
        exact = label_tags.get(f"name:{language}")
        base = language.partition("-")[0]
        value = exact or label_tags.get(f"name:{base}")
        if value:
            variants.append(LabelVariant("preferred", language, value))

    if international_fallback:
        fallback = normalize_language_tag(international_fallback)
        value = label_tags.get(f"name:{fallback}") or label_tags.get("int_name")
        if value:
            variants.append(LabelVariant("international", fallback, value))

    reference = label_tags.get("ref")
    if reference:
        variants.append(LabelVariant("ref", None, reference))

    # Semantic duplicates are retained across kinds because Preferred mode must
    # still resolve when the translated spelling happens to equal the local
    # spelling. Duplicate entries within one semantic kind are unnecessary.
    result: list[LabelVariant] = []
    seen: set[tuple[str, str | None, str]] = set()
    for variant in variants:
        identity = (variant.kind, variant.language, variant.text)
        if identity not in seen:
            seen.add(identity)
            result.append(variant)
    return tuple(result)


def road_rank(type_id: int) -> int:
    if type_id in {1, 2}:
        return 0
    if type_id in {3, 4}:
        return 1
    if type_id == 5:
        return 2
    if type_id in {6, 7}:
        return 3
    if type_id == 10:
        return 4
    if 50 <= type_id < 100:
        return 5
    return 6


def label_max_zoom(rank: int) -> int:
    return LABEL_MAX_ZOOM_BY_RANK[min(max(rank, 0), 6)]


def _world_units_per_pixel(zoom: int) -> float:
    """Mirror the firmware's map-coordinate transform for each zoom level."""

    if zoom == 0:
        return 0.5
    if zoom == 1:
        return 2.0 / 3.0
    return float(zoom - 1)


def _estimated_text_width_pixels(variants) -> float:
    """Conservative test fallback when a production font measurer is absent."""

    widths = []
    for item in variants:
        width = sum(
            18.0 if unicodedata.east_asian_width(character) in {"F", "W"} else 10.0
            for character in item.text
        )
        widths.append(width)
    return max(widths, default=0.0)


def _angle(a, b) -> float:
    return math.atan2(b.y - a.y, b.x - a.x)


def _angle_delta(a: float, b: float) -> float:
    return abs((a - b + math.pi) % (2 * math.pi) - math.pi)


def _candidate_centers(length: float, spacing: float) -> list[float]:
    if length <= spacing:
        return [length / 2.0]
    count = max(1, int(length // spacing))
    step = length / (count + 1)
    return [step * index for index in range(1, count + 1)]


def generate_candidates(
    line: LineString,
    variants,
    rank: int,
    diagnostics: dict | None = None,
    text_width_pixels: float | None = None,
) -> list[dict]:
    """Generate stable candidates sized for shaped text at supported zooms."""

    if not isinstance(line, LineString) or line.is_empty or line.length < 24:
        if diagnostics is not None:
            rejected = diagnostics.setdefault("rejectedCandidates", {})
            rejected["roadTooShort"] = rejected.get("roadTooShort", 0) + 1
        return []
    if not variants:
        if diagnostics is not None:
            rejected = diagnostics.setdefault("rejectedCandidates", {})
            rejected["noUsableText"] = rejected.get("noUsableText", 0) + 1
        return []

    if text_width_pixels is None:
        text_width_pixels = _estimated_text_width_pixels(variants)
    if not math.isfinite(text_width_pixels) or text_width_pixels <= 0:
        if diagnostics is not None:
            rejected = diagnostics.setdefault("rejectedCandidates", {})
            rejected["noUsableText"] = rejected.get("noUsableText", 0) + 1
        return []

    spacing = (240, 220, 190, 160, 130, 110, 100)[min(rank, 6)]
    maximum_zoom = label_max_zoom(rank)
    maximum_path_span = line.length * 0.82
    span_options = []
    for zoom in range(maximum_zoom, -1, -1):
        required_chord = (
            text_width_pixels + LABEL_PADDING_PIXELS
        ) * _world_units_per_pixel(zoom)
        # Candidates must retain at least 90% of their path length as a chord,
        # so reserve that curvature allowance before testing the geometry.
        if maximum_path_span < max(20.0, required_chord):
            continue
        path_span = min(
            maximum_path_span,
            max(MIN_CANDIDATE_SPAN_METERS, required_chord / 0.90),
        )
        span_options.append((zoom, path_span, required_chord))
    if not span_options:
        if diagnostics is not None:
            rejected = diagnostics.setdefault("rejectedCandidates", {})
            rejected["spanTooShort"] = rejected.get("spanTooShort", 0) + 1
        return []

    candidates: list[dict] = []
    for center in _candidate_centers(line.length, spacing):
        selected = None
        rejected_for_bend = False
        for supported_zoom, desired_span, required_chord in span_options:
            start_distance = max(0.0, center - desired_span / 2.0)
            end_distance = min(line.length, center + desired_span / 2.0)
            midpoint_distance = (start_distance + end_distance) / 2.0
            start = line.interpolate(start_distance)
            midpoint = line.interpolate(midpoint_distance)
            end = line.interpolate(end_distance)
            chord = start.distance(end)
            path_length = end_distance - start_distance
            if (
                chord < max(20.0, required_chord)
                or chord / max(path_length, 1.0) < 0.90
            ):
                continue
            left_angle = _angle(start, midpoint)
            right_angle = _angle(midpoint, end)
            bend = _angle_delta(left_angle, right_angle)
            if bend > math.radians(30):
                rejected_for_bend = True
                continue
            selected = (
                supported_zoom,
                start,
                midpoint,
                end,
                bend,
            )
            break
        if selected is None:
            if diagnostics is not None:
                rejected = diagnostics.setdefault("rejectedCandidates", {})
                reason = (
                    "excessiveBend"
                    if rejected_for_bend
                    else "insufficientStraightSpan"
                )
                rejected[reason] = rejected.get(reason, 0) + 1
            continue
        supported_zoom, start, midpoint, end, bend = selected
        straightness = 1.0 - min(1.0, bend / math.radians(30))
        zoom_coverage = (supported_zoom + 1) / (maximum_zoom + 1)
        quality = min(
            255,
            max(0, int(round(128 + straightness * 79 + zoom_coverage * 48))),
        )
        candidates.append(
            {
                "start": (int(round(start.x)), int(round(start.y))),
                "end": (int(round(end.x)), int(round(end.y))),
                "midpoint": (
                    int(round(midpoint.x)),
                    int(round(midpoint.y)),
                ),
                "quality": quality,
                "flags": 0,
            }
        )
    if diagnostics is not None:
        emitted = diagnostics.setdefault("candidatesByRoadRank", {})
        key = str(min(max(rank, 0), 6))
        emitted[key] = emitted.get(key, 0) + len(candidates)
    return candidates


def _joined_lines(geometries) -> list[LineString]:
    unified = unary_union(geometries)
    if isinstance(unified, LineString):
        return [unified]
    merged = linemerge(unified)
    if isinstance(merged, LineString):
        return [merged]
    if isinstance(merged, MultiLineString):
        return list(merged.geoms)
    return []


def join_named_roads(features: list[dict], diagnostics: dict | None = None) -> list[dict]:
    """Join compatible named road fragments before block clipping."""

    grouped: dict[tuple, list[dict]] = {}
    untouched: list[dict] = []
    for feature in features:
        labels = feature.get("label_tags") or {}
        if (
            feature.get("geom_type") != "line"
            or not str(feature.get("type", "")).startswith("highway.")
            or not labels
        ):
            untouched.append(feature)
            continue
        key = (
            feature.get("type"),
            tuple(sorted(labels.items())),
            tuple(sorted((feature.get("label_join") or {}).items())),
            feature.get("z_order"),
        )
        grouped.setdefault(key, []).append(feature)

    if diagnostics is not None:
        diagnostics["namedRoadsRead"] = sum(len(group) for group in grouped.values())

    joined: list[dict] = list(untouched)
    for key in sorted(grouped, key=repr):
        group = grouped[key]
        template = group[0]
        geometries = [feature["geom"] for feature in group]
        merged = _joined_lines(geometries)
        if not merged:
            joined.extend(group)
            continue
        source_ids = sorted(str(feature.get("id", "")) for feature in group)
        for index, geometry in enumerate(merged):
            result = dict(template)
            result["id"] = f"{source_ids[0]}:{index}"
            result["geom"] = geometry
            result["bbox"] = geometry.bounds
            joined.append(result)
    if diagnostics is not None:
        diagnostics["namedRoadsJoined"] = sum(
            1 for feature in joined
            if feature.get("geom_type") == "line"
            and str(feature.get("type", "")).startswith("highway.")
            and feature.get("label_tags")
        )
    return joined


def prepare_road_labels(
    features: list[dict],
    preferred_languages=(),
    international_fallback: str | None = "en",
    diagnostics: dict | None = None,
    measure_text=None,
) -> list[dict]:
    prepared: list[dict] = []
    for feature in features:
        result = dict(feature)
        labels = result.get("label_tags") or {}
        variants = label_variants(
            labels,
            preferred_languages=preferred_languages,
            international_fallback=international_fallback,
        )
        if diagnostics is not None:
            by_kind = diagnostics.setdefault("variantsByKind", {})
            by_language = diagnostics.setdefault("variantsByLanguage", {})
            for variant in variants:
                by_kind[variant.kind] = by_kind.get(variant.kind, 0) + 1
                if variant.language is not None:
                    by_language[variant.language] = by_language.get(variant.language, 0) + 1
        type_id = result.get("type_id", get_type_id(result.get("type", "")))
        result["type_id"] = type_id
        rank = road_rank(type_id)
        result["label_variants"] = [item.to_dict() for item in variants]
        result["label_rank"] = rank
        text_width_pixels = None
        if measure_text is not None:
            text_width_pixels = max(
                (
                    width
                    for item in variants
                    for width in measure_text(item.text, item.language)
                ),
                default=0.0,
            )
        result["label_candidates"] = generate_candidates(
            result["geom"],
            variants,
            rank,
            diagnostics=diagnostics,
            text_width_pixels=text_width_pixels,
        )
        if diagnostics is not None:
            count = len(result["label_candidates"])
            by_class = diagnostics.setdefault("candidatesByRoadClass", {})
            road_class = str(result.get("type") or "unknown")
            by_class[road_class] = by_class.get(road_class, 0) + count
            by_zoom = diagnostics.setdefault("candidatesByZoomBand", {})
            maximum_zoom = label_max_zoom(rank)
            zoom_band = f"0-{maximum_zoom}"
            by_zoom[zoom_band] = by_zoom.get(zoom_band, 0) + count
        prepared.append(result)
    return prepared
