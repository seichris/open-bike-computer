from __future__ import annotations

import json
import unittest
import tempfile
import hashlib
from pathlib import Path

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, utils

from map_platform.map_stream import (
    FIXED_HEADER_BYTES,
    MAX_BLOCK_BYTES,
    MAX_RELATIVE_PATH_BYTES,
    P256_ORDER,
    SIGNATURE_DOMAIN,
    MapStreamFormatError,
    MapStreamBuildError,
    MapStreamHeader,
    MapStreamLayout,
    MapStreamSignatureEnvelope,
    canonical_manifest_bytes,
    manifest_receipt,
    signed_manifest_receipt,
    write_map_stream_artifact,
)
from map_platform.map_signing import P256MapArtifactSigner
from tools.generate_map_stream_golden import build_vector


FIXTURE = Path(__file__).parent / "fixtures" / "map_stream_v1_golden.txt"


def read_fixture() -> dict[str, str]:
    return dict(line.split("=", 1) for line in FIXTURE.read_text().splitlines())


class MapStreamFormatTests(unittest.TestCase):
    def test_canonical_manifest_uses_integer_e7_bounds_and_rejects_floats(self):
        file = {
            "path": "VECTMAP/map/+0000+0000/1.fmb",
            "bytes": 1,
            "sha256": "0" * 64,
        }
        encoded = canonical_manifest_bytes(
            {
                "schemaVersion": 1,
                "mapId": "map",
                "bounds": [103.75, 1.24, 103.93, 1.37],
                "files": [file],
            }
        )
        self.assertIn(b'"boundsE7":[1037500000,12400000,1039300000,13700000]', encoded)
        self.assertNotIn(b'"bounds"', encoded)

        with self.assertRaises(MapStreamFormatError):
            canonical_manifest_bytes(
                {
                    "schemaVersion": 1,
                    "mapId": "map",
                    "files": [file],
                    "z": 1.234567890123456789,
                }
            )

        integer_extension = canonical_manifest_bytes(
            {
                "schemaVersion": 1,
                "mapId": "map",
                "files": [file],
                "z": -1,
            }
        )
        self.assertIn(b'"z":-1', integer_extension)

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
        self.assertEqual(header.payload_bytes, len(b"FMB\x01\x00\x00\x00\x00"))
        self.assertEqual(header.total_bytes, len(stream))
        self.assertEqual(envelope.key_id, "map-test-2026-01")
        self.assertEqual(payload, bytes.fromhex(fixture["payload_hex"]))
        self.assertEqual(manifest.hex(), fixture["manifest_hex"])
        self.assertEqual(json.loads(manifest)["preview"]["path"], "preview.png")
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

    def test_canonical_manifest_enforces_renderer_block_budget(self):
        path = "VECTMAP/map/+0000+0000/1.fmb"
        canonical_manifest_bytes(
            {
                "schemaVersion": 1,
                "mapId": "map",
                "files": [
                    {"path": path, "bytes": MAX_BLOCK_BYTES, "sha256": "0" * 64}
                ],
            }
        )
        with self.assertRaises(MapStreamFormatError):
            canonical_manifest_bytes(
                {
                    "schemaVersion": 1,
                    "mapId": "map",
                    "files": [
                        {
                            "path": path,
                            "bytes": MAX_BLOCK_BYTES + 1,
                            "sha256": "0" * 64,
                        }
                    ],
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

    def test_artifact_writer_is_deterministic_one_pass_and_payload_ordered(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            map_id = "writer-map"
            first_path = f"VECTMAP/{map_id}/+0000+0000/1.fmb"
            second_path = f"VECTMAP/{map_id}/+0000+0000/2.fmp"
            first = root / first_path
            second = root / second_path
            first.parent.mkdir(parents=True)
            first.write_bytes(b"first-payload")
            second.write_bytes(b"second-payload")
            manifest = {
                "schemaVersion": 1,
                "mapId": map_id,
                "files": [
                    {
                        "path": second_path,
                        "bytes": second.stat().st_size,
                        "sha256": hashlib.sha256(second.read_bytes()).hexdigest(),
                    },
                    {
                        "path": first_path,
                        "bytes": first.stat().st_size,
                        "sha256": hashlib.sha256(first.read_bytes()).hexdigest(),
                    },
                ],
            }
            signer = P256MapArtifactSigner(
                "map-writer-test",
                ec.derive_private_key(4, ec.SECP256R1()),
            )

            first_build = write_map_stream_artifact(root, manifest, signer, root / "first.bmap")
            second_build = write_map_stream_artifact(root, manifest, signer, root / "second.bmap")
            self.assertEqual(first_build.sha256, second_build.sha256)
            self.assertEqual(first_build.path.read_bytes(), second_build.path.read_bytes())
            self.assertEqual(first_build.sha256, hashlib.sha256(first_build.path.read_bytes()).hexdigest())
            self.assertEqual(first_build.file_count, 2)
            self.assertEqual(first_build.payload_bytes, len(b"first-payloadsecond-payload"))
            stream = first_build.path.read_bytes()
            header = MapStreamHeader.decode(stream[:FIXED_HEADER_BYTES])
            layout = MapStreamLayout.from_header(header, len(stream))
            self.assertEqual(stream[layout.payload_offset :], b"first-payloadsecond-payload")
            self.assertTrue(all(value >= 0 for value in first_build.timings.values()))

            second.write_bytes(b"changed-after-manifest")
            failed_output = root / "failed.bmap"
            with self.assertRaises(MapStreamBuildError):
                write_map_stream_artifact(root, manifest, signer, failed_output)
            self.assertFalse(failed_output.exists())

            blocked_parent = root / "not-a-directory"
            blocked_parent.write_bytes(b"file")
            with self.assertRaises(MapStreamBuildError) as raised:
                write_map_stream_artifact(
                    root,
                    manifest,
                    signer,
                    blocked_parent / "failed.bmap",
                )
            self.assertEqual(raised.exception.code, "map_stream_build_failed")

    def test_artifact_writer_omits_redundant_oversized_text_fallback(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            map_id = "binary-preferred-map"
            binary_path = f"VECTMAP/{map_id}/+0000+0000/1.fmb"
            ascii_path = f"VECTMAP/{map_id}/+0000+0000/1.fmp"
            binary = root / binary_path
            ascii_fallback = root / ascii_path
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"binary-map-block")
            ascii_fallback.write_bytes(b"x" * (MAX_BLOCK_BYTES + 1))
            manifest = {
                "schemaVersion": 1,
                "mapId": map_id,
                "files": [
                    {
                        "path": ascii_path,
                        "bytes": ascii_fallback.stat().st_size,
                        "sha256": hashlib.sha256(ascii_fallback.read_bytes()).hexdigest(),
                    },
                    {
                        "path": binary_path,
                        "bytes": binary.stat().st_size,
                        "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                    },
                ],
            }
            signer = P256MapArtifactSigner(
                "map-writer-test",
                ec.derive_private_key(4, ec.SECP256R1()),
            )

            build = write_map_stream_artifact(
                root,
                manifest,
                signer,
                root / "binary-preferred.bmap",
            )

            stream = build.path.read_bytes()
            header = MapStreamHeader.decode(stream[:FIXED_HEADER_BYTES])
            layout = MapStreamLayout.from_header(header, len(stream))
            stream_manifest = json.loads(
                stream[layout.manifest_offset : layout.signature_envelope_offset]
            )
            self.assertEqual(build.file_count, 1)
            self.assertEqual(build.payload_bytes, binary.stat().st_size)
            self.assertEqual(
                [file["path"] for file in stream_manifest["files"]],
                [binary_path],
            )
            self.assertEqual(stream[layout.payload_offset :], binary.read_bytes())


if __name__ == "__main__":
    unittest.main()
