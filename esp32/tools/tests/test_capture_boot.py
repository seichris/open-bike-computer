from __future__ import annotations

import io
import unittest
from contextlib import redirect_stderr

from capture_boot import (
    _EMPTY_RETAINED_HISTORY,
    _open_serial,
    _resolve_port,
    cold_start_evidence,
    format_summary,
    main,
    summarize,
    validation_errors,
)
from resolve_upload_port import ResolvedDevice


POWER_BUTTON_FIELDS = (
    "powerButtonOffConfigured=1 powerButtonOffSeconds=4 "
    "powerButtonOffLevel=0 powerButtonConfigRead=1 powerButtonConfig=0xF3"
)
READ_ONLY_PMIC_LINE = (
    "BOOT_PMIC schema=1 mode=read-only available=1 "
    "railState=current-preserved statusRead=1 status1=0x20 status2=0x15 "
    "vbus=1 battery=0 currentDirection=0 charging=5 ldoRead=1 ldo=0xFF "
    + POWER_BUTTON_FIELDS
)
DISPLAY_RECOVERY_PMIC_LINE = (
    "BOOT_PMIC schema=1 mode=display-enable-only available=1 "
    "railState=display-enabled statusRead=1 status1=0x20 status2=0x15 "
    "vbus=1 battery=0 currentDirection=0 charging=5 ldoRead=1 ldo=0x80 "
    "displayRecovery=1 displayChanged=1 "
    + POWER_BUTTON_FIELDS
)

HEALTHY_CAPTURE = f"""
BOOT_META schema=1 sequence=2 target=WAVESHARE_AMOLED_175 profile=WAVESHARE_AMOLED_175 version=0.2.2 build=7 git=0123456789012345678901234567890123456789 built=2026-07-31T01:02:03Z fingerprint=12345678 reset=usb resetCode=11
BOOT_PREVIOUS schema=1 history=retained valid=1 sameFirmware=1 sequence=1 fingerprint=12345678 ready=1 safeMode=0 diagnosticHold=0 reset=power_on resetCode=1 active=ready completed=ready failureCount=0 failureStage=none failureAfter=none failureReset=unknown failureResetCode=0
BOOT_FAILURE schema=1 recorded=0 count=0 threshold=3 stage=none after=none reset=unknown resetCode=0 safeMode=0
{READ_ONLY_PMIC_LINE}
BOOT_STAGE schema=1 sequence=2 event=ready id=15 name=ready uptimeMs=1042
"""

USB_COLD_CAPTURE = f"""
BOOT_META schema=1 sequence=1 target=WAVESHARE_AMOLED_175 profile=WAVESHARE_AMOLED_175 version=0.2.2 build=7 git=0123456789012345678901234567890123456789 built=2026-07-31T01:02:03Z fingerprint=12345678 reset=usb resetCode=11
BOOT_PREVIOUS schema=1 history=empty_or_invalid valid=0 sameFirmware=0 sequence=0 fingerprint=00000000 ready=0 safeMode=0 diagnosticHold=0 reset=unknown resetCode=0 active=none completed=none failureCount=0 failureStage=none failureAfter=none failureReset=unknown failureResetCode=0
BOOT_FAILURE schema=1 recorded=0 count=0 threshold=3 stage=none after=none reset=unknown resetCode=0 safeMode=0
{READ_ONLY_PMIC_LINE}
BOOT_STAGE schema=1 sequence=1 event=ready id=15 name=ready uptimeMs=1042
"""

DISPLAY_RECOVERY_CAPTURE = HEALTHY_CAPTURE.replace(
    "target=WAVESHARE_AMOLED_175 profile=WAVESHARE_AMOLED_175",
    "target=WAVESHARE_AMOLED_206 profile=WAVESHARE_AMOLED_206",
).replace(READ_ONLY_PMIC_LINE, DISPLAY_RECOVERY_PMIC_LINE)


