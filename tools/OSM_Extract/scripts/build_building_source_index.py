#!/usr/bin/env python3
"""Build the immutable relation/geometry index for one OSM source snapshot."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import signal
import sqlite3
import sys

from building_source_index import (
    BuildingSourceIndex,
    BuildingSourceIndexError,
    canonical_json,
    file_sha256,
    initialize_source_index_database,
)


PYOSMIUM_LOCATION_INDEX_TYPE = "sparse_file_array"


class SourceIndexTermination(BaseException):
    """Cooperative process termination that still executes cleanup handlers."""


def _terminate_source_index(_signum, _frame):
    raise SourceIndexTermination()


def scan_source(path: Path, spool_path: Path) -> None:
    try:
        import osmium
    except ImportError as exc:  # pragma: no cover - container dependency
        raise RuntimeError("pyosmium is required to build the source index") from exc

    connection = sqlite3.connect(spool_path)
    try:
        initialize_source_index_database(connection)
        connection.executescript(
            """
            CREATE TABLE raw_relations (
                relation_id INTEGER PRIMARY KEY,
                tags_json TEXT NOT NULL,
                members_json TEXT NOT NULL,
                seed INTEGER NOT NULL,
                eligible_parent INTEGER NOT NULL
            );
            CREATE TABLE raw_relation_members (
                relation_id INTEGER NOT NULL,
                member_index INTEGER NOT NULL,
                member_type TEXT NOT NULL,
                member_ref INTEGER NOT NULL,
                role TEXT NOT NULL,
                PRIMARY KEY (relation_id, member_index)
            );
            CREATE INDEX raw_relation_member_lookup
                ON raw_relation_members(member_type, member_ref);
            CREATE TABLE tagged_ways (way_id INTEGER PRIMARY KEY);
            CREATE TABLE selected_relations (relation_id INTEGER PRIMARY KEY);
            """
        )

        class RelationPass(osmium.SimpleHandler):
            def relation(self, relation):
                tags = {tag.k: tag.v for tag in relation.tags}
                members = [
                    {
                        "type": member.type,
                        "key": f"{member.type}{member.ref}",
                        "role": member.role,
                    }
                    for member in relation.members
                    if member.type in {"n", "w", "r"}
                ]
                seed = (
                    tags.get("type") == "building"
                    or tags.get("building") not in (None, "", "no")
                    or tags.get("building:part") not in (None, "", "no")
                )
                eligible_parent = seed or tags.get("type") == "multipolygon"
                connection.execute(
                    "INSERT INTO raw_relations VALUES (?, ?, ?, ?, ?)",
                    (
                        relation.id,
                        canonical_json(tags).decode("utf-8"),
                        canonical_json(members).decode("utf-8"),
                        int(seed),
                        int(eligible_parent),
                    ),
                )
                connection.executemany(
                    "INSERT INTO raw_relation_members VALUES (?, ?, ?, ?, ?)",
                    (
                        (relation.id, index, member.type, member.ref, member.role)
                        for index, member in enumerate(relation.members)
                        if member.type in {"n", "w", "r"}
                    ),
                )

        RelationPass().apply_file(str(path))
        connection.commit()

        class TaggedWayPass(osmium.SimpleHandler):
            def way(self, way):
                tags = {tag.k: tag.v for tag in way.tags}
                if (
                    tags.get("building") not in (None, "", "no")
                    or tags.get("building:part") not in (None, "", "no")
                ):
                    connection.execute(
                        "INSERT OR IGNORE INTO tagged_ways VALUES (?)", (way.id,)
                    )

        TaggedWayPass().apply_file(str(path))
        connection.commit()
        connection.execute(
            "INSERT OR IGNORE INTO selected_relations SELECT relation_id FROM raw_relations WHERE seed = 1"
        )
        connection.execute(
            """
            INSERT OR IGNORE INTO selected_relations
            SELECT DISTINCT member.relation_id
            FROM raw_relation_members member
            JOIN tagged_ways way ON member.member_type = 'w' AND member.member_ref = way.way_id
            JOIN raw_relations relation ON relation.relation_id = member.relation_id
            WHERE relation.eligible_parent = 1
            """
        )
        while True:
            before = connection.total_changes
            connection.execute(
                """
                INSERT OR IGNORE INTO selected_relations
                SELECT member.member_ref
                FROM raw_relation_members member
                JOIN selected_relations selected ON selected.relation_id = member.relation_id
                JOIN raw_relations child ON child.relation_id = member.member_ref
                WHERE member.member_type = 'r'
                """
            )
            connection.execute(
                """
                INSERT OR IGNORE INTO selected_relations
                SELECT member.relation_id
                FROM raw_relation_members member
                JOIN selected_relations selected ON selected.relation_id = member.member_ref
                JOIN raw_relations parent ON parent.relation_id = member.relation_id
                WHERE member.member_type = 'r' AND parent.eligible_parent = 1
                """
            )
            if connection.total_changes == before:
                break
        connection.commit()

        connection.execute(
            """
            INSERT INTO relations
            SELECT 'r' || relation.relation_id,
                   relation.tags_json,
                   relation.members_json,
                   '[]'
            FROM raw_relations relation
            JOIN selected_relations selected ON selected.relation_id = relation.relation_id
            ORDER BY relation.relation_id
            """
        )
        connection.execute(
            """
            INSERT INTO relation_members
            SELECT 'r' || member.relation_id,
                   member.member_index,
                   member.member_type,
                   member.member_type || member.member_ref,
                   member.role
            FROM raw_relation_members member
            JOIN selected_relations selected ON selected.relation_id = member.relation_id
            ORDER BY member.relation_id, member.member_index
            """
        )
        referenced_ways = {
            row[0]
            for row in connection.execute(
                """
                SELECT DISTINCT member.member_ref
                FROM raw_relation_members member
                JOIN selected_relations selected ON selected.relation_id = member.relation_id
                WHERE member.member_type = 'w'
                """
            )
        }
        referenced_nodes = {
            row[0]
            for row in connection.execute(
                """
                SELECT DISTINCT member.member_ref
                FROM raw_relation_members member
                JOIN selected_relations selected ON selected.relation_id = member.relation_id
                WHERE member.member_type = 'n'
                """
            )
        }
        class GeometryPass(osmium.SimpleHandler):
            def node(self, node):
                if node.id not in referenced_nodes:
                    return
                if not node.location.valid():
                    raise BuildingSourceIndexError(
                        "building_relation_incomplete",
                        f"source node n{node.id} has no location",
                    )
                connection.execute(
                    "INSERT OR REPLACE INTO nodes VALUES (?, ?, ?)",
                    (
                        f"n{node.id}",
                        round(node.location.lon * 10_000_000),
                        round(node.location.lat * 10_000_000),
                    ),
                )

            def way(self, way):
                tags = {tag.k: tag.v for tag in way.tags}
                if (
                    way.id not in referenced_ways
                    and tags.get("building") in (None, "", "no")
                    and tags.get("building:part") in (None, "", "no")
                ):
                    return
                way_nodes = []
                for node in way.nodes:
                    if not node.location.valid():
                        raise BuildingSourceIndexError(
                            "building_relation_incomplete",
                            f"source way w{way.id} node n{node.ref} has no location",
                        )
                    record = {
                        "key": f"n{node.ref}",
                        "lonE7": round(node.location.lon * 10_000_000),
                        "latE7": round(node.location.lat * 10_000_000),
                    }
                    way_nodes.append(record)
                    connection.execute(
                        "INSERT OR IGNORE INTO nodes VALUES (?, ?, ?)",
                        (record["key"], record["lonE7"], record["latE7"]),
                    )
                bounds = [
                    min(node[axis] for node in way_nodes)
                    for axis in ("lonE7", "latE7")
                ] + [
                    max(node[axis] for node in way_nodes)
                    for axis in ("lonE7", "latE7")
                ]
                connection.execute(
                    "INSERT INTO ways VALUES (?, ?, ?, ?)",
                    (
                        f"w{way.id}",
                        canonical_json(tags).decode("utf-8"),
                        canonical_json(way_nodes).decode("utf-8"),
                        json.dumps(bounds, separators=(",", ":")),
                    ),
                )

        location_index = Path(f"{spool_path}.locations")
        try:
            GeometryPass().apply_file(
                str(path),
                locations=True,
                idx=f"{PYOSMIUM_LOCATION_INDEX_TYPE},{location_index}",
            )
        finally:
            location_index.unlink(missing_ok=True)
        connection.executescript(
            """
            DROP TABLE raw_relation_members;
            DROP TABLE raw_relations;
            DROP TABLE tagged_ways;
            DROP TABLE selected_relations;
            """
        )
        connection.commit()
    finally:
        connection.close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-pbf", type=Path)
    parser.add_argument("--source-sha256", required=True)
    parser.add_argument("--cache-root", type=Path, required=True)
    parser.add_argument("--result-json", type=Path)
    parser.add_argument("--cleanup-unpublished", action="store_true")
    parser.add_argument("--lock-timeout-seconds", type=float)
    args = parser.parse_args()
    index = BuildingSourceIndex(args.cache_root, args.source_sha256)
    if args.cleanup_unpublished:
        index.cleanup_unpublished_scans(
            lock_timeout_seconds=args.lock_timeout_seconds
        )
        return
    if args.source_pbf is None:
        parser.error("--source-pbf is required unless --cleanup-unpublished is used")
    print(
        'BUILDING_PREPROCESS_PROGRESS:{"completed":0,"indeterminate":true,"unit":"source_index"}',
        flush=True,
    )
    try:
        source_before = file_sha256(args.source_pbf)
    except OSError as exc:
        raise BuildingSourceIndexError(
            "building_source_snapshot_changed", "source snapshot is unavailable"
        ) from exc
    if source_before != args.source_sha256:
        raise BuildingSourceIndexError(
            "building_source_snapshot_changed", "source changed before indexing"
        )
    def scanner(spool_path):
        scan_source(args.source_pbf, spool_path)
        if file_sha256(args.source_pbf) != args.source_sha256:
            raise BuildingSourceIndexError(
                "building_source_snapshot_changed", "source changed during indexing"
            )

    manifest = index.build_with_scanner(scanner)
    if file_sha256(args.source_pbf) != args.source_sha256:
        raise BuildingSourceIndexError(
            "building_source_snapshot_changed",
            "source changed before source-index result publication",
        )
    result = {
        key: value
        for key, value in manifest.items()
        if key not in {"manifestSha256"}
    }
    result["manifestPath"] = str(index.manifest_path)
    if args.result_json:
        args.result_json.write_text(json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n")
    public = {key: value for key, value in result.items() if key != "manifestPath"}
    print("BUILDING_SOURCE_INDEX_STATS:" + json.dumps(public, sort_keys=True, separators=(",", ":")))
    print(
        'BUILDING_PREPROCESS_PROGRESS:{"completed":1,"indeterminate":false,"total":1,"unit":"source_index"}',
        flush=True,
    )


if __name__ == "__main__":
    previous_sigterm_handler = signal.signal(signal.SIGTERM, _terminate_source_index)
    try:
        main()
    except SourceIndexTermination:
        raise SystemExit(143)
    except BuildingSourceIndexError as exc:
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
                    "code": "building_relation_incomplete",
                    "message": "source-index preprocessing failed",
                },
                sort_keys=True,
                separators=(",", ":"),
            ),
            file=sys.stderr,
            flush=True,
        )
        raise SystemExit(2) from exc
    finally:
        signal.signal(signal.SIGTERM, previous_sigterm_handler)
