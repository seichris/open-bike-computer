import copy
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verify_firmware_boot_acceptance import validate


class FirmwareBootAcceptanceTests(unittest.TestCase):
    def test_exact_production_checkpoint_and_rejections(self):
        for target in ("WAVESHARE_AMOLED_175", "WAVESHARE_AMOLED_206"):
            fields = {"schemaVersion": 1, "firmwareTarget": target,
                      "firmwareProfile": target + "_PRODUCTION", "firmwareGitSha": "a" * 40,
                      "firmwareVersion": "0.3.4", "firmwareBuild": 94, "bootSequence": 4, "ready": True, "otaState": "valid"}
            record = {"schema": 1, "source": "firmware", "category": "boot", "event": "acceptance", "fields": fields}
            args = dict(target=target, git_sha="a" * 40, version="0.3.4", build=94, boot_sequence=4, ota=True)
            validate(record, **args)
            for key, value in (("firmwareProfile", target), ("firmwareProfile", target + "_REMOTE_DEBUG"),
                               ("firmwareTarget", "wrong"), ("firmwareGitSha", "a" * 12),
                               ("firmwareVersion", "0.3.3"), ("firmwareBuild", 93), ("bootSequence", 3), ("ready", False),
                               ("ready", 1), ("schemaVersion", 2), ("otaState", "pending_verify"),
                               ("otaState", "unknown"), ("otaState", "untracked")):
                bad = copy.deepcopy(record)
                bad["fields"][key] = value
                with self.subTest(target=target, key=key, value=value), self.assertRaises(ValueError):
                    validate(bad, **args)
            fields["otaState"] = "untracked"
            validate(record, **{**args, "ota": False})


if __name__ == "__main__":
    unittest.main()
