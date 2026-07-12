from __future__ import annotations

import unittest
from pathlib import Path

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, utils

from map_platform.map_stream import (
    FIXED_HEADER_BYTES,
    MAX_RELATIVE_PATH_BYTES,
    P256_ORDER,
    SIGNATURE_DOMAIN,
    MapStreamFormatError,
    MapStreamHeader,
    MapStreamLayout,
    MapStreamSignatureEnvelope,
    canonical_manifest_bytes,
    manifest_receipt,
    signed_manifest_receipt,
)
from tools.generate_map_stream_golden import build_vector


FIXTURE = Path(__file__).parent / "fixtures" / "map_stream_v1_golden.txt"


def read_fixture() -> dict[str, str]:
    return dict(line.split("=", 1) for line in FIXTURE.read_text().splitlines())


class MapStreamFormatTests(unittest.TestCase):
    def test_golden_vector_header_envelope_receipts_and_signature(self):
        fixture = read_fixture()
        stream = bytes.fromhex(fixture["stream_hex"])
        header = MapStreamHeader.decode(stream[:FIXED_HEADER_BYTES])
        layout = MapStreamLayout.from_header(header, len(stream))
        manifest = stream[layout.manifest_offset : layout.signature_envelope_offset]
        envelope_bytes = stream[layout.signature_envelope_offset : layout.payload_offset]
        payload = stream[layout.payload_offset : layout.end_offset]
        envelope = MapStreamSignatureEnvelope.decode(envelope_bytes)

        self.assertEqual(header.file_count, 1)
        self.assertEqual(header.payload_bytes, len(b"map-block"))
        self.assertEqual(header.total_bytes, len(stream))
        self.assertEqual(envelope.key_id, "map-test-2026-01")
        self.assertEqual(payload, bytes.fromhex(fixture["payload_hex"]))
        self.assertEqual(manifest.hex(), fixture["manifest_hex"])
        self.assertEqual(manifest_receipt(manifest), fixture["manifest_receipt"])
        self.assertEqual(
            signed_manifest_receipt(manifest, envelope_bytes),
            fixture["signed_manifest_receipt"],
        )

        public_key = ec.EllipticCurvePublicKey.from_encoded_point(
            ec.SECP256R1(), bytes.fromhex(fixture["public_key_x963_hex"])
        )
        raw = envelope.raw_signature
        der = utils.encode_dss_signature(
            int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big")
        )
        public_key.verify(der, SIGNATURE_DOMAIN + manifest, ec.ECDSA(hashes.SHA256()))

        tampered_manifest = bytearray(manifest)
        tampered_manifest[0] ^= 1
        with self.assertRaises(InvalidSignature):
            public_key.verify(
                der,
                SIGNATURE_DOMAIN + bytes(tampered_manifest),
                ec.ECDSA(hashes.SHA256()),
            )
        tampered_raw = bytearray(raw)
        tampered_raw[-1] ^= 1
        tampered_der = utils.encode_dss_signature(
            int.from_bytes(tampered_raw[:32], "big"),
            int.from_bytes(tampered_raw[32:], "big"),
        )
        with self.assertRaises(InvalidSignature):
            public_key.verify(
                tampered_der,
                SIGNATURE_DOMAIN + manifest,
                ec.ECDSA(hashes.SHA256()),
            )

        with self.assertRaises(MapStreamFormatError):
            MapStreamLayout.from_header(header, len(stream) - 1)
        with self.assertRaises(MapStreamFormatError):
            MapStreamLayout.from_header(header, len(stream) + 1)

    def test_rejects_unsupported_header_and_malformed_envelope(self):
        fixture = read_fixture()
        header = bytearray.fromhex(fixture["header_hex"])
        header[8] = 2
        with self.assertRaises(MapStreamFormatError):
            MapStreamHeader.decode(bytes(header))

        envelope = bytearray.fromhex(fixture["signature_envelope_hex"])
        envelope[2] = 63
        with self.assertRaises(MapStreamFormatError):
            MapStreamSignatureEnvelope.decode(bytes(envelope))

    def test_canonical_manifest_sorts_files_and_rejects_duplicates(self):
        first = {"path": "VECTMAP/map/+0000+0000/2.fmb", "bytes": 1, "sha256": "0" * 64}
        second = {"path": "VECTMAP/map/+0000+0000/1.fmb", "bytes": 1, "sha256": "1" * 64}
        forward = canonical_manifest_bytes(
            {"schemaVersion": 1, "mapId": "map", "files": [first, second]}
        )
        reverse = canonical_manifest_bytes(
            {"schemaVersion": 1, "mapId": "map", "files": [second, first]}
        )
        self.assertEqual(forward, reverse)
        self.assertLess(forward.index(b"1.fmb"), forward.index(b"2.fmb"))
        with self.assertRaises(MapStreamFormatError):
            canonical_manifest_bytes(
                {"schemaVersion": 1, "mapId": "map", "files": [first, first]}
            )

    def test_canonical_manifest_rejects_unsafe_or_noncanonical_paths(self):
        def manifest(path: str) -> dict[str, object]:
            return {
                "schemaVersion": 1,
                "mapId": "map",
                "files": [{"path": path, "bytes": 1, "sha256": "0" * 64}],
            }

        invalid_paths = (
            "../VECTMAP/map/+0000+0000/1.fmb",
            "/VECTMAP/map/+0000+0000/1.fmb",
            "VECTMAP/map//+0000+0000/1.fmb",
            "VECTMAP/map/./1.fmb",
            "VECTMAP/map/+0000+0000/1.txt",
            "VECTMAP/other/+0000+0000/1.fmb",
            "VECTMAP/map/+0000+0000/1.fmb\n",
        )
        for path in invalid_paths:
            with self.subTest(path=path), self.assertRaises(MapStreamFormatError):
                canonical_manifest_bytes(manifest(path))

    def test_canonical_manifest_freezes_device_compatible_path_limits(self):
        map_id = "m" * 64
        directory = "d" * 64
        filename = f"{'f' * 60}.fmb"
        maximum_path = f"VECTMAP/{map_id}/{directory}/{filename}"
        self.assertEqual(len(maximum_path.encode("ascii")), MAX_RELATIVE_PATH_BYTES)
        canonical_manifest_bytes(
            {
                "schemaVersion": 1,
                "mapId": map_id,
                "files": [{"path": maximum_path, "bytes": 1, "sha256": "0" * 64}],
            }
        )

        invalid = (
            ("m" * 65, f"VECTMAP/{'m' * 65}/{directory}/{filename}"),
            (map_id, f"VECTMAP/{map_id}/{'d' * 65}/{filename}"),
            (map_id, f"VECTMAP/{map_id}/{directory}/{'f' * 61}.fmb"),
        )
        for oversized_map_id, path in invalid:
            with self.subTest(path=path), self.assertRaises(MapStreamFormatError):
                canonical_manifest_bytes(
                    {
                        "schemaVersion": 1,
                        "mapId": oversized_map_id,
                        "files": [{"path": path, "bytes": 1, "sha256": "0" * 64}],
                    }
                )

    def test_signature_envelope_rejects_malleable_high_s_twin(self):
        fixture = read_fixture()
        envelope = bytearray.fromhex(fixture["signature_envelope_hex"])
        s = int.from_bytes(envelope[-32:], "big")
        envelope[-32:] = (P256_ORDER - s).to_bytes(32, "big")
        with self.assertRaises(MapStreamFormatError):
            MapStreamSignatureEnvelope.decode(bytes(envelope))

    def test_golden_generator_is_deterministic_and_fixture_is_current(self):
        fixture = read_fixture()
        self.assertEqual(build_vector(), build_vector())
        self.assertEqual(build_vector(), fixture)


if __name__ == "__main__":
    unittest.main()
