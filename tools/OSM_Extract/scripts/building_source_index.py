"""Immutable SQLite index of source-snapshot building geometry and relations."""

from __future__ import annotations

import hashlib
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import tempfile
from typing import Any, Iterable
import uuid

from building_calibration_cache import (
    CalibrationCacheError,
    _CacheLock,
    atomic_write_json,
    canonical_json,
)


SOURCE_INDEX_SCHEMA_VERSION = 1
SOURCE_INDEX_ALGORITHM_VERSION = 2
SOURCE_INDEX_CREATION_TOOL = "open-bike-building-source-index"
SOURCE_INDEX_MAX_RELATION_DEPTH = 256
_SHA256 = re.compile(r"[0-9a-f]{64}")
_OBJECT_KEY = re.compile(r"[nwr][0-9]+")
_EARTH_RADIUS_METERS = 6_378_137


class BuildingSourceIndexError(RuntimeError):
    def __init__(self, code: str, message: str):
        self.code = code
        super().__init__(message)


def _building_tags(tags: dict[str, str]) -> bool:
    return (
        tags.get("type") == "building"
        or tags.get("building") not in (None, "", "no")
        or tags.get("building:part") not in (None, "", "no")
    )


def _eligible_building_parent(tags: dict[str, str]) -> bool:
    return _building_tags(tags) or tags.get("type") == "multipolygon"


def _bounds_intersect_any(bounds, rectangles) -> bool:
    return any(
        bounds[0] <= rectangle[2]
        and bounds[2] >= rectangle[0]
        and bounds[1] <= rectangle[3]
        and bounds[3] >= rectangle[1]
        for rectangle in rectangles
    )


def _lon_e7_to_x(value: int) -> float:
    return math.radians(value / 10_000_000) * _EARTH_RADIUS_METERS


def _lat_e7_to_y(value: int) -> float:
    latitude = max(-85.05112878, min(85.05112878, value / 10_000_000))
    return (
        math.log(math.tan(math.radians(latitude) / 2 + math.pi / 4))
        * _EARTH_RADIUS_METERS
    )


