"""Typed OSM building normalization, height resolution, and seam-safe clipping."""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, replace
import hashlib
import json
import math
from pathlib import Path
import statistics
from typing import Any, Iterable, Mapping

import yaml
from shapely.geometry import (
    LineString,
    MultiLineString,
    MultiPolygon,
    Polygon,
    mapping,
    shape,
)
from shapely.geometry.base import BaseGeometry
from shapely.geometry.polygon import orient
from shapely.ops import transform, unary_union
from shapely.prepared import prep
from shapely.strtree import STRtree

from building_height import (
    HeightProvenance,
    HeightRules,
    PROVENANCE_NAMES,
    ResolvedHeight,
    direct_height,
    normalized_building_class,
    resolve_height,
)
from building_calibration_cache import (
    CalibrationCache,
    CalibrationCacheError,
    calibration_cell_for_bounds,
)
from feature_types import get_type_id
from funcs import parse_tags
from map_format import MAX_BUILDING_RINGS


BUILDING_PROFILE_VERSION = 1
BUILDING_FLAG_PART = 1 << 0
BUILDING_FLAG_FLAT_BASE = 1 << 1
RELATION_PARENT_TOLERANCE_METERS = 0.25
RING_FLAG_HOLE = 1 << 0
EARTH_RADIUS_METERS = 6_378_137
MAX_BUILDING_COMPLEXITY_PRODUCT = 9_000_000_000_000_000


@dataclass(frozen=True)
class SourceBuilding:
    object_key: str
    building_class: str
    is_part: bool
    geometry: Polygon | MultiPolygon
    tags: dict[str, str]
    resolved: ResolvedHeight | None = None
    association: str = "none"
    parent_key: str | None = None
    extrude: bool = True
    flat_base: bool = False
    wall_boundary: BaseGeometry | None = None


class OutlineSpatialIndex:
    """Deterministic, lazy containment lookup for building parts.

    STRtree only removes outlines whose envelopes cannot possibly contain a
    part. The exact legacy predicates and tie-breaking remain authoritative,
    so replacing the previous all-outlines scan cannot change associations.
    Prepared buffers are materialized only for envelope candidates and
    retained for the rest of the request. Ordinary inferred containment keeps
    the legacy exact envelope predicate and 5 cm geometry buffer; explicit
    relation candidates allow 25 cm of envelope and geometry tolerance for
    small source-boundary drift.
    """

    def __init__(self, outlines: Iterable[SourceBuilding]):
        self.outlines = tuple(outlines)
        self.envelopes = tuple(outline.geometry.envelope for outline in self.outlines)
        self.tree = STRtree(self.envelopes) if self.envelopes else None
        self._indices_by_geometry_id = {
            id(geometry): index for index, geometry in enumerate(self.envelopes)
        }
        self._indices_by_geometry_wkb: dict[bytes, list[int]] = defaultdict(list)
        for index, geometry in enumerate(self.envelopes):
            self._indices_by_geometry_wkb[geometry.wkb].append(index)
        self._prepared: dict[tuple[int, float], Any] = {}
        self.query_count = 0
        self.spatial_candidate_count = 0
        self.envelope_candidate_count = 0

    def _query_indices(self, geometry: BaseGeometry) -> list[int]:
        if self.tree is None:
            return []
        matches = self.tree.query(geometry)
        if len(matches) == 0:
            return []
        first = matches[0]
        if hasattr(first, "item"):
            first = first.item()
        if isinstance(first, int):
            return [int(value) for value in matches]
        indices = set()
        for candidate in matches:
            index = self._indices_by_geometry_id.get(id(candidate))
            if index is not None:
                indices.add(index)
                continue
            # Shapely 1.x normally returns the original geometry objects. Keep
            # every equal envelope if an alternate build returns copies; using
            # only the first would break object-key tie ordering.
            indices.update(self._indices_by_geometry_wkb.get(candidate.wkb, ()))
        return sorted(indices)

    def containment_parent(
        self,
        part: SourceBuilding,
        *,
        allowed_keys: set[str] | None = None,
        tolerance_meters: float = 0.05,
        envelope_tolerance_meters: float = 0.0,
    ) -> str | None:
        self.query_count += 1
        part_envelope = part.geometry.envelope
        query_envelope = (
            part_envelope.buffer(envelope_tolerance_meters)
            if envelope_tolerance_meters
            else part_envelope
        )
        indices = self._query_indices(query_envelope)
        self.spatial_candidate_count += len(indices)
        candidates: list[SourceBuilding] = []
        for index in indices:
            outline = self.outlines[index]
            if allowed_keys is not None and outline.object_key not in allowed_keys:
                continue
            min_x, min_y, max_x, max_y = self.envelopes[index].bounds
            part_min_x, part_min_y, part_max_x, part_max_y = part_envelope.bounds
            if (
                part_min_x < min_x - envelope_tolerance_meters
                or part_min_y < min_y - envelope_tolerance_meters
                or part_max_x > max_x + envelope_tolerance_meters
                or part_max_y > max_y + envelope_tolerance_meters
            ):
                continue
            self.envelope_candidate_count += 1
            prepared_key = (index, tolerance_meters)
            prepared = self._prepared.get(prepared_key)
            if prepared is None:
                prepared = prep(outline.geometry.buffer(tolerance_meters))
                self._prepared[prepared_key] = prepared
            if prepared.covers(part.geometry):
                candidates.append(outline)
        if not candidates:
            return None
        return min(
            candidates,
            key=lambda item: (item.geometry.area, item.object_key),
        ).object_key

    def metrics(self) -> dict[str, int]:
        return {
            "containmentQueryCount": self.query_count,
            "containmentSpatialCandidateCount": self.spatial_candidate_count,
            "containmentEnvelopeCandidateCount": self.envelope_candidate_count,
            "containmentPreparedOutlineCount": len(
                {index for index, _tolerance in self._prepared}
            ),
        }


