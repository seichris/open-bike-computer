from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from tools.generate_map_stream_trust import (
    FORBIDDEN_FIXTURE_PUBLIC_KEYS,
    check_outputs,
    expected_outputs,
    load_registry,
    public_registry_entry_from_private_key,
    render_cpp,
    render_swift,
)


class MapStreamTrustRegistryTests(unittest.TestCase):
    def public_key_hex(self, scalar: int) -> str:
        public_key = ec.derive_private_key(
            scalar,
            ec.SECP256R1(),
        ).public_key()
        return public_key.public_bytes(
            serialization.Encoding.X962,
            serialization.PublicFormat.UncompressedPoint,
        ).hex()

    def write_registry(self, document: dict) -> Path:
        path = Path(self.tmp.name) / "trust.json"
        path.write_text(json.dumps(document), encoding="utf-8")
        return path

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.tmp.cleanup()

    def test_one_registry_generates_matching_swift_and_cpp_trust(self):
        path = self.write_registry(
            {
                "schemaVersion": 1,
                "keys": [
                    {
                        "keyId": "map-prod-2026-01",
                        "publicKeyX963Hex": self.public_key_hex(7),
                        "state": "trusted",
                        "createdAt": "2026-07-13",
                        "retireAfter": "2027-07-13",
                    },
                    {
                        "keyId": "map-retired-2025-01",
                        "publicKeyX963Hex": self.public_key_hex(8),
                        "state": "retired",
                        "createdAt": "2025-01-01",
                    },
                ],
            }
        )
        keys = load_registry(path)
        swift = render_swift(keys)
        cpp = render_cpp(keys)
        self.assertIn("map-prod-2026-01", swift)
        self.assertIn("map-prod-2026-01", cpp)
        self.assertNotIn("map-retired-2025-01", swift)
        self.assertNotIn("map-retired-2025-01", cpp)
        self.assertIn(self.public_key_hex(7), swift)
        self.assertIn(self.public_key_hex(7), cpp)
        fingerprint = hashlib.sha256(bytes.fromhex(self.public_key_hex(7))).hexdigest()
        self.assertIn(fingerprint, cpp)

    def test_schema_version_must_be_an_integer(self):
        with self.assertRaisesRegex(ValueError, "unsupported"):
            load_registry(
                self.write_registry({"schemaVersion": True, "keys": []})
            )

    def test_fixture_and_private_key_material_are_rejected(self):
        fixture_public_key = sorted(FORBIDDEN_FIXTURE_PUBLIC_KEYS)[0]
        fixture = {
            "schemaVersion": 1,
            "keys": [
                {
                    "keyId": "map-prod-unsafe",
                    "publicKeyX963Hex": fixture_public_key,
                    "state": "trusted",
                    "createdAt": "2026-07-13",
                }
            ],
        }
        with self.assertRaisesRegex(ValueError, "golden-vector public keys"):
            load_registry(self.write_registry(fixture))

        private_material = {
            "schemaVersion": 1,
            "keys": [
                {
                    "keyId": "map-prod-2026-01",
                    "publicKeyX963Hex": self.public_key_hex(9),
                    "state": "trusted",
                    "createdAt": "2026-07-13",
                    "privateKey": "forbidden",
                }
            ],
        }
        with self.assertRaisesRegex(ValueError, "missing or unexpected fields"):
            load_registry(self.write_registry(private_material))

    def test_invalid_points_duplicates_order_and_trust_size_fail_closed(self):
        invalid_documents = [
            {
                "schemaVersion": 1,
                "keys": [
                    {
                        "keyId": "map-prod-invalid",
                        "publicKeyX963Hex": "04" + "00" * 64,
                        "state": "trusted",
                        "createdAt": "2026-07-13",
                    }
                ],
            },
            {
                "schemaVersion": 1,
                "keys": [
                    {
                        "keyId": "z-key",
                        "publicKeyX963Hex": self.public_key_hex(10),
                        "state": "trusted",
                        "createdAt": "2026-07-13",
                    },
                    {
                        "keyId": "a-key",
                        "publicKeyX963Hex": self.public_key_hex(11),
                        "state": "trusted",
                        "createdAt": "2026-07-13",
                    },
                ],
            },
            {
                "schemaVersion": 1,
                "keys": [
                    {
                        "keyId": f"map-prod-{index}",
                        "publicKeyX963Hex": self.public_key_hex(20 + index),
                        "state": "trusted",
                        "createdAt": "2026-07-13",
                    }
                    for index in range(5)
                ],
            },
        ]
        for document in invalid_documents:
            with self.subTest(document=document):
                with self.assertRaises(ValueError):
                    load_registry(self.write_registry(document))

    def test_checked_in_generated_files_match_the_registry(self):
        self.assertTrue(check_outputs(expected_outputs()))

    def test_duplicate_registry_keys_are_rejected(self):
        path = Path(self.tmp.name) / "duplicate-trust.json"
        path.write_text(
            '{"schemaVersion":1,"schemaVersion":1,"keys":[]}',
            encoding="utf-8",
        )
        with self.assertRaisesRegex(ValueError, "duplicate JSON object key"):
            load_registry(path)

    def test_trust_dates_must_be_canonical_and_chronological(self):
        document = {
            "schemaVersion": 1,
            "keys": [
                {
                    "keyId": "map-prod-date-test",
                    "publicKeyX963Hex": self.public_key_hex(13),
                    "state": "trusted",
                    "createdAt": "2026-12-31",
                    "retireAfter": "2026-W01-1",
                }
            ],
        }
        with self.assertRaisesRegex(ValueError, "ISO date"):
            load_registry(self.write_registry(document))

    def test_private_key_inspection_emits_public_registry_material_only(self):
        private_path = Path(self.tmp.name) / "map-signing-key.pem"
        private_key = ec.derive_private_key(12, ec.SECP256R1())
        private_path.write_bytes(
            private_key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            )
        )
        private_path.chmod(0o600)
        entry = public_registry_entry_from_private_key(
            private_path,
            key_id="map-prod-2026-01",
            created_at="2026-07-13",
            retire_after="2027-07-13",
        )
        self.assertEqual(entry["publicKeyX963Hex"], self.public_key_hex(12))
        self.assertNotIn("private", " ".join(entry).lower())
        self.assertNotIn("pem", json.dumps(entry).lower())

        fixture_path = Path(self.tmp.name) / "fixture-key.pem"
        fixture_path.write_bytes(
            ec.derive_private_key(1, ec.SECP256R1()).private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            )
        )
        fixture_path.chmod(0o600)
        with self.assertRaisesRegex(ValueError, "golden-vector private keys"):
            public_registry_entry_from_private_key(
                fixture_path,
                key_id="map-prod-forbidden",
                created_at="2026-07-13",
                retire_after=None,
            )


if __name__ == "__main__":
    unittest.main()
