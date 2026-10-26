import struct
import shutil
import subprocess
import tempfile
import unittest
import zlib
from pathlib import Path

from map_platform.poi_index import (
    ENTRY, HEADER, MAX_BYTES, MAX_ENTRIES, build_index, decode_index,
    index_path, validate_index,
)
from tests.map_label_fixtures import fmb6_with_pois


class PoiIndexTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.map_id = "fixture"
        self.files = []
        self.add_block("+000+000/0_0.fmb")

    def add_block(self, name, pois=None):
        relative = f"VECTMAP/{self.map_id}/{name}"
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(fmb6_with_pois() if pois is None else fmb6_with_pois(pois))
        self.files.append({"path": relative})

    def publish_index(self, raw):
        relative = index_path(self.map_id)
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
        return [*self.files, {"path": relative}]

    def changed(self, raw, offset, value, format="<I"):
        output = bytearray(raw)
        struct.pack_into(format, output, offset, value)
        struct.pack_into("<I", output, 12, zlib.crc32(output[HEADER.size:]) & 0xffffffff)
        return bytes(output)

    def test_exact_layout_and_block_correspondence(self):
        self.assertEqual((HEADER.size, ENTRY.size, MAX_BYTES), (16, 32, 524304))
        self.add_block("-001+000/15_0.fmb")
        self.add_block("+000+000/1_0.fmb", ())
        raw = build_index(self.root, self.map_id, self.files)
        self.assertEqual(raw, build_index(self.root, self.map_id, list(reversed(self.files))))
        entries = validate_index(self.root, self.map_id, self.publish_index(raw))
        self.assertEqual([(entry.x, entry.y) for entry in entries], [(-1, 0), (0, 0)])
        self.assertEqual(entries[0].category_counts, (0, 1, 0, 0, 1))
        self.assertEqual(entries[0].category_mask, 18)
        self.assertEqual(entries[0].section_bytes, 24)
        self.assertEqual(entries[0].relative_path(self.map_id), self.files[1]["path"])

    def test_empty_index_is_valid_only_for_empty_poi_data(self):
        raw = build_index(self.root, self.map_id, [])
        self.assertEqual(decode_index(raw), ())
        with self.assertRaisesRegex(ValueError, "every nonempty"):
            validate_index(self.root, self.map_id, self.publish_index(raw))
        (self.root / self.files[0]["path"]).write_bytes(fmb6_with_pois(()))
        self.assertEqual(validate_index(self.root, self.map_id, self.publish_index(raw)), ())

    def test_missing_index_blocks_duplicate_paths_and_wrong_map_rejected(self):
        with self.assertRaisesRegex(ValueError, "exactly one"):
            validate_index(self.root, self.map_id, self.files)
        for files, map_id in ((self.files * 2, self.map_id), (self.files, "other")):
            with self.subTest(map_id=map_id), self.assertRaisesRegex(ValueError, "block path"):
                build_index(self.root, map_id, files)
        for map_id in ("..", ".", "a/b", "x" * 65):
            with self.assertRaises(ValueError):
                index_path(map_id)

    def test_valid_structure_cannot_hide_wrong_block_summary(self):
        raw = build_index(self.root, self.map_id, self.files)
        # A syntactically valid changed offset, coordinate, or category ownership
        # still has to match the actual signed section.
        for changed in (
            self.changed(raw, 16, 1, "<i"),
            self.changed(raw, 16 + 22, 112),
            self.changed(self.changed(self.changed(raw, 16 + 8, 17), 16 + 12, 1, "<H"), 16 + 14, 0, "<H"),
        ):
            self.assertEqual(len(decode_index(changed)), 1)
            with self.assertRaisesRegex(ValueError, "every nonempty"):
                validate_index(self.root, self.map_id, self.publish_index(changed))

    def test_truncation_crc_flags_length_and_order_rejected(self):
        raw = build_index(self.root, self.map_id, self.files)
        invalid = [raw[:size] for size in range(len(raw))]
        invalid += [raw + b"\0", self.changed(raw, 16 + 30, 1, "<H"),
                    self.changed(raw, 16 + 8, 1), self.changed(raw, 16 + 22, 0),
                    self.changed(raw, 16 + 26, 8), self.changed(raw, 8, MAX_ENTRIES + 1)]
        corrupted = bytearray(raw)
        corrupted[-1] ^= 1
        invalid.append(bytes(corrupted))
        duplicated = raw[16:] * 2
        invalid.append(HEADER.pack(b"FPI1", 32, 0, 2, zlib.crc32(duplicated)) + duplicated)
        for number, value in enumerate(invalid):
            with self.subTest(number=number), self.assertRaises(ValueError):
                decode_index(value)

    def test_entry_ceiling_and_cancellation(self):
        entries = b"".join(ENTRY.pack(x, 0, 1, 1, 0, 0, 0, 0, 112, 16, 0)
                           for x in range(MAX_ENTRIES))
        raw = HEADER.pack(b"FPI1", 32, 0, MAX_ENTRIES, zlib.crc32(entries)) + entries
        self.assertEqual(len(decode_index(raw)), MAX_ENTRIES)
        with self.assertRaises(ValueError):
            decode_index(raw + entries[:32])
        def cancelled():
            raise RuntimeError("cancelled")
        with self.assertRaisesRegex(RuntimeError, "cancelled"):
            build_index(self.root, self.map_id, self.files, cancel=cancelled)

    def test_symlink_rejected(self):
        path = self.root / self.files[0]["path"]
        other = self.root / "untrusted.fmb"
        path.rename(other)
        path.symlink_to(other)
        with self.assertRaisesRegex(ValueError, "symlink"):
            build_index(self.root, self.map_id, self.files)

    @unittest.skipUnless(shutil.which("c++"), "C++ compiler required for cross-reader contract")
    def test_cpp_reader_matches_independent_python_corpus(self):
        repo = Path(__file__).resolve().parents[3]
        executable = self.root / "index-validator"
        subprocess.run(["c++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                        "-I", str(repo / "esp32/lib/maps/src"),
                        str(Path(__file__).with_name("poi_index_validator_cli.cpp")),
                        "-o", str(executable)], check=True, capture_output=True)
        self.add_block("-001+000/15_0.fmb")
        raw = build_index(self.root, self.map_id, self.files)
        corpus = [raw, build_index(self.root, self.map_id, []), raw + b"\0"]
        corpus.extend(raw[:size] for size in range(len(raw)))
        for position in range(len(raw)):
            for mask in (1, 0x80, 0xff):
                changed = bytearray(raw)
                changed[position] ^= mask
                if position >= 16:
                    struct.pack_into("<I", changed, 12, zlib.crc32(changed[16:]) & 0xffffffff)
                corpus.append(bytes(changed))
        expected = []
        for value in corpus:
            try:
                decode_index(value)
                expected.append("1")
            except ValueError:
                expected.append("0")
        actual = subprocess.run([str(executable)], input="\n".join(value.hex() for value in corpus) + "\n",
                                text=True, capture_output=True, check=True).stdout.splitlines()
        self.assertEqual(actual, expected)


if __name__ == "__main__":
    unittest.main()
