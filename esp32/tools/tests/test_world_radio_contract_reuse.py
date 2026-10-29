"""Contract-generation regression tests; no network or platform dependencies."""
import copy
import importlib.util
import json
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("ride_contract", ROOT / "tools/generate_ride_ble_contract.py")
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


class WorldRadioContractReuseTests(unittest.TestCase):
    def test_stable_screen_ids_and_single_source(self):
        contract = generator.load_contract()
        self.assertEqual(contract["screen_types"], {
            "map": 0, "navigation": 1, "ride_stats": 2,
            "map_plus_navigation": 3, "battery_status": 4, "world_radio": 5,
            "elevation": 6,
            "nearby": 7,
        })
        self.assertEqual(generator.SWIFT_OUTPUT.read_text(), generator.render_swift(contract))
        self.assertEqual(generator.CPP_OUTPUT.read_text(), generator.render_cpp(contract))
        legacy_enum = generator.render_swift(contract).split(
            "nonisolated enum RideBLELegacyScreenV1", 1
        )[1].split("var wireType", 1)[0]
        self.assertNotIn("case nearby", legacy_enum)
        # Freeze this feature's wire requirement, not the latest client version:
        # adding an unrelated capability must not invalidate World Radio.
        radio = contract["capabilities"]["features"]["world_radio"]
        self.assertEqual(radio, {"bit": 27, "minimum_client_version": 25})
        self.assertGreaterEqual(contract["capabilities"]["current_client_version"],
                                radio["minimum_client_version"])
        self.assertEqual(
            contract["capabilities"]["features"]["board_display_metadata"],
            {"bit": 31, "minimum_client_version": 29},
        )

    def test_ble_protocol_extended_feature_examples_match_contract(self):
        # docs/ble-protocol.md is the cross-device source of truth. Keep its CAP2
        # extended-feature wire examples on the generated contract's bits.
        features = generator.load_contract()["capabilities"]["extended_features"]
        document = (ROOT / "docs/ble-protocol.md").read_text(encoding="utf-8")
        examples = {
            "Friend-marker sizing": "friend_marker_scale_v1",
            "Route elevation profiles": "route_elevation_v1",
            "Map POIs and Nearby": "map_pois",
        }
        for label, name in examples.items():
            with self.subTest(feature=name):
                bit = features[name]["bit"]
                match = re.search(
                    re.escape(label) + r", CAP2 schema 1, extended feature bit "
                    r"(\d+) \(TLV type 3\):\n((?:[0-9A-F]{2} ?)+)\n", document)
                self.assertIsNotNone(match)
                self.assertEqual(int(match.group(1)), bit)
                payload = bytes.fromhex(match.group(2))
                self.assertEqual(payload[-6:-4], bytes([3, 4]))
                self.assertEqual(int.from_bytes(payload[-4:], "little"), 1 << bit)
        self.assertIn(
            f"Extended bit `{features['map_pois']['bit']}` reports the\n"
            "target-5/FMB6 POI reader", document)

    def test_invalid_screen_assignments_fail_closed(self):
        for values in ({"map": 0, "radio": 0}, {"map": -1}, {"map": 8},
                       {"map": True}, {"bad-name": 0}, {}):
            with self.subTest(values=values), tempfile.TemporaryDirectory() as directory:
                contract = copy.deepcopy(generator.load_contract())
                contract["screen_types"] = values
                source = Path(directory) / "contract.json"
                source.write_text(json.dumps(contract))
                with patch.object(generator, "SOURCE", source), self.assertRaises(SystemExit):
                    generator.load_contract()


if __name__ == "__main__":
    unittest.main()
