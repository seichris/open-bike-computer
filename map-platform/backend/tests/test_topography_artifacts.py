import shutil
import struct
import subprocess
import tempfile
import unittest
import zlib
from dataclasses import replace
from pathlib import Path

from map_platform.map_artifact_validation import validate_fmb5, _parse_base_geometry
from map_platform.topography_artifacts import (
    Contour, ContourSection, HEADER, RECORD, decode_contour_section,
    encode_contour_section, upgrade_fmb4,
)
from tests.map_label_fixtures import one_building_fmb4

ROOT = Path(__file__).resolve().parents[3]


class ContourArtifactsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "block.fmb"
        self.path.write_bytes(one_building_fmb4())
        self.section = ContourSection(20, 100, (
            Contour(-100, 1, ((0, 0), (100, 100), (200, 50))),
            Contour(20, 0, ((100, 0), (300, 200))),
        ))

    def test_fmb5_preserves_buildings_and_labels(self):
        encoded = upgrade_fmb4(self.path, self.section)
        self.path.write_bytes(encoded)
        result = validate_fmb5(self.path)
        self.assertEqual(result.contour_records, 2)
        self.assertEqual(result.contour_points, 5)
        self.assertEqual(result.contour_intervals, (20, 100))
        self.assertEqual(result.building_records, 1)
        self.assertEqual(result.profile_fingerprint, 0x12345678)

    def test_round_trip_and_canonical_order(self):
        encoded = encode_contour_section(self.section)
        self.assertEqual(decode_contour_section(encoded), self.section)
        self.assertEqual(encoded, encode_contour_section(replace(self.section, contours=tuple(reversed(self.section.contours)))))
        empty = ContourSection(50, 250, ())
        self.assertEqual(decode_contour_section(encode_contour_section(empty)), empty)

    def test_rejects_invalid_encoder_inputs(self):
        base = self.section.contours[0]
        for contour in (replace(base, flags=0), replace(base, elevation_m=True),
                        replace(base, flags=8), replace(base, points=((0, 0), (513, 0))),
                        replace(base, points=((0, 0), (0, 0))),
                        replace(base, points=((-1, 0), (0, 0))),
                        replace(base, points=((0, 0),) * 257)):
            with self.subTest(contour=contour), self.assertRaises(ValueError):
                encode_contour_section(replace(self.section, contours=(contour,)))
        with self.assertRaises(ValueError):
            encode_contour_section(replace(self.section, contours=(base, base)))

    def test_malformed_section_corpus(self):
        encoded = encode_contour_section(self.section)
        for length in range(len(encoded)):
            with self.assertRaises(ValueError):
                decode_contour_section(encoded[:length])
        for offset in (0, 1, 2, 4, 6, 8, HEADER.size + 2, HEADER.size + 3, HEADER.size + 4, HEADER.size + 6):
            changed = bytearray(encoded)
            changed[offset] ^= 0x80
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                decode_contour_section(changed)

    @unittest.skipUnless(shutil.which("swiftc"), "Swift compiler required for iPhone cross-reader contract")
    def test_iphone_and_backend_accept_exactly_the_same_sections(self):
        executable = Path(self.tmp.name) / "swift-validator"
        subprocess.run(["swiftc", "-parse-as-library",
                        str(ROOT / "ios-app/BikeComputer/BikeComputer/Models/TopographyContourSection.swift"),
                        str(Path(__file__).with_name("contour_validator_cli.swift")), "-o", str(executable)],
                       check=True)
        section = encode_contour_section(self.section)
        corpus = [section, encode_contour_section(ContourSection(20, 100, ())),
                  section + b"\0", *(section[:size] for size in range(len(section)))]
        for position in range(len(section)):
            for mask in (1, 0x80, 0xff):
                changed = bytearray(section)
                changed[position] ^= mask
                corpus.append(bytes(changed))
        expected = []
        for value in corpus:
            try:
                decode_contour_section(value)
            except ValueError:
                expected.append("0")
            else:
                expected.append("1")
        actual = subprocess.run([str(executable)], input="\n".join(value.hex() for value in corpus) + "\n",
                                text=True, capture_output=True, check=True).stdout.splitlines()
        self.assertEqual(actual, expected)

    @unittest.skipUnless(shutil.which("c++"), "C++ compiler required for cross-reader contract")
    def test_firmware_and_backend_accept_exactly_the_same_corpus(self):
        executable = Path(self.tmp.name) / "validator"
        subprocess.run(["c++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                        "-I", str(ROOT / "esp32/lib/maps/src"),
                        str(Path(__file__).with_name("contour_validator_cli.cpp")),
                        str(ROOT / "esp32/lib/maps/src/mapBlockFormat.cpp"),
                        "-o", str(executable)], check=True, capture_output=True)
        block = upgrade_fmb4(self.path, self.section)
        directory, _ = _parse_base_geometry(block)
        entry = directory + 8 + 4 * 16
        offset, length = struct.unpack_from("<II", block, entry + 4)
        corpus = [block, upgrade_fmb4(self.path, ContourSection(20, 100, ())), block[:-1], block + b"\0"]
        # Refresh CRC so semantic corruption cannot be hidden by the checksum
        # check. Exercise every section byte under several changed bit patterns.
        for position in range(length):
            for mask in (1, 0x80, 0xff):
                changed = bytearray(block)
                changed[offset + position] ^= mask
                struct.pack_into("<I", changed, entry + 12, zlib.crc32(changed[offset:offset + length]) & 0xffffffff)
                corpus.append(bytes(changed))
        expected = []
        for value in corpus:
            self.path.write_bytes(value)
            try:
                validate_fmb5(self.path)
            except ValueError:
                expected.append("0")
            else:
                expected.append("1")
        actual = subprocess.run([str(executable)], input="\n".join(value.hex() for value in corpus) + "\n",
                                text=True, capture_output=True, check=True).stdout.splitlines()
        self.assertEqual(actual, expected)
