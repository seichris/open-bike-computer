#!/usr/bin/env python3
"""Export missing building-closure objects from a verified source index.

The clipped PBF is small enough to inspect per request. Only objects absent
from that clip are emitted, so merging never introduces a second version of an
existing OSM object. The source country PBF is not read here.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
from xml.sax.saxutils import quoteattr

from building_calibration_cache import canonical_json
from building_source_index import BuildingSourceIndex, BuildingSourceIndexError

_KEY = re.compile(r"[nwr][1-9][0-9]*")
_FIELDS = {"n": ("requiredNodeKeys", "nodes"),
           "w": ("requiredWayKeys", "ways"),
           "r": ("requiredRelationKeys", "relations")}


def _coordinate(value: int) -> str:
    sign = "-" if value < 0 else ""
    whole, fractional = divmod(abs(value), 10_000_000)
    return f"{sign}{whole}.{fractional:07d}"


def _read_closure(path: Path, source_sha256: str) -> dict[str, list[str]]:
    try:
        document = json.loads(path.read_bytes())
        digest = document.pop("closurePlanSha256")
    except (OSError, ValueError, TypeError, KeyError) as exc:
        raise BuildingSourceIndexError("building_relation_incomplete", "closure plan is unavailable") from exc
    if (not isinstance(document, dict)
            or not isinstance(digest, str)
            or hashlib.sha256(canonical_json(document)).hexdigest() != digest
            or document.get("schemaVersion") != 1
            or document.get("sourceSnapshotSha256") != source_sha256):
        raise BuildingSourceIndexError("building_relation_incomplete", "closure identity is invalid")
    keys = {}
    for prefix, (field, _) in _FIELDS.items():
        value = document.get(field)
        if (not isinstance(value, list) or len(value) > 500_000
                or any(not isinstance(key, str) or not _KEY.fullmatch(key)
                       or not key.startswith(prefix) for key in value)
                or len(value) != len(set(value))):
            raise BuildingSourceIndexError("building_relation_incomplete", "closure object keys are invalid")
        keys[prefix] = value
    if sum(map(len, keys.values())) > 500_000:
        raise BuildingSourceIndexError("building_object_limit_exceeded", "closure exceeds object limit")
    return keys


def _present_keys(clipped_pbf: Path, wanted: dict[str, list[str]]) -> set[str]:
    try:
        import osmium
    except ImportError as exc:
        raise RuntimeError("pyosmium is required to inspect the clipped PBF") from exc
    wanted_sets = {prefix: set(values) for prefix, values in wanted.items()}
    present = set()

    class Existing(osmium.SimpleHandler):
        def node(self, obj):
            key = f"n{obj.id}"
            if key in wanted_sets["n"]:
                present.add(key)

        def way(self, obj):
            key = f"w{obj.id}"
            if key in wanted_sets["w"]:
                present.add(key)

        def relation(self, obj):
            key = f"r{obj.id}"
            if key in wanted_sets["r"]:
                present.add(key)

    Existing().apply_file(str(clipped_pbf), locations=False)
    return present


def export_closure(manifest: Path, closure_plan: Path, clipped_pbf: Path, output_xml: Path) -> dict[str, int]:
    index = BuildingSourceIndex.from_manifest(manifest, validate_database=False)
    wanted = _read_closure(closure_plan, index.source_snapshot_sha256)
    present = _present_keys(clipped_pbf, wanted)
    missing = {prefix: sorted((key for key in keys if key not in present),
                              key=lambda key: int(key[1:]))
               for prefix, keys in wanted.items()}
    output_xml.parent.mkdir(parents=True, exist_ok=True)
    connection = index.connect_verified_database()
    staged = None
    try:
        descriptor, name = tempfile.mkstemp(prefix=".closure-", suffix=".osm", dir=output_xml.parent)
        staged = Path(name)
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            output.write('<?xml version="1.0" encoding="UTF-8"?>\n<osm version="0.6" generator="open-bike-source-index">\n')
            for prefix in _FIELDS:
                for key in missing[prefix]:
                    if prefix == "n":
                        row = connection.execute("SELECT lon_e7, lat_e7 FROM nodes WHERE object_key = ?", (key,)).fetchone()
                        if row is None:
                            raise BuildingSourceIndexError("building_relation_incomplete", f"missing indexed node {key}")
                        output.write(f'<node id="{key[1:]}" lon="{_coordinate(row[0])}" lat="{_coordinate(row[1])}"/>\n')
                    elif prefix == "w":
                        row = connection.execute("SELECT tags_json, nodes_json FROM ways WHERE object_key = ?", (key,)).fetchone()
                        if row is None:
                            raise BuildingSourceIndexError("building_relation_incomplete", f"missing indexed way {key}")
                        tags, nodes = json.loads(row[0]), json.loads(row[1])
                        output.write(f'<way id="{key[1:]}">\n')
                        for node in nodes:
                            output.write(f'<nd ref="{node["key"][1:]}"/>\n')
                        for tag, value in sorted(tags.items()):
                            output.write(f'<tag k={quoteattr(tag)} v={quoteattr(value)}/>\n')
                        output.write('</way>\n')
                    else:
                        row = connection.execute("SELECT tags_json, members_json FROM relations WHERE object_key = ?", (key,)).fetchone()
                        if row is None:
                            raise BuildingSourceIndexError("building_relation_incomplete", f"missing indexed relation {key}")
                        tags, members = json.loads(row[0]), json.loads(row[1])
                        output.write(f'<relation id="{key[1:]}">\n')
                        for member in members:
                            object_type = {"n": "node", "w": "way", "r": "relation"}[member["type"]]
                            output.write(f'<member type="{object_type}" ref="{member["key"][1:]}" role={quoteattr(member["role"])}/>\n')
                        for tag, value in sorted(tags.items()):
                            output.write(f'<tag k={quoteattr(tag)} v={quoteattr(value)}/>\n')
                        output.write('</relation>\n')
            output.write('</osm>\n')
            output.flush()
            os.fsync(output.fileno())
        index.verify_database_unchanged()
        os.replace(staged, output_xml)
        staged = None
        return {"requested": sum(map(len, wanted.values())), "missing": sum(map(len, missing.values()))}
    finally:
        connection.close()
        if staged is not None:
            staged.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-index-manifest", type=Path, required=True)
    parser.add_argument("--closure-plan", type=Path, required=True)
    parser.add_argument("--clipped-pbf", type=Path, required=True)
    parser.add_argument("--output-xml", type=Path, required=True)
    args = parser.parse_args()
    result = export_closure(args.source_index_manifest, args.closure_plan, args.clipped_pbf, args.output_xml)
    print("BUILDING_CLOSURE_EXPORT:" + json.dumps(result, sort_keys=True, separators=(",", ":")))


if __name__ == "__main__":
    main()
