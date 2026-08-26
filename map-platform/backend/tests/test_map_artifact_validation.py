import tempfile
import unittest
from pathlib import Path

from map_platform.map_artifact_validation import (
    MAX_BUILDINGS,
    validate_fma1,
    validate_fmb3,
    validate_fmb4,
    validate_renderer_artifacts,
)
from tests.map_label_fixtures import (
    golden_fmb,
    one_building_fmb4,
    one_label_fma1,
    one_label_fmb3,
)


class MapArtifactValidationTests(unittest.TestCase):
    def test_dense_building_record_ceiling_matches_fmb_v4_contract(self):
        self.assertEqual(MAX_BUILDINGS, 12288)

    def test_shared_legacy_fmb_golden_blocks_remain_target_one_compatible(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            map_id = "fixture-map"
            files = []
            for version in (1, 2):
                relative = f"VECTMAP/{map_id}/+0000+0000/{version}.fmb"
                block = root / relative
                block.parent.mkdir(parents=True, exist_ok=True)
                block.write_bytes(golden_fmb(f"fmb_v{version}"))
                files.append({"path": relative})

            validate_renderer_artifacts(root, map_id, files, 1)

    def test_nonempty_fmb3_and_fma1_cross_file_contract(self):
        self.assertEqual(one_label_fmb3(), golden_fmb("fmb_v3"))
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            map_id = "fixture-map"
            block_relative = f"VECTMAP/{map_id}/+0000+0000/1.fmb"
            font_relative = f"VECTMAP/{map_id}/assets/street-labels.fma"
            block = root / block_relative
            font = root / font_relative
            block.parent.mkdir(parents=True)
            font.parent.mkdir(parents=True)
            block.write_bytes(one_label_fmb3())
            font.write_bytes(one_label_fma1())

            block_metadata = validate_fmb3(block)
            font_metadata = validate_fma1(font)
            self.assertEqual(block_metadata.maximum_glyph_id, 1)
            self.assertEqual(font_metadata.glyph_count, 1)
            validate_renderer_artifacts(
                root,
                map_id,
                [{"path": block_relative}, {"path": font_relative}],
                2,
            )

    def test_crc_and_profile_mismatch_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            block = root / "block.fmb"
            corrupted = bytearray(one_label_fmb3())
            corrupted[-1] ^= 1
            block.write_bytes(corrupted)
            with self.assertRaisesRegex(ValueError, "CRC"):
                validate_fmb3(block)

            map_id = "fixture-map"
            block_relative = f"VECTMAP/{map_id}/+0000+0000/1.fmb"
            font_relative = f"VECTMAP/{map_id}/assets/street-labels.fma"
            pack_block = root / block_relative
            pack_font = root / font_relative
            pack_block.parent.mkdir(parents=True)
            pack_font.parent.mkdir(parents=True)
            pack_block.write_bytes(one_label_fmb3(0x11111111))
            pack_font.write_bytes(one_label_fma1(0x22222222))
            with self.assertRaisesRegex(ValueError, "fingerprint mismatch"):
                validate_renderer_artifacts(
                    root,
                    map_id,
                    [{"path": block_relative}, {"path": font_relative}],
                    2,
                )

    def test_fmb4_building_contract_and_target_three_composition(self):
        self.assertEqual(one_building_fmb4(), golden_fmb("fmb_v4"))
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            map_id = "fixture-map"
            block_relative = f"VECTMAP/{map_id}/+0000+0000/1.fmb"
            font_relative = f"VECTMAP/{map_id}/assets/street-labels.fma"
            block = root / block_relative
            font = root / font_relative
            block.parent.mkdir(parents=True)
            font.parent.mkdir(parents=True)
            block.write_bytes(one_building_fmb4())
            font.write_bytes(one_label_fma1())

            metadata = validate_fmb4(block)
            self.assertEqual(metadata.building_records, 1)
            self.assertEqual(metadata.building_provenance, (1, 0, 0, 0, 0))
            validate_renderer_artifacts(
                root,
                map_id,
                [{"path": block_relative}, {"path": font_relative}],
                3,
            )

            corrupted = bytearray(block.read_bytes())
            corrupted[-1] = 0x8F
            block.write_bytes(corrupted)
            with self.assertRaisesRegex(ValueError, "padding|CRC"):
                validate_fmb4(block)

            block.write_bytes(one_building_fmb4(flags=3))
            with self.assertRaisesRegex(ValueError, "record is invalid"):
                validate_fmb4(block)


if __name__ == "__main__":
    unittest.main()
