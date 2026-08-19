#!/usr/bin/env python
"""Index explicit OSM type=building outline/part relationships."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sqlite3

import osmium

from building_calibration_cache import canonical_json
from building_source_index import BuildingSourceIndex, BuildingSourceIndexError
from build_building_closure import output_bounds_e7


def member_key(member) -> str:
    return f"{member.type}{member.ref}"


class BuildingRelationHandler(osmium.SimpleHandler):
    def __init__(self, *, expected_closure: dict | None = None) -> None:
        super().__init__()
        self.audit_enabled = expected_closure is not None
        self.required_relations = set((expected_closure or {}).get("requiredRelationKeys", ()))
        self.required_ways = set((expected_closure or {}).get("requiredWayKeys", ()))
        self.required_nodes = set((expected_closure or {}).get("requiredNodeKeys", ()))
        self.part_parents: dict[str, str] = {}
        self.parent_tags: dict[str, dict[str, str]] = {}
        self.relations = 0
        self.ambiguous_parts = 0
        self.seen_nodes: set[str] = set()
        self.way_nodes: dict[str, list[str]] = {}
        self.building_ways: set[str] = set()
        self.relation_members: dict[str, list[dict[str, str]]] = {}
        self.building_relations: set[str] = set()
        self.way_tags: dict[str, dict[str, str]] = {}
        self.part_parent_candidates: dict[str, set[str]] = {}
        self.parts_without_outline: set[str] = set()
        # Keep the relation identity alongside the legacy part set. The set is
        # used for closure intersection; this detail map makes a fail-closed
        # source diagnostic actionable without dumping a whole relation/PBF.
        self.incomplete_relation_parts: dict[str, tuple[str, ...]] = {}
        self.standalone_part_keys: set[str] = set()

    def node(self, node) -> None:
        key = f"n{node.id}"
        if self.audit_enabled and key in self.required_nodes:
            self.seen_nodes.add(key)

    def way(self, way) -> None:
        if not self.audit_enabled:
            return
        key = f"w{way.id}"
        if key not in self.required_ways:
            return
        self.way_nodes[key] = [f"n{node.ref}" for node in way.nodes]
        self.way_tags[key] = dict(sorted((tag.k, tag.v) for tag in way.tags))
        if (
            way.tags.get("building") not in (None, "", "no")
            or way.tags.get("building:part") not in (None, "", "no")
        ):
            self.building_ways.add(key)

    def relation(self, relation) -> None:
        relation_key = f"r{relation.id}"
        relation_tags = {tag.k: tag.v for tag in relation.tags}
        if self.audit_enabled:
            if relation_key not in self.required_relations:
                return
            self.relation_members[relation_key] = [
                {"type": member.type, "key": member_key(member), "role": member.role}
                for member in relation.members
                if member.type in {"n", "w", "r"}
            ]
            if is_building_relation(relation_tags):
                self.building_relations.add(relation_key)
        if relation.tags.get("type") != "building":
            return
        outlines = sorted(
            member_key(member)
            for member in relation.members
            if member.role == "outline" and member.type in {"w", "r"}
        )
        if not outlines:
            outer_aliases = sorted(
                member_key(member)
                for member in relation.members
                if member.role == "outer" and member.type in {"w", "r"}
            )
            # Some real-world type=building relations use multipolygon-style
            # roles. A single outer is an unambiguous outline alias; multiple
            # outers may be ring fragments or separate outlines and must keep
            # failing closed instead of selecting an arbitrary parent.
            if len(outer_aliases) == 1:
                outlines = outer_aliases
        parts = sorted(
            member_key(member)
            for member in relation.members
            if member.role in {"part", "building:part"}
            and member.type in {"w", "r"}
        )
        if not outlines or not parts:
            if self.audit_enabled and parts and not outlines:
                self.parts_without_outline.update(parts)
                self.incomplete_relation_parts[relation_key] = tuple(parts)
            return
        self.relations += 1
        parent = outlines[0]
        existing_parent_tags = self.parent_tags.get(parent)
        canonical_parent_tags = dict(sorted(relation_tags.items()))
        if (
            existing_parent_tags is not None
            and existing_parent_tags != canonical_parent_tags
        ):
            self.ambiguous_parts += 1
        else:
            self.parent_tags[parent] = canonical_parent_tags
        for part in parts:
            if self.audit_enabled:
                self.part_parent_candidates.setdefault(part, set()).update(outlines)
            existing = self.part_parents.get(part)
            if existing is not None and existing != parent:
                self.ambiguous_parts += 1
                self.part_parents[part] = min(existing, parent)
            else:
                self.part_parents[part] = parent

    def finalize(self) -> None:
        """Apply the narrow standalone-part normalization after all ways arrive.

        OSM objects are normally delivered ways before relations, but the
        policy must not depend on callback order. Only a single direct way
        member with an explicit ``building`` tag qualifies. Any part shared
        with another malformed relation remains fail-closed rather than being
        silently reinterpreted.
        """

        qualified_relations = {
            relation_key
            for relation_key, parts in self.incomplete_relation_parts.items()
            if len(parts) == 1
            and parts[0].startswith("w")
            and self.way_tags.get(parts[0], {}).get("building")
            not in (None, "", "no")
        }
        unsafe_parts = {
            part
            for relation_key, parts in self.incomplete_relation_parts.items()
            if relation_key not in qualified_relations
            for part in parts
        }
        self.standalone_part_keys = {
            part
            for relation_key in qualified_relations
            for part in self.incomplete_relation_parts[relation_key]
            if part not in unsafe_parts
        }
        self.parts_without_outline.difference_update(self.standalone_part_keys)


def load_scope_policy(path: Path) -> dict:
    try:
        value = json.loads(path.read_bytes())
        digest = value.pop("scopePlanSha256")
    except (OSError, TypeError, ValueError, KeyError) as exc:
        raise BuildingSourceIndexError(
            "building_scope_policy_invalid", "scope plan is unavailable"
        ) from exc
    if (
        hashlib.sha256(canonical_json(value)).hexdigest() != digest
        or value.get("schemaVersion") != 1
        or value.get("policy", {}).get("relationClosureMode")
        != "source_snapshot_index"
    ):
        raise BuildingSourceIndexError(
            "building_scope_policy_invalid", "scope plan identity is invalid"
        )
    maximum = value["policy"].get("maxRelationObjectsPerJob")
    if isinstance(maximum, bool) or not isinstance(maximum, int) or maximum <= 0:
        raise BuildingSourceIndexError(
            "building_scope_policy_invalid", "scope relation limit is invalid"
        )
    calibration = value.get("calibration", {})
    return {
        "scopePlanSha256": digest,
        "maximumObjects": maximum,
        "outputBoundsE7": output_bounds_e7(value),
        "calibrationCellSizeMeters": calibration.get("cellSizeMeters"),
        "calibrationHaloCells": calibration.get("haloCells"),
    }


def load_source_index_manifest(path: str | Path) -> BuildingSourceIndex:
    """Open a sealed source index without rescanning its database.

    The source-index builder validates and seals the database before
    publishing this manifest. Chunk workers verify the manifest identity and
    reuse it; calling ``validate()`` here would hash and audit the
    multi-gigabyte SQLite database once per chunk.
    """

    return BuildingSourceIndex.from_manifest(path, validate_database=False)


def audit_closure(
    handler: BuildingRelationHandler,
    index: BuildingSourceIndex,
    scope_policy: dict,
    relation_retry_count: int,
    expected: dict | None = None,
) -> dict[str, int | str]:
    connection = sqlite3.connect(f"file:{index.database_path}?mode=ro", uri=True)
    try:
        expected = expected or index.closure_for_bounds(
                scope_policy["outputBoundsE7"],
                maximum_objects=scope_policy["maximumObjects"],
                calibration_cell_size_meters=scope_policy["calibrationCellSizeMeters"],
                calibration_halo_cells=scope_policy["calibrationHaloCells"],
            )
        required_relations = set(expected["requiredRelationKeys"])
        required_ways = set(expected["requiredWayKeys"])
        required_nodes = set(expected["requiredNodeKeys"])
        ambiguous_parts = {
            part
            for part, parents in handler.part_parent_candidates.items()
            if len(parents) != 1 and part in required_ways | required_relations
        }
        missing_parent_parts = handler.parts_without_outline.intersection(
            required_ways | required_relations
        )
        if ambiguous_parts or missing_parent_parts:
            incomplete_relations = [
                (relation_key, handler.incomplete_relation_parts[relation_key])
                for relation_key in sorted(handler.incomplete_relation_parts)
                if set(handler.incomplete_relation_parts[relation_key])
                & (required_ways | required_relations)
            ]
            if incomplete_relations:
                relation_key, parts = incomplete_relations[0]
                detail = (
                    f"source relation {relation_key} has part members but no outline"
                )
                if parts:
                    detail += f" ({','.join(parts[:8])}"
                    if len(parts) > 8:
                        detail += ",..."
                    detail += ")"
                raise BuildingSourceIndexError(
                    "building_relation_incomplete",
                    detail,
                )
            raise BuildingSourceIndexError(
                "building_relation_incomplete",
                "output building relation has ambiguous or missing explicit parents",
            )
        for relation_key, members_json in _closure_rows(
            connection,
            table="relations",
            value_column="members_json",
            keys=required_relations,
        ):
            if members_json is None:
                raise BuildingSourceIndexError(
                    "building_relation_incomplete", f"source relation {relation_key} is unavailable"
                )
            source_members = json.loads(members_json)
            if handler.relation_members.get(relation_key) != source_members:
                raise BuildingSourceIndexError(
                    "building_relation_incomplete", f"source relation {relation_key} is incomplete"
                )

        for way_key, nodes_json in _closure_rows(
            connection,
            table="ways",
            value_column="nodes_json",
            keys=required_ways,
        ):
            if nodes_json is None:
                raise BuildingSourceIndexError(
                    "building_relation_incomplete", f"source way {way_key} is unavailable"
                )
            source_nodes = [node["key"] for node in json.loads(nodes_json)]
            if handler.way_nodes.get(way_key) != source_nodes:
                raise BuildingSourceIndexError(
                    "building_relation_incomplete", f"source way {way_key} is incomplete"
                )
            if not set(source_nodes).issubset(required_nodes):
                raise BuildingSourceIndexError(
                    "building_relation_incomplete", f"source way {way_key} node closure is invalid"
                )
        missing_nodes = required_nodes.difference(handler.seen_nodes)
        if missing_nodes:
            raise BuildingSourceIndexError(
                "building_relation_incomplete", "source closure has missing nodes"
            )
        return {
            "closureRelationCount": len(required_relations),
            "closureWayCount": len(required_ways),
            "closureNodeCount": len(required_nodes),
            "relationRetryCount": relation_retry_count,
            "candidateCount": len(expected["candidateKeys"]),
            "sourceIndexKey": index.index_key,
            "sourceSnapshotSha256": index.source_snapshot_sha256,
            "scopePlanSha256": scope_policy["scopePlanSha256"],
        }
    finally:
        connection.close()


def _closure_rows(
    connection: sqlite3.Connection,
    *,
    table: str,
    value_column: str,
    keys: set[str],
    batch_size: int = 500,
):
    """Yield closure rows using bounded ``IN`` queries instead of N+1 reads."""

    if table not in {"relations", "ways"} or value_column not in {
        "members_json",
        "nodes_json",
    }:
        raise ValueError("invalid closure row selector")
    ordered_keys = tuple(sorted(keys))
    for offset in range(0, len(ordered_keys), batch_size):
        batch = ordered_keys[offset : offset + batch_size]
        placeholders = ",".join("?" for _ in batch)
        rows = connection.execute(
            f"SELECT object_key, {value_column} FROM {table} "
            f"WHERE object_key IN ({placeholders}) ORDER BY object_key",
            batch,
        ).fetchall()
        values = {row[0]: row[1] for row in rows}
        for key in batch:
            yield key, values.get(key)


def is_building_relation(tags: dict[str, str]) -> bool:
    return (
        tags.get("type") == "building"
        or tags.get("building") not in (None, "", "no")
        or tags.get("building:part") not in (None, "", "no")
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("pbf")
    parser.add_argument("output")
    parser.add_argument("--source-index-manifest")
    parser.add_argument("--scope-plan")
    parser.add_argument("--relation-retry-count", type=int, default=0)
    args = parser.parse_args()
    closure_audit = None
    if bool(args.source_index_manifest) != bool(args.scope_plan):
        raise BuildingSourceIndexError(
            "building_scope_policy_invalid",
            "source index manifest and scope plan must be supplied together",
        )
    if args.relation_retry_count < 0 or (
        args.relation_retry_count and not args.source_index_manifest
    ):
        raise BuildingSourceIndexError(
            "building_scope_policy_invalid", "relation retry count is invalid"
        )
    index = None
    scope_policy = None
    expected = None
    if args.source_index_manifest:
        index = load_source_index_manifest(args.source_index_manifest)
        scope_policy = load_scope_policy(Path(args.scope_plan))
        expected = index.closure_for_bounds(
            scope_policy["outputBoundsE7"],
            maximum_objects=scope_policy["maximumObjects"],
            calibration_cell_size_meters=scope_policy["calibrationCellSizeMeters"],
            calibration_halo_cells=scope_policy["calibrationHaloCells"],
        )
    handler = BuildingRelationHandler(expected_closure=expected)
    handler.apply_file(args.pbf, locations=False)
    handler.finalize()
    if index is not None:
        closure_audit = audit_closure(
            handler,
            index,
            scope_policy,
            args.relation_retry_count,
            expected,
        )
    result = {
        "schemaVersion": 1,
        "partParents": dict(sorted(handler.part_parents.items())),
        "parentTags": dict(sorted(handler.parent_tags.items())),
        "relations": handler.relations,
        "ambiguousParts": handler.ambiguous_parts,
    }
    if handler.standalone_part_keys:
        result["standalonePartKeys"] = sorted(handler.standalone_part_keys)
    if closure_audit is not None:
        result["closureAudit"] = closure_audit
    Path(args.output).write_text(
        json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    try:
        main()
    except BuildingSourceIndexError as exc:
        print(
            "BUILDING_PREPROCESS_FAILURE:"
            + json.dumps(
                {"code": exc.code, "message": str(exc)},
                sort_keys=True,
                separators=(",", ":"),
            ),
            flush=True,
        )
        raise SystemExit(2) from exc
