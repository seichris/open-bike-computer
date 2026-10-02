from __future__ import annotations

import tempfile
import unittest
from os import environ
from pathlib import Path
from subprocess import CompletedProcess
from unittest.mock import patch

from compare_amoled_artifacts import EvidenceError
from qualify_amoled_equivalence import (
    _preprocess_arguments,
    _run_verified_build,
    _source_for_entry,
)


class QualifyAmoledEquivalenceTests(unittest.TestCase):
    def test_verified_build_does_not_inherit_driver_pythonpath(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            project = Path(temporary)
            tools = project / "tools"
            tools.mkdir()
            (tools / "build_firmware.py").write_text("", encoding="utf-8")
            with (
                patch.dict(environ, {"PYTHONPATH": "/preserved/tools"}),
                patch(
                    "qualify_amoled_equivalence.subprocess.run",
                    return_value=CompletedProcess([], 0),
                ) as runner,
            ):
                _run_verified_build(project, "WAVESHARE_AMOLED_175")

            self.assertNotIn("PYTHONPATH", runner.call_args.kwargs["env"])

    def test_preprocess_arguments_preserve_build_inputs_and_replace_outputs(self) -> None:
        output = Path("/evidence/maps.ii")
        result = _preprocess_arguments(
            [
                "/private/toolchain/g++",
                "-o",
                ".pio/build/maps.cpp.o",
                "-c",
                "-MMD",
                "-MF",
                ".pio/build/maps.cpp.d",
                "-DMAP_STABLE_CAMERA=1",
                "-Ilib/maps/src",
                "lib/maps/src/maps.cpp",
            ],
            "lib/maps/src/maps.cpp",
            output,
        )

        self.assertEqual("/private/toolchain/g++", result[0])
        self.assertIn("-DMAP_STABLE_CAMERA=1", result)
        self.assertNotIn("-c", result)
        self.assertNotIn("-MMD", result)
        self.assertNotIn(".pio/build/maps.cpp.o", result)
        self.assertEqual(
            ["-E", "-P", "-o", str(output), "lib/maps/src/maps.cpp"],
            result[-5:],
        )

    def test_preprocess_arguments_require_declared_source(self) -> None:
        with self.assertRaisesRegex(EvidenceError, "declared source"):
            _preprocess_arguments(
                ["/private/toolchain/g++", "-c", "another.cpp"],
                "lib/maps/src/maps.cpp",
                Path("/evidence/maps.ii"),
            )

    def test_source_entry_is_resolved_below_project(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            project = Path(temporary).resolve()
            source = project / "lib/maps/src/maps.cpp"
            source.parent.mkdir(parents=True)
            source.write_text("", encoding="utf-8")
            self.assertEqual(
                "lib/maps/src/maps.cpp",
                _source_for_entry(
                    {"file": "lib/maps/src/maps.cpp", "directory": str(project)},
                    project,
                ),
            )
            self.assertIsNone(
                _source_for_entry(
                    {"file": "/outside/maps.cpp", "directory": str(project)},
                    project,
                )
            )


if __name__ == "__main__":
    unittest.main()
