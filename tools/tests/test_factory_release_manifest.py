from __future__ import annotations

import base64
import hashlib
import json
import subprocess
import sys
import tarfile
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
    def write_archive(self, bundle: Path, bundle_root: Path) -> None:
        with tarfile.open(bundle, "w:gz") as archive:
            archive.add(bundle_root, arcname=bundle_root.name)

    def write_checksums(self, bundle_root: Path) -> None:
        checksum_files = sorted(
            path
            for path in bundle_root.rglob("*")
            if path.is_file() and path.name != "SHA256SUMS"
        )
        (bundle_root / "SHA256SUMS").write_text(
            "".join(
                f"{hashlib.sha256(path.read_bytes()).hexdigest()}  "
                f"{path.relative_to(bundle_root).as_posix()}\n"
                for path in checksum_files
            ),
            encoding="utf-8",
        )

    def create_inputs(self, root: Path) -> tuple[Path, Path, Path, str]:
        bundle_root = root / f"{TARGET}.factory"
        image_path = bundle_root / "images" / "00010000-firmware.bin"
        image_path.parent.mkdir(parents=True)
        image_path.write_bytes(b"factory application image")
        merged_path = bundle_root / f"{TARGET}.factory.bin"
        merged_path.write_bytes(b"merged factory image")
        attestation_path = bundle_root / "attestation" / "build-manifest.json"
        attestation_path.parent.mkdir()
        attestation_path.write_bytes(b'{"schema":20}\n')
        descriptor = root / f"{TARGET}.factory-bundle.json"
        descriptor_value = {
            "schemaVersion": 1,
            "artifactType": "esp32-factory-flash-bundle",
            "target": TARGET,
            "environment": ENVIRONMENT,
            "sourceIdentity": GIT_SHA,
            "firmwareVersion": {"version": "2.3.4", "build": 57},
            "buildAttestation": {
                "file": "attestation/build-manifest.json",
                "size": attestation_path.stat().st_size,
                "sha256": hashlib.sha256(attestation_path.read_bytes()).hexdigest(),
            },
            "flashPlan": {
                "images": [
                    {
                        "file": "images/00010000-firmware.bin",
                        "size": image_path.stat().st_size,
                        "sha256": hashlib.sha256(image_path.read_bytes()).hexdigest(),
                    }
                ],
                "mergedImage": {
                    "file": merged_path.name,
                    "size": merged_path.stat().st_size,
                    "sha256": hashlib.sha256(merged_path.read_bytes()).hexdigest(),
                },
            },
        }
        descriptor_bytes = (
            json.dumps(descriptor_value, indent=2, sort_keys=True) + "\n"
        ).encode("utf-8")
        descriptor.write_bytes(descriptor_bytes)
        (bundle_root / "factory-bundle.json").write_bytes(descriptor_bytes)
        self.write_checksums(bundle_root)
        bundle = root / f"{TARGET}.factory.tar.gz"
        self.write_archive(bundle, bundle_root)
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
        tag: str = "v2.3.4",
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
            tag,
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

    def test_cli_rejects_a_corrupt_factory_archive(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            bundle, descriptor, platformio_ini, key = self.create_inputs(root)
            bundle.write_bytes(b"not a tar archive")

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
            self.assertIn("archive is invalid", completed.stderr)

    def test_cli_rejects_an_unsafe_archive_member(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            bundle, descriptor, platformio_ini, key = self.create_inputs(root)
            bundle_root = root / f"{TARGET}.factory"
            with tarfile.open(bundle, "w:gz") as archive:
                archive.add(bundle_root, arcname=bundle_root.name)
                unsafe = tarfile.TarInfo(f"{bundle_root.name}/../escape")
                unsafe.size = 1
                archive.addfile(unsafe, fileobj=None)

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
            self.assertIn("archive member is unsafe", completed.stderr)

    def test_cli_rejects_an_archive_with_another_embedded_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            bundle, descriptor, platformio_ini, key = self.create_inputs(root)
            value = json.loads(descriptor.read_text(encoding="utf-8"))
            value["releaseNote"] = "external manifest changed after packaging"
            descriptor.write_text(
                json.dumps(value, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )

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
            self.assertIn("supplied bundle manifest", completed.stderr)

    def test_cli_rejects_archive_checksum_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            bundle, descriptor, platformio_ini, key = self.create_inputs(root)
            bundle_root = root / f"{TARGET}.factory"
            checksum_path = bundle_root / "SHA256SUMS"
            checksum_path.write_text(
                ("0" * 64) + checksum_path.read_text(encoding="utf-8")[64:],
                encoding="utf-8",
            )
            self.write_archive(bundle, bundle_root)

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
            self.assertIn("SHA256SUMS does not match", completed.stderr)

    def test_cli_rejects_image_bytes_not_declared_by_bundle_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            bundle, descriptor, platformio_ini, key = self.create_inputs(root)
            bundle_root = root / f"{TARGET}.factory"
            image_path = bundle_root / "images" / "00010000-firmware.bin"
            image_path.write_bytes(b"different but internally checksummed image")
            self.write_checksums(bundle_root)
            self.write_archive(bundle, bundle_root)

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
            self.assertIn("in its manifest", completed.stderr)

    def test_cli_rejects_a_tag_for_another_firmware_version(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            bundle, descriptor, platformio_ini, key = self.create_inputs(root)

            completed = subprocess.run(
                self.command(
                    bundle=bundle,
                    descriptor=descriptor,
                    platformio_ini=platformio_ini,
                    private_key_base64=key,
                    output=root / "release.json",
                    tag="v9.9.9",
                ),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(1, completed.returncode)
            self.assertIn("does not match firmware version", completed.stderr)

    def test_cli_allows_a_version_matched_prerelease_tag(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            bundle, descriptor, platformio_ini, key = self.create_inputs(root)
            output = root / "release.json"

            completed = subprocess.run(
                self.command(
                    bundle=bundle,
                    descriptor=descriptor,
                    platformio_ini=platformio_ini,
                    private_key_base64=key,
                    output=output,
                    tag="v2.3.4-ota-test.1",
                ),
                check=False,
            )

            self.assertEqual(0, completed.returncode)
            self.assertTrue(output.is_file())

    def test_cli_rejects_symlinked_release_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            bundle, descriptor, platformio_ini, key = self.create_inputs(root)
            bundle_link = root / "linked" / bundle.name
            bundle_link.parent.mkdir()
            bundle_link.symlink_to(bundle)

            completed = subprocess.run(
                self.command(
                    bundle=bundle_link,
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
            self.assertIn("missing or unsafe", completed.stderr)


if __name__ == "__main__":
    unittest.main()
