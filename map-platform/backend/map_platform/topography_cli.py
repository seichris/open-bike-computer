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


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument("--cache", type=Path, required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("coverage", help="verify pinned global catalogs and count geocells")
    for command in ("plan", "stage", "sample"):
        child = commands.add_parser(command)
        child.add_argument("--bounds", nargs=4, type=float, required=True, metavar=("W", "S", "E", "N"))
        if command in ("stage", "sample"):
            child.add_argument("--max-tiles", type=int, default=8)
        if command == "sample":
            child.add_argument("--output", type=Path, required=True, help="new evidence JSON file; never overwritten")
    args = parser.parse_args(argv)
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
    data = canonical_bytes(contour_sample(policy, cache, args.bounds, maximum_tiles=args.max_tiles))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # Same-filesystem staging + link: atomic publication without overwriting.
    with tempfile.TemporaryDirectory(prefix="contour-evidence-", dir=args.output.parent) as tmp:
        staged = Path(tmp) / "sample.json"
        with staged.open("xb") as file:
            file.write(data)
            file.flush()
            os.fsync(file.fileno())
        os.link(staged, args.output)
        _sync_directory(args.output.parent)
    print(json.dumps({"output": str(args.output), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                      "productionEligible": False}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
