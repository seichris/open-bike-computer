import copy
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("speech_contract_generator", ROOT / "tools/generate_ride_ble_contract.py")
GENERATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GENERATOR)


class SpokenContractGenerationTests(unittest.TestCase):
    def setUp(self):
        self.contract = json.loads((ROOT / "protocol/ride-ble-contract-v1.json").read_text())

    def test_checked_in_generated_contract_is_current(self):
        self.assertEqual(GENERATOR.render_swift(self.contract), GENERATOR.SWIFT_OUTPUT.read_text())
        self.assertEqual(GENERATOR.render_cpp(self.contract), GENERATOR.CPP_OUTPUT.read_text())

    def test_rejects_incompatible_layout_and_relaxed_bounds(self):
        for field, value in {"version": 2, "cue_bytes": 55, "control_bytes": 37,
                             "maximum_start_lifetime_ms": 5001, "progress_lease_ms": 5001,
                             "maximum_dynamic_asset_bytes": 65537, "dynamic_cache_bytes": 131073,
                             "maximum_audio_frames": 128001, "audio_sample_rate": 48000,
                             "audio_block_frames": 320}.items():
            with self.subTest(field=field):
                speech = copy.deepcopy(self.contract["spoken_directions"])
                speech["limits"][field] = value
                with self.assertRaises(SystemExit):
                    GENERATOR.validate_spoken_contract(speech)

    def test_rejects_invalid_enums_goldens_and_magic(self):
        for group in ("phases", "maneuvers", "controls"):
            speech = copy.deepcopy(self.contract["spoken_directions"])
            values = list(speech[group])
            speech[group][values[1]] = speech[group][values[0]]
            with self.assertRaises(SystemExit):
                GENERATOR.validate_spoken_contract(speech)
        for field in ("cue", "control"):
            speech = copy.deepcopy(self.contract["spoken_directions"])
            speech["golden"][field + "_hex"] += "00"
            with self.assertRaises(SystemExit):
                GENERATOR.validate_spoken_contract(speech)
        speech = copy.deepcopy(self.contract["spoken_directions"])
        speech["magic"]["cue"] = "BAD"
        with self.assertRaises(SystemExit):
            GENERATOR.validate_spoken_contract(speech)


if __name__ == "__main__":
    unittest.main()
