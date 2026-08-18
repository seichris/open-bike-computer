import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from building_source_index import (  # noqa: E402
    BuildingSourceIndex,
    BuildingSourceIndexError,
    initialize_source_index_database,
    verify_source_index_database,
)
from building_calibration_cache import _CacheLock  # noqa: E402


def records():
    nodes = [
        {"objectKey": "n1", "lonE7": 100, "latE7": 100},
        {"objectKey": "n2", "lonE7": 200, "latE7": 100},
        {"objectKey": "n3", "lonE7": 200, "latE7": 200},
        {"objectKey": "n4", "lonE7": 100, "latE7": 200},
    ]
    way = {
        "objectKey": "w10",
        "tags": {"building": "yes"},
        "nodes": [
            {"key": "n1", "lonE7": 100, "latE7": 100},
            {"key": "n2", "lonE7": 200, "latE7": 100},
            {"key": "n3", "lonE7": 200, "latE7": 200},
            {"key": "n4", "lonE7": 100, "latE7": 200},
            {"key": "n1", "lonE7": 100, "latE7": 100},
        ],
    }
    relation = {
        "objectKey": "r20",
        "tags": {"type": "building"},
        "members": [{"type": "w", "key": "w10", "role": "outline"}],
    }
    return nodes, [way], [relation]


def write_spool(path, nodes, ways, relations):
    connection = sqlite3.connect(path)
    initialize_source_index_database(connection)
    connection.executemany(
        "INSERT INTO nodes VALUES (?, ?, ?)",
        ((node["objectKey"], node["lonE7"], node["latE7"]) for node in nodes),
    )
    for way in ways:
        bounds = [
            min(node[axis] for node in way["nodes"])
            for axis in ("lonE7", "latE7")
        ] + [
            max(node[axis] for node in way["nodes"])
            for axis in ("lonE7", "latE7")
        ]
        connection.execute(
            "INSERT INTO ways VALUES (?, ?, ?, ?)",
            (
                way["objectKey"],
                json.dumps(way["tags"], sort_keys=True, separators=(",", ":")),
                json.dumps(way["nodes"], sort_keys=True, separators=(",", ":")),
                json.dumps(bounds, separators=(",", ":")),
            ),
        )
    for relation in relations:
        members = relation["members"]
        connection.execute(
            "INSERT INTO relations VALUES (?, ?, ?, '[]')",
            (
                relation["objectKey"],
                json.dumps(relation["tags"], sort_keys=True, separators=(",", ":")),
                json.dumps(members, sort_keys=True, separators=(",", ":")),
            ),
        )
        connection.executemany(
            "INSERT INTO relation_members VALUES (?, ?, ?, ?, ?)",
            (
                (
                    relation["objectKey"],
                    index,
                    member["type"],
                    member["key"],
                    member["role"],
                )
                for index, member in enumerate(members)
            ),
        )
    connection.commit()
    connection.close()


