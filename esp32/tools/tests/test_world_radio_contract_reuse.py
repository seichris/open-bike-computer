"""Contract-generation regression tests; no network or platform dependencies."""
import copy
import importlib.util
import json
from pathlib import Path
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
        })
        self.assertEqual(generator.SWIFT_OUTPUT.read_text(), generator.render_swift(contract))
        self.assertEqual(generator.CPP_OUTPUT.read_text(), generator.render_cpp(contract))
        # Freeze this feature's wire requirement, not the latest client version:
        # adding an unrelated capability must not invalidate World Radio.
        radio = contract["capabilities"]["features"]["world_radio"]
        self.assertEqual(radio, {"bit": 27, "minimum_client_version": 25})
        self.assertGreaterEqual(contract["capabilities"]["current_client_version"],
                                radio["minimum_client_version"])

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
