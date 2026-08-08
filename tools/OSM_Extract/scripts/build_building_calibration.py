#!/usr/bin/env python3
"""Materialize deterministic calibration cells from one immutable OSM snapshot."""

from __future__ import annotations

import argparse
from collections import defaultdict
import hashlib
import json
import math
from pathlib import Path
import sys
import tempfile

from shapely.geometry import MultiPolygon, Polygon
from shapely.ops import transform

from building_calibration_cache import (
    CalibrationCache,
    CalibrationCacheError,
    CalibrationIdentity,
    CalibrationSample,
    calibration_cell_for_bounds,
    canonical_json,
)
from building_height import direct_height, normalized_building_class
from building_pipeline import BUILDING_PROFILE_VERSION, EARTH_RADIUS_METERS, load_rules


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_scope(path: Path) -> dict:
    value = json.loads(path.read_bytes())
    expected = value.pop("scopePlanSha256", None)
    actual = hashlib.sha256(canonical_json(value)).hexdigest()
    if expected != actual or value.get("schemaVersion") != 1:
        raise ValueError("scope plan identity is invalid")
    return value


def project_polygon(ring_groups) -> Polygon | MultiPolygon | None:
    def project(lon, lat, altitude=None):
        del altitude
        return (
            math.radians(lon) * EARTH_RADIUS_METERS,
            math.log(math.tan(math.radians(lat) / 2 + math.pi / 4))
            * EARTH_RADIUS_METERS,
        )

    try:
        polygons = [
            Polygon(
                [(node.lon, node.lat) for node in outer],
                [[(node.lon, node.lat) for node in inner] for inner in inners],
            )
            for outer, inners in ring_groups
        ]
        geometry = polygons[0] if len(polygons) == 1 else MultiPolygon(polygons)
        projected = transform(project, geometry)
    except (TypeError, ValueError, RuntimeError):
        return None
    return projected if not projected.is_empty and projected.is_valid else None


MAX_COMPLETE_CALIBRATION_CELLS = 250_000
PYOSMIUM_LOCATION_INDEX_TYPE = "sparse_file_array"


def apply_area_handler(handler, path: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="building-area-locations-") as temporary:
        location_index = Path(temporary) / "nodes.idx"
        handler.apply_file(
            str(path),
            locations=True,
            idx=f"{PYOSMIUM_LOCATION_INDEX_TYPE},{location_index}",
        )


def source_cell_domain(
    path: Path,
    cell_size_meters: int,
    halo_cells: int,
) -> tuple[tuple[int, int], ...]:
    """Derive the complete calibration domain from the immutable source itself."""
    try:
        import osmium
    except ImportError as exc:  # pragma: no cover - container dependency
        raise RuntimeError("pyosmium is required to derive the calibration domain") from exc

    domain: set[tuple[int, int]] = set()

    class DomainHandler(osmium.SimpleHandler):
        def area(self, area):
            tags = {tag.k: tag.v for tag in area.tags}
            if (
                tags.get("building") in (None, "", "no")
                and tags.get("building:part") in (None, "", "no")
            ):
                return
            ring_groups = []
            try:
                for outer in area.outer_rings():
                    ring_groups.append(
                        (list(outer), [list(inner) for inner in area.inner_rings(outer)])
                    )
            except (RuntimeError, ValueError):
                return
            geometry = project_polygon(ring_groups)
            if geometry is None:
                return
            x, y = calibration_cell_for_bounds(geometry.bounds, cell_size_meters)
            domain.update(
                (x + dx, y + dy)
                for dx in range(-halo_cells, halo_cells + 1)
                for dy in range(-halo_cells, halo_cells + 1)
            )
            if len(domain) > MAX_COMPLETE_CALIBRATION_CELLS:
                raise CalibrationCacheError(
                    "building_calibration_unavailable",
                    f"complete calibration domain exceeds {MAX_COMPLETE_CALIBRATION_CELLS} cells",
                )

    try:
        apply_area_handler(DomainHandler(), path)
    except CalibrationCacheError:
        raise
    except (RuntimeError, ValueError) as exc:
        raise CalibrationCacheError(
            "building_calibration_unavailable",
            "source snapshot calibration domain could not be assembled",
        ) from exc
    if not domain:
        raise CalibrationCacheError(
            "building_calibration_unavailable", "source snapshot has no building areas"
        )
    return tuple(sorted(domain))


