from __future__ import annotations

import hashlib
import json
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from firmware_runtime import FirmwareRuntimeError
from firmware_runtime_publication import (
    _canonical,
    load_publication_identity,
    stage_publication,
    verify_staged_publication,
)


class FirmwareRuntimePublicationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        runtime = self.root / "tools/firmware-runtime"
        runtime.mkdir(parents=True)
        (runtime / "publication-v1.json").write_bytes(
            _canonical(
                {
                    "schema": 1,
                    "lockSetId": "firmware-runtime-2026-08-12-1",
                    "releaseTag": "firmware-runtime-2026-08-12-1",
                }
            )
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def candidate_wrapper(self, target: str, bundle: Path) -> dict[str, object]:
        return {
            "generator": {"commit": "a" * 40},
            "target": {
                "id": target,
                "bundle": {
                    "size": bundle.stat().st_size,
                    "sha256": hashlib.sha256(bundle.read_bytes()).hexdigest(),
                    "url": f"https://example.invalid/{bundle.name}",
                },
            },
        }

    def make_candidates(self) -> tuple[Path, dict[str, dict[str, object]]]:
        candidates = self.root / "candidates"
        wrappers: dict[str, dict[str, object]] = {}
        for target in ("linux-x86_64-cp313", "macos-arm64-cp313"):
            directory = candidates / f"firmware-runtime-candidate-{target}"
            directory.mkdir(parents=True)
            (directory / "inputs.json").write_text('{"schema":1}\n', encoding="utf-8")
            bundle = directory / f"open-bike-firmware-runtime-{target}.tar.gz"
            bundle.write_bytes(target.encode())
            wrappers[target] = self.candidate_wrapper(target, bundle)
            for prefix in ("contract", "evidence", "licenses", "offline-replay"):
                (directory / f"{prefix}-{target}.json").write_text(
                    json.dumps({"target": target}) + "\n", encoding="utf-8"
                )
        return candidates, wrappers

    def test_identity_is_canonical_and_tag_matches_lock(self) -> None:
        self.assertEqual(
            "firmware-runtime-2026-08-12-1",
            load_publication_identity(self.root)["releaseTag"],
        )
        path = self.root / "tools/firmware-runtime/publication-v1.json"
        value = json.loads(path.read_text(encoding="utf-8"))
        value["releaseTag"] = "firmware-runtime-2026-08-12-2"
        path.write_bytes(_canonical(value))
        with self.assertRaisesRegex(FirmwareRuntimeError, "contract is invalid"):
            load_publication_identity(self.root)

    def test_stage_and_transport_verification_are_create_only(self) -> None:
        candidates, wrappers = self.make_candidates()
        assets = self.root / "publication/assets"
        manifest = self.root / "publication/manifest.json"

        def load_contract(_project: Path, path: Path, expected_target: str | None = None):
            target = expected_target or path.stem.removeprefix("contract-")
            return wrappers[target]

        with mock.patch(
            "firmware_runtime_publication._load_candidate_contract",
            side_effect=load_contract,
        ), mock.patch(
            "firmware_runtime_publication._clean_generator_commit",
            return_value="a" * 40,
        ):
            value = stage_publication(self.root, candidates, assets)
        manifest.parent.mkdir(parents=True, exist_ok=True)
        manifest.write_bytes(_canonical(value))

        self.assertEqual(11, len(value["assets"]))
        self.assertEqual(value, verify_staged_publication(self.root, assets, manifest))
        with self.assertRaisesRegex(FirmwareRuntimeError, "new empty directory"):
            stage_publication(self.root, candidates, assets)

        first = assets / value["assets"][0]["name"]
        first.write_bytes(first.read_bytes() + b"tampered")
        with self.assertRaisesRegex(FirmwareRuntimeError, "changed in transit"):
            verify_staged_publication(self.root, assets, manifest)


if __name__ == "__main__":
    unittest.main()
