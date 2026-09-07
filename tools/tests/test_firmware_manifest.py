from __future__ import annotations

import base64
import argparse
import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec


SCRIPT = Path(__file__).resolve().parents[1] / "firmware_manifest.py"
SPEC = importlib.util.spec_from_file_location("firmware_manifest", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
firmware_manifest = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = firmware_manifest
SPEC.loader.exec_module(firmware_manifest)


class FirmwareManifestTests(unittest.TestCase):
    def test_new_signing_rejects_short_or_unverified_source_before_reading_image(self):
        for sha in ("a" * 12, "unverified-main", "A" * 40, "a" * 41):
            with self.subTest(sha=sha), self.assertRaisesRegex(ValueError, "full immutable Git SHA"):
                firmware_manifest.write_manifest(argparse.Namespace(git_sha=sha))

    def test_canonical_payload_requires_and_orders_signed_fields(self) -> None:
        manifest = {
            "schemaVersion": 1,
            "target": "WAVESHARE_AMOLED_175",
            "version": "2.3.4",
            "build": 57,
            "gitSha": "0123456789ab",
            "size": 18,
            "sha256": "abc123",
            "url": "https://example.invalid/firmware.bin",
            "minUpdaterProtocol": 1,
        }

        payload = firmware_manifest.canonical_payload(manifest).decode("utf-8")

        self.assertEqual(
            "schemaVersion=1\n"
            "target=WAVESHARE_AMOLED_175\n"
            "version=2.3.4\n"
            "build=57\n"
            "gitSha=0123456789ab\n"
            "size=18\n"
            "sha256=abc123\n"
            "url=https://example.invalid/firmware.bin\n"
            "minUpdaterProtocol=1\n",
            payload,
        )
        del manifest["sha256"]
        with self.assertRaisesRegex(ValueError, "manifest is missing sha256"):
            firmware_manifest.canonical_payload(manifest)

    def test_release_cli_emits_complete_hash_and_signature_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            firmware = root / "firmware.bin"
            firmware_bytes = b"open-bike-firmware"
            firmware.write_bytes(firmware_bytes)
            platformio_ini = root / "platformio.ini"
            platformio_ini.write_text(
                "[common]\nversion = 2.3.4\nrevision = 57\n",
                encoding="utf-8",
            )
            output = root / "public" / "manifest.json"
            private_scalar = (1).to_bytes(32, byteorder="big")
            private_key_base64 = base64.b64encode(private_scalar).decode("ascii")
            subprocess.run(
                (
                    sys.executable,
                    str(SCRIPT),
                    "--firmware",
                    str(firmware),
                    "--target",
                    "WAVESHARE_AMOLED_175",
                    "--repository",
                    "owner/repository",
                    "--tag",
                    "v2.3.4",
                    "--git-sha",
                    "0123456789abcdef0123456789abcdef01234567",
                    "--private-key-base64",
                    private_key_base64,
                    "--output",
                    str(output),
                    "--platformio-ini",
                    str(platformio_ini),
                ),
                check=True,
            )

            manifest = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(
                {
                    "schemaVersion": 1,
                    "target": "WAVESHARE_AMOLED_175",
                    "version": "2.3.4",
                    "build": 57,
                    "gitSha": "0123456789abcdef0123456789abcdef01234567",
                    "size": len(firmware_bytes),
                    "sha256": hashlib.sha256(firmware_bytes).hexdigest(),
                    "url": (
                        "https://github.com/owner/repository/releases/download/"
                        "v2.3.4/WAVESHARE_AMOLED_175.bin"
                    ),
                    "minUpdaterProtocol": 1,
                },
                {key: value for key, value in manifest.items() if key != "signature"},
            )
            expected_payload = (
                "schemaVersion=1\n"
                "target=WAVESHARE_AMOLED_175\n"
                "version=2.3.4\n"
                "build=57\n"
                "gitSha=0123456789abcdef0123456789abcdef01234567\n"
                f"size={len(firmware_bytes)}\n"
                f"sha256={hashlib.sha256(firmware_bytes).hexdigest()}\n"
                "url=https://github.com/owner/repository/releases/download/"
                "v2.3.4/WAVESHARE_AMOLED_175.bin\n"
                "minUpdaterProtocol=1\n"
            ).encode("utf-8")
            public_key = ec.derive_private_key(1, ec.SECP256R1()).public_key()
            public_key.verify(
                base64.b64decode(manifest["signature"], validate=True),
                expected_payload,
                ec.ECDSA(hashes.SHA256()),
            )

    def test_signing_rejects_a_zero_private_scalar(self) -> None:
        zero_scalar = base64.b64encode(bytes(32)).decode("ascii")

        with self.assertRaisesRegex(ValueError, "greater than zero"):
            firmware_manifest.sign_manifest({}, zero_scalar)


if __name__ == "__main__":
    unittest.main()