def _scan_pbf(
    path: Path,
    rules,
    required_cells: set[tuple[int, int]] | None,
    *,
    derive_complete_domain: bool,
    anchor_cells_by_object: dict[str, tuple[int, int]] | None = None,
):
    try:
        import osmium
    except ImportError as exc:  # pragma: no cover - container dependency
        raise RuntimeError("pyosmium is required to build calibration cells") from exc

    samples = defaultdict(list)
    rejections = defaultdict(lambda: defaultdict(int))
    domain: set[tuple[int, int]] = set()
    diagnostics = {
        "areasSeen": 0,
        "directSamples": 0,
        "invalidGeometry": 0,
        "outsideRequestedCells": 0,
    }

    class Handler(osmium.SimpleHandler):
        def area(self, area):
            tags = {tag.k: tag.v for tag in area.tags}
            if tags.get("building") in (None, "", "no") and tags.get("building:part") in (None, "", "no"):
                return
            diagnostics["areasSeen"] += 1
            if diagnostics["areasSeen"] % 5_000 == 0:
                print("BUILDING_PREPROCESS_PROGRESS:" + json.dumps({
                    "phase": "calibration_scan",
                    "unit": "osm_areas",
                    "completed": diagnostics["areasSeen"],
                    "indeterminate": True,
                }, sort_keys=True, separators=(",", ":")), flush=True)
            ring_groups = []
            try:
                for outer in area.outer_rings():
                    ring_groups.append(
                        (list(outer), [list(inner) for inner in area.inner_rings(outer)])
                    )
            except (RuntimeError, ValueError):
                diagnostics["invalidGeometry"] += 1
                return
            geometry = project_polygon(ring_groups)
            if geometry is None:
                diagnostics["invalidGeometry"] += 1
                return
            cell = calibration_cell_for_bounds(
                geometry.bounds, rules.cell_size_meters
            )
            prefix = "w" if area.from_way() else "r"
            object_key = f"{prefix}{area.orig_id()}"
            if anchor_cells_by_object is not None:
                anchor_cells_by_object[object_key] = cell
            if derive_complete_domain:
                domain.update(
                    (cell[0] + dx, cell[1] + dy)
                    for dx in range(-rules.halo_cells, rules.halo_cells + 1)
                    for dy in range(-rules.halo_cells, rules.halo_cells + 1)
                )
                if len(domain) > MAX_COMPLETE_CALIBRATION_CELLS:
                    raise CalibrationCacheError(
                        "building_calibration_unavailable",
                        f"complete calibration domain exceeds {MAX_COMPLETE_CALIBRATION_CELLS} cells",
                    )
            elif cell not in required_cells:
                diagnostics["outsideRequestedCells"] += 1
                return
            tag_diagnostics = {}
            direct = direct_height(tags, rules, tag_diagnostics)
            for reason, count in tag_diagnostics.items():
                rejections[cell][reason] += count
            if direct is None:
                return
            samples[cell].append(
                CalibrationSample(
                    object_key,
                    normalized_building_class(tags, rules),
                    max(1, min(65_535, int(math.floor(direct[0] * 10 + 0.5)))),
                )
            )
            diagnostics["directSamples"] += 1

    try:
        apply_area_handler(Handler(), path)
    except CalibrationCacheError:
        raise
    except (RuntimeError, ValueError) as exc:
        raise CalibrationCacheError(
            "building_calibration_unavailable",
            "source snapshot calibration samples could not be assembled",
        ) from exc
    return (
        tuple(sorted(domain)) if derive_complete_domain else None,
        samples,
        rejections,
        diagnostics,
    )


