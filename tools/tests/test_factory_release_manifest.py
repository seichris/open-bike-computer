from __future__ import annotations

import base64
import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec


SCRIPT = Path(__file__).resolve().parents[1] / "factory_release_manifest.py"
TARGET = "WAVESHARE_AMOLED_175"
ENVIRONMENT = f"{TARGET}_PRODUCTION"
GIT_SHA = "0123456789abcdef0123456789abcdef01234567"


class FactoryReleaseManifestTests(unittest.TestCase):
    def create_inputs(self, root: Path) -> tuple[Path, Path, Path, str]:
        bundle = root / f"{TARGET}.factory.tar.gz"
        bundle.write_bytes(b"deterministic factory archive")
        descriptor = root / f"{TARGET}.factory-bundle.json"
        descriptor.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "artifactType": "esp32-factory-flash-bundle",
                    "target": TARGET,
                    "environment": ENVIRONMENT,
                    "sourceIdentity": GIT_SHA,
                    "firmwareVersion": {"version": "2.3.4", "build": 57},
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        platformio_ini = root / "platformio.ini"
        platformio_ini.write_text(
            "[common]\nversion = 2.3.4\nrevision = 57\n",
            encoding="utf-8",
        )
        private_key_base64 = base64.b64encode(
            (1).to_bytes(32, byteorder="big")
        ).decode("ascii")
        return bundle, descriptor, platformio_ini, private_key_base64

    def command(
        self,
        *,
        bundle: Path,
        descriptor: Path,
        platformio_ini: Path,
        private_key_base64: str,
        output: Path,
    ) -> tuple[str, ...]:
        return (
            sys.executable,
            str(SCRIPT),
            "--bundle",
            str(bundle),
            "--bundle-manifest",
            str(descriptor),
            "--target",
            TARGET,
            "--repository",
            "owner/repository",
            "--tag",
            "v2.3.4",
            "--git-sha",
            GIT_SHA,
            "--private-key-base64",
            private_key_base64,
            "--output",
            str(output),
            "--platformio-ini",
            str(platformio_ini),
        )

    def test_cli_signs_the_archive_and_bundle_manifest_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            bundle, descriptor, platformio_ini, key = self.create_inputs(root)
            output = root / "release" / f"{TARGET}.factory-release.json"

            subprocess.run(
                self.command(
                    bundle=bundle,
                    descriptor=descriptor,
                    platformio_ini=platformio_ini,
                    private_key_base64=key,
                    output=output,
                ),
                check=True,
            )

            manifest = json.loads(output.read_text(encoding="utf-8"))
            expected = {
                "schemaVersion": 1,
                "artifactType": "esp32-factory-flash-bundle",
                "target": TARGET,
                "environment": ENVIRONMENT,
                "version": "2.3.4",
                "build": 57,
                "gitSha": GIT_SHA,
                "assetName": bundle.name,
                "size": bundle.stat().st_size,
                "sha256": hashlib.sha256(bundle.read_bytes()).hexdigest(),
                "bundleManifestName": descriptor.name,
                "bundleManifestSha256": hashlib.sha256(
                    descriptor.read_bytes()
                ).hexdigest(),
                "url": (
                    "https://github.com/owner/repository/releases/download/"
                    f"v2.3.4/{bundle.name}"
                ),
            }
            self.assertEqual(
                expected,
                {key: value for key, value in manifest.items() if key != "signature"},
            )
            payload = (
                "schemaVersion=1\n"
                "artifactType=esp32-factory-flash-bundle\n"
                f"target={TARGET}\n"
                f"environment={ENVIRONMENT}\n"
                "version=2.3.4\n"
                "build=57\n"
                f"gitSha={GIT_SHA}\n"
                f"assetName={bundle.name}\n"
                f"size={bundle.stat().st_size}\n"
                f"sha256={expected['sha256']}\n"
                f"bundleManifestName={descriptor.name}\n"
                f"bundleManifestSha256={expected['bundleManifestSha256']}\n"
                f"url={expected['url']}\n"
            ).encode("utf-8")
            public_key = ec.derive_private_key(1, ec.SECP256R1()).public_key()
            public_key.verify(
                base64.b64decode(manifest["signature"], validate=True),
                payload,
                ec.ECDSA(hashes.SHA256()),
            )

    def test_cli_rejects_a_bundle_manifest_for_another_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            bundle, descriptor, platformio_ini, key = self.create_inputs(root)
            value = json.loads(descriptor.read_text(encoding="utf-8"))
            value["sourceIdentity"] = "f" * 40
            descriptor.write_text(json.dumps(value), encoding="utf-8")

            completed = subprocess.run(
                self.command(
                    bundle=bundle,
                    descriptor=descriptor,
                    platformio_ini=platformio_ini,
                    private_key_base64=key,
                    output=root / "release.json",
                ),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(1, completed.returncode)
            self.assertIn("sourceIdentity does not match", completed.stderr)


if __name__ == "__main__":
    unittest.main()