def load_rules(path: str | Path) -> tuple[HeightRules, str]:
    path = Path(path)
    raw = path.read_bytes()
    rules = HeightRules.from_mapping(yaml.safe_load(raw))
    return rules, hashlib.sha256(raw).hexdigest()


def load_relation_index(
    path: str | Path,
    *,
    require_closure: bool = False,
) -> dict[str, Any]:
    path = Path(path)
    if not path.is_file():
        if require_closure:
            raise ValueError("building relation closure audit is required")
        return {
            "schemaVersion": 1,
            "partParents": {},
            "parentTags": {},
            "relations": 0,
            "ambiguousParts": 0,
        }
    value = json.loads(path.read_text(encoding="utf-8"))
    standalone_part_keys = value.get("standalonePartKeys", [])
    part_parent_candidates = value.get("partParentCandidates", {})
    parent_geometry_sources = value.get("parentGeometrySources", {})
    closure = value.get("closureAudit")
    closure_count_fields = {
        "closureRelationCount",
        "closureWayCount",
        "closureNodeCount",
        "relationRetryCount",
        "candidateCount",
    }
    closure_identity_fields = {
        "sourceIndexKey",
        "sourceSnapshotSha256",
        "scopePlanSha256",
    }
    valid_closure = closure is None or (
        isinstance(closure, dict)
        and set(closure) == closure_count_fields | closure_identity_fields
        and all(
            isinstance(closure[field], int)
            and not isinstance(closure[field], bool)
            and closure[field] >= 0
            for field in closure_count_fields
        )
        and all(
            isinstance(closure[field], str)
            and len(closure[field]) == 64
            and all(character in "0123456789abcdef" for character in closure[field])
            for field in closure_identity_fields
        )
    )
    if (
        not isinstance(value, dict)
        or value.get("schemaVersion") != 1
        or not isinstance(value.get("partParents"), dict)
        or not isinstance(part_parent_candidates, dict)
        or not isinstance(parent_geometry_sources, dict)
        or not isinstance(standalone_part_keys, list)
        or any(
            not isinstance(key, str)
            or not key.startswith("w")
            or key in value.get("partParents", {})
            for key in standalone_part_keys
        )
        or any(
            not isinstance(child, str)
            or not child.startswith(("w", "r"))
            or not isinstance(parent, str)
            or not parent.startswith(("w", "r"))
            for child, parent in value.get("partParents", {}).items()
        )
        or any(
            not isinstance(child, str)
            or not child.startswith(("w", "r"))
            or child in value.get("partParents", {})
            or child in standalone_part_keys
            or not isinstance(parents, list)
            or len(parents) < 2
            or parents != sorted(set(parents))
            or any(
                not isinstance(parent, str)
                or not parent.startswith(("w", "r"))
                for parent in parents
            )
            for child, parents in part_parent_candidates.items()
        )
        or any(
            not isinstance(parent, str)
            or not parent.startswith("w")
            or parent not in {
                *value.get("partParents", {}).values(),
                *(
                    candidate
                    for candidates in part_parent_candidates.values()
                    for candidate in candidates
                ),
            }
            or not isinstance(source, str)
            or not source.startswith("r")
            for parent, source in parent_geometry_sources.items()
        )
        or len(set(parent_geometry_sources.values()))
        != len(parent_geometry_sources)
        or not isinstance(value.get("parentTags", {}), dict)
        or any(
            not isinstance(parent, str)
            or not parent.startswith(("w", "r"))
            or not isinstance(tags, dict)
            or any(
                not isinstance(key, str) or not isinstance(tag_value, str)
                for key, tag_value in tags.items()
            )
            for parent, tags in value.get("parentTags", {}).items()
        )
        or any(
            isinstance(value.get(field), bool)
            or not isinstance(value.get(field), int)
            or value[field] < 0
            for field in ("relations", "ambiguousParts")
        )
        or not valid_closure
        or (require_closure and closure is None)
    ):
        raise ValueError("building relation index is invalid")
    return value


