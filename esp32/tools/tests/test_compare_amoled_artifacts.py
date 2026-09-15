from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from compare_amoled_artifacts import (
    EvidenceError,
    REQUIRED_PREPROCESSED_SOURCES,
    _parse_preprocessed,
    capture,
    compare,
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class CompareAmoledArtifactsTests(unittest.TestCase):
    def make_project(self, root: Path, identity: str) -> tuple[Path, dict[str, Path]]:
        root = root.resolve()
        environment = "WAVESHARE_AMOLED_175"
        build = root / ".pio/build" / environment
        build.mkdir(parents=True)
        (build / "firmware.map").write_text(
            f"LOAD {root}/lib/gui/src/mainScr.cpp\n.text 0x10 0x20\n",
            encoding="utf-8",
        )
        first = build / "lib111/gui/mainScr.cpp.o"
        second = build / "lib222/maps/maps.cpp.o"
        metadata = build / "lib333/firmware_metadata/firmware_metadata.cpp.o"
        for path, content in (
            (first, b"main-object"),
            (second, b"maps-object"),
            (metadata, identity.encode()),
        ):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)

        runtime = {"manifestSha256": "a" * 64, "target": "test"}
        manifest = {
            "environment": environment,
            "uploadEligible": True,
            "sourceIdentity": identity,
            "runtimeProvenance": runtime,
            "coreInputKey": "b" * 64,
            "coreAttestation": {
                "environment": environment,
                "coreDir": str(root / ".pio/private-core"),
                "packagesTreeSha256": "c" * 64,
            },
            "platformArchiveSha256": "d" * 64,
            "platformPackagesSha256": "e" * 64,
            "libraryDependenciesSha256": "f" * 64,
            "managedComponentsSha256": "1" * 64,
            "bootloaderBinSha256": "2" * 64,
            "partitionTableBinSha256": "3" * 64,
            "bootApp0Sha256": "4" * 64,
        }
        manifest_path = (
            root / ".pio/open-bike-build/builds" / environment / "current.json"
        )
        manifest_path.parent.mkdir(parents=True)
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

        preprocessed: dict[str, Path] = {}
        for index, source in enumerate(sorted(REQUIRED_PREPROCESSED_SOURCES)):
            path = root / "preprocessed" / f"{index}.ii"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'# 1 "source.cpp"\nint unchanged;\n')
            preprocessed[source] = path
        return root, preprocessed

    def test_capture_and_compare_ignore_only_documented_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            baseline_root, baseline_preprocessed = self.make_project(
                root / "baseline", "1" * 40
            )
            candidate_root, candidate_preprocessed = self.make_project(
                root / "candidate", "2" * 40
            )
            baseline = capture(
                project_dir=baseline_root,
                environment="WAVESHARE_AMOLED_175",
                preprocessed=baseline_preprocessed,
            )
            candidate = capture(
                project_dir=candidate_root,
                environment="WAVESHARE_AMOLED_175",
                preprocessed=candidate_preprocessed,
            )

            result = compare(baseline, candidate)

            self.assertEqual("pass", result["status"])
            self.assertEqual(2, result["comparedObjectCount"])
            self.assertNotIn(
                sha256(("1" * 40).encode()), baseline["objectsSha256"].values()
            )

    def test_object_or_map_change_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            baseline_root, baseline_preprocessed = self.make_project(
                root / "baseline", "1" * 40
            )
            candidate_root, candidate_preprocessed = self.make_project(
                root / "candidate", "2" * 40
            )
            changed = candidate_root / ".pio/build/WAVESHARE_AMOLED_175/lib222/maps/maps.cpp.o"
            changed.write_bytes(b"changed")
            (candidate_root / ".pio/build/WAVESHARE_AMOLED_175/firmware.map").write_text(
                ".text 0x10 0x21\n", encoding="utf-8"
            )

            result = compare(
                capture(
                    project_dir=baseline_root,
                    environment="WAVESHARE_AMOLED_175",
                    preprocessed=baseline_preprocessed,
                ),
                capture(
                    project_dir=candidate_root,
                    environment="WAVESHARE_AMOLED_175",
                    preprocessed=candidate_preprocessed,
                ),
            )

            self.assertEqual("fail", result["status"])
            self.assertIn("objectsSha256", result["failures"])
            self.assertIn("linkerMapSha256", result["failures"])

    def test_preprocessed_set_is_closed(self) -> None:
        with self.assertRaisesRegex(EvidenceError, "missing"):
            _parse_preprocessed([])


if __name__ == "__main__":
    unittest.main()
