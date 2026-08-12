from __future__ import annotations

import hashlib
import importlib.util
import json
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "package_factory_firmware.py"
PROJECT_DIR = SCRIPT.parents[1]
if str(SCRIPT.parent) not in sys.path:
    sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("package_factory_firmware", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
package_factory_firmware = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = package_factory_firmware
SPEC.loader.exec_module(package_factory_firmware)


TARGET = "WAVESHARE_AMOLED_175"
ENVIRONMENT = f"{TARGET}_PRODUCTION"
GIT_SHA = "0123456789abcdef0123456789abcdef01234567"


def sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


class FactoryFirmwareBundleTests(unittest.TestCase):
    def test_repository_production_profiles_resolve_configured_capacity(self) -> None:
        platformio_ini = PROJECT_DIR / "platformio.ini"
        expected_sha256 = sha256(platformio_ini.read_bytes())

        for environment in (
            "WAVESHARE_AMOLED_175_PRODUCTION",
            "WAVESHARE_AMOLED_206_PRODUCTION",
        ):
            with self.subTest(environment=environment):
                _, capacity = package_factory_firmware._read_release_metadata(
                    platformio_ini,
                    expected_sha256,
                    environment,
                )
                self.assertEqual(16 * 1024 * 1024, capacity)

    def create_project(self, root: Path) -> tuple[Path, Path, dict[str, Path]]:
        project = root / "esp32"
        project.mkdir()
        (project / "platformio.ini").write_text(
            "[common]\n"
            "version = 2.3.4\n"
            "revision = 57\n"
            "[factory_base]\n"
            "board_upload.flash_size = 1MB\n"
            f"[env:{ENVIRONMENT}]\n"
            "extends = factory_base\n",
            encoding="utf-8",
        )
        build_dir = project / ".pio" / "build" / ENVIRONMENT
        build_dir.mkdir(parents=True)
        framework_dir = project / ".pio" / "framework" / "partitions"
        framework_dir.mkdir(parents=True)
        image_values = {
            "bootloader.bin": b"BOOT",
            "partitions.bin": b"PART",
            "boot_app0.bin": b"APP0",
            "firmware.bin": b"FIRMWARE",
        }
        images = {
            "bootloader.bin": build_dir / "bootloader.bin",
            "partitions.bin": build_dir / "partitions.bin",
            "boot_app0.bin": framework_dir / "boot_app0.bin",
            "firmware.bin": build_dir / "firmware.bin",
        }
        for name, path in images.items():
            path.write_bytes(image_values[name])

        offsets = {
            "bootloader.bin": "0x0",
            "partitions.bin": "0x10",
            "boot_app0.bin": "0x20",
            "firmware.bin": "0x30",
        }
        flash_images = [
            {
                "offset": offsets[name],
                "path": str(path.resolve()),
                "size": path.stat().st_size,
                "sha256": sha256(path.read_bytes()),
            }
            for name, path in images.items()
        ]
        command = [
            "/verified/esptool",
            "--chip",
            "esp32s3",
            "--port",
            "__OPEN_BIKE_UPLOAD_PORT__",
            "write-flash",
            "-z",
            "--flash-mode",
            "keep",
            "--flash-freq",
            "keep",
            "--flash-size",
            "keep",
        ]
        for image in flash_images:
            command.extend((image["offset"], image["path"]))
        flash_plan = {
            "schema": 2,
            "environment": ENVIRONMENT,
            "uploadPortPlaceholder": "__OPEN_BIKE_UPLOAD_PORT__",
            "uploader": "/verified/esptool",
            "command": command,
            "platformioFlashParameters": {
                "mode": "qio",
                "frequency": "80m",
                "size": "detect",
            },
            "platformioAppOffset": "0x30",
            "applicationOffsetSource": "partition-table",
            "images": flash_images,
        }
        manifest = {
            "schema": 20,
            "sourceIdentity": GIT_SHA,
            "sourceDateEpoch": 1_700_000_000,
            "buildTimestamp": "2023-11-14T22:13:20Z",
            "uploadEligible": True,
            "platformioIniSha256": sha256(
                (project / "platformio.ini").read_bytes()
            ),
            "firmwareBinSha256": flash_images[3]["sha256"],
            "bootloaderBinSha256": flash_images[0]["sha256"],
            "partitionTableBinSha256": flash_images[1]["sha256"],
            "bootApp0Sha256": flash_images[2]["sha256"],
            "flashPlan": flash_plan,
            "flashPlanSha256": hashlib.sha256(
                json.dumps(
                    flash_plan, sort_keys=True, separators=(",", ":")
                ).encode("utf-8")
            ).hexdigest(),
        }
        manifest_path = (
            project
            / ".pio"
            / "open-bike-build"
            / "builds"
            / ENVIRONMENT
            / "current.json"
        )
        manifest_path.parent.mkdir(parents=True)
        manifest_path.write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        return project, manifest_path, images

    def package(self, project: Path, output: Path) -> tuple[Path, Path]:
        with mock.patch.object(
            package_factory_firmware,
            "current_source_identity",
            return_value=GIT_SHA,
        ):
            return package_factory_firmware.package_factory_bundle(
                project_dir=project,
                environment=ENVIRONMENT,
                target=TARGET,
                expected_git_sha=GIT_SHA,
                output_dir=output,
            )

    def test_bundle_is_complete_portable_and_reproducible(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            project, manifest_path, images = self.create_project(root)
            archive, descriptor_path = self.package(project, root / "dist-one")
            second_archive, second_descriptor = self.package(
                project, root / "dist-two"
            )

            self.assertEqual(archive.read_bytes(), second_archive.read_bytes())
            self.assertEqual(
                descriptor_path.read_bytes(), second_descriptor.read_bytes()
            )
            descriptor = json.loads(descriptor_path.read_text(encoding="utf-8"))
            self.assertEqual(1, descriptor["schemaVersion"])
            self.assertEqual(
                "esp32-factory-flash-bundle", descriptor["artifactType"]
            )
            self.assertEqual(TARGET, descriptor["target"])
            self.assertEqual(ENVIRONMENT, descriptor["environment"])
            self.assertEqual(GIT_SHA, descriptor["sourceIdentity"])
            self.assertEqual(
                {"version": "2.3.4", "build": 57},
                descriptor["firmwareVersion"],
            )
            self.assertEqual(
                sha256(manifest_path.read_bytes()),
                descriptor["buildAttestation"]["sha256"],
            )
            self.assertEqual(
                {"flashMode": "keep", "flashFrequency": "keep", "flashSize": "keep"},
                descriptor["flashPlan"]["writeParameters"],
            )
            self.assertEqual(
                1024 * 1024, descriptor["flashPlan"]["flashCapacity"]
            )
            self.assertEqual(
                "detect",
                descriptor["flashPlan"]["platformioResolvedParameters"]["size"],
            )

            root_name = f"{TARGET}.factory"
            with tarfile.open(archive, "r:gz") as bundle:
                names = set(bundle.getnames())
                self.assertIn(f"{root_name}/factory-bundle.json", names)
                self.assertIn(f"{root_name}/SHA256SUMS", names)
                self.assertIn(
                    f"{root_name}/attestation/build-manifest.json", names
                )
                for offset, name in (
                    (0x0, "bootloader.bin"),
                    (0x10, "partitions.bin"),
                    (0x20, "boot_app0.bin"),
                    (0x30, "firmware.bin"),
                ):
                    self.assertIn(
                        f"{root_name}/images/{offset:08x}-{name}", names
                    )
                merged = bundle.extractfile(
                    f"{root_name}/{TARGET}.factory.bin"
                )
                assert merged is not None
                merged_bytes = merged.read()
                self.assertEqual(
                    images["bootloader.bin"].read_bytes(), merged_bytes[:4]
                )
                self.assertEqual(b"\xff" * 12, merged_bytes[4:0x10])
                self.assertEqual(
                    images["partitions.bin"].read_bytes(),
                    merged_bytes[0x10:0x14],
                )
                self.assertEqual(
                    images["boot_app0.bin"].read_bytes(),
                    merged_bytes[0x20:0x24],
                )
                self.assertEqual(
                    images["firmware.bin"].read_bytes(), merged_bytes[0x30:]
                )
                embedded_descriptor = bundle.extractfile(
                    f"{root_name}/factory-bundle.json"
                )
                assert embedded_descriptor is not None
                self.assertEqual(
                    descriptor_path.read_bytes(), embedded_descriptor.read()
                )
                for member in bundle.getmembers():
                    self.assertEqual(1_700_000_000, member.mtime)
                    self.assertEqual(0, member.uid)
                    self.assertEqual(0, member.gid)
                    self.assertEqual("root", member.uname)
                    self.assertEqual("root", member.gname)
                    self.assertFalse(member.issym())
                    self.assertFalse(member.islnk())
                checksum_member = bundle.extractfile(
                    f"{root_name}/SHA256SUMS"
                )
                assert checksum_member is not None
                checksums = checksum_member.read().decode("utf-8").splitlines()
                self.assertEqual(7, len(checksums))
                for line in checksums:
                    digest, relative = line.split("  ", maxsplit=1)
                    member = bundle.extractfile(f"{root_name}/{relative}")
                    assert member is not None
                    self.assertEqual(digest, sha256(member.read()))

    def test_changed_image_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            project, _, images = self.create_project(root)
            images["firmware.bin"].write_bytes(b"changed after attestation")

            with self.assertRaisesRegex(
                package_factory_firmware.BundleError,
                "size changed after attestation|changed after attestation",
            ):
                self.package(project, root / "dist")

    def test_changed_source_identity_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            project, _, _ = self.create_project(root)

            with mock.patch.object(
                package_factory_firmware,
                "current_source_identity",
                return_value=f"dirty-{GIT_SHA}",
            ):
                with self.assertRaisesRegex(
                    package_factory_firmware.BundleError,
                    "source changed after",
                ):
                    package_factory_firmware.package_factory_bundle(
                        project_dir=project,
                        environment=ENVIRONMENT,
                        target=TARGET,
                        expected_git_sha=GIT_SHA,
                        output_dir=root / "dist",
                    )

    def test_changed_platformio_metadata_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            project, _, _ = self.create_project(root)
            (project / "platformio.ini").write_text(
                "[common]\nversion = 9.9.9\nrevision = 999\n"
                "[factory_base]\nboard_upload.flash_size = 1MB\n"
                f"[env:{ENVIRONMENT}]\nextends = factory_base\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                package_factory_firmware.BundleError,
                "PlatformIO configuration changed",
            ):
                self.package(project, root / "dist")

    def test_nonproduction_environment_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            project, _, _ = self.create_project(root)

            with self.assertRaisesRegex(
                package_factory_firmware.BundleError,
                "matching production environment",
            ):
                with mock.patch.object(
                    package_factory_firmware,
                    "current_source_identity",
                    return_value=GIT_SHA,
                ):
                    package_factory_firmware.package_factory_bundle(
                        project_dir=project,
                        environment=TARGET,
                        target=TARGET,
                        expected_git_sha=GIT_SHA,
                        output_dir=root / "dist",
                    )


if __name__ == "__main__":
    unittest.main()
