from __future__ import annotations

import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from building_calibration_cache import canonical_json  # noqa: E402
from building_source_index import BuildingSourceIndex, BuildingSourceIndexError  # noqa: E402
from export_building_closure import export_closure  # noqa: E402


class ExportBuildingClosureTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("osmium"), "osmium CLI is required")
    def test_exports_only_missing_objects_and_merges_without_duplicates(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            index = BuildingSourceIndex(root / "cache", "a" * 64)
            nodes = [
                {"objectKey": "n1", "lonE7": 0, "latE7": 0},
                {"objectKey": "n2", "lonE7": 10_000, "latE7": 0},
            ]
            index.build(
                nodes=nodes,
                ways=[{"objectKey": "w10", "tags": {"building": "yes"},
                       "nodes": [{"key": node["objectKey"], "lonE7": node["lonE7"],
                                  "latE7": node["latE7"]} for node in nodes]}],
                relations=[{"objectKey": "r20", "tags": {"type": "building"},
                            "members": [{"type": "w", "key": "w10", "role": "outline"}]}],
            )
            body = {"schemaVersion": 1, "sourceSnapshotSha256": "a" * 64,
                    "requiredNodeKeys": ["n1", "n2"], "requiredWayKeys": ["w10"],
                    "requiredRelationKeys": ["r20"]}
            closure = root / "closure.json"
            closure.write_bytes(canonical_json({
                **body, "closurePlanSha256": hashlib.sha256(canonical_json(body)).hexdigest(),
            }))
            clipped_xml = root / "clipped.osm"
            clipped_xml.write_text('<osm version="0.6"><node id="1" version="3" lon="0" lat="0"/></osm>')
            clipped_pbf = root / "clipped.osm.pbf"
            subprocess.run(["osmium", "cat", str(clipped_xml), "-o", str(clipped_pbf)], check=True)
            exported_xml = root / "missing.osm"
            self.assertEqual(export_closure(index.manifest_path, closure, clipped_pbf, exported_xml),
                             {"requested": 4, "missing": 3})
            tree = ElementTree.parse(exported_xml)
            self.assertEqual([(child.tag, child.attrib["id"]) for child in tree.getroot()],
                             [("node", "2"), ("way", "10"), ("relation", "20")])
            exported_pbf = root / "missing.osm.pbf"
            merged_pbf = root / "merged.osm.pbf"
            subprocess.run(["osmium", "cat", str(exported_xml), "-o", str(exported_pbf)], check=True)
            subprocess.run(["osmium", "merge", str(clipped_pbf), str(exported_pbf),
                            "-o", str(merged_pbf)], check=True)
            merged = subprocess.run(["osmium", "cat", str(merged_pbf), "-f", "osm"],
                                    check=True, capture_output=True, text=True)
            merged_tree = ElementTree.fromstring(merged.stdout)
            self.assertEqual([(child.tag, child.attrib["id"]) for child in merged_tree],
                             [("node", "1"), ("node", "2"), ("way", "10"), ("relation", "20")])

    def test_rejects_changed_closure_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            index = BuildingSourceIndex(root / "cache", "a" * 64)
            index.build(nodes=[], ways=[], relations=[])
            closure = root / "closure.json"
            closure.write_text(json.dumps({"schemaVersion": 1, "sourceSnapshotSha256": "a" * 64,
                                           "requiredNodeKeys": ["n1"], "requiredWayKeys": [],
                                           "requiredRelationKeys": [], "closurePlanSha256": "0" * 64}))
            with self.assertRaisesRegex(BuildingSourceIndexError, "identity"):
                export_closure(index.manifest_path, closure, root / "missing.pbf", root / "missing.osm")
