import json
import hashlib
from pathlib import Path
import sys
import unittest

from shapely.geometry import box

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from building_pipeline import clip_buildings, load_rules, prepare_buildings  # noqa: E402
from map_format import _building_section  # noqa: E402


class SelectedAreaFixtureTests(unittest.TestCase):
    def test_fixture_pins_topology_height_and_seam_contract(self):
        fixture = json.loads(
            (Path(__file__).parent / "fixtures" / "selected_area_buildings.json").read_text()
        )
        rules, rules_sha256 = load_rules(ROOT / "conf" / "building_height_rules.yaml")
        buildings, report, _flat = prepare_buildings(
            fixture["features"], rules, fixture["relationIndex"]
        )
        expected = fixture["expected"]
        source_bytes = json.dumps(
            {
                "features": fixture["features"],
                "relationIndex": fixture["relationIndex"],
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode()
        self.assertEqual(hashlib.sha256(source_bytes).hexdigest(), expected["canonicalSourceSha256"])
        self.assertEqual(rules_sha256, expected["rulesSha256"])
        self.assertEqual(report["sourceCount"], expected["sourceCount"])
        self.assertEqual(report["relationAssociationCount"], expected["relationAssociationCount"])
        self.assertGreaterEqual(report["holeCount"], expected["minimumHoleCount"])
        self.assertEqual(report["rejectedTags"]["heightMalformed"], expected["malformedHeightCount"])
        self.assertRegex(rules_sha256, r"^[0-9a-f]{64}$")

        left, _ = clip_buildings(buildings, box(0, 0, 4096, 4096), 0, 0)
        right, _ = clip_buildings(buildings, box(4096, 0, 8192, 4096), 4096, 0)
        bottom, _ = clip_buildings(buildings, box(0, 0, 4096, 4096), 0, 0)
        top, _ = clip_buildings(buildings, box(0, 4096, 4096, 8192), 0, 4096)
        self.assertIn(expected["verticalSeamSource"], {record["source_key"] for record in left})
        self.assertIn(expected["verticalSeamSource"], {record["source_key"] for record in right})
        self.assertIn(expected["horizontalSeamSource"], {record["source_key"] for record in bottom})
        self.assertIn(expected["horizontalSeamSource"], {record["source_key"] for record in top})
        for origin, block in {
            "0,0": box(0, 0, 4096, 4096),
            "4096,0": box(4096, 0, 8192, 4096),
            "0,4096": box(0, 4096, 4096, 8192),
            "4096,4096": box(4096, 4096, 8192, 8192),
        }.items():
            min_x, min_y = (int(value) for value in origin.split(","))
            records, _stats = clip_buildings(buildings, block, min_x, min_y)
            section, metadata = _building_section(records)
            golden = expected["buildingSections"][origin]
            self.assertEqual(len(records), golden["records"])
            self.assertEqual(metadata["buildingBytes"], golden["bytes"])
            self.assertEqual(hashlib.sha256(section).hexdigest(), golden["sha256"])


if __name__ == "__main__":
    unittest.main()