class BuildingSourceIndexTests(unittest.TestCase):
    def test_output_closure_includes_old_style_multipolygon_and_enforces_total_cap(self):
        nodes, ways, relations = records()
        relations.append(
            {
                "objectKey": "r21",
                "tags": {"type": "multipolygon"},
                "members": [{"type": "w", "key": "w10", "role": "outer"}],
            }
        )
        with tempfile.TemporaryDirectory() as root:
            index = BuildingSourceIndex(root, "1" * 64)
            index.build(nodes=nodes, ways=ways, relations=relations)
            closure = index.closure_for_bounds(
                [(0, 0, 500, 500)],
                maximum_objects=100,
                calibration_cell_size_meters=8192,
                calibration_halo_cells=1,
            )
            self.assertEqual(closure["requiredRelationKeys"], ["r20", "r21"])
            self.assertEqual(closure["requiredWayKeys"], ["w10"])
            self.assertEqual(len(closure["requiredNodeKeys"]), 4)
            with self.assertRaises(BuildingSourceIndexError) as raised:
                index.closure_for_bounds(
                    [(0, 0, 500, 500)],
                    maximum_objects=6,
                    calibration_cell_size_meters=8192,
                    calibration_halo_cells=1,
                )
            self.assertEqual(raised.exception.code, "building_object_limit_exceeded")

    def test_output_candidate_extent_adds_its_runtime_calibration_anchor(self):
        nodes = [
            {"objectKey": "n1", "lonE7": 0, "latE7": 0},
            {"objectKey": "n2", "lonE7": 2_000_000, "latE7": 0},
            {"objectKey": "n3", "lonE7": 2_000_000, "latE7": 100},
            {"objectKey": "n4", "lonE7": 0, "latE7": 100},
        ]
        way = {
            "objectKey": "w10",
            "tags": {"building": "yes"},
            "nodes": [
                {"key": node["objectKey"], "lonE7": node["lonE7"], "latE7": node["latE7"]}
                for node in [*nodes, nodes[0]]
            ],
        }
        with tempfile.TemporaryDirectory() as root:
            index = BuildingSourceIndex(root, "2" * 64)
            index.build(nodes=nodes, ways=[way], relations=[])
            closure = index.closure_for_bounds(
                [(-10, -10, 10, 110)],
                maximum_objects=100,
                calibration_cell_size_meters=8192,
                calibration_halo_cells=1,
            )
            self.assertEqual(closure["calibrationTargetCells"], [[1, 0]])
            self.assertIn([1, 0], closure["calibrationSampleCells"])

    def test_build_is_immutable_complete_and_order_deterministic(self):
        nodes, ways, relations = records()
        with tempfile.TemporaryDirectory() as first_root, tempfile.TemporaryDirectory() as second_root:
            first = BuildingSourceIndex(first_root, "1" * 64)
            second = BuildingSourceIndex(second_root, "1" * 64)
            first_manifest = first.build(nodes=nodes, ways=ways, relations=relations)
            second_manifest = second.build(
                nodes=reversed(nodes), ways=reversed(ways), relations=reversed(relations)
            )
            self.assertEqual(first_manifest["databaseSha256"], second_manifest["databaseSha256"])
            self.assertEqual(first_manifest["relationMemberCount"], 1)
            self.assertEqual(first.validate()["indexKey"], first.index_key)
            connection = sqlite3.connect(first.database_path)
            bounds = connection.execute("SELECT bounds_e7_json FROM relations WHERE object_key='r20'").fetchone()[0]
            connection.close()
            self.assertEqual(bounds, "[100,100,200,200]")

    def test_missing_relation_member_fails_closed(self):
        nodes, ways, relations = records()
        relations[0]["members"][0]["key"] = "w999"
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaises(BuildingSourceIndexError) as raised:
                BuildingSourceIndex(root, "1" * 64).build(
                    nodes=nodes, ways=ways, relations=relations
                )
            self.assertEqual(raised.exception.code, "building_relation_incomplete")

    def test_relation_cycle_fails_closed(self):
        nodes, ways, relations = records()
        relations.extend([
            {"objectKey": "r21", "tags": {"type": "building"}, "members": [{"type": "r", "key": "r22", "role": "part"}]},
            {"objectKey": "r22", "tags": {"type": "building"}, "members": [{"type": "r", "key": "r21", "role": "part"}]},
        ])
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaises(BuildingSourceIndexError):
                BuildingSourceIndex(root, "1" * 64).build(
                    nodes=nodes, ways=ways, relations=relations
                )

    def test_database_tampering_is_rejected(self):
        nodes, ways, relations = records()
        with tempfile.TemporaryDirectory() as root:
            index = BuildingSourceIndex(root, "1" * 64)
            index.build(nodes=nodes, ways=ways, relations=relations)
            with index.database_path.open("ab") as output:
                output.write(b"tamper")
            with self.assertRaises(BuildingSourceIndexError):
                index.validate()

    def test_way_and_relation_bounds_are_recomputed_during_validation(self):
        nodes, ways, relations = records()
        with tempfile.TemporaryDirectory() as root:
            index = BuildingSourceIndex(root, "1" * 64)
            index.build(nodes=nodes, ways=ways, relations=relations)
            connection = sqlite3.connect(index.database_path)
            connection.execute(
                "UPDATE ways SET bounds_e7_json='[0,0,0,0]' WHERE object_key='w10'"
            )
            connection.commit()
            with self.assertRaisesRegex(BuildingSourceIndexError, "bounds"):
                verify_source_index_database(
                    connection, repair_relation_bounds=False
                )
            connection.execute(
                "UPDATE ways SET bounds_e7_json='[100,100,200,200]' WHERE object_key='w10'"
            )
            connection.execute(
                "UPDATE relations SET bounds_e7_json='[0,0,0,0]' WHERE object_key='r20'"
            )
            connection.commit()
            with self.assertRaisesRegex(BuildingSourceIndexError, "relation r20 bounds"):
                verify_source_index_database(
                    connection, repair_relation_bounds=False
                )
            connection.close()

    def test_way_node_coordinates_must_match_canonical_nodes(self):
        nodes, ways, relations = records()
        ways[0]["nodes"][0]["lonE7"] = 101
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaisesRegex(BuildingSourceIndexError, "inconsistent"):
                BuildingSourceIndex(root, "1" * 64).build(
                    nodes=nodes, ways=ways, relations=relations
                )

    def test_corrupt_artifacts_are_quarantined_and_rebuilt(self):
        nodes, ways, relations = records()
        with tempfile.TemporaryDirectory() as root:
            index = BuildingSourceIndex(root, "1" * 64)
            original = index.build(nodes=nodes, ways=ways, relations=relations)
            index.database_path.write_bytes(b"corrupt")
            rebuilt = index.build(nodes=nodes, ways=ways, relations=relations)
            self.assertEqual(rebuilt["databaseSha256"], original["databaseSha256"])
            self.assertEqual(len(list(index.index_root.glob("index.sqlite.corrupt-*"))), 1)
            self.assertEqual(len(list(index.index_root.glob("manifest.json.corrupt-*"))), 1)

    def test_scanner_is_single_flight_under_the_index_lock(self):
        nodes, ways, relations = records()
        with tempfile.TemporaryDirectory() as root:
            index = BuildingSourceIndex(root, "1" * 64)
            barrier = threading.Barrier(4)
            calls = []
            errors = []

            def scanner(path):
                calls.append(1)
                write_spool(path, nodes, ways, relations)

            def build():
                try:
                    barrier.wait()
                    index.build_with_scanner(scanner)
                except Exception as exc:  # pragma: no cover - asserted below
                    errors.append(exc)

            threads = [threading.Thread(target=build) for _ in range(4)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join()
            self.assertEqual(errors, [])
            self.assertEqual(len(calls), 1)

    def test_scanner_source_change_failure_is_typed_and_publishes_nothing(self):
        with tempfile.TemporaryDirectory() as root:
            index = BuildingSourceIndex(root, "1" * 64)

            def scanner(_path):
                raise RuntimeError("building_source_snapshot_changed: changed")

            with self.assertRaises(BuildingSourceIndexError) as raised:
                index.build_with_scanner(scanner)
            self.assertEqual(raised.exception.code, "building_source_snapshot_changed")
            self.assertFalse(index.database_path.exists())
            self.assertFalse(index.manifest_path.exists())

    def test_cleanup_removes_only_unpublished_scan_work_products(self):
        nodes, ways, relations = records()
        with tempfile.TemporaryDirectory() as root:
            index = BuildingSourceIndex(root, "1" * 64)
            manifest = index.build(
                nodes=nodes, ways=ways, relations=relations
            )
            partials = (
                index.index_root / ".scan.cancelled.sqlite",
                index.index_root / ".scan.cancelled.sqlite.locations",
                index.index_root / ".scan.cancelled.sqlite-wal",
            )
            for path in partials:
                path.write_bytes(b"partial")

            index.cleanup_unpublished_scans()

            self.assertTrue(index.database_path.is_file())
            self.assertTrue(index.manifest_path.is_file())
            self.assertEqual(index.validate(), manifest)
            self.assertTrue(all(not path.exists() for path in partials))

    def test_deep_relation_nesting_fails_with_typed_limit(self):
        nodes, ways, _ = records()
        relations = []
        first = 1000
        for index in range(258):
            member = (
                {"type": "w", "key": "w10", "role": "part"}
                if index == 257
                else {"type": "r", "key": f"r{first + index + 1}", "role": "part"}
            )
            relations.append(
                {
                    "objectKey": f"r{first + index}",
                    "tags": {"type": "building"},
                    "members": [member],
                }
            )
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaisesRegex(BuildingSourceIndexError, "exceeds"):
                BuildingSourceIndex(root, "1" * 64).build(
                    nodes=nodes, ways=ways, relations=relations
                )

    def test_lock_timeout_is_typed_and_does_not_invoke_scanner(self):
        with tempfile.TemporaryDirectory() as root:
            index = BuildingSourceIndex(root, "1" * 64)
            index.index_root.mkdir(parents=True)
            calls = []
            with _CacheLock(index.index_root / ".write.lock", timeout_seconds=1):
                with self.assertRaises(BuildingSourceIndexError) as raised:
                    index.build_with_scanner(
                        lambda _path: calls.append(1), lock_timeout_seconds=0.01
                    )
            self.assertEqual(raised.exception.code, "building_relation_incomplete")
            self.assertEqual(calls, [])

    def test_promotion_io_failure_is_typed_and_publishes_no_pair(self):
        nodes, ways, relations = records()
        with tempfile.TemporaryDirectory() as root:
            index = BuildingSourceIndex(root, "1" * 64)
            with patch("building_source_index.os.replace", side_effect=OSError("disk")):
                with self.assertRaises(BuildingSourceIndexError):
                    index.build_with_scanner(
                        lambda path: write_spool(path, nodes, ways, relations)
                    )
            self.assertFalse(index.database_path.exists())
            self.assertFalse(index.manifest_path.exists())


if __name__ == "__main__":
    unittest.main()
