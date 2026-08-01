from __future__ import annotations

import unittest

from capture_boot import _open_serial, format_summary, summarize, validation_errors


HEALTHY_CAPTURE = """
BOOT_META schema=1 sequence=2 target=WAVESHARE_AMOLED_175 profile=WAVESHARE_AMOLED_175 version=0.2.2 build=7 git=0123456789012345678901234567890123456789 built=2026-07-31T01:02:03Z fingerprint=12345678 reset=usb resetCode=11
BOOT_PREVIOUS schema=1 history=retained valid=1 sameFirmware=1 sequence=1 fingerprint=12345678 ready=1 safeMode=0 diagnosticHold=0 reset=power_on resetCode=1 active=ready completed=ready failureCount=0 failureStage=none failureAfter=none failureReset=unknown failureResetCode=0
BOOT_FAILURE schema=1 recorded=0 count=0 threshold=3 stage=none after=none reset=unknown resetCode=0 safeMode=0
BOOT_PMIC schema=1 mode=read-only available=1 railState=current-preserved statusRead=1 status1=0x20 status2=0x15 vbus=1 battery=0 currentDirection=0 charging=5 ldoRead=1 ldo=0xFF
BOOT_STAGE schema=1 sequence=2 event=ready id=15 name=ready uptimeMs=1042
"""

DISPLAY_RECOVERY_CAPTURE = HEALTHY_CAPTURE.replace(
    "target=WAVESHARE_AMOLED_175 profile=WAVESHARE_AMOLED_175",
    "target=WAVESHARE_AMOLED_206 profile=WAVESHARE_AMOLED_206",
).replace(
    "BOOT_PMIC schema=1 mode=read-only available=1 railState=current-preserved statusRead=1 status1=0x20 status2=0x15 vbus=1 battery=0 currentDirection=0 charging=5 ldoRead=1 ldo=0xFF",
    "BOOT_PMIC schema=1 mode=display-enable-only available=1 railState=display-enabled statusRead=1 status1=0x20 status2=0x15 vbus=1 battery=0 currentDirection=0 charging=5 ldoRead=1 ldo=0x80 displayRecovery=1 displayChanged=1",
)


