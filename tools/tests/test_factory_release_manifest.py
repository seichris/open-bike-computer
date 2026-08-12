from __future__ import annotations

import base64
import hashlib
import io
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
        images_dir = bundle_root / "images"
        images_dir.mkdir(parents=True)
        image_values = {
            "00000000-bootloader.bin": b"BOOT",
            "00000010-partitions.bin": b"PART",
            "00000020-boot_app0.bin": b"APP0",
            "00000030-firmware.bin": b"factory application image",
        }
        image_paths = {}
        for name, encoded in image_values.items():
            image_paths[name] = images_dir / name
            image_paths[name].write_bytes(encoded)
        image_path = image_paths["00000030-firmware.bin"]
        merged_size = 0x30 + image_path.stat().st_size
        merged_path = bundle_root / f"{TARGET}.factory.bin"
        merged_bytes = bytearray(b"\xff" * merged_size)
        for index, path in enumerate(image_paths.values()):
            offset = index * 0x10
            encoded = path.read_bytes()
            merged_bytes[offset : offset + len(encoded)] = encoded
        merged_path.write_bytes(merged_bytes)
        attestation_path = bundle_root / "attestation" / "build-manifest.json"
        attestation_path.parent.mkdir()
        runtime_provenance = {
            "lockSetId": "firmware-runtime-test-1",
            "target": "linux-x86_64-cp313",
            "manifestSha256": "1" * 64,
            "bundleSha256": "2" * 64,
        }
        runtime_digest = hashlib.sha256(
            json.dumps(
                runtime_provenance,
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
        ).hexdigest()
        attested_images = [
            {
                "offset": hex(index * 0x10),
                "path": f"/verified/{name.split('-', 1)[1]}",
                "size": path.stat().st_size,
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            }
            for index, (name, path) in enumerate(image_paths.items())
        ]
        attested_flash_plan = {
            "schema": 2,
            "environment": ENVIRONMENT,
            "applicationOffsetSource": "partition-table",
            "command": [
                "/verified/esptool",
                "--chip",
                "esp32s3",
                "write-flash",
                "--flash-mode",
                "keep",
                "--flash-freq",
                "keep",
                "--flash-size",
                "keep",
                *(
                    item
                    for image in attested_images
                    for item in (image["offset"], image["path"])
                ),
            ],
            "images": attested_images,
        }
        flash_plan_digest = hashlib.sha256(
            json.dumps(
                attested_flash_plan, sort_keys=True, separators=(",", ":")
            ).encode("utf-8")
        ).hexdigest()
        build_manifest_bytes = (
            json.dumps(
                {
                    "schema": 20,
                    "sourceIdentity": GIT_SHA,
                    "flashPlan": attested_flash_plan,
                    "flashPlanSha256": flash_plan_digest,
                    "runtimeProvenance": runtime_provenance,
                },
                sort_keys=True,
                separators=(",", ":"),
            )
            + "\n"
        ).encode("utf-8")
        attestation_path.write_bytes(build_manifest_bytes)
        descriptor = root / f"{TARGET}.factory-bundle.json"
        descriptor_value = {
            "schemaVersion": 2,
            "artifactType": "esp32-factory-flash-bundle",
            "target": TARGET,
            "environment": ENVIRONMENT,
            "sourceIdentity": GIT_SHA,
            "sourceDateEpoch": "1700000000",
            "buildTimestamp": "2023-11-14T22:13:20Z",
            "firmwareVersion": {"version": "2.3.4", "build": 57},
            "buildAttestation": {
                "schema": 20,
                "file": "attestation/build-manifest.json",
                "size": attestation_path.stat().st_size,
                "sha256": hashlib.sha256(attestation_path.read_bytes()).hexdigest(),
                "flashPlanSha256": flash_plan_digest,
            },
            "runtimeAttestation": {
                **runtime_provenance,
                "runtimeProvenanceSha256": runtime_digest,
            },
            "flashPlan": {
                "schemaVersion": 2,
                "chip": "esp32s3",
                "applicationOffsetSource": "partition-table",
                "flashCapacity": 1024 * 1024,
                "writeParameters": {
                    "flashMode": "keep",
                    "flashFrequency": "keep",
                    "flashSize": "keep",
                },
                "platformioResolvedParameters": {
                    "mode": "qio",
                    "frequency": "80m",
                    "size": "detect",
                },
                "images": [
                    {
                        "offset": hex(index * 0x10),
                        "file": f"images/{name}",
                        "size": path.stat().st_size,
                        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                    }
                    for index, (name, path) in enumerate(image_paths.items())
                ],
                "mergedImage": {
                    "offset": "0x0",
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
            descriptor_value = json.loads(
                descriptor.read_text(encoding="utf-8")
            )
            build_manifest_digest = descriptor_value["buildAttestation"][
                "sha256"
            ]
            runtime_digest = descriptor_value["runtimeAttestation"][
                "runtimeProvenanceSha256"
            ]
            expected = {
                "schemaVersion": 2,
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
                "buildAttestationSha256": build_manifest_digest,
                "runtimeProvenanceSha256": runtime_digest,
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
                "schemaVersion=2\n"
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
                f"buildAttestationSha256={build_manifest_digest}\n"
                f"runtimeProvenanceSha256={runtime_digest}\n"
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
                archive.addfile(unsafe, fileobj=io.BytesIO(b"x"))

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
            self.assertIn("unsafe path", completed.stderr)

    def test_cli_rejects_an_archive_with_another_embedded_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            bundle, descriptor, platformio_ini, key = self.create_inputs(root)
            value = json.loads(descriptor.read_text(encoding="utf-8"))
            value["sourceDateEpoch"] = "1700000001"
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
            self.assertIn("not identical", completed.stderr)

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
            self.assertIn("checksum mismatch", completed.stderr)

    def test_cli_rejects_image_bytes_not_declared_by_bundle_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            bundle, descriptor, platformio_ini, key = self.create_inputs(root)
            bundle_root = root / f"{TARGET}.factory"
            image_path = bundle_root / "images" / "00000030-firmware.bin"
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
            self.assertIn("merged image does not match", completed.stderr)

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

    def test_cli_rejects_external_descriptor_not_in_archive(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            bundle, descriptor, platformio_ini, key = self.create_inputs(root)
            descriptor.write_bytes(descriptor.read_bytes() + b" ")

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
            self.assertIn("not identical", completed.stderr)

    def test_cli_rejects_runtime_digest_not_bound_to_build(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            bundle, descriptor, platformio_ini, key = self.create_inputs(root)
            value = json.loads(descriptor.read_text(encoding="utf-8"))
            value["runtimeAttestation"]["runtimeProvenanceSha256"] = "f" * 64
            changed_descriptor = json.dumps(
                value, indent=2, sort_keys=True
            ) + "\n"
            descriptor.write_text(changed_descriptor, encoding="utf-8")
            bundle_root = root / f"{TARGET}.factory"
            (bundle_root / "factory-bundle.json").write_text(
                changed_descriptor, encoding="utf-8"
            )
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
            self.assertIn("runtime attestation does not match", completed.stderr)

    def test_cli_rejects_nonattested_flash_write_parameters(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            bundle, descriptor, platformio_ini, key = self.create_inputs(root)
            value = json.loads(descriptor.read_text(encoding="utf-8"))
            value["flashPlan"]["writeParameters"]["flashMode"] = "qio"
            changed_descriptor = json.dumps(
                value, indent=2, sort_keys=True
            ) + "\n"
            descriptor.write_text(changed_descriptor, encoding="utf-8")
            bundle_root = root / f"{TARGET}.factory"
            (bundle_root / "factory-bundle.json").write_text(
                changed_descriptor, encoding="utf-8"
            )
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
            self.assertIn("flash plan is invalid", completed.stderr)

    def test_cli_rejects_portable_offsets_not_bound_to_attested_plan(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            bundle, descriptor, platformio_ini, key = self.create_inputs(root)
            bundle_root = root / f"{TARGET}.factory"
            build_path = bundle_root / "attestation/build-manifest.json"
            build = json.loads(build_path.read_text(encoding="utf-8"))
            build["flashPlan"]["images"][-1]["offset"] = "0x40"
            build["flashPlan"]["command"][-2] = "0x40"
            build["flashPlanSha256"] = hashlib.sha256(
                json.dumps(
                    build["flashPlan"],
                    sort_keys=True,
                    separators=(",", ":"),
                ).encode("utf-8")
            ).hexdigest()
            build_path.write_text(
                json.dumps(build, sort_keys=True, separators=(",", ":")) + "\n",
                encoding="utf-8",
            )
            value = json.loads(descriptor.read_text(encoding="utf-8"))
            value["buildAttestation"].update(
                {
                    "size": build_path.stat().st_size,
                    "sha256": hashlib.sha256(build_path.read_bytes()).hexdigest(),
                    "flashPlanSha256": build["flashPlanSha256"],
                }
            )
            changed_descriptor = json.dumps(value, indent=2, sort_keys=True) + "\n"
            descriptor.write_text(changed_descriptor, encoding="utf-8")
            (bundle_root / "factory-bundle.json").write_text(
                changed_descriptor, encoding="utf-8"
            )
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
            self.assertIn("do not match the attested flash plan", completed.stderr)

    def test_cli_rejects_rehashed_non_erased_merged_gap(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            bundle, descriptor, platformio_ini, key = self.create_inputs(root)
            bundle_root = root / f"{TARGET}.factory"
            merged = bundle_root / f"{TARGET}.factory.bin"
            merged_bytes = bytearray(merged.read_bytes())
            merged_bytes[8] = 0
            merged.write_bytes(merged_bytes)
            value = json.loads(descriptor.read_text(encoding="utf-8"))
            value["flashPlan"]["mergedImage"]["sha256"] = hashlib.sha256(
                merged.read_bytes()
            ).hexdigest()
            changed_descriptor = json.dumps(value, indent=2, sort_keys=True) + "\n"
            descriptor.write_text(changed_descriptor, encoding="utf-8")
            (bundle_root / "factory-bundle.json").write_text(
                changed_descriptor, encoding="utf-8"
            )
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
            self.assertIn("gap is not erased", completed.stderr)


if __name__ == "__main__":
    unittest.main()
