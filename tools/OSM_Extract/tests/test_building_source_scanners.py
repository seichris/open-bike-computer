from pathlib import Path
import hashlib
import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from build_building_calibration import (  # noqa: E402
    load_scope,
    scan_pbf,
    source_cell_domain,
)
from build_building_source_index import scan_source  # noqa: E402
from building_pipeline import (  # noqa: E402
    _calibration_cell,
    load_rules,
    projected_selection_geometry,
)
from building_calibration_cache import CalibrationCacheError  # noqa: E402
from building_source_index import BuildingSourceIndex, BuildingSourceIndexError  # noqa: E402


class BuildingSourceScannerTests(unittest.TestCase):
    def setUp(self):
        self.source = Path(__file__).parent / "fixtures" / "calibration_source.osm"
        self.rules, _ = load_rules(ROOT / "conf" / "building_height_rules.yaml")

    def test_calibration_scanner_includes_direct_way_and_relation_samples_only(self):
        samples, rejections, diagnostics = scan_pbf(self.source, self.rules, {(0, 0)})
        rows = sorted(
            (sample.object_key, sample.height_dm)
            for sample in samples[(0, 0)]
        )
        self.assertEqual(rows, [("r30", 300), ("w10", 100), ("w11", 85)])
        self.assertEqual(diagnostics["directSamples"], 3)
        self.assertEqual(rejections[(0, 0)]["heightMalformed"], 1)
        self.assertGreaterEqual(diagnostics["invalidGeometry"], 1)

    def test_complete_calibration_domain_is_derived_from_building_areas(self):
        self.assertEqual(
            source_cell_domain(self.source, 8192, 1),
            tuple((x, y) for x in range(-1, 2) for y in range(-1, 2)),
        )

    def test_calibration_scope_loader_accepts_global_plan_identity_alias(self):
        body = {
            "schemaVersion": 1,
            "calibration": {
                "cellSizeMeters": 8192,
                "haloCells": 1,
                "minimumSamples": 3,
                "sampleCells": [[0, 0]],
            },
        }
        encoded = json.dumps(
            body,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
        ).encode()
        digest = hashlib.sha256(encoded).hexdigest()
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "global-scope.json"
            path.write_bytes(
                json.dumps(
                    {
                        **body,
                        "scopePlanSha256": digest,
                        "globalPlanSha256": digest,
                    },
                    sort_keys=True,
                    separators=(",", ":"),
                ).encode()
            )
            self.assertEqual(load_scope(path), body)

    def test_complete_calibration_domain_has_a_hard_cell_cap(self):
        with patch("build_building_calibration.MAX_COMPLETE_CALIBRATION_CELLS", 8):
            with self.assertRaisesRegex(CalibrationCacheError, "exceeds 8"):
                source_cell_domain(self.source, 8192, 1)

    def test_full_source_scans_never_use_an_in_memory_location_index(self):
        scripts = [
            ROOT / "scripts" / "build_building_calibration.py",
            ROOT / "scripts" / "build_building_source_index.py",
        ]
        for script in scripts:
            self.assertNotIn('idx="flex_mem"', script.read_text())

    def test_cli_failures_preserve_typed_codes_at_the_process_boundary(self):
        bad_sha = "0" * 64
        with tempfile.TemporaryDirectory() as temporary:
            invalid_scope = Path(temporary) / "invalid-scope.json"
            invalid_scope.write_text("{}")
            commands = [
                ([
                sys.executable,
                str(ROOT / "scripts" / "build_building_source_index.py"),
                "--source-pbf", str(self.source),
                "--source-sha256", bad_sha,
                "--cache-root", tempfile.gettempdir(),
                ], "building_source_snapshot_changed"),
                ([
                sys.executable,
                str(ROOT / "scripts" / "build_building_calibration.py"),
                "--source-pbf", str(self.source),
                "--source-sha256", bad_sha,
                "--rules", str(ROOT / "conf" / "building_height_rules.yaml"),
                "--scope-plan", str(ROOT / "tests" / "missing-scope.json"),
                "--cache-root", tempfile.gettempdir(),
                ], "building_source_snapshot_changed"),
                ([
                sys.executable,
                str(ROOT / "scripts" / "build_building_source_index.py"),
                "--source-pbf", str(Path(temporary) / "missing.osm"),
                "--source-sha256", bad_sha,
                "--cache-root", tempfile.gettempdir(),
                ], "building_source_snapshot_changed"),
                ([
                sys.executable,
                str(ROOT / "scripts" / "build_building_calibration.py"),
                "--source-pbf", str(self.source),
                "--source-sha256", hashlib.sha256(self.source.read_bytes()).hexdigest(),
                "--rules", str(ROOT / "conf" / "building_height_rules.yaml"),
                "--scope-plan", str(invalid_scope),
                "--cache-root", tempfile.gettempdir(),
                ], "building_scope_policy_invalid"),
            ]
            for command, expected_code in commands:
                result = subprocess.run(command, text=True, capture_output=True)
                self.assertEqual(result.returncode, 2, result.stderr)
                marker = next(
                    line.split(":", 1)[1]
                    for line in result.stderr.splitlines()
                    if line.startswith("BUILDING_PREPROCESS_FAILURE:")
                )
                self.assertEqual(json.loads(marker)["code"], expected_code)

    def test_source_index_scanner_retains_relation_members_roles_and_nodes(self):
        with tempfile.TemporaryDirectory() as root:
            index = BuildingSourceIndex(root, "1" * 64)
            index.build_with_scanner(lambda path: scan_source(self.source, path))
            connection = sqlite3.connect(index.database_path)
            way_keys = {row[0] for row in connection.execute("SELECT object_key FROM ways")}
            node_keys = {row[0] for row in connection.execute("SELECT object_key FROM nodes")}
            by_key = {
                key: {"members": json.loads(members)}
                for key, members in connection.execute(
                    "SELECT object_key, members_json FROM relations"
                )
            }
            connection.close()
        self.assertIn("w20", way_keys)
        self.assertTrue({"n13", "n14", "n15", "n16"}.issubset(node_keys))
        self.assertEqual(by_key["r30"]["members"], [{"type": "w", "key": "w20", "role": "outer"}])
        self.assertEqual(
            by_key["r40"]["members"],
            [
                {"type": "w", "key": "w10", "role": "outline"},
                {"type": "w", "key": "w11", "role": "part"},
            ],
        )
        self.assertEqual(
            by_key["r31"]["members"],
            [
                {"type": "w", "key": "w21", "role": "outer"},
                {"type": "w", "key": "w22", "role": "inner"},
            ],
        )
        self.assertIn("w22", way_keys)
        self.assertTrue(
            {"n21", "n22", "n23", "n24"}.issubset(
                node_keys
            )
        )
        self.assertTrue({"r50", "r51", "r52"}.issubset(by_key))
        self.assertEqual(
            by_key["r50"]["members"],
            [{"type": "r", "key": "r51", "role": "part"}],
        )
        self.assertEqual(
            by_key["r52"]["members"],
            [{"type": "r", "key": "r50", "role": "outer"}],
        )

    def test_source_index_scanner_canonicalizes_non_ascii_tags(self):
        source_xml = """<?xml version="1.0" encoding="UTF-8"?>
<osm version="0.6">
  <node id="1" lat="31.0" lon="121.0"/>
  <node id="2" lat="31.0" lon="121.001"/>
  <node id="3" lat="31.001" lon="121.001"/>
  <way id="10">
    <nd ref="1"/><nd ref="2"/><nd ref="3"/><nd ref="1"/>
    <tag k="building" v="yes"/><tag k="name" v="上海"/>
  </way>
</osm>
"""
        with tempfile.TemporaryDirectory() as root:
            source = Path(root) / "non-ascii.osm"
            source.write_text(source_xml, encoding="utf-8")
            index = BuildingSourceIndex(Path(root) / "index", "1" * 64)

            index.build_with_scanner(lambda path: scan_source(source, path))

            connection = sqlite3.connect(index.database_path)
            tags_json = connection.execute(
                "SELECT tags_json FROM ways WHERE object_key='w10'"
            ).fetchone()[0]
            connection.close()
            self.assertEqual(
                tags_json,
                '{"building":"yes","name":"上海"}',
            )
            self.assertEqual(index.validate()["wayCount"], 1)

    def test_source_index_scanner_fails_closed_on_missing_way_location(self):
        source = Path(__file__).parent / "fixtures" / "missing_location_building.osm"
        with tempfile.TemporaryDirectory() as root:
            index = BuildingSourceIndex(root, "1" * 64)
            with self.assertRaises(BuildingSourceIndexError) as raised:
                index.build_with_scanner(lambda path: scan_source(source, path))
            self.assertEqual(raised.exception.code, "building_relation_incomplete")
            self.assertFalse(index.database_path.exists())

    def test_scanner_and_runtime_geometry_share_boundary_anchor_cell(self):
        source = Path(__file__).parent / "fixtures" / "calibration_anchor_boundary.osm"
        anchors = {}
        scan_pbf(
            source,
            self.rules,
            {(1, 0)},
            anchor_cells_by_object=anchors,
        )
        runtime_geometry = projected_selection_geometry(
            {
                "type": "Polygon",
                "coordinates": [[
                    [0.07358, 0.001],
                    [0.07360, 0.001],
                    [0.07360, 0.002],
                    [0.07358, 0.002],
                    [0.07358, 0.001],
                ]],
            }
        )
        self.assertEqual(anchors["w100"], (1, 0))
        self.assertEqual(
            anchors["w100"],
            _calibration_cell(
                runtime_geometry,
                self.rules.cell_size_meters,
                bounds_midpoint=True,
            ),
        )


if __name__ == "__main__":
    unittest.main()