class CaptureBootTests(unittest.TestCase):
    def test_healthy_capture(self) -> None:
        summary = summarize(HEALTHY_CAPTURE)
        self.assertTrue(summary.ready)
        self.assertEqual(summary.meta["target"], "WAVESHARE_AMOLED_175")
        self.assertEqual(summary.previous["active"], "ready")
        self.assertEqual(summary.previous["fingerprint"], "12345678")
        self.assertEqual(summary.pmic["ldo"], "0xFF")
        self.assertEqual(summary.sequence_mismatches, 0)
        self.assertEqual(summary.boot_discontinuities, 0)
        self.assertEqual(summary.blocked_writes, 0)
        self.assertEqual(
            validation_errors(
                summary,
                expected_target="WAVESHARE_AMOLED_175",
                expected_profile="WAVESHARE_AMOLED_175",
                expected_git="0123456789012345678901234567890123456789",
                expected_reset="usb",
                require_ready=True,
                require_pmic_read_only=True,
            ),
            [],
        )
        rendered = format_summary(summary)
        self.assertIn("ready=1", rendered)
        self.assertIn("pmicMode=read-only", rendered)
        self.assertIn("pmicRailState=current-preserved", rendered)
        self.assertIn("profile=WAVESHARE_AMOLED_175", rendered)
        self.assertIn("previousFingerprint=12345678", rendered)
        self.assertIn("sequenceMismatches=0", rendered)
        self.assertIn("bootDiscontinuities=0", rendered)

        previous_line = next(
            line for line in HEALTHY_CAPTURE.splitlines() if line.startswith("BOOT_PREVIOUS ")
        )
        self.assertGreater(len(previous_line.encode()), 256)

        identity_errors = validation_errors(
            summary,
            expected_profile="WAVESHARE_AMOLED_175_LIGHT_SLEEP",
            expected_reset="power_on",
        )
        self.assertIn(
            "profile expected WAVESHARE_AMOLED_175_LIGHT_SLEEP, got WAVESHARE_AMOLED_175",
            identity_errors,
        )
        self.assertIn("reset expected power_on, got usb", identity_errors)

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
BOOT_META schema=1 sequence=3 target=WAVESHARE_AMOLED_175 profile=WAVESHARE_AMOLED_175 version=0.2.2 build=7 git=0123456789012345678901234567890123456789 built=2026-07-31T01:02:03Z fingerprint=12345678 reset=panic resetCode=4
BOOT_PREVIOUS schema=1 history=retained valid=1 sameFirmware=1 sequence=2 fingerprint=12345678 ready=1 safeMode=0 diagnosticHold=0 reset=usb resetCode=11 active=ready completed=ready failureCount=0 failureStage=none failureAfter=none failureReset=unknown failureResetCode=0
BOOT_FAILURE schema=1 recorded=0 count=0 threshold=3 stage=none after=none reset=unknown resetCode=0 safeMode=0
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

    def test_newer_stage_without_meta_cannot_reuse_older_ready_gate(self) -> None:
        missing_meta_reboot = (
            HEALTHY_CAPTURE
            + "\nBOOT_STAGE schema=1 sequence=3 event=enter id=1 "
            "name=startup uptimeMs=0\n"
        )
        summary = summarize(missing_meta_reboot)
        self.assertFalse(summary.ready)
        self.assertEqual(summary.meta["sequence"], "2")
        self.assertEqual(summary.sequence_mismatches, 1)
        errors = validation_errors(
            summary,
            expected_target="WAVESHARE_AMOLED_175",
            expected_git="0123456789012345678901234567890123456789",
            expected_reset="usb",
            require_ready=True,
            require_pmic_read_only=True,
        )
        self.assertIn("ready marker missing", errors)
        self.assertTrue(
            any(error.startswith("boot sequence mismatch observed:") for error in errors)
        )

    def test_truncated_stage_without_meta_cannot_reuse_older_ready_gate(self) -> None:
        summary = summarize(HEALTHY_CAPTURE + "\nBOOT_STAGE truncated\n")
        self.assertFalse(summary.ready)
        self.assertEqual(summary.meta["sequence"], "2")
        self.assertEqual(summary.sequence_mismatches, 1)
        errors = validation_errors(summary, require_ready=True)
        self.assertIn("ready marker missing", errors)
        self.assertTrue(
            any(error.startswith("boot sequence mismatch observed:") for error in errors)
        )

    def test_exact_truncated_boot_marker_cannot_reuse_older_ready(self) -> None:
        for marker in (
            "BOOT_META",
            "BOOT_STAGE",
            "BOOT_PREVIOUS",
            "BOOT_FAILURE",
            "BOOT_PMIC",
            "BOOT_SAFE_MODE",
        ):
            with self.subTest(marker=marker):
                summary = summarize(HEALTHY_CAPTURE + "\n" + marker)
                self.assertFalse(summary.ready)
                self.assertIn(
                    "ready marker missing",
                    validation_errors(summary, require_ready=True),
                )

    def test_exact_truncated_hazard_markers_fail_validation(self) -> None:
        summary = summarize(
            HEALTHY_CAPTURE + "\nAXP_WRITE_BLOCKED\nBOOT_DIAGNOSTICS_ERROR"
        )
        self.assertEqual(summary.blocked_writes, 1)
        self.assertEqual(summary.diagnostic_errors, 1)
        errors = validation_errors(summary)
        self.assertIn("blocked AXP2101 writes observed: 1", errors)
        self.assertIn("boot diagnostic errors observed: 1", errors)

    def test_same_sequence_restart_after_ready_cannot_false_green(self) -> None:
        reused_sequence = (
            HEALTHY_CAPTURE
            + "\nBOOT_STAGE schema=1 sequence=2 event=enter id=1 "
            "name=startup uptimeMs=0\n"
        )
        summary = summarize(reused_sequence)
        self.assertFalse(summary.ready)
        self.assertEqual(summary.sequence_mismatches, 0)
        self.assertEqual(summary.boot_discontinuities, 1)
        errors = validation_errors(
            summary,
            require_ready=True,
            require_pmic_read_only=True,
        )
        self.assertIn("ready marker missing", errors)
        self.assertIn(
            "boot stream continued after ready marker: 1 later boot marker(s) observed",
            errors,
        )

    def test_setup_record_without_meta_or_stage_cannot_reuse_older_ready(self) -> None:
        later_boot_records = (
            "BOOT_PREVIOUS schema=1 history=retained valid=1 sameFirmware=1 "
            "sequence=2 fingerprint=12345678 ready=1 safeMode=0 "
            "diagnosticHold=0 reset=usb resetCode=11 active=ready "
            "completed=ready failureCount=0 failureStage=none "
            "failureAfter=none failureReset=unknown failureResetCode=0",
            "BOOT_FAILURE schema=1 recorded=1 count=1 threshold=3 "
            "stage=startup after=none reset=panic resetCode=4 safeMode=0",
            "BOOT_PMIC schema=1 mode=read-only available=1 "
            "railState=current-preserved statusRead=1 status1=0x20 "
            "status2=0x15 vbus=1 battery=0 currentDirection=0 charging=5 "
            "ldoRead=1 ldo=0xFF",
            "BOOT_SAFE_MODE schema=1 active=1 peripherals=skipped "
            "failureCount=3 threshold=3",
        )

        for record in later_boot_records:
            with self.subTest(marker=record.split()[0]):
                summary = summarize(HEALTHY_CAPTURE + "\n" + record + "\n")
                self.assertFalse(summary.ready)
                self.assertEqual(summary.meta["sequence"], "2")
                self.assertEqual(summary.boot_discontinuities, 1)
                errors = validation_errors(
                    summary,
                    require_ready=True,
                    require_pmic_read_only=True,
                )
                self.assertIn("ready marker missing", errors)
                self.assertIn(
                    "boot stream continued after ready marker: "
                    "1 later boot marker(s) observed",
                    errors,
                )

    def test_pmic_gate_requires_probe_and_both_reads(self) -> None:
        unavailable = HEALTHY_CAPTURE.replace(
            "BOOT_PMIC schema=1 mode=read-only available=1 railState=current-preserved statusRead=1 status1=0x20 status2=0x15 vbus=1 battery=0 currentDirection=0 charging=5 ldoRead=1 ldo=0xFF",
            "BOOT_PMIC schema=1 mode=read-only available=0 railState=unknown",
        )
        errors = validation_errors(
            summarize(unavailable), require_pmic_read_only=True
        )
        self.assertIn("PMIC probe required (got 0)", errors)
        self.assertIn("PMIC status read required (got missing)", errors)
        self.assertIn("PMIC LDO-state read required (got missing)", errors)

        unreadable = HEALTHY_CAPTURE.replace(
            "available=1 railState=current-preserved statusRead=1 status1=0x20 status2=0x15 vbus=1 battery=0 currentDirection=0 charging=5 ldoRead=1 ldo=0xFF",
            "available=1 railState=current-preserved statusRead=0 ldoRead=0 ldo=0x00",
        )
        errors = validation_errors(
            summarize(unreadable), require_pmic_read_only=True
        )
        self.assertNotIn("PMIC probe required (got 0)", errors)
        self.assertIn("PMIC status read required (got 0)", errors)
        self.assertIn("PMIC LDO-state read required (got 0)", errors)

    def test_206_pmic_gate_requires_verified_display_enable_only_recovery(self) -> None:
        summary = summarize(DISPLAY_RECOVERY_CAPTURE)
        self.assertEqual(
            validation_errors(
                summary,
                expected_target="WAVESHARE_AMOLED_206",
                require_ready=True,
                require_pmic_display_enable_only=True,
            ),
            [],
        )
        rendered = format_summary(summary)
        self.assertIn("pmicMode=display-enable-only", rendered)
        self.assertIn("pmicDisplayRecovery=1", rendered)
        self.assertIn("pmicDisplayChanged=1", rendered)

        for old, new, expected_error in (
            ("displayRecovery=1", "displayRecovery=0", "PMIC display recovery required (got 0)"),
            ("railState=display-enabled", "railState=unknown", "PMIC display-enabled rail state required (got unknown)"),
            ("ldo=0x80", "ldo=0x00", "PMIC 2.06 display-enable bit required (got 0x00)"),
        ):
            errors = validation_errors(
                summarize(DISPLAY_RECOVERY_CAPTURE.replace(old, new)),
                require_pmic_display_enable_only=True,
            )
            self.assertIn(expected_error, errors)

        read_only_errors = validation_errors(
            summarize(HEALTHY_CAPTURE),
            require_pmic_display_enable_only=True,
        )
        self.assertIn(
            "PMIC display-enable-only marker missing (got read-only)",
            read_only_errors,
        )

    def test_previous_safe_mode_failure_survives_firmware_change_log(self) -> None:
        recovery = HEALTHY_CAPTURE.replace(
            "history=retained valid=1 sameFirmware=1 sequence=1 fingerprint=12345678 ready=1 safeMode=0 diagnosticHold=0 reset=power_on resetCode=1 active=ready completed=ready failureCount=0 failureStage=none failureAfter=none failureReset=unknown failureResetCode=0",
            "history=firmware_changed valid=1 sameFirmware=0 sequence=8 fingerprint=DEADBEEF ready=0 safeMode=1 diagnosticHold=0 reset=panic resetCode=4 active=safe_mode completed=none failureCount=3 failureStage=display failureAfter=clock_and_sensors failureReset=brownout failureResetCode=9",
        )
        summary = summarize(recovery)
        self.assertEqual(summary.previous["fingerprint"], "DEADBEEF")
        self.assertEqual(summary.previous["failureCount"], "3")
        self.assertEqual(summary.previous["failureStage"], "display")
        self.assertEqual(summary.previous["failureReset"], "brownout")
        self.assertIn("previousFailureStage=display", format_summary(summary))
        self.assertIn("previousFingerprint=DEADBEEF", format_summary(summary))
        self.assertIn("previousFailureReset=brownout", format_summary(summary))

    def test_serial_control_lines_are_deasserted_before_open(self) -> None:
        events: list[tuple[str, object]] = []

        class FakeDevice:
            def __init__(self, *, port, baudrate, timeout):
                events.append(("construct_port", port))
                events.append(("baudrate", baudrate))
                events.append(("timeout", timeout))
                self._dtr = True
                self._rts = True
                self.port = port
                self.is_open = False

            @property
            def dtr(self):
                return self._dtr

            @dtr.setter
            def dtr(self, value):
                self._dtr = value
                events.append(("dtr", value))

            @property
            def rts(self):
                return self._rts

            @rts.setter
            def rts(self, value):
                self._rts = value
                events.append(("rts", value))

            def open(self):
                events.append(("open_dtr", self.dtr))
                events.append(("open_rts", self.rts))
                events.append(("open_port", self.port))
                self.is_open = True

        class FakeSerialModule:
            Serial = FakeDevice

        device = _open_serial(FakeSerialModule, "/dev/cu.test", 115200)
        self.assertTrue(device.is_open)
        self.assertEqual(events[0], ("construct_port", None))
        self.assertLess(
            events.index(("dtr", False)), events.index(("open_dtr", False))
        )
        self.assertLess(
            events.index(("rts", False)), events.index(("open_rts", False))
        )
        self.assertIn(("open_port", "/dev/cu.test"), events)


if __name__ == "__main__":
    unittest.main()