def scan_pbf(
    path: Path,
    rules,
    required_cells: set[tuple[int, int]],
    *,
    anchor_cells_by_object: dict[str, tuple[int, int]] | None = None,
):
    _, samples, rejections, diagnostics = _scan_pbf(
        path,
        rules,
        required_cells,
        derive_complete_domain=False,
        anchor_cells_by_object=anchor_cells_by_object,
    )
    return samples, rejections, diagnostics


def scan_full_pbf(
    path: Path,
    rules,
    *,
    anchor_cells_by_object: dict[str, tuple[int, int]] | None = None,
):
    domain, samples, rejections, diagnostics = _scan_pbf(
        path,
        rules,
        None,
        derive_complete_domain=True,
        anchor_cells_by_object=anchor_cells_by_object,
    )
    if not domain:
        raise CalibrationCacheError(
            "building_calibration_unavailable", "source snapshot has no valid building areas"
        )
    return domain, samples, rejections, diagnostics


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-pbf", type=Path, required=True)
    parser.add_argument("--source-sha256", required=True)
    parser.add_argument("--rules", type=Path, required=True)
    parser.add_argument("--scope-plan", type=Path, required=True)
    parser.add_argument("--closure-plan", type=Path)
    parser.add_argument("--cache-root", type=Path, required=True)
    parser.add_argument("--result-json", type=Path)
    parser.add_argument(
        "--full-precompute",
        action="store_true",
        help="derive the complete cell domain from the source snapshot and materialize it",
    )
    args = parser.parse_args()
    print(
        'BUILDING_PREPROCESS_PROGRESS:{"completed":0,"indeterminate":true,"unit":"calibration_cells"}',
        flush=True,
    )

    try:
        source_before = file_sha256(args.source_pbf)
    except OSError as exc:
        raise CalibrationCacheError(
            "building_source_snapshot_changed", "source PBF is unavailable"
        ) from exc
    if source_before != args.source_sha256:
        raise CalibrationCacheError(
            "building_source_snapshot_changed",
            "source PBF identity changed before calibration",
        )
    try:
        scope = load_scope(args.scope_plan)
    except (OSError, TypeError, ValueError) as exc:
        raise CalibrationCacheError(
            "building_scope_policy_invalid", "scope plan is unavailable or invalid"
        ) from exc
    try:
        rules, rules_sha256 = load_rules(args.rules)
    except (OSError, TypeError, ValueError) as exc:
        raise CalibrationCacheError(
            "building_calibration_unavailable", "building height rules are unavailable or invalid"
        ) from exc
    calibration = scope["calibration"]
    if (
        calibration["cellSizeMeters"] != rules.cell_size_meters
        or calibration["haloCells"] != rules.halo_cells
        or calibration["minimumSamples"] != rules.minimum_samples
    ):
        raise ValueError("scope calibration policy does not match the rules")
    if not args.full_precompute:
        required_cells = {tuple(cell) for cell in calibration["sampleCells"]}
        if args.closure_plan is not None:
            try:
                closure = json.loads(args.closure_plan.read_bytes())
                closure_digest = closure.pop("closurePlanSha256")
            except (OSError, TypeError, ValueError, KeyError) as exc:
                raise CalibrationCacheError(
                    "building_calibration_unavailable",
                    "building closure plan is unavailable",
                ) from exc
            if (
                hashlib.sha256(canonical_json(closure)).hexdigest() != closure_digest
                or closure.get("schemaVersion") != 1
                or closure.get("scopePlanSha256")
                != hashlib.sha256(canonical_json(scope)).hexdigest()
                or closure.get("sourceSnapshotSha256") != source_before
            ):
                raise CalibrationCacheError(
                    "building_calibration_unavailable",
                    "building closure plan identity is invalid",
                )
            required_cells.update(
                tuple(cell) for cell in closure.get("calibrationSampleCells", [])
            )
    identity = CalibrationIdentity(
        source_snapshot_sha256=source_before,
        rules_sha256=rules_sha256,
        building_profile_version=BUILDING_PROFILE_VERSION,
        cell_size_meters=rules.cell_size_meters,
        halo_cells=rules.halo_cells,
        minimum_samples=rules.minimum_samples,
    )
    cache = CalibrationCache(args.cache_root, identity)
    def populate(missing_cells):
        samples, rejections, scan_metrics = scan_pbf(args.source_pbf, rules, set(missing_cells))
        if file_sha256(args.source_pbf) != source_before:
            raise CalibrationCacheError(
                "building_source_snapshot_changed",
                "source PBF identity changed during calibration",
            )
        return samples, rejections, scan_metrics

    if args.full_precompute:
        def scan_complete_snapshot():
            domain, samples, rejections, scan_metrics = scan_full_pbf(
                args.source_pbf, rules
            )
            if file_sha256(args.source_pbf) != source_before:
                raise CalibrationCacheError(
                    "building_source_snapshot_changed",
                    "source PBF identity changed while scanning complete calibration",
                )
            return domain, samples, rejections, scan_metrics

        try:
            sealed_manifest = cache.validate_complete_generation()
        except CalibrationCacheError:
            sealed_manifest = None
        if sealed_manifest is not None:
            sealed_count = len(sealed_manifest["cells"])
            cache_metrics = {
                "requested": sealed_count,
                "hits": sealed_count,
                "misses": 0,
                "rebuilt": 0,
            }
            scan = None
        else:
            cache_metrics, scan = cache.materialize_complete_with_snapshot_builder(
                scan_complete_snapshot
            )
    else:
        cache_metrics, scan = cache.materialize_with_builder(
            required_cells,
            populate,
        )
    if file_sha256(args.source_pbf) != source_before:
        raise CalibrationCacheError(
            "building_source_snapshot_changed",
            "source PBF identity changed before calibration result publication",
        )
    scan = scan or {
        "areasSeen": 0,
        "directSamples": 0,
        "invalidGeometry": 0,
        "outsideRequestedCells": 0,
    }
    result = {
        "calibrationKey": identity.key,
        "manifestPath": str(cache.key_root / "manifest.json"),
        "rulesSha256": rules_sha256,
        "sourceSnapshotSha256": source_before,
        **scan,
        **{f"cells{key.title()}": value for key, value in cache_metrics.items()},
    }
    if args.result_json:
        args.result_json.write_bytes(canonical_json(result) + b"\n")
    public_result = {key: value for key, value in result.items() if key != "manifestPath"}
    print("BUILDING_CALIBRATION_STATS:" + json.dumps(public_result, sort_keys=True, separators=(",", ":")), flush=True)
    print(
        'BUILDING_PREPROCESS_PROGRESS:{"completed":1,"indeterminate":false,"total":1,"unit":"calibration_cells"}',
        flush=True,
    )


if __name__ == "__main__":
    try:
        main()
    except CalibrationCacheError as exc:
        print(
            "BUILDING_PREPROCESS_FAILURE:"
            + json.dumps(
                {"code": exc.code, "message": str(exc)},
                sort_keys=True,
                separators=(",", ":"),
            ),
            file=sys.stderr,
            flush=True,
        )
        raise SystemExit(2) from exc
    except Exception as exc:
        print(
            "BUILDING_PREPROCESS_FAILURE:"
            + json.dumps(
                {
                    "code": "building_calibration_unavailable",
                    "message": "calibration preprocessing failed",
                },
                sort_keys=True,
                separators=(",", ":"),
            ),
            file=sys.stderr,
            flush=True,
        )
        raise SystemExit(2) from exc
