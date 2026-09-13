"""Operator elevation research tools, intentionally separate from user jobs."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import tempfile
from pathlib import Path

from .topography_cache import ElevationCache, _sync_directory
from .topography_pipeline import canonical_bytes, contour_sample
from .topography_sources import load_topography_source_policy, plan_elevation


def _write_evidence(output: Path, value: dict) -> None:
    data = canonical_bytes(value)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="elevation-evidence-", dir=output.parent) as tmp:
        staged = Path(tmp) / "evidence.json"
        with staged.open("xb") as file:
            file.write(data)
            file.flush()
            os.fsync(file.fileno())
        os.link(staged, output)
        _sync_directory(output.parent)
    print(json.dumps({"output": str(output), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                      "productionEligible": False}))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument("--cache", type=Path, required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("coverage", help="verify pinned global catalogs and count geocells")
    commands.add_parser("sources", help="report source implementation stages and missing qualification evidence; no network")
    from .topography_discovery import REGIONAL_SOURCES, discover_regional
    discover = commands.add_parser("discover", help="snapshot regional native-asset metadata; no raster downloads or approval")
    discover.add_argument("--source", choices=sorted(REGIONAL_SOURCES), required=True)
    discover.add_argument("--bounds", nargs=4, type=float, required=True, metavar=("W", "S", "E", "N"))
    discover.add_argument("--output", type=Path, required=True)
    encode = commands.add_parser("encode", help="compile a development device/companion pair; does not publish or sign")
    encode.add_argument("--sample", type=Path, required=True)
    encode.add_argument("--selection", type=Path, required=True, help="WGS-84 Polygon/MultiPolygon or LineString GeoJSON geometry")
    encode.add_argument("--corridor-width-m", type=int, default=0)
    encode.add_argument("--vector-pack", type=Path, required=True, help="existing renderer-3 pack root containing VECTMAP")
    encode.add_argument("--map-id", required=True)
    encode.add_argument("--attribution", type=Path, required=True, help="complete UTF-8 notices for all contributing sources")
    encode.add_argument("--output", type=Path, required=True, help="new development pair directory; never overwritten")
    for command in ("plan", "stage", "sample"):
        child = commands.add_parser(command)
        child.add_argument("--bounds", nargs=4, type=float, required=True, metavar=("W", "S", "E", "N"))
        if command in ("stage", "sample"):
            child.add_argument("--max-tiles", type=int, default=8)
        if command == "sample":
            child.add_argument("--output", type=Path, required=True, help="new evidence JSON file; never overwritten")
    args = parser.parse_args(argv)
    if args.command == "sources":
        from .topography_qualification import load_qualification_registry, qualification_summary
        print(json.dumps(qualification_summary(load_qualification_registry(args.repo_root)), indent=2, sort_keys=True))
        return 0
    if args.command == "discover":
        if args.output.exists() or args.output.is_symlink():
            parser.error("output already exists")
        _write_evidence(args.output, discover_regional(args.source, args.bounds))
        return 0
    if args.command == "encode":
        from .topography_geometry import compile_contours
        from .topography_pack import assemble_topographic_pack
        for path, maximum in ((args.sample, 32 * 1024 * 1024), (args.selection, 2 * 1024 * 1024), (args.attribution, 256 * 1024)):
            if not path.is_file() or path.stat().st_size > maximum:
                parser.error("encoding input is missing or exceeds its byte limit")
        sample = json.loads(args.sample.read_bytes())
        policy = load_topography_source_policy(args.repo_root)
        if sample.get("sourcePolicySha256") != policy.sha256:
            parser.error("sample belongs to a different source policy")
        compiled = compile_contours(sample, json.loads(args.selection.read_bytes()), corridor_width_m=args.corridor_width_m)
        receipt = assemble_topographic_pack(args.vector_pack, args.output, args.map_id, compiled, sample, args.attribution.read_bytes())
        print(json.dumps({"output": str(args.output), "productionEligible": False, "intermediateSha256": receipt["intermediateSha256"],
                          "recordCount": receipt["recordCount"], "pointCount": receipt["pointCount"], "companion": receipt["companion"]}, sort_keys=True))
        return 0
    if args.command in ("stage", "sample") and not 1 <= args.max_tiles <= 256:
        parser.error("--max-tiles must be between 1 and 256")
    if args.command == "sample" and args.output.exists():
        parser.error("output already exists")
    policy = load_topography_source_policy(args.repo_root)
    cache = ElevationCache(args.cache)
    indexes = {source.id: cache.index(source) for source in policy.sources}
    if args.command == "coverage":
        seen = set()
        sources = []
        for source in policy.sources:
            cells = indexes[source.id]
            sources.append({"sourceId": source.id, "catalogTiles": len(cells),
                            "additionalGeocells": len(cells - seen), "indexSha256": source.index_sha256})
            seen.update(cells)
        print(json.dumps({**policy.public_summary(), "sources": sources, "coveredGeocells": len(seen)}, indent=2))
        return 0
    plan = plan_elevation(policy, indexes, args.bounds)
    if args.command == "plan":
        print(json.dumps(plan, indent=2, sort_keys=True))
        return 0 if plan["coverageComplete"] else 2
    if not plan["coverageComplete"] or len(plan["tiles"]) > args.max_tiles:
        parser.error("request has uncovered geocells or exceeds --max-tiles; inspect with plan")
    if args.command == "stage":
        sources = {source.id: source for source in policy.sources}
        receipts = [cache.stage(sources[tile["sourceId"]], tuple(tile["cell"])) for tile in plan["tiles"]]
        print(json.dumps({"plan": plan, "receipts": receipts}, indent=2, sort_keys=True))
        return 0
    _write_evidence(args.output, contour_sample(policy, cache, args.bounds, maximum_tiles=args.max_tiles))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
