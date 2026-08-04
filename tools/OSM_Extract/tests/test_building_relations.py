import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = Path(__file__).resolve().parent / "fixtures" / "building_relations.osm"
SCRIPT = ROOT / "scripts" / "extract_building_relations.py"


class BuildingRelationIngressTests(unittest.TestCase):
    def test_cli_indexes_real_osm_building_relations_deterministically(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "building-relations.json"
            subprocess.run(
                [sys.executable, str(SCRIPT), str(FIXTURE), str(output)],
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertEqual(
                json.loads(output.read_text(encoding="utf-8")),
                {
                    "schemaVersion": 1,
                    "partParents": {"w20": "w10"},
                    "relations": 2,
                    "ambiguousParts": 1,
                },
            )
            self.assertEqual(
                output.read_text(encoding="utf-8"),
                '{"ambiguousParts":1,"partParents":{"w20":"w10"},'
                '"relations":2,"schemaVersion":1}\n',
            )


if __name__ == "__main__":
    unittest.main()