def collect_building_features(
    polygon_features: Iterable[Mapping[str, Any]],
    line_features: Iterable[Mapping[str, Any]],
    relation_index: Mapping[str, Any] | None = None,
) -> list[Mapping[str, Any]]:
    """Return polygon buildings plus required closed ways from GDAL's line layer.

    GDAL's OSM driver classifies a closed way tagged only with
    ``building:part`` as a line. It can do the same for an untagged outline or
    part whose building semantics come from a ``type=building`` relation.
    Convert those required closed rings back to polygons before the normal
    building validation and relation association pass.
    """
    collected = list(polygon_features)
    part_parents = dict((relation_index or {}).get("partParents", {}))
    part_parent_candidates = dict(
        (relation_index or {}).get("partParentCandidates", {})
    )
    parent_geometry_sources = dict(
        (relation_index or {}).get("parentGeometrySources", {})
    )
    standalone_part_keys = set(
        (relation_index or {}).get("standalonePartKeys", ())
    )
    required_relation_ways = {
        key
        for key in {
            *part_parents,
            *part_parents.values(),
            *part_parent_candidates,
            *(
                parent
                for parents in part_parent_candidates.values()
                for parent in parents
            ),
            *standalone_part_keys,
        }
        if key.startswith("w")
    }
    known_keys = {
        source_object_key(properties)
        for feature in collected
        if isinstance((properties := feature.get("properties")), Mapping)
    }
    for feature in line_features:
        properties = feature.get("properties")
        if not isinstance(properties, Mapping):
            continue
        normalized_properties = dict(properties)
        if (
            normalized_properties.get("osm_way_id") in (None, "")
            and normalized_properties.get("osm_id") not in (None, "")
        ):
            # The GDAL OSM lines layer stores way IDs in osm_id, while the
            # multipolygons layer exposes closed-way IDs as osm_way_id.
            normalized_properties["osm_way_id"] = normalized_properties["osm_id"]
        tags = _building_tags(properties)
        object_key = source_object_key(normalized_properties)
        if (
            tags.get("building:part") in (None, "", "no")
            and object_key not in required_relation_ways
        ):
            continue
        if not object_key or object_key in known_keys:
            continue
        try:
            geometry = shape(feature.get("geometry"))
        except (TypeError, ValueError):
            continue
        rings = (
            [geometry]
            if isinstance(geometry, LineString)
            else list(geometry.geoms)
            if isinstance(geometry, MultiLineString)
            else []
        )
        polygons = [
            Polygon(ring.coords)
            for ring in rings
            if len(ring.coords) >= 4 and ring.is_ring
        ]
        converted = _polygonal_geometry(unary_union(polygons)) if polygons else None
        if converted is None or not converted.is_valid:
            continue
        collected.append(
            {
                **feature,
                "properties": normalized_properties,
                "geometry": mapping(converted),
            }
        )
        known_keys.add(object_key)

    features_by_key = {
        source_object_key(properties): feature
        for feature in collected
        if isinstance((properties := feature.get("properties")), Mapping)
    }
    required_relationship_keys = {
        *part_parents,
        *part_parents.values(),
        *part_parent_candidates,
        *(
            parent
            for parents in part_parent_candidates.values()
            for parent in parents
        ),
        *standalone_part_keys,
    }
    replaced_geometry_sources: set[str] = set()
    for parent, geometry_source in sorted(parent_geometry_sources.items()):
        if geometry_source not in features_by_key:
            continue
        if parent in features_by_key:
            if geometry_source not in required_relationship_keys:
                replaced_geometry_sources.add(geometry_source)
            continue
        source_feature = features_by_key[geometry_source]
        cloned = {
            **source_feature,
            # Use only the restored way identity. The extractor supplies the
            # target outline's exact tags via parentTags; retaining the
            # multipolygon provider's tags could incorrectly turn the clone
            # into a building part.
            "properties": {"osm_way_id": parent[1:]},
        }
        collected.append(cloned)
        features_by_key[parent] = cloned
        if geometry_source not in required_relationship_keys:
            replaced_geometry_sources.add(geometry_source)
    if replaced_geometry_sources:
        collected = [
            feature
            for feature in collected
            if not (
                isinstance((properties := feature.get("properties")), Mapping)
                and source_object_key(properties) in replaced_geometry_sources
            )
        ]
    return collected