class BuildingSourceIndex:
    def __init__(self, root: str | Path, source_snapshot_sha256: str):
        if not _SHA256.fullmatch(str(source_snapshot_sha256 or "")):
            raise BuildingSourceIndexError("building_source_snapshot_changed", "source index snapshot identity is invalid")
        self.root = Path(root)
        self.source_snapshot_sha256 = source_snapshot_sha256
        self.identity = {
            "schemaVersion": SOURCE_INDEX_SCHEMA_VERSION,
            "algorithmVersion": SOURCE_INDEX_ALGORITHM_VERSION,
            "creationTool": SOURCE_INDEX_CREATION_TOOL,
            "sourceSnapshotSha256": source_snapshot_sha256,
        }
        self.index_key = hashlib.sha256(canonical_json(self.identity)).hexdigest()
        self.index_root = (
            self.root
            / f"building-source-index-v{SOURCE_INDEX_SCHEMA_VERSION}"
            / source_snapshot_sha256
            / self.index_key
        )
        self.database_path = self.index_root / "index.sqlite"
        self.manifest_path = self.index_root / "manifest.json"

    @classmethod
    def from_manifest(
        cls,
        path: str | Path,
        *,
        validate_database: bool = True,
    ) -> "BuildingSourceIndex":
        path = Path(path)
        try:
            raw = json.loads(path.read_bytes())
            value = dict(raw)
            digest = value.pop("manifestSha256")
            source_sha256 = value["sourceSnapshotSha256"]
        except (OSError, TypeError, ValueError, KeyError) as exc:
            raise BuildingSourceIndexError(
                "building_relation_incomplete", "source index manifest is unavailable"
            ) from exc
        index = cls(path.parent, source_sha256)
        index.index_root = path.parent
        index.database_path = path.parent / "index.sqlite"
        index.manifest_path = path
        if value.get("indexKey") != index.index_key:
            raise BuildingSourceIndexError(
                "building_relation_incomplete", "source index manifest key is invalid"
            )
        index._validate_manifest_document(value, digest)
        if validate_database:
            index.validate()
        return index

    def _validate_manifest_document(self, manifest, digest: str) -> None:
        expected_manifest_keys = set(self.identity) | {
            "indexKey",
            "databaseSha256",
            "nodeCount",
            "wayCount",
            "relationCount",
            "relationMemberCount",
        }
        if (
            set(manifest) != expected_manifest_keys
            or not _SHA256.fullmatch(str(digest))
            or hashlib.sha256(canonical_json(manifest)).hexdigest() != digest
            or any(manifest.get(key) != value for key, value in self.identity.items())
            or manifest.get("indexKey") != self.index_key
            or not _SHA256.fullmatch(str(manifest.get("databaseSha256") or ""))
            or any(
                isinstance(manifest.get(key), bool)
                or not isinstance(manifest.get(key), int)
                or manifest.get(key) < 0
                for key in (
                    "nodeCount",
                    "wayCount",
                    "relationCount",
                    "relationMemberCount",
                )
            )
        ):
            raise BuildingSourceIndexError(
                "building_relation_incomplete", "source index manifest is invalid"
            )

    def validate(self) -> dict[str, Any]:
        try:
            manifest = json.loads(self.manifest_path.read_bytes())
            digest = manifest.pop("manifestSha256")
        except (OSError, ValueError, KeyError) as exc:
            raise BuildingSourceIndexError("building_relation_incomplete", "source index manifest is unavailable") from exc
        try:
            database_sha256 = file_sha256(self.database_path)
        except OSError as exc:
            raise BuildingSourceIndexError("building_relation_incomplete", "source index database is unavailable") from exc
        self._validate_manifest_document(manifest, digest)
        if manifest.get("databaseSha256") != database_sha256:
            raise BuildingSourceIndexError("building_relation_incomplete", "source index identity is invalid")
        try:
            connection = sqlite3.connect(f"file:{self.database_path}?mode=ro", uri=True)
            metadata = dict(connection.execute("SELECT key, value FROM metadata"))
            counts = verify_source_index_database(
                connection, repair_relation_bounds=False
            )
        except BuildingSourceIndexError:
            raise
        except (AttributeError, OSError, sqlite3.Error, TypeError, ValueError) as exc:
            raise BuildingSourceIndexError("building_relation_incomplete", "source index database is invalid") from exc
        finally:
            if "connection" in locals():
                connection.close()
        if any(manifest.get(key) != value for key, value in counts.items()):
            raise BuildingSourceIndexError("building_relation_incomplete", "source index has incomplete relation members")
        expected_metadata = {
            "sourceSnapshotSha256": self.source_snapshot_sha256,
            "indexKey": self.index_key,
            "schemaVersion": str(SOURCE_INDEX_SCHEMA_VERSION),
            "algorithmVersion": str(SOURCE_INDEX_ALGORITHM_VERSION),
        }
        if metadata != expected_metadata:
            raise BuildingSourceIndexError("building_relation_incomplete", "source index metadata is invalid")
        return {**manifest, "manifestSha256": digest}

    def validate_manifest_only(self) -> dict[str, Any]:
        """Validate the immutable manifest without rescanning its database."""
        try:
            manifest = json.loads(self.manifest_path.read_bytes())
            digest = manifest.pop("manifestSha256")
        except (OSError, TypeError, ValueError, KeyError) as exc:
            raise BuildingSourceIndexError(
                "building_relation_incomplete", "source index manifest is unavailable"
            ) from exc
        self._validate_manifest_document(manifest, digest)
        if not self.database_path.is_file():
            raise BuildingSourceIndexError(
                "building_relation_incomplete", "source index database is unavailable"
            )
        return {**manifest, "manifestSha256": digest}

    def build(
        self,
        *,
        nodes: Iterable[dict[str, Any]],
        ways: Iterable[dict[str, Any]],
        relations: Iterable[dict[str, Any]],
        lock_timeout_seconds: float | None = None,
    ) -> dict[str, Any]:
        try:
            self.index_root.mkdir(parents=True, exist_ok=True)
            with _CacheLock(self.index_root / ".write.lock", timeout_seconds=lock_timeout_seconds):
                existing = self._validate_or_quarantine_locked()
                if existing is not None:
                    return existing
                return self._build_locked(nodes=nodes, ways=ways, relations=relations)
        except BuildingSourceIndexError:
            raise
        except CalibrationCacheError as exc:
            raise BuildingSourceIndexError(
                "building_relation_incomplete", "timed out waiting for source index lock"
            ) from exc
        except (OSError, sqlite3.Error, ValueError, TypeError) as exc:
            raise BuildingSourceIndexError("building_relation_incomplete", "source index build failed") from exc

    def closure_for_bounds(
        self,
        bounds_e7: Iterable[tuple[int, int, int, int]],
        *,
        maximum_objects: int,
        calibration_cell_size_meters: int,
        calibration_halo_cells: int,
    ) -> dict[str, Any]:
        rectangles = tuple(sorted(set(bounds_e7)))
        if (
            not rectangles
            or isinstance(maximum_objects, bool)
            or not isinstance(maximum_objects, int)
            or maximum_objects <= 0
            or calibration_cell_size_meters <= 0
            or not 0 <= calibration_halo_cells <= 8
        ):
            raise BuildingSourceIndexError(
                "building_scope_policy_invalid", "building closure policy is invalid"
            )
        for rectangle in rectangles:
            if (
                len(rectangle) != 4
                or any(isinstance(value, bool) or not isinstance(value, int) for value in rectangle)
                or rectangle[2] < rectangle[0]
                or rectangle[3] < rectangle[1]
            ):
                raise BuildingSourceIndexError(
                    "building_scope_policy_invalid", "building closure bounds are invalid"
                )
        connection = sqlite3.connect(f"file:{self.database_path}?mode=ro", uri=True)
        try:
            spatial_clause = " OR ".join(
                """(
                    CAST(json_extract(bounds_e7_json, '$[0]') AS INTEGER) <= ?
                    AND CAST(json_extract(bounds_e7_json, '$[2]') AS INTEGER) >= ?
                    AND CAST(json_extract(bounds_e7_json, '$[1]') AS INTEGER) <= ?
                    AND CAST(json_extract(bounds_e7_json, '$[3]') AS INTEGER) >= ?
                )"""
                for _ in rectangles
            )
            spatial_parameters = tuple(
                value
                for min_lon, min_lat, max_lon, max_lat in rectangles
                for value in (max_lon, min_lon, max_lat, min_lat)
            )
            building_clause = """(
                json_extract(tags_json, '$.type') = 'building'
                OR COALESCE(json_extract(tags_json, '$.building'), '') NOT IN ('', 'no')
                OR COALESCE(json_extract(tags_json, '$."building:part"'), '') NOT IN ('', 'no')
            )"""
            seed_ways = {
                key
                for key, in connection.execute(
                    f"SELECT object_key FROM ways WHERE {building_clause} AND ({spatial_clause}) ORDER BY object_key",
                    spatial_parameters,
                )
            }
            seed_relations = {
                key
                for key, in connection.execute(
                    f"SELECT object_key FROM relations WHERE {building_clause} AND ({spatial_clause}) ORDER BY object_key",
                    spatial_parameters,
                )
            }
            required_relations = set(seed_relations)
            required_ways = set(seed_ways)
            required_nodes: set[str] = set()
            pending_objects = list(sorted(seed_ways | seed_relations))
            visited_parents: set[str] = set()
            while pending_objects:
                member_key = pending_objects.pop()
                if member_key not in visited_parents:
                    visited_parents.add(member_key)
                    for parent_key, tags_json in connection.execute(
                        """
                        SELECT relation_members.relation_key, relations.tags_json
                        FROM relation_members
                        JOIN relations
                          ON relations.object_key = relation_members.relation_key
                        WHERE member_key = ? ORDER BY relation_key
                        """,
                        (member_key,),
                    ):
                        if not _eligible_building_parent(json.loads(tags_json)):
                            continue
                        if parent_key not in required_relations:
                            required_relations.add(parent_key)
                            pending_objects.append(parent_key)
                if member_key.startswith("r"):
                    relation = connection.execute(
                        "SELECT members_json FROM relations WHERE object_key = ?",
                        (member_key,),
                    ).fetchone()
                    if relation is None:
                        raise BuildingSourceIndexError(
                            "building_relation_incomplete", f"source relation {member_key} is unavailable"
                        )
                    for member in json.loads(relation[0]):
                        key = member["key"]
                        if member["type"] == "r" and key not in required_relations:
                            required_relations.add(key)
                            pending_objects.append(key)
                        elif member["type"] == "w" and key not in required_ways:
                            required_ways.add(key)
                            pending_objects.append(key)
                        elif member["type"] == "n":
                            required_nodes.add(key)
                if len(required_relations) + len(required_ways) + len(required_nodes) > maximum_objects:
                    raise BuildingSourceIndexError(
                        "building_object_limit_exceeded", "building closure exceeds the job object limit"
                    )

            for way_key in sorted(required_ways):
                way = connection.execute(
                    "SELECT nodes_json FROM ways WHERE object_key = ?", (way_key,)
                ).fetchone()
                if way is None:
                    raise BuildingSourceIndexError(
                        "building_relation_incomplete", f"source way {way_key} is unavailable"
                    )
                required_nodes.update(node["key"] for node in json.loads(way[0]))
                if len(required_relations) + len(required_ways) + len(required_nodes) > maximum_objects:
                    raise BuildingSourceIndexError(
                        "building_object_limit_exceeded", "building closure exceeds the job object limit"
                    )

            target_cells = set()
            for key in sorted(seed_ways | seed_relations):
                table = "ways" if key.startswith("w") else "relations"
                row = connection.execute(
                    f"SELECT bounds_e7_json FROM {table} WHERE object_key = ?", (key,)
                ).fetchone()
                if row is None:
                    continue
                bounds = json.loads(row[0])
                min_x = _lon_e7_to_x(bounds[0])
                min_y = _lat_e7_to_y(bounds[1])
                max_x = _lon_e7_to_x(bounds[2])
                max_y = _lat_e7_to_y(bounds[3])
                target_cells.add(
                    (
                        math.floor(((min_x + max_x) / 2) / calibration_cell_size_meters),
                        math.floor(((min_y + max_y) / 2) / calibration_cell_size_meters),
                    )
                )
            sample_cells = {
                (cell_x + dx, cell_y + dy)
                for cell_x, cell_y in target_cells
                for dx in range(-calibration_halo_cells, calibration_halo_cells + 1)
                for dy in range(-calibration_halo_cells, calibration_halo_cells + 1)
            }
            return {
                "sourceIndexKey": self.index_key,
                "sourceSnapshotSha256": self.source_snapshot_sha256,
                "candidateKeys": sorted(seed_ways | seed_relations),
                "requiredRelationKeys": sorted(required_relations),
                "requiredWayKeys": sorted(required_ways),
                "requiredNodeKeys": sorted(required_nodes),
                "calibrationTargetCells": [list(cell) for cell in sorted(target_cells)],
                "calibrationSampleCells": [list(cell) for cell in sorted(sample_cells)],
            }
        except BuildingSourceIndexError:
            raise
        except (json.JSONDecodeError, sqlite3.Error, TypeError, ValueError) as exc:
            raise BuildingSourceIndexError(
                "building_relation_incomplete", "building closure query failed"
            ) from exc
        finally:
            connection.close()

    def workload_for_bounds(
        self,
        bounds_e7: Iterable[tuple[int, int, int, int]],
        *,
        maximum_objects: int,
        calibration_cell_size_meters: int,
        calibration_halo_cells: int,
    ) -> dict[str, Any]:
        """Return exact closure counters without decoding source geometry.

        The closure ID sets are still materialized because they are the
        correctness receipt used by execution.  Geometry payloads are not
        decoded; the additional counters come from indexed JSON lengths and
        tags, making this operation suitable for planner admission.
        """

        closure = self.closure_for_bounds(
            bounds_e7,
            maximum_objects=maximum_objects,
            calibration_cell_size_meters=calibration_cell_size_meters,
            calibration_halo_cells=calibration_halo_cells,
        )
        relation_keys = tuple(closure["requiredRelationKeys"])
        way_keys = tuple(closure["requiredWayKeys"])
        node_keys = tuple(closure["requiredNodeKeys"])
        connection = sqlite3.connect(f"file:{self.database_path}?mode=ro", uri=True)
        try:
            connection.execute(
                "CREATE TEMP TABLE workload_relation_keys(object_key TEXT PRIMARY KEY)"
            )
            connection.executemany(
                "INSERT INTO workload_relation_keys(object_key) VALUES (?)",
                ((key,) for key in relation_keys),
            )
            connection.execute(
                "CREATE TEMP TABLE workload_way_keys(object_key TEXT PRIMARY KEY)"
            )
            connection.executemany(
                "INSERT INTO workload_way_keys(object_key) VALUES (?)",
                ((key,) for key in way_keys),
            )
            relation_members = 0
            if relation_keys:
                relation_members = int(
                    connection.execute(
                        """
                        SELECT COUNT(*)
                        FROM relation_members members
                        JOIN workload_relation_keys selected
                          ON selected.object_key = members.relation_key
                        """
                    ).fetchone()[0]
                )
            way_node_references = 0
            vertex_count = 0
            part_count = 0
            outline_count = 0
            if way_keys:
                rows = connection.execute(
                    """
                    SELECT ways.tags_json, ways.nodes_json
                    FROM ways
                    JOIN workload_way_keys selected
                      ON selected.object_key = ways.object_key
                    ORDER BY ways.object_key
                    """
                )
                for tags_json, nodes_json in rows:
                    tags = json.loads(tags_json)
                    nodes = json.loads(nodes_json)
                    references = len(nodes)
                    way_node_references += references
                    vertex_count += references
                    if tags.get("building:part") not in (None, "", "no"):
                        part_count += 1
                    elif _building_tags(tags):
                        outline_count += 1
            closure_body = {
                "schemaVersion": SOURCE_INDEX_SCHEMA_VERSION,
                "sourceIndexKey": self.index_key,
                "sourceSnapshotSha256": self.source_snapshot_sha256,
                "candidateKeys": closure["candidateKeys"],
                "requiredRelationKeys": relation_keys,
                "requiredWayKeys": way_keys,
                "requiredNodeKeys": node_keys,
            }
            closure_plan_sha256 = hashlib.sha256(
                canonical_json(closure_body)
            ).hexdigest()
            return {
                **closure,
                "closurePlanSha256": closure_plan_sha256,
                "relationCount": len(relation_keys),
                "wayCount": len(way_keys),
                "nodeCount": len(node_keys),
                "totalObjectCount": len(relation_keys) + len(way_keys) + len(node_keys),
                "storedRelationMemberCount": relation_members,
                "wayNodeReferenceCount": way_node_references,
                "vertexCount": vertex_count,
                "candidateOutlineCount": outline_count,
                "candidatePartCount": part_count,
                "ringCount": None,
                "holeCount": None,
            }
        except (json.JSONDecodeError, sqlite3.Error, TypeError, ValueError) as exc:
            raise BuildingSourceIndexError(
                "building_relation_incomplete", "building workload query failed"
            ) from exc
        finally:
            connection.close()

    def build_with_scanner(self, scanner, *, lock_timeout_seconds: float | None = None):
        """Run the expensive source scan once, while holding the artifact lock."""
        try:
            self.index_root.mkdir(parents=True, exist_ok=True)
            with _CacheLock(self.index_root / ".write.lock", timeout_seconds=lock_timeout_seconds):
                self._cleanup_unpublished_scans_locked()
                existing = self._validate_or_quarantine_locked(
                    validate_database=False
                )
                if existing is not None:
                    return existing
                descriptor, temporary_name = tempfile.mkstemp(
                    prefix=".scan.", suffix=".sqlite", dir=self.index_root
                )
                os.close(descriptor)
                temporary = Path(temporary_name)
                temporary.unlink()
                try:
                    scanner(temporary)
                    return self._finalize_database_locked(temporary)
                finally:
                    temporary.unlink(missing_ok=True)
        except BuildingSourceIndexError:
            raise
        except CalibrationCacheError as exc:
            raise BuildingSourceIndexError(
                "building_relation_incomplete", "timed out waiting for source index lock"
            ) from exc
        except RuntimeError as exc:
            code = (
                "building_source_snapshot_changed"
                if str(exc).startswith("building_source_snapshot_changed")
                else "building_relation_incomplete"
            )
            raise BuildingSourceIndexError(code, str(exc)) from exc
        except (OSError, sqlite3.Error, ValueError, TypeError) as exc:
            raise BuildingSourceIndexError("building_relation_incomplete", "source index build failed") from exc

    def cleanup_unpublished_scans(
        self, *, lock_timeout_seconds: float | None = None
    ) -> None:
        """Delete scan work products that were never atomically published."""
        try:
            self.index_root.mkdir(parents=True, exist_ok=True)
            with _CacheLock(
                self.index_root / ".write.lock",
                timeout_seconds=lock_timeout_seconds,
            ):
                self._cleanup_unpublished_scans_locked()
        except CalibrationCacheError as exc:
            raise BuildingSourceIndexError(
                "building_relation_incomplete",
                "timed out waiting for source index cleanup lock",
            ) from exc
        except OSError as exc:
            raise BuildingSourceIndexError(
                "building_relation_incomplete",
                "source index cleanup failed",
            ) from exc

    def _cleanup_unpublished_scans_locked(self) -> None:
        for path in self.index_root.glob(".scan.*"):
            if path.is_file() or path.is_symlink():
                path.unlink(missing_ok=True)

    def _validate_or_quarantine_locked(self, *, validate_database: bool = True):
        artifacts = (self.database_path, self.manifest_path)
        if not any(path.exists() for path in artifacts):
            return None
        if all(path.is_file() for path in artifacts):
            try:
                if validate_database:
                    return self.validate()
                return self.validate_manifest_only()
            except BuildingSourceIndexError:
                pass
        quarantine_id = uuid.uuid4().hex
        for path in artifacts:
            if path.exists():
                os.replace(path, path.with_name(f"{path.name}.corrupt-{quarantine_id}"))
        return None

    def _build_locked(self, *, nodes, ways, relations):
        normalized_nodes = sorted((_normalize_node(value) for value in nodes), key=lambda value: value["objectKey"])
        normalized_ways = sorted((_normalize_way(value) for value in ways), key=lambda value: value["objectKey"])
        normalized_relations = sorted((_normalize_relation(value) for value in relations), key=lambda value: value["objectKey"])
        _require_unique(normalized_nodes)
        _require_unique(normalized_ways)
        _require_unique(normalized_relations)
        node_by_key = {value["objectKey"]: value for value in normalized_nodes}
        node_keys = set(node_by_key)
        way_keys = {value["objectKey"] for value in normalized_ways}
        relation_keys = {value["objectKey"] for value in normalized_relations}
        for way in normalized_ways:
            if any(node["key"] not in node_keys for node in way["nodes"]):
                raise BuildingSourceIndexError("building_relation_incomplete", f"source way {way['objectKey']} has a missing node")
            if any(
                (node["lonE7"], node["latE7"])
                != (node_by_key[node["key"]]["lonE7"], node_by_key[node["key"]]["latE7"])
                for node in way["nodes"]
            ):
                raise BuildingSourceIndexError(
                    "building_relation_incomplete",
                    f"source way {way['objectKey']} has inconsistent node geometry",
                )
        for relation in normalized_relations:
            for member in relation["members"]:
                available = {"n": node_keys, "w": way_keys, "r": relation_keys}[member["type"]]
                if member["key"] not in available:
                    raise BuildingSourceIndexError("building_relation_incomplete", f"source relation {relation['objectKey']} has a missing member")
        bounds_by_key = {
            **{value["objectKey"]: [value["lonE7"], value["latE7"], value["lonE7"], value["latE7"]] for value in normalized_nodes},
            **{value["objectKey"]: value["boundsE7"] for value in normalized_ways},
        }
        unresolved = {
            value["objectKey"]: value for value in normalized_relations
        }
        for _depth in range(SOURCE_INDEX_MAX_RELATION_DEPTH + 1):
            resolved = []
            for key, relation in unresolved.items():
                if not relation["members"]:
                    raise BuildingSourceIndexError(
                        "building_relation_incomplete",
                        f"source relation {key} has no geometry members",
                    )
                if all(member["key"] in bounds_by_key for member in relation["members"]):
                    member_bounds = [
                        bounds_by_key[member["key"]] for member in relation["members"]
                    ]
                    bounds = [
                        min(value[0] for value in member_bounds),
                        min(value[1] for value in member_bounds),
                        max(value[2] for value in member_bounds),
                        max(value[3] for value in member_bounds),
                    ]
                    relation["boundsE7"] = bounds
                    bounds_by_key[key] = bounds
                    resolved.append(key)
            for key in resolved:
                del unresolved[key]
            if not unresolved:
                break
            if not resolved:
                raise BuildingSourceIndexError(
                    "building_relation_incomplete",
                    "source relation membership contains a cycle or unresolved geometry",
                )
        if unresolved:
            raise BuildingSourceIndexError(
                "building_relation_incomplete",
                f"source relation nesting exceeds {SOURCE_INDEX_MAX_RELATION_DEPTH}",
            )

        descriptor, temporary_name = tempfile.mkstemp(prefix=".index.", suffix=".sqlite", dir=self.index_root)
        os.close(descriptor)
        temporary = Path(temporary_name)
        connection = None
        try:
            connection = sqlite3.connect(temporary)
            initialize_source_index_database(connection)
            connection.executemany(
                "INSERT INTO metadata(key, value) VALUES (?, ?)",
                sorted({
                    "sourceSnapshotSha256": self.source_snapshot_sha256,
                    "indexKey": self.index_key,
                    "schemaVersion": str(SOURCE_INDEX_SCHEMA_VERSION),
                    "algorithmVersion": str(SOURCE_INDEX_ALGORITHM_VERSION),
                }.items()),
            )
            connection.executemany(
                "INSERT INTO nodes VALUES (?, ?, ?)",
                ((value["objectKey"], value["lonE7"], value["latE7"]) for value in normalized_nodes),
            )
            connection.executemany(
                "INSERT INTO ways VALUES (?, ?, ?, ?)",
                ((value["objectKey"], _text(value["tags"]), _text(value["nodes"]), _text(value["boundsE7"])) for value in normalized_ways),
            )
            connection.executemany(
                "INSERT INTO relations VALUES (?, ?, ?, ?)",
                ((value["objectKey"], _text(value["tags"]), _text(value["members"]), _text(value["boundsE7"])) for value in normalized_relations),
            )
            connection.executemany(
                "INSERT INTO relation_members VALUES (?, ?, ?, ?, ?)",
                (
                    (relation["objectKey"], index, member["type"], member["key"], member["role"])
                    for relation in normalized_relations
                    for index, member in enumerate(relation["members"])
                ),
            )
            connection.commit()
            connection.close()
            connection = None
            return self._finalize_database_locked(temporary)
        finally:
            if connection is not None:
                connection.close()
            temporary.unlink(missing_ok=True)

    def _finalize_database_locked(self, temporary: Path) -> dict[str, Any]:
        connection = sqlite3.connect(temporary)
        try:
            counts = verify_source_index_database(connection, repair_relation_bounds=True)
            connection.executemany(
                "INSERT OR REPLACE INTO metadata(key, value) VALUES (?, ?)",
                sorted(
                    {
                        "sourceSnapshotSha256": self.source_snapshot_sha256,
                        "indexKey": self.index_key,
                        "schemaVersion": str(SOURCE_INDEX_SCHEMA_VERSION),
                        "algorithmVersion": str(SOURCE_INDEX_ALGORITHM_VERSION),
                    }.items()
                ),
            )
            connection.commit()
            connection.execute("VACUUM")
        finally:
            connection.close()
        with temporary.open("rb") as source:
            os.fsync(source.fileno())
        os.replace(temporary, self.database_path)
        directory = os.open(self.index_root, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
        manifest = {
            **self.identity,
            "indexKey": self.index_key,
            "databaseSha256": file_sha256(self.database_path),
            **counts,
        }
        manifest["manifestSha256"] = hashlib.sha256(canonical_json(manifest)).hexdigest()
        atomic_write_json(self.manifest_path, manifest)
        return self.validate()


def _normalize_node(value):
    result = {"objectKey": str(value["objectKey"]), "lonE7": value["lonE7"], "latE7": value["latE7"]}
    if (
        not re.fullmatch(r"n[0-9]+", result["objectKey"])
        or any(
            isinstance(result[key], bool) or not isinstance(result[key], int)
            for key in ("lonE7", "latE7")
        )
        or not -1_800_000_000 <= result["lonE7"] <= 1_800_000_000
        or not -850_511_288 <= result["latE7"] <= 850_511_288
    ):
        raise ValueError("source node is invalid")
    return result


def _normalize_way(value):
    key = str(value["objectKey"])
    nodes = [{"key": str(node["key"]), "lonE7": node["lonE7"], "latE7": node["latE7"]} for node in value["nodes"]]
    if (
        not re.fullmatch(r"w[0-9]+", key)
        or len(nodes) < 2
        or any(not re.fullmatch(r"n[0-9]+", node["key"]) for node in nodes)
        or any(
            isinstance(node[axis], bool) or not isinstance(node[axis], int)
            for node in nodes
            for axis in ("lonE7", "latE7")
        )
        or any(
            not -1_800_000_000 <= node["lonE7"] <= 1_800_000_000
            or not -850_511_288 <= node["latE7"] <= 850_511_288
            for node in nodes
        )
    ):
        raise ValueError("source way is invalid")
    bounds = [min(node[axis] for node in nodes) for axis in ("lonE7", "latE7")] + [max(node[axis] for node in nodes) for axis in ("lonE7", "latE7")]
    return {"objectKey": key, "tags": dict(sorted(value.get("tags", {}).items())), "nodes": nodes, "boundsE7": bounds}


def _normalize_relation(value):
    key = str(value["objectKey"])
    members = [{"type": member["type"], "key": str(member["key"]), "role": str(member.get("role", ""))} for member in value["members"]]
    if not re.fullmatch(r"r[0-9]+", key) or any(
        member["type"] not in {"n", "w", "r"}
        or not _OBJECT_KEY.fullmatch(member["key"])
        or not member["key"].startswith(member["type"])
        for member in members
    ):
        raise ValueError("source relation is invalid")
    return {"objectKey": key, "tags": dict(sorted(value.get("tags", {}).items())), "members": members}


def initialize_source_index_database(connection: sqlite3.Connection) -> None:
    connection.executescript(
        """
        PRAGMA journal_mode=DELETE;
        PRAGMA synchronous=FULL;
        CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE nodes (
            object_key TEXT PRIMARY KEY,
            lon_e7 INTEGER NOT NULL,
            lat_e7 INTEGER NOT NULL
        );
        CREATE TABLE ways (
            object_key TEXT PRIMARY KEY,
            tags_json TEXT NOT NULL,
            nodes_json TEXT NOT NULL,
            bounds_e7_json TEXT NOT NULL
        );
        CREATE TABLE relations (
            object_key TEXT PRIMARY KEY,
            tags_json TEXT NOT NULL,
            members_json TEXT NOT NULL,
            bounds_e7_json TEXT NOT NULL
        );
        CREATE TABLE relation_members (
            relation_key TEXT NOT NULL,
            member_index INTEGER NOT NULL,
            member_type TEXT NOT NULL,
            member_key TEXT NOT NULL,
            role TEXT NOT NULL,
            PRIMARY KEY (relation_key, member_index)
        );
        CREATE INDEX relation_member_lookup
            ON relation_members(member_type, member_key);
        CREATE INDEX way_min_lon_lookup
            ON ways(CAST(json_extract(bounds_e7_json, '$[0]') AS INTEGER));
        CREATE INDEX way_max_lon_lookup
            ON ways(CAST(json_extract(bounds_e7_json, '$[2]') AS INTEGER));
        CREATE INDEX relation_min_lon_lookup
            ON relations(CAST(json_extract(bounds_e7_json, '$[0]') AS INTEGER));
        CREATE INDEX relation_max_lon_lookup
            ON relations(CAST(json_extract(bounds_e7_json, '$[2]') AS INTEGER));
        """
    )


def verify_source_index_database(
    connection: sqlite3.Connection,
    *,
    repair_relation_bounds: bool,
) -> dict[str, int]:
    tables = {
        row[0]
        for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table'"
        )
    }
    if tables != {"metadata", "nodes", "ways", "relations", "relation_members"}:
        raise BuildingSourceIndexError(
            "building_relation_incomplete", "source index database schema is invalid"
        )
    indexes = {
        row[0]
        for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type = 'index'"
        )
    }
    if not {
        "relation_member_lookup",
        "way_min_lon_lookup",
        "way_max_lon_lookup",
        "relation_min_lon_lookup",
        "relation_max_lon_lookup",
    }.issubset(indexes):
        raise BuildingSourceIndexError(
            "building_relation_incomplete", "source index lookup schema is invalid"
        )
    quick_check = connection.execute("PRAGMA quick_check").fetchone()[0]
    if quick_check != "ok":
        raise BuildingSourceIndexError(
            "building_relation_incomplete", "source index database integrity check failed"
        )
    invalid_node = connection.execute(
        """
        SELECT 1 FROM nodes
        WHERE object_key NOT GLOB 'n[0-9]*'
           OR length(object_key) < 2
           OR substr(object_key, 2) GLOB '*[^0-9]*'
           OR lon_e7 < -1800000000 OR lon_e7 > 1800000000
           OR lat_e7 < -850511288 OR lat_e7 > 850511288
        LIMIT 1
        """
    ).fetchone()
    if invalid_node:
        raise BuildingSourceIndexError(
            "building_relation_incomplete", "source index contains an invalid node"
        )

    connection.execute("DROP TABLE IF EXISTS temp.resolved_bounds")
    connection.execute(
        """
        CREATE TEMP TABLE resolved_bounds (
            object_key TEXT PRIMARY KEY,
            min_lon_e7 INTEGER NOT NULL,
            min_lat_e7 INTEGER NOT NULL,
            max_lon_e7 INTEGER NOT NULL,
            max_lat_e7 INTEGER NOT NULL
        )
        """
    )
    connection.execute(
        """
        INSERT INTO resolved_bounds
        SELECT object_key, lon_e7, lat_e7, lon_e7, lat_e7 FROM nodes
        """
    )
    for object_key, tags_json, nodes_json, stored_bounds_json in connection.execute(
        "SELECT object_key, tags_json, nodes_json, bounds_e7_json FROM ways ORDER BY object_key"
    ):
        try:
            normalized = _normalize_way(
                {
                    "objectKey": object_key,
                    "tags": json.loads(tags_json),
                    "nodes": json.loads(nodes_json),
                }
            )
            stored_bounds = json.loads(stored_bounds_json)
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
            raise BuildingSourceIndexError(
                "building_relation_incomplete", f"source way {object_key} is invalid"
            ) from exc
        if (
            _text(normalized["tags"]) != tags_json
            or _text(normalized["nodes"]) != nodes_json
            or stored_bounds != normalized["boundsE7"]
        ):
            raise BuildingSourceIndexError(
                "building_relation_incomplete", f"source way {object_key} bounds are invalid"
            )
        connection.execute(
            "INSERT INTO resolved_bounds VALUES (?, ?, ?, ?, ?)",
            (object_key, *normalized["boundsE7"]),
        )
    inconsistent_way_node = connection.execute(
        """
        SELECT way.object_key
        FROM ways way, json_each(way.nodes_json) embedded
        LEFT JOIN nodes node
          ON node.object_key = json_extract(embedded.value, '$.key')
        WHERE node.object_key IS NULL
           OR node.lon_e7 != json_extract(embedded.value, '$.lonE7')
           OR node.lat_e7 != json_extract(embedded.value, '$.latE7')
        LIMIT 1
        """
    ).fetchone()
    if inconsistent_way_node:
        raise BuildingSourceIndexError(
            "building_relation_incomplete",
            f"source way {inconsistent_way_node[0]} has inconsistent node geometry",
        )

    relation_count = connection.execute("SELECT COUNT(*) FROM relations").fetchone()[0]
    orphan_member = connection.execute(
        """
        SELECT member.relation_key
        FROM relation_members member
        LEFT JOIN relations relation ON relation.object_key = member.relation_key
        WHERE relation.object_key IS NULL
        LIMIT 1
        """
    ).fetchone()
    if orphan_member:
        raise BuildingSourceIndexError(
            "building_relation_incomplete", "source index contains an orphan relation member"
        )
    for relation_key, tags_json, members_json in connection.execute(
        "SELECT object_key, tags_json, members_json FROM relations ORDER BY object_key"
    ):
        try:
            normalized = _normalize_relation(
                {
                    "objectKey": relation_key,
                    "tags": json.loads(tags_json),
                    "members": json.loads(members_json),
                }
            )
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
            raise BuildingSourceIndexError(
                "building_relation_incomplete", f"source relation {relation_key} is invalid"
            ) from exc
        indexed_members = [
            {"type": member_type, "key": member_key, "role": role}
            for member_type, member_key, role in connection.execute(
                """
                SELECT member_type, member_key, role
                FROM relation_members
                WHERE relation_key = ?
                ORDER BY member_index
                """,
                (relation_key,),
            )
        ]
        if (
            _text(normalized["tags"]) != tags_json
            or _text(normalized["members"]) != members_json
            or normalized["members"] != indexed_members
            or not normalized["members"]
        ):
            raise BuildingSourceIndexError(
                "building_relation_incomplete",
                f"source relation {relation_key} membership is invalid",
            )

    for _depth in range(SOURCE_INDEX_MAX_RELATION_DEPTH + 1):
        before = connection.total_changes
        connection.execute(
            """
            INSERT OR IGNORE INTO resolved_bounds
            SELECT relation.object_key,
                   MIN(member_bounds.min_lon_e7),
                   MIN(member_bounds.min_lat_e7),
                   MAX(member_bounds.max_lon_e7),
                   MAX(member_bounds.max_lat_e7)
            FROM relations relation
            JOIN relation_members member ON member.relation_key = relation.object_key
            JOIN resolved_bounds member_bounds ON member_bounds.object_key = member.member_key
            WHERE NOT EXISTS (
                SELECT 1
                FROM relation_members required
                LEFT JOIN resolved_bounds available
                    ON available.object_key = required.member_key
                WHERE required.relation_key = relation.object_key
                  AND available.object_key IS NULL
            )
            GROUP BY relation.object_key
            """
        )
        if connection.total_changes == before:
            break
    resolved_relations = connection.execute(
        """
        SELECT COUNT(*)
        FROM relations relation
        JOIN resolved_bounds bounds ON bounds.object_key = relation.object_key
        """
    ).fetchone()[0]
    if resolved_relations != relation_count:
        raise BuildingSourceIndexError(
            "building_relation_incomplete",
            f"source relation closure is cyclic, incomplete, or deeper than {SOURCE_INDEX_MAX_RELATION_DEPTH}",
        )
    relation_bounds = connection.execute(
        """
        SELECT relation.object_key, relation.bounds_e7_json,
               bounds.min_lon_e7, bounds.min_lat_e7,
               bounds.max_lon_e7, bounds.max_lat_e7
        FROM relations relation
        JOIN resolved_bounds bounds ON bounds.object_key = relation.object_key
        ORDER BY relation.object_key
        """
    ).fetchall()
    for relation_key, stored_json, *computed in relation_bounds:
        if repair_relation_bounds:
            connection.execute(
                "UPDATE relations SET bounds_e7_json = ? WHERE object_key = ?",
                (_text(computed), relation_key),
            )
        else:
            try:
                stored = json.loads(stored_json)
            except (TypeError, ValueError) as exc:
                raise BuildingSourceIndexError(
                    "building_relation_incomplete",
                    f"source relation {relation_key} bounds are invalid",
                ) from exc
            if stored != computed:
                raise BuildingSourceIndexError(
                    "building_relation_incomplete",
                    f"source relation {relation_key} bounds are invalid",
                )

    return {
        "nodeCount": connection.execute("SELECT COUNT(*) FROM nodes").fetchone()[0],
        "wayCount": connection.execute("SELECT COUNT(*) FROM ways").fetchone()[0],
        "relationCount": relation_count,
        "relationMemberCount": connection.execute(
            "SELECT COUNT(*) FROM relation_members"
        ).fetchone()[0],
    }


def _require_unique(values):
    keys = [value["objectKey"] for value in values]
    if len(keys) != len(set(keys)):
        raise ValueError("source index contains duplicate object identities")


def _text(value) -> str:
    return canonical_json(value).decode()


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()
