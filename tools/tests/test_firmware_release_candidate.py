from __future__ import annotations

import hashlib
import importlib.util
import json
import stat
import tempfile
import unittest
import zipfile
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "firmware_release_candidate.py"
SPEC = importlib.util.spec_from_file_location("firmware_release_candidate", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
candidate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(candidate)

REPOSITORY = "owner/repository"
TAG = "v1.2.3-release.4"
GIT_SHA = "0123456789abcdef0123456789abcdef01234567"


class FirmwareReleaseCandidateTests(unittest.TestCase):
    def create_candidate(
        self,
        root: Path,
        target: str,
        *,
        version: str = "1.2.3",
        build: int = 4,
    ) -> Path:
        environment = candidate.TARGET_ENVIRONMENTS[target]
        directory = root / f"firmware-{target}"
        directory.mkdir(parents=True)
        firmware = directory / f"{target}.bin"
        firmware.write_bytes(f"firmware for {target}".encode())
        (directory / f"{target}.factory.tar.gz").write_bytes(
            f"factory archive for {target}".encode()
        )
        descriptor = {
            "schemaVersion": 2,
            "artifactType": "esp32-factory-flash-bundle",
            "target": target,
            "environment": environment,
            "sourceIdentity": GIT_SHA,
            "firmwareVersion": {"version": version, "build": build},
            "flashPlan": {
                "images": [
                    {
                        "file": "images/00010000-firmware.bin",
                        "size": firmware.stat().st_size,
                        "sha256": hashlib.sha256(firmware.read_bytes()).hexdigest(),
                    }
                ]
            },
        }
        (directory / f"{target}.factory-bundle.json").write_text(
            json.dumps(descriptor, sort_keys=True), encoding="utf-8"
        )
        receipt = directory / "candidate-receipt.json"
        candidate.record_candidate(
            directory,
            receipt,
            target=target,
            environment=environment,
            repository=REPOSITORY,
            tag=TAG,
            git_sha=GIT_SHA,
        )
        return directory

    def create_all_candidates(self, root: Path) -> None:
        for target in candidate.TARGET_ENVIRONMENTS:
            self.create_candidate(root, target)

    def test_record_is_canonical_and_binds_exact_candidate_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = "WAVESHARE_AMOLED_175"
            directory = self.create_candidate(root, target)
            receipt_path = directory / "candidate-receipt.json"
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))

            self.assertEqual(
                receipt_path.read_bytes(), candidate._canonical(receipt)
            )
            self.assertEqual(target, receipt["target"])
            self.assertEqual(GIT_SHA, receipt["gitSha"])
            self.assertEqual(
                [
                    f"{target}.bin",
                    f"{target}.factory-bundle.json",
                    f"{target}.factory.tar.gz",
                ],
                [item["name"] for item in receipt["files"]],
            )

    def test_verify_stages_only_the_six_bound_release_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifacts = root / "artifacts"
            artifacts.mkdir()
            self.create_all_candidates(artifacts)
            release_assets = root / "release-assets"
            combined_path = root / "candidate-verification.json"

            combined = candidate.verify_candidates(
                artifacts,
                release_assets,
                combined_path,
                repository=REPOSITORY,
                tag=TAG,
                git_sha=GIT_SHA,
                run_id=1234,
            )

            self.assertEqual(1234, combined["candidateRunId"])
            self.assertEqual(2, len(combined["targets"]))
            self.assertEqual(
                {
                    name
                    for target in candidate.TARGET_ENVIRONMENTS
                    for name in candidate._expected_names(target)
                },
                {path.name for path in release_assets.iterdir()},
            )
            self.assertEqual(
                combined_path.read_bytes(), candidate._canonical(combined)
            )

    def test_verify_rejects_tamper_replay_and_unexpected_inputs(self) -> None:
        mutators = {
            "tampered firmware": lambda directory: (
                directory / "WAVESHARE_AMOLED_175.bin"
            ).write_bytes(b"changed"),
            "replayed receipt": lambda directory: self.rewrite_receipt(
                directory, gitSha="f" * 40
            ),
            "duplicate receipt key": lambda directory: (
                directory / "candidate-receipt.json"
            ).write_text('{"schemaVersion":1,"schemaVersion":1}\n', encoding="utf-8"),
            "unexpected file": lambda directory: (
                directory / "unexpected.txt"
            ).write_text("unexpected", encoding="utf-8"),
            "symlinked file": lambda directory: (
                directory / "unsafe-link"
            ).symlink_to(directory / "WAVESHARE_AMOLED_175.bin"),
        }
        for label, mutate in mutators.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                artifacts = root / "artifacts"
                artifacts.mkdir()
                self.create_all_candidates(artifacts)
                mutate(artifacts / "firmware-WAVESHARE_AMOLED_175")

                with self.assertRaises(ValueError):
                    candidate.verify_candidates(
                        artifacts,
                        root / "release-assets",
                        root / "combined.json",
                        repository=REPOSITORY,
                        tag=TAG,
                        git_sha=GIT_SHA,
                        run_id=1234,
                    )
                self.assertFalse((root / "release-assets").exists())

    def rewrite_receipt(self, directory: Path, **changes: object) -> None:
        path = directory / "candidate-receipt.json"
        value = json.loads(path.read_text(encoding="utf-8"))
        value.update(changes)
        path.write_bytes(candidate._canonical(value))

    def test_verify_rejects_missing_target_and_existing_staging_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifacts = root / "artifacts"
            artifacts.mkdir()
            self.create_candidate(artifacts, "WAVESHARE_AMOLED_175")
            with self.assertRaisesRegex(ValueError, "artifact set is not exact"):
                candidate.verify_candidates(
                    artifacts,
                    root / "release-assets",
                    root / "combined.json",
                    repository=REPOSITORY,
                    tag=TAG,
                    git_sha=GIT_SHA,
                    run_id=1234,
                )

            self.create_candidate(artifacts, "WAVESHARE_AMOLED_206")
            (root / "release-assets").mkdir()
            with self.assertRaisesRegex(ValueError, "must not already exist"):
                candidate.verify_candidates(
                    artifacts,
                    root / "release-assets",
                    root / "combined.json",
                    repository=REPOSITORY,
                    tag=TAG,
                    git_sha=GIT_SHA,
                    run_id=1234,
                )

    def test_version_binding_rejects_wrong_tag_and_mixed_target_builds(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaisesRegex(ValueError, "firmware version is invalid"):
                self.create_candidate(
                    root, "WAVESHARE_AMOLED_175", version="1.2.4"
                )

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifacts = root / "artifacts"
            artifacts.mkdir()
            self.create_candidate(
                artifacts, "WAVESHARE_AMOLED_175", build=4
            )
            self.create_candidate(
                artifacts, "WAVESHARE_AMOLED_206", build=5
            )
            with self.assertRaisesRegex(ValueError, "one firmware version"):
                candidate.verify_candidates(
                    artifacts,
                    root / "release-assets",
                    root / "combined.json",
                    repository=REPOSITORY,
                    tag=TAG,
                    git_sha=GIT_SHA,
                    run_id=1234,
                )
            self.assertFalse((root / "release-assets").exists())

    def test_extract_accepts_only_the_exact_bounded_candidate_zip(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = "WAVESHARE_AMOLED_175"
            directory = self.create_candidate(root, target)
            archive = root / "candidate.zip"
            with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
                for path in directory.iterdir():
                    bundle.write(path, path.name)

            output = root / "extracted"
            candidate.extract_candidate_archive(archive, output, target=target)

            self.assertEqual(
                {path.name for path in directory.iterdir()},
                {path.name for path in output.iterdir()},
            )
            for path in directory.iterdir():
                self.assertEqual(path.read_bytes(), (output / path.name).read_bytes())

    def test_extract_rejects_extra_and_symlink_entries(self) -> None:
        for label, make_archive in (
            ("extra", self.write_extra_archive),
            ("symlink", self.write_symlink_archive),
        ):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                target = "WAVESHARE_AMOLED_175"
                archive = root / "candidate.zip"
                make_archive(archive, target)
                output = root / "extracted"

                with self.assertRaises(ValueError):
                    candidate.extract_candidate_archive(
                        archive, output, target=target
                    )
                self.assertFalse(output.exists())

    def write_extra_archive(self, archive: Path, target: str) -> None:
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
            for name in (*candidate._expected_names(target), "candidate-receipt.json"):
                bundle.writestr(name, b"value")
            bundle.writestr("unexpected", b"value")

    def write_symlink_archive(self, archive: Path, target: str) -> None:
        expected = (*candidate._expected_names(target), "candidate-receipt.json")
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
            for index, name in enumerate(expected):
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                mode = stat.S_IFLNK | 0o777 if index == 0 else stat.S_IFREG | 0o644
                info.external_attr = mode << 16
                bundle.writestr(info, b"value")


if __name__ == "__main__":
    unittest.main()
