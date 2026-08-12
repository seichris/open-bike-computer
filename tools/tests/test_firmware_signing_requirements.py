from __future__ import annotations

import json
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class FirmwareSigningRequirementsTests(unittest.TestCase):
    def test_signer_wheels_are_exact_hashes_already_reviewed_in_linux_runtime(self) -> None:
        requirements = (
            ROOT / "tools/firmware-signing-requirements.txt"
        ).read_text(encoding="utf-8")
        logical_requirements = requirements.replace("\\\n    ", "")
        records = re.findall(
            r"(?m)^([A-Za-z0-9_-]+)==([^ ]+) --hash=sha256:([0-9a-f]{64})$",
            logical_requirements,
        )
        self.assertEqual(3, len(records))
        self.assertEqual(
            len(records), len({name.casefold() for name, _, _ in records})
        )

        lock = json.loads(
            (ROOT / "esp32/tools/firmware-runtime/lock-v1.json").read_text(
                encoding="utf-8"
            )
        )
        linux = next(
            target
            for target in lock["targets"]
            if target["id"] == "linux-x86_64-cp313"
        )
        accepted = {
            (wheel["normalizedName"], wheel["version"], wheel["sha256"])
            for wheel in linux["contents"]["wheels"]
        }
        for name, version, digest in records:
            with self.subTest(name=name):
                self.assertIn(
                    (name.casefold().replace("_", "-"), version, digest), accepted
                )


if __name__ == "__main__":
    unittest.main()