class CaptureBootTests(unittest.TestCase):
    def test_hardware_serial_resolution_uses_current_port(self) -> None:
        calls: list[tuple[str, float]] = []

        def resolve(serial_number: str, timeout_seconds: float) -> ResolvedDevice:
            calls.append((serial_number, timeout_seconds))
            return ResolvedDevice(
                port="/dev/cu.current",
                serial_number=serial_number,
                vid=0x303A,
                pid=0x1001,
                description="USB JTAG/serial debug unit",
            )

        self.assertEqual(
            _resolve_port(
                None,
                45.0,
                device_serial="3c:dc:75:6e:f0:10",
                device_resolver=resolve,
            ),
            "/dev/cu.current",
        )
        self.assertEqual(calls, [("3c:dc:75:6e:f0:10", 45.0)])

    def test_capture_port_rejects_invalid_wait(self) -> None:
        for wait_seconds in (-1.0, float("nan"), float("inf")):
            with self.subTest(wait_seconds=wait_seconds):
                with self.assertRaisesRegex(RuntimeError, "finite nonnegative"):
                    _resolve_port("/dev/cu.test", wait_seconds)

    def test_capture_cli_rejects_two_port_selectors(self) -> None:
        stderr = io.StringIO()
        with redirect_stderr(stderr):
            with self.assertRaises(SystemExit) as error:
                main(
                    [
                        "--port",
                        "/dev/cu.test",
                        "--device-serial",
                        "3c:dc:75:6e:f0:10",
                    ]
                )
        self.assertEqual(error.exception.code, 2)
        self.assertIn("not allowed with argument", stderr.getvalue())

    def test_usb_empty_history_plus_confirmation_validates_cold_start(self) -> None:
        summary = summarize(USB_COLD_CAPTURE)
        self.assertEqual(cold_start_evidence(summary), "usb_empty_history")
        self.assertEqual(
            validation_errors(
                summary,
                expected_reset="usb",
                require_cold_start=True,
                confirmed_all_power_removed=True,
                require_ready=True,
                require_pmic_read_only=True,
            ),
            [],
        )
        rendered = format_summary(summary, confirmed_all_power_removed=True)
        self.assertIn("coldStartCandidate=1", rendered)
        self.assertIn("coldStartEvidence=usb_empty_history", rendered)
        self.assertIn("operatorPowerRemovalConfirmed=1", rendered)
        self.assertIn("coldStartValidated=1", rendered)

        # The new gate does not weaken exact reset-cause validation.
        self.assertIn(
            "reset expected power_on, got usb",
            validation_errors(summary, expected_reset="power_on"),
        )

    def test_cold_start_evidence_fails_closed(self) -> None:
        self.assertIsNone(cold_start_evidence(summarize(HEALTHY_CAPTURE)))
        self.assertIn(
            "cold start required; got reset=usb resetCode=11 sequence=2 "
            "history=retained previousValid=1",
            validation_errors(summarize(HEALTHY_CAPTURE), require_cold_start=True),
        )

        corruptions = (
            ("sequence=1 target=", "sequence=2 target="),
            ("reset=usb resetCode=11", "reset=usb resetCode=1"),
            ("history=empty_or_invalid", "history=retained"),
            ("valid=0 sameFirmware=0", "valid=1 sameFirmware=0"),
            ("sequence=0 fingerprint=00000000", "sequence=1 fingerprint=00000000"),
            ("fingerprint=00000000", "fingerprint=12345678"),
            ("ready=0 safeMode=0", "ready=1 safeMode=0"),
            ("active=none completed=none", "active=ready completed=ready"),
        )
        for original, replacement in corruptions:
            with self.subTest(replacement=replacement):
                summary = summarize(USB_COLD_CAPTURE.replace(original, replacement, 1))
                self.assertIsNone(cold_start_evidence(summary))
                self.assertTrue(
                    validation_errors(
                        summary,
                        require_cold_start=True,
                        confirmed_all_power_removed=True,
                    )
                )

        previous_line = next(
            line
            for line in USB_COLD_CAPTURE.splitlines()
            if line.startswith("BOOT_PREVIOUS ")
        )
        for field in _EMPTY_RETAINED_HISTORY:
            with self.subTest(missing_field=field):
                incomplete_line = " ".join(
                    token
                    for token in previous_line.split()
                    if not token.startswith(f"{field}=")
                )
                summary = summarize(
                    USB_COLD_CAPTURE.replace(previous_line, incomplete_line, 1)
                )
                self.assertIsNone(cold_start_evidence(summary))
                self.assertTrue(
                    validation_errors(
                        summary,
                        require_cold_start=True,
                        confirmed_all_power_removed=True,
                    )
                )

    def test_empty_history_requires_operator_power_removal_confirmation(self) -> None:
        summary = summarize(USB_COLD_CAPTURE)
        self.assertEqual(cold_start_evidence(summary), "usb_empty_history")
        self.assertIn(
            "cold start requires explicit operator confirmation that USB and "
            "battery power were removed",
            validation_errors(summary, require_cold_start=True),
        )
        self.assertEqual(
            validation_errors(
                summary,
                require_cold_start=True,
                confirmed_all_power_removed=True,
            ),
            [],
        )

    def test_cold_start_cli_rejects_unconfirmed_or_warm_reset_options(self) -> None:
        invalid_arguments = (
            ["--require-cold-start"],
            ["--confirm-all-power-removed"],
            [
                "--require-cold-start",
                "--confirm-all-power-removed",
                "--reset",
            ],
        )
        for arguments in invalid_arguments:
            with self.subTest(arguments=arguments):
                stderr = io.StringIO()
                with redirect_stderr(stderr):
                    with self.assertRaises(SystemExit) as error:
                        main(arguments)
                self.assertEqual(error.exception.code, 2)
                self.assertIn("error:", stderr.getvalue())

    def test_power_on_with_empty_history_is_supporting_evidence(self) -> None:
        capture = USB_COLD_CAPTURE.replace(
            "reset=usb resetCode=11", "reset=power_on resetCode=1", 1
        )
        self.assertEqual(
            cold_start_evidence(summarize(capture)), "power_on_empty_history"
        )

    def test_healthy_capture(self) -> None:
        summary = summarize(HEALTHY_CAPTURE)
        self.assertTrue(summary.ready)
        self.assertEqual(summary.meta["target"], "WAVESHARE_AMOLED_175")
        self.assertEqual(summary.previous["active"], "ready")
        self.assertEqual(summary.previous["fingerprint"], "12345678")
        self.assertEqual(summary.pmic["ldo"], "0xFF")
        self.assertEqual(summary.stage_schema_mismatches, 0)
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
        self.assertIn("pmicPowerButtonOffConfigured=1", rendered)
        self.assertIn("pmicPowerButtonOffSeconds=4", rendered)
        self.assertIn("pmicPowerButtonOffLevel=0", rendered)
        self.assertIn("pmicPowerButtonConfigRead=1", rendered)
        self.assertIn("pmicPowerButtonConfig=0xF3", rendered)
        self.assertIn("profile=WAVESHARE_AMOLED_175", rendered)
        self.assertIn("previousFingerprint=12345678", rendered)
        self.assertIn("stageSchemaMismatches=0", rendered)
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

    def test_safety_gates_reject_unknown_record_schemas(self) -> None:
        unknown_meta = summarize(
            HEALTHY_CAPTURE.replace("BOOT_META schema=1", "BOOT_META schema=2")
        )
        self.assertIn(
            "BOOT_META schema 1 required for gated validation (got 2)",
            validation_errors(
                unknown_meta,
                expected_target="WAVESHARE_AMOLED_175",
                require_ready=True,
            ),
        )

        unknown_stage = summarize(
            HEALTHY_CAPTURE.replace("BOOT_STAGE schema=1", "BOOT_STAGE schema=2")
        )
        self.assertFalse(unknown_stage.ready)
        self.assertEqual(unknown_stage.stage_schema_mismatches, 1)
        stage_errors = validation_errors(unknown_stage, require_ready=True)
        self.assertIn("unsupported BOOT_STAGE schema observed: 1 marker(s)", stage_errors)
        self.assertIn("ready marker missing", stage_errors)

        unknown_pmic = summarize(
            HEALTHY_CAPTURE.replace("BOOT_PMIC schema=1", "BOOT_PMIC schema=2")
        )
        self.assertIn(
            "BOOT_PMIC schema 1 required for read-only validation (got 2)",
            validation_errors(unknown_pmic, require_pmic_read_only=True),
        )

        unknown_display_pmic = summarize(
            DISPLAY_RECOVERY_CAPTURE.replace(
                "BOOT_PMIC schema=1", "BOOT_PMIC schema=2"
            )
        )
        self.assertIn(
            "BOOT_PMIC schema 1 required for display-enable validation (got 2)",
            validation_errors(
                unknown_display_pmic,
                require_pmic_display_enable_only=True,
            ),
        )

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
            READ_ONLY_PMIC_LINE,
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

        changed_rails = HEALTHY_CAPTURE.replace(
            "railState=current-preserved", "railState=changed"
        )
        self.assertIn(
            "PMIC current-preserved rail state required (got changed)",
            validation_errors(
                summarize(changed_rails), require_pmic_read_only=True
            ),
        )

    def test_pmic_gate_requires_verified_four_second_power_button_config(self) -> None:
        for capture, gate in (
            (HEALTHY_CAPTURE, {"require_pmic_read_only": True}),
            (
                DISPLAY_RECOVERY_CAPTURE,
                {"require_pmic_display_enable_only": True},
            ),
        ):
            with self.subTest(mode=summarize(capture).pmic["mode"]):
                self.assertEqual(validation_errors(summarize(capture), **gate), [])
                legacy = capture.replace(" " + POWER_BUTTON_FIELDS, "", 1)
                errors = validation_errors(summarize(legacy), **gate)
                self.assertIn(
                    "PMIC four-second power-button-off configuration required "
                    "(got missing)",
                    errors,
                )
                self.assertIn(
                    "PMIC power-button config read required (got missing)", errors
                )
                self.assertIn(
                    "PMIC power-button-off seconds expected 4, got missing", errors
                )
                self.assertIn(
                    "PMIC power-button-off level expected 0, got missing", errors
                )
                self.assertIn(
                    "PMIC power-button config byte required (got missing)", errors
                )

        for old, new, expected_error in (
            (
                "powerButtonOffConfigured=1",
                "powerButtonOffConfigured=0",
                "PMIC four-second power-button-off configuration required (got 0)",
            ),
            (
                "powerButtonConfigRead=1",
                "powerButtonConfigRead=0",
                "PMIC power-button config read required (got 0)",
            ),
            (
                "powerButtonOffSeconds=4",
                "powerButtonOffSeconds=6",
                "PMIC power-button-off seconds expected 4, got 6",
            ),
            (
                "powerButtonOffLevel=0",
                "powerButtonOffLevel=1",
                "PMIC power-button-off level expected 0, got 1",
            ),
            (
                "powerButtonConfig=0xF3",
                "powerButtonConfig=0xF7",
                "PMIC power-button config off-level bits expected 0, got 1",
            ),
            (
                "powerButtonConfig=0xF3",
                "powerButtonConfig=invalid",
                "PMIC power-button config byte required (got invalid)",
            ),
        ):
            errors = validation_errors(
                summarize(HEALTHY_CAPTURE.replace(old, new, 1)),
                require_pmic_read_only=True,
            )
            self.assertIn(expected_error, errors)

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