def prepare_buildings(
    features: Iterable[Mapping[str, Any]],
    rules: HeightRules,
    relation_index: Mapping[str, Any] | None = None,
    selection_geometry: Polygon | MultiPolygon | None = None,
    calibration_cache: CalibrationCache | None = None,
    calibration_rules_sha256: str | None = None,
    calibration_source_sha256: str | None = None,
    strict_relations: bool = False,
    on_complexity=None,
    on_association_progress=None,
) -> tuple[list[SourceBuilding], dict[str, Any], set[str]]:
    if calibration_cache is not None and (
        calibration_cache.identity.rules_sha256 != calibration_rules_sha256
        or calibration_cache.identity.source_snapshot_sha256 != calibration_source_sha256
        or calibration_cache.identity.building_profile_version != BUILDING_PROFILE_VERSION
        or calibration_cache.identity.cell_size_meters != rules.cell_size_meters
        or calibration_cache.identity.halo_cells != rules.halo_cells
        or calibration_cache.identity.minimum_samples != rules.minimum_samples
    ):
        raise CalibrationCacheError(
            "building_calibration_unavailable",
            "building calibration cache identity does not match extraction inputs",
        )
    diagnostics: dict[str, int] = {}
    part_parents = dict((relation_index or {}).get("partParents", {}))
    part_parent_candidates = {
        child: tuple(parents)
        for child, parents in (relation_index or {})
        .get("partParentCandidates", {})
        .items()
    }
    standalone_part_keys = set(
        (relation_index or {}).get("standalonePartKeys", ())
    )
    parent_tags = dict((relation_index or {}).get("parentTags", {}))
    explicit_parent_keys = set(part_parents.values()) | {
        parent
        for parents in part_parent_candidates.values()
        for parent in parents
    }
    sources: list[SourceBuilding] = []
    for feature in features:
        properties = feature.get("properties")
        object_key = (
            source_object_key(properties)
            if isinstance(properties, Mapping)
            else ""
        )
        source = _source_building(
            feature,
            rules,
            diagnostics,
            explicit_part=(
                object_key in part_parents
                or object_key in part_parent_candidates
                or object_key in standalone_part_keys
            ),
            explicit_parent=object_key in explicit_parent_keys,
            explicit_parent_tags=parent_tags.get(object_key),
        )
        if source is not None:
            sources.append(source)
    sources.sort(key=lambda item: item.object_key)
    by_key = {source.object_key: source for source in sources}
    if strict_relations and int((relation_index or {}).get("ambiguousParts", 0)):
        raise CalibrationCacheError(
            "building_relation_incomplete",
            "output building relations contain ambiguous explicit parents",
        )

    if on_complexity is not None:
        on_complexity(
            building_complexity_snapshot(
                sources,
                part_parents=part_parents,
                diagnostics=diagnostics,
            )
        )

    outlines = [source for source in sources if not source.is_part]
    unresolved_parts = sum(
        source.is_part
        and source.object_key not in standalone_part_keys
        and part_parents.get(source.object_key) is None
        for source in sources
    )
    containment_index = OutlineSpatialIndex(outlines)
    associated: list[SourceBuilding] = []
    associated_unresolved_parts = 0
    progress_interval = max(1, (unresolved_parts + 99) // 100)
    if on_association_progress is not None and unresolved_parts:
        on_association_progress(0, unresolved_parts)
    for source in sources:
        if not source.is_part:
            associated.append(source)
            continue
        if source.object_key in standalone_part_keys:
            associated.append(replace(source, association="standalone"))
            continue
        parent_key = part_parents.get(source.object_key)
        association = "relation" if parent_key in by_key else "none"
        used_containment = False
        if parent_key is not None and association == "none" and strict_relations:
            raise CalibrationCacheError(
                "building_relation_incomplete",
                "an explicit building parent is missing from converted geometry",
            )
        candidate_keys = part_parent_candidates.get(source.object_key)
        if candidate_keys is not None:
            available_candidates = {
                key
                for key in candidate_keys
                if key in by_key and not by_key[key].is_part
            }
            if strict_relations and len(available_candidates) != len(candidate_keys):
                raise CalibrationCacheError(
                    "building_relation_incomplete",
                    "a declared building parent candidate is missing from converted geometry",
                )
            parent_key = containment_index.containment_parent(
                source,
                allowed_keys=available_candidates,
                tolerance_meters=RELATION_PARENT_TOLERANCE_METERS,
                envelope_tolerance_meters=RELATION_PARENT_TOLERANCE_METERS,
            )
            association = "relation" if parent_key is not None else "none"
            if strict_relations and parent_key is None:
                raise CalibrationCacheError(
                    "building_relation_incomplete",
                    "a building part is not contained by any declared parent candidate",
                )
            associated_unresolved_parts += 1
            used_containment = True
        elif parent_key is None:
            parent_key = containment_index.containment_parent(source)
            association = "containment" if parent_key is not None else "none"
            associated_unresolved_parts += 1
            used_containment = True
        if (
            used_containment
            and on_association_progress is not None
            and (
                associated_unresolved_parts == unresolved_parts
                or associated_unresolved_parts % progress_interval == 0
            )
        ):
            on_association_progress(
                associated_unresolved_parts,
                unresolved_parts,
            )
        associated.append(replace(source, parent_key=parent_key, association=association))
    sources = associated
    by_key = {source.object_key: source for source in sources}

    direct: dict[str, ResolvedHeight] = {}
    calibration: dict[tuple[int, int, str], list[float]] = defaultdict(list)
    for source in sources:
        # The first pass only identifies eligible calibration samples and direct
        # parents. Rejection diagnostics belong to the single resolving pass
        # below, otherwise malformed tags are counted two or three times.
        candidate = direct_height(source.tags, rules)
        if candidate is None:
            continue
        resolved = resolve_height(source.tags, rules)
        direct[source.object_key] = resolved
        if calibration_cache is None:
            cell_x, cell_y = _calibration_cell(source.geometry, rules.cell_size_meters)
            calibration[(cell_x, cell_y, source.building_class)].append(candidate[0])

    resolved_sources: list[SourceBuilding] = []
    for source in sources:
        parent = direct.get(source.parent_key or "")
        cell = _calibration_cell(
            source.geometry,
            rules.cell_size_meters,
            bounds_midpoint=calibration_cache is not None,
        )
        local_median = (
            calibration_cache.local_median_meters(cell, source.building_class)
            if calibration_cache is not None
            else _local_median(source, calibration, rules)
        )
        resolved = resolve_height(
            source.tags,
            rules,
            parent=parent,
            local_median=local_median,
            diagnostics=diagnostics,
        )
        resolved_sources.append(replace(source, resolved=resolved))

    parts_by_parent: dict[str, list[SourceBuilding]] = defaultdict(list)
    for source in resolved_sources:
        if source.is_part and source.parent_key is not None:
            parts_by_parent[source.parent_key].append(source)
    covered_outline_keys = {
        source.object_key
        for source in resolved_sources
        if not source.is_part
        and _parts_cover_outline(source, parts_by_parent.get(source.object_key, ()))
    }
    rendered_sources: list[SourceBuilding] = []
    for source in resolved_sources:
        if source.is_part:
            rendered_sources.append(source)
            continue
        if source.object_key in covered_outline_keys:
            rendered_sources.append(replace(source, extrude=False, flat_base=True))
            continue
        parts = parts_by_parent.get(source.object_key, ())
        if not parts:
            rendered_sources.append(source)
            continue
        remainder = _polygonal_geometry(
            source.geometry.difference(unary_union([part.geometry for part in parts]))
        )
        if remainder is None:
            # Numerical edge cases that leave no outline area are equivalent to
            # complete part coverage and retain the outline only as a base.
            rendered_sources.append(replace(source, extrude=False, flat_base=True))
            covered_outline_keys.add(source.object_key)
            continue
        rendered_sources.append(
            replace(
                source,
                geometry=remainder,
                wall_boundary=source.geometry.boundary,
            )
        )
    resolved_sources = rendered_sources
    if selection_geometry is not None:
        resolved_sources = [
            source
            for source in resolved_sources
            if source.geometry.intersects(selection_geometry)
        ]
    flat_outline_keys = {
        source.object_key for source in resolved_sources if source.flat_base
    }

    provenance_counts = {name + "Count": 0 for name in PROVENANCE_NAMES.values()}
    holes = 0
    for source in resolved_sources:
        if (source.extrude or source.flat_base) and source.resolved is not None:
            provenance_counts[
                PROVENANCE_NAMES[source.resolved.provenance] + "Count"
            ] += 1
        holes += sum(len(polygon.interiors) for polygon in _polygons(source.geometry))
    report = {
        "profileVersion": BUILDING_PROFILE_VERSION,
        "sourceCount": len(resolved_sources),
        "outlineCount": sum(not source.is_part for source in resolved_sources),
        "partCount": sum(source.is_part for source in resolved_sources),
        "extrudedSourceCount": sum(source.extrude for source in resolved_sources),
        "flatOutlineCount": len(flat_outline_keys),
        "holeCount": holes,
        "relationAssociationCount": sum(source.association == "relation" for source in resolved_sources),
        "standaloneRelationPartCount": sum(
            source.association == "standalone" for source in resolved_sources
        ),
        "containmentAssociationCount": sum(source.association == "containment" for source in resolved_sources),
        "unassociatedPartCount": sum(source.is_part and source.parent_key is None for source in resolved_sources),
        "relationCount": int((relation_index or {}).get("relations", 0)),
        "ambiguousRelationPartCount": int(
            (relation_index or {}).get("ambiguousParts", 0)
        ),
        "relationClosure": (relation_index or {}).get("closureAudit"),
        "rejectedTags": dict(sorted(diagnostics.items())),
        "calibrationSource": (
            "sourceSnapshotCache" if calibration_cache is not None else "requestCandidates"
        ),
        "calibrationKey": calibration_cache.key if calibration_cache is not None else None,
        "calibrationLookup": (
            calibration_cache.lookup_diagnostics()
            if calibration_cache is not None
            else None
        ),
        **containment_index.metrics(),
        **provenance_counts,
    }
    return resolved_sources, report, flat_outline_keys


def building_complexity_snapshot(
    sources: Iterable[SourceBuilding],
    *,
    part_parents: Mapping[str, str],
    diagnostics: Mapping[str, int],
) -> dict[str, int]:
    """Return bounded counters from the already materialized building list."""
    materialized = list(sources)
    known_keys = {source.object_key for source in materialized}
    outlines = [source for source in materialized if not source.is_part]
    parts = [source for source in materialized if source.is_part]
    explicit = sum(
        part_parents.get(source.object_key) in known_keys for source in parts
    )
    unresolved = len(parts) - explicit
    product = min(
        MAX_BUILDING_COMPLEXITY_PRODUCT,
        unresolved * len(outlines),
    )
    polygons = 0
    rings = 0
    holes = 0
    coordinates = 0
    maximum_coordinates = 0
    for source in materialized:
        object_coordinates = 0
        for polygon in _polygons(source.geometry):
            polygons += 1
            polygon_rings = [polygon.exterior, *polygon.interiors]
            rings += len(polygon_rings)
            holes += len(polygon.interiors)
            for ring in polygon_rings:
                count = len(ring.coords)
                coordinates += count
                object_coordinates += count
        maximum_coordinates = max(maximum_coordinates, object_coordinates)
    return {
        "schemaVersion": 1,
        "sourceCount": len(materialized),
        "outlineCount": len(outlines),
        "partCount": len(parts),
        "explicitParentCount": explicit,
        "unresolvedPartCount": unresolved,
        "containmentCandidateProduct": product,
        "polygonCount": polygons,
        "ringCount": rings,
        "holeCount": holes,
        "sourceVertexCount": coordinates,
        "maximumVerticesPerObject": maximum_coordinates,
        "preparationRejectedCount": sum(
            value
            for value in diagnostics.values()
            if isinstance(value, int)
            and not isinstance(value, bool)
            and value >= 0
        ),
    }


def clip_buildings(
    buildings: Iterable[SourceBuilding],
    block: Polygon,
    min_x: int,
    min_y: int,
    *,
    tolerance: float = 0.05,
) -> tuple[list[dict[str, Any]], dict[str, int]]:
    records: list[dict[str, Any]] = []
    suppressed_walls = 0
    emitted_walls = 0
    points = 0
    dropped_holes = 0
    provenance_counts = {name + "Count": 0 for name in PROVENANCE_NAMES.values()}
    for source in buildings:
        if (not source.extrude and not source.flat_base) or source.resolved is None:
            continue
        if not source.geometry.intersects(block) or source.geometry.touches(block):
            continue
        clipped = source.geometry.intersection(block)
        original_boundary = (
            source.wall_boundary
            if source.wall_boundary is not None
            else source.geometry.boundary
        )
        prepared_wall_region = (
            None
            if source.flat_base
            else prep(
                original_boundary.buffer(
                    tolerance, cap_style=2, join_style=2
                )
            )
        )
        for fragment in _polygons(clipped):
            if fragment.is_empty or not fragment.is_valid:
                continue
            oriented = orient(fragment, sign=1.0)
            ring_candidates: list[tuple[float, dict[str, Any], int, int]] = []
            for ring_index, ring in enumerate([oriented.exterior, *oriented.interiors]):
                coordinates = list(ring.coords)
                if len(coordinates) > 1 and coordinates[0] == coordinates[-1]:
                    coordinates.pop()
                local, walls = _rounded_ring_with_walls(
                    coordinates,
                    min_x,
                    min_y,
                    prepared_wall_region,
                )
                if len(local) < 3:
                    continue
                local, rotation = _canonical_rotation(local)
                walls = walls[rotation:] + walls[:rotation]
                ring_emitted_walls = sum(walls)
                ring_suppressed_walls = len(walls) - ring_emitted_walls
                ring_record = {
                        "flags": RING_FLAG_HOLE if ring_index > 0 else 0,
                        "points": local,
                        "walls": walls,
                    }
                ring_candidates.append(
                    (
                        abs(Polygon(ring).area),
                        ring_record,
                        ring_emitted_walls,
                        ring_suppressed_walls,
                    )
                )
            if not ring_candidates or ring_candidates[0][1]["flags"] != 0:
                continue
            outer = ring_candidates[0]
            holes = sorted(
                ring_candidates[1:],
                key=lambda item: (-item[0], tuple(item[1]["points"])),
            )
            selected = [outer, *holes[: MAX_BUILDING_RINGS - 1]]
            dropped_holes += max(0, len(holes) - (MAX_BUILDING_RINGS - 1))
            rings = [item[1] for item in selected]
            emitted_walls += sum(item[2] for item in selected)
            suppressed_walls += sum(item[3] for item in selected)
            points += sum(len(item[1]["points"]) for item in selected)
            if not rings or rings[0]["flags"] != 0:
                continue
            bounds = [coordinate for ring in rings for coordinate in ring["points"]]
            records.append(
                {
                    "type_id": get_type_id(f"building.{source.building_class}"),
                    "flags": (
                        (BUILDING_FLAG_PART if source.is_part else 0)
                        | (BUILDING_FLAG_FLAT_BASE if source.flat_base else 0)
                    ),
                    "provenance": int(source.resolved.provenance),
                    "height_dm": source.resolved.height_dm,
                    "minimum_height_dm": source.resolved.minimum_height_dm,
                    "bbox": (
                        min(point[0] for point in bounds),
                        min(point[1] for point in bounds),
                        max(point[0] for point in bounds),
                        max(point[1] for point in bounds),
                    ),
                    "rings": rings,
                    "source_key": source.object_key,
                }
            )
            provenance_counts[
                PROVENANCE_NAMES[source.resolved.provenance] + "Count"
            ] += 1
    records.sort(
        key=lambda item: (
            item["bbox"], item["height_dm"], item["source_key"], item["flags"]
        )
    )
    return records, {
        "recordCount": len(records),
        "pointCount": points,
        "emittedWallCount": emitted_walls,
        "suppressedWallCount": suppressed_walls,
        "droppedHoleCount": dropped_holes,
        **provenance_counts,
    }


def source_object_key(properties: Mapping[str, Any]) -> str:
    if properties.get("osm_way_id") not in (None, ""):
        return f"w{properties['osm_way_id']}"
    raw = properties.get("osm_id")
    if raw in (None, ""):
        return ""
    # GDAL uses osm_id for assembled multipolygon relations and osm_way_id for
    # closed ways in the multipolygons layer.
    return f"r{raw}"


def _source_building(
    feature: Mapping[str, Any],
    rules: HeightRules,
    diagnostics: dict[str, int],
    *,
    explicit_part: bool = False,
    explicit_parent: bool = False,
    explicit_parent_tags: Mapping[str, str] | None = None,
) -> SourceBuilding | None:
    properties = feature.get("properties")
    if not isinstance(properties, Mapping):
        return None
    tags = _building_tags(properties)
    if explicit_parent_tags:
        tags = {**explicit_parent_tags, **tags}
    if (
        explicit_parent
        and tags.get("building") in (None, "", "no")
        and tags.get("building:part") in (None, "", "no")
    ):
        tags["building"] = "yes"
    if (
        explicit_part
        and tags.get("building") in (None, "", "no")
        and tags.get("building:part") in (None, "", "no")
    ):
        tags["building:part"] = "yes"
    if tags.get("building") in (None, "no") and tags.get("building:part") in (None, "no"):
        return None
    object_key = source_object_key(properties)
    if not object_key:
        diagnostics["missingObjectIdentity"] = diagnostics.get("missingObjectIdentity", 0) + 1
        return None
    try:
        geometry = shape(feature.get("geometry"))
    except (TypeError, ValueError):
        diagnostics["invalidGeometry"] = diagnostics.get("invalidGeometry", 0) + 1
        return None
    if not isinstance(geometry, (Polygon, MultiPolygon)) or geometry.is_empty or not geometry.is_valid:
        diagnostics["invalidGeometry"] = diagnostics.get("invalidGeometry", 0) + 1
        return None
    return SourceBuilding(
        object_key=object_key,
        building_class=normalized_building_class(tags, rules),
        is_part=(
            explicit_part
            or tags.get("building:part") not in (None, "", "no")
        ),
        geometry=geometry,
        tags=dict(sorted(tags.items())),
    )


def _building_tags(properties: Mapping[str, Any]) -> dict[str, str]:
    tags = parse_tags(properties.get("other_tags"))
    for key in (
        "building", "building:part", "height", "min_height",
        "building:levels", "building:min_level", "roof:height", "roof:levels",
    ):
        if properties.get(key) not in (None, ""):
            tags[key] = str(properties[key])
    return tags


def _containment_parent(part: SourceBuilding, outlines) -> str | None:
    candidates = [
        outline
        for outline, prepared in outlines
        if outline.geometry.envelope.covers(part.geometry.envelope)
        and prepared.covers(part.geometry)
    ]
    if not candidates:
        return None
    return min(candidates, key=lambda item: (item.geometry.area, item.object_key)).object_key


def _parts_cover_outline(
    outline: SourceBuilding,
    parts: Iterable[SourceBuilding],
    tolerance: float = 0.05,
) -> bool:
    part_geometries = [part.geometry for part in parts]
    if not part_geometries:
        return False
    target = outline.geometry.buffer(-tolerance)
    if target.is_empty:
        target = outline.geometry
    coverage = unary_union(part_geometries).buffer(tolerance)
    return prep(coverage).covers(target)


def _polygonal_geometry(geometry: BaseGeometry) -> Polygon | MultiPolygon | None:
    if isinstance(geometry, Polygon):
        return geometry if not geometry.is_empty else None
    if isinstance(geometry, MultiPolygon):
        return geometry if not geometry.is_empty else None
    polygons = [
        item
        for item in getattr(geometry, "geoms", ())
        if isinstance(item, Polygon) and not item.is_empty
    ]
    if not polygons:
        return None
    merged = unary_union(polygons)
    return merged if isinstance(merged, (Polygon, MultiPolygon)) else None


def projected_selection_geometry(
    value: Mapping[str, Any],
    *,
    buffer_meters: float = 0.0,
) -> Polygon | MultiPolygon:
    """Project a normalized WGS84 selection into the extractor's Mercator CRS."""
    if not math.isfinite(buffer_meters) or buffer_meters < 0:
        raise ValueError("selection buffer is invalid")
    geometry = shape(value)
    if geometry.is_empty or not geometry.is_valid:
        raise ValueError("selection geometry is invalid")

    def project(lon: float, lat: float, altitude=None):
        del altitude
        latitude = max(-85.05112878, min(85.05112878, lat))
        return (
            math.radians(lon) * EARTH_RADIUS_METERS,
            math.log(math.tan(math.radians(latitude) / 2 + math.pi / 4))
            * EARTH_RADIUS_METERS,
        )

    projected = transform(project, geometry)
    if buffer_meters > 0:
        projected = projected.buffer(buffer_meters)
    if not isinstance(projected, (Polygon, MultiPolygon)) or projected.is_empty:
        raise ValueError("selection geometry does not produce an area")
    return projected


def _calibration_cell(
    geometry: Polygon | MultiPolygon,
    size: int,
    *,
    bounds_midpoint: bool = False,
) -> tuple[int, int]:
    if bounds_midpoint:
        return calibration_cell_for_bounds(geometry.bounds, size)
    point = geometry.representative_point()
    return math.floor(point.x / size), math.floor(point.y / size)


def _local_median(
    source: SourceBuilding,
    calibration: Mapping[tuple[int, int, str], list[float]],
    rules: HeightRules,
) -> float | None:
    cell_x, cell_y = _calibration_cell(source.geometry, rules.cell_size_meters)
    samples: list[float] = []
    for x in range(cell_x - rules.halo_cells, cell_x + rules.halo_cells + 1):
        for y in range(cell_y - rules.halo_cells, cell_y + rules.halo_cells + 1):
            samples.extend(calibration.get((x, y, source.building_class), ()))
    return statistics.median(sorted(samples)) if len(samples) >= rules.minimum_samples else None


def _polygons(geometry) -> list[Polygon]:
    if isinstance(geometry, Polygon):
        return [geometry]
    if isinstance(geometry, MultiPolygon):
        return list(geometry.geoms)
    return []


def _rounded_ring_with_walls(
    coordinates: list[tuple[float, float]],
    min_x: int,
    min_y: int,
    prepared_wall_region,
) -> tuple[list[tuple[int, int]], list[bool]]:
    """Quantize a ring while retaining pre-quantization edge provenance.

    Testing rounded segments against the source boundary loses ordinary OSM
    facades whenever Mercator coordinates are more than the wall tolerance
    from an integer meter. Evaluate each clipped edge first, then discard only
    edges whose endpoints collapse to the same encoded point.
    """
    points: list[tuple[int, int]] = []
    walls: list[bool] = []
    for index, start in enumerate(coordinates):
        end = coordinates[(index + 1) % len(coordinates)]
        rounded_start = (
            int(math.floor(start[0] - min_x + 0.5)),
            int(math.floor(start[1] - min_y + 0.5)),
        )
        rounded_end = (
            int(math.floor(end[0] - min_x + 0.5)),
            int(math.floor(end[1] - min_y + 0.5)),
        )
        if rounded_start == rounded_end:
            continue
        points.append(rounded_start)
        walls.append(
            False
            if prepared_wall_region is None
            else bool(prepared_wall_region.covers(LineString((start, end))))
        )
    if any(not -32768 <= value <= 32767 for point in points for value in point):
        raise ValueError("building coordinate exceeds int16")
    return points, walls


def _canonical_rotation(
    points: list[tuple[int, int]],
) -> tuple[list[tuple[int, int]], int]:
    rotation = min(range(len(points)), key=lambda index: (points[index], points[(index + 1) % len(points)]))
    return points[rotation:] + points[:rotation], rotation
