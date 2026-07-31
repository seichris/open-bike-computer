from __future__ import annotations

import unittest

from capture_boot import format_summary, summarize, validation_errors


HEALTHY_CAPTURE = """
BOOT_META schema=1 sequence=2 target=WAVESHARE_AMOLED_175 version=0.2.2 build=7 git=0123456789012345678901234567890123456789 built=2026-07-31T01:02:03Z fingerprint=12345678 reset=usb resetCode=11
BOOT_PREVIOUS schema=1 history=retained valid=1 sameFirmware=1 sequence=1 ready=1 safeMode=0 reset=power_on resetCode=1 active=ready completed=ready
BOOT_FAILURE schema=1 recorded=0 count=0 threshold=3 stage=none after=none safeMode=0
BOOT_PMIC schema=1 mode=read-only available=1 statusRead=1 status1=0x20 status2=0x15 vbus=1 battery=0 currentDirection=0 charging=5 ldoRead=1 ldo=0xFF
BOOT_STAGE schema=1 sequence=2 event=ready id=15 name=ready uptimeMs=1042
"""


class CaptureBootTests(unittest.TestCase):
    def test_healthy_capture(self) -> None:
        summary = summarize(HEALTHY_CAPTURE)
        self.assertTrue(summary.ready)
        self.assertEqual(summary.meta["target"], "WAVESHARE_AMOLED_175")
        self.assertEqual(summary.previous["active"], "ready")
        self.assertEqual(summary.pmic["ldo"], "0xFF")
        self.assertEqual(summary.blocked_writes, 0)
        self.assertEqual(
            validation_errors(
                summary,
                expected_target="WAVESHARE_AMOLED_175",
                expected_git="0123456789012345678901234567890123456789",
                require_ready=True,
                require_pmic_read_only=True,
            ),
            [],
        )
        rendered = format_summary(summary)
        self.assertIn("ready=1", rendered)
        self.assertIn("pmicMode=read-only", rendered)

    def test_hazard_and_incomplete_boot_fail_validation(self) -> None:
        capture = HEALTHY_CAPTURE.replace(
            "BOOT_STAGE schema=1 sequence=2 event=ready id=15 name=ready uptimeMs=1042\n",
            "AXP_WRITE_BLOCKED schema=1 reg=0x90 value=0x9D policy=interrupt-only\n",
        )
        summary = summarize(capture)
        errors = validation_errors(summary, require_ready=True)
        self.assertIn("ready marker missing", errors)
        self.assertIn("blocked AXP2101 writes observed: 1", errors)

    def test_only_latest_boot_can_satisfy_ready_gate(self) -> None:
        interrupted_boot = """
BOOT_META schema=1 sequence=3 target=WAVESHARE_AMOLED_175 version=0.2.2 build=7 git=0123456789012345678901234567890123456789 built=2026-07-31T01:02:03Z fingerprint=12345678 reset=panic resetCode=4
BOOT_PREVIOUS schema=1 history=retained valid=1 sameFirmware=1 sequence=2 ready=1 safeMode=0 reset=usb resetCode=11 active=ready completed=ready
BOOT_FAILURE schema=1 recorded=0 count=0 threshold=3 stage=none after=none safeMode=0
BOOT_STAGE schema=1 sequence=3 event=enter id=1 name=startup uptimeMs=0
"""
        summary = summarize(HEALTHY_CAPTURE + interrupted_boot)
        self.assertFalse(summary.ready)
        self.assertEqual(summary.meta["sequence"], "3")
        self.assertEqual(summary.meta["reset"], "panic")
        self.assertEqual(summary.pmic, {})
        self.assertIn(
            "ready marker missing",
            validation_errors(
                summary,
                require_ready=True,
                require_pmic_read_only=True,
            ),
        )
        self.assertIn(
            "PMIC read-only marker missing (got missing)",
            validation_errors(summary, require_pmic_read_only=True),
        )


if __name__ == "__main__":
    unittest.main()
