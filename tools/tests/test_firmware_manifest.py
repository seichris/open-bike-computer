from __future__ import annotations

import argparse
import base64
import importlib.util
import json
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
    def test_canonical_payload_requires_and_orders_signed_fields(self) -> None:
        manifest = {
            field: index
            for index, field in enumerate(reversed(firmware_manifest.SIGNATURE_FIELDS))
        }

        payload = firmware_manifest.canonical_payload(manifest).decode("utf-8")

        self.assertEqual(
            "".join(
                f"{field}={manifest[field]}\n"
                for field in firmware_manifest.SIGNATURE_FIELDS
            ),
            payload,
        )
        del manifest["sha256"]
        with self.assertRaisesRegex(ValueError, "manifest is missing sha256"):
            firmware_manifest.canonical_payload(manifest)

    def test_write_manifest_hashes_and_signs_release_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            firmware = root / "firmware.bin"
            firmware.write_bytes(b"open-bike-firmware")
            platformio_ini = root / "platformio.ini"
            platformio_ini.write_text(
                "[common]\nversion = 2.3.4\nrevision = 57\n",
                encoding="utf-8",
            )
            output = root / "public" / "manifest.json"
            private_scalar = (1).to_bytes(32, byteorder="big")
            private_key_base64 = base64.b64encode(private_scalar).decode("ascii")
            args = argparse.Namespace(
                firmware=firmware,
                target="WAVESHARE_AMOLED_175",
                repository="owner/repository",
                git_sha="0123456789ab",
                private_key_base64=private_key_base64,
                output=output,
                platformio_ini=platformio_ini,
                version=None,
                build=None,
                tag="v2.3.4",
                asset_name=None,
                min_updater_protocol=2,
            )

            firmware_manifest.write_manifest(args)

            manifest = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual("2.3.4", manifest["version"])
            self.assertEqual(57, manifest["build"])
            self.assertEqual(len(b"open-bike-firmware"), manifest["size"])
            self.assertEqual(
                "https://github.com/owner/repository/releases/download/"
                "v2.3.4/WAVESHARE_AMOLED_175.bin",
                manifest["url"],
            )
            public_key = ec.derive_private_key(1, ec.SECP256R1()).public_key()
            public_key.verify(
                base64.b64decode(manifest["signature"], validate=True),
                firmware_manifest.canonical_payload(manifest),
                ec.ECDSA(hashes.SHA256()),
            )

    def test_signing_rejects_a_zero_private_scalar(self) -> None:
        manifest = {
            field: index
            for index, field in enumerate(firmware_manifest.SIGNATURE_FIELDS)
        }
        zero_scalar = base64.b64encode(bytes(32)).decode("ascii")

        with self.assertRaisesRegex(ValueError, "greater than zero"):
            firmware_manifest.sign_manifest(manifest, zero_scalar)


if __name__ == "__main__":
    unittest.main()
