#!/usr/bin/env python3
"""Capture ESP32 USB serial and summarize the structured boot contract."""

from __future__ import annotations

import argparse
import codecs
import glob
import sys
import time
from dataclasses import dataclass


_POST_READY_BOOT_RECORD_MARKERS = (
    "BOOT_PREVIOUS",
    "BOOT_FAILURE",
    "BOOT_PMIC",
    "BOOT_SAFE_MODE",
)


def _fields(line: str, marker: str) -> dict[str, str] | None:
    if line != marker and not line.startswith(f"{marker} "):
        return None
    parsed: dict[str, str] = {}
    for token in line.split()[1:]:
        key, separator, value = token.partition("=")
        if separator:
            parsed[key] = value
    return parsed


def _latest(capture: str, marker: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in capture.splitlines():
        parsed = _fields(line.strip(), marker)
        if parsed is not None:
            result = parsed
    return result


@dataclass(frozen=True)
class BootSummary:
    meta: dict[str, str]
    previous: dict[str, str]
    failure: dict[str, str]
    pmic: dict[str, str]
    ready: bool
    sequence_mismatches: int
    boot_discontinuities: int
    blocked_writes: int
    diagnostic_errors: int


def summarize(capture: str) -> BootSummary:
    lines = capture.splitlines()
    latest_boot_index = 0
    for index, line in enumerate(lines):
        if _fields(line.strip(), "BOOT_META") is not None:
            latest_boot_index = index
    latest_boot = "\n".join(lines[latest_boot_index:])

    meta = _latest(latest_boot, "BOOT_META")
    expected_sequence = meta.get("sequence")
    ready = False
    sequence_mismatches = 0
    boot_discontinuities = 0
    saw_ready = False
    for line in latest_boot.splitlines():
        stripped = line.strip()
        stage = _fields(stripped, "BOOT_STAGE")
        if stage is None:
            if saw_ready and any(
                _fields(stripped, marker) is not None
                for marker in _POST_READY_BOOT_RECORD_MARKERS
            ):
                # These records are emitted before readiness during setup. If
                # one appears after ready, capture has crossed into a later
                # boot whose BOOT_META/BOOT_STAGE output may have been lost
                # while USB serial re-enumerated.
                boot_discontinuities += 1
                ready = False
            continue
        if not expected_sequence or stage.get("sequence") != expected_sequence:
            sequence_mismatches += 1
            ready = False
            continue
        if saw_ready:
            # Ready is terminal for one boot. A later stage means a new or
            # corrupted boot stream even if RTC history reused the same numeric
            # sequence and its BOOT_META line was lost during USB enumeration.
            boot_discontinuities += 1
            ready = False
            continue
        if stage.get("event") == "ready" and stage.get("name") == "ready":
            ready = True
            saw_ready = True

    return BootSummary(
        meta=meta,
        previous=_latest(latest_boot, "BOOT_PREVIOUS"),
        failure=_latest(latest_boot, "BOOT_FAILURE"),
        pmic=_latest(latest_boot, "BOOT_PMIC"),
        ready=ready,
        sequence_mismatches=sequence_mismatches,
        boot_discontinuities=boot_discontinuities,
        blocked_writes=sum(
            _fields(line.strip(), "AXP_WRITE_BLOCKED") is not None
            for line in lines
        ),
        diagnostic_errors=sum(
            _fields(line.strip(), "BOOT_DIAGNOSTICS_ERROR") is not None
            for line in lines
        ),
    )


def format_summary(summary: BootSummary) -> str:
    def value(fields: dict[str, str], key: str) -> str:
        return fields.get(key, "missing")

    return (
        "BOOT_CAPTURE_SUMMARY schema=1 "
        f"target={value(summary.meta, 'target')} "
        f"profile={value(summary.meta, 'profile')} "
        f"git={value(summary.meta, 'git')} "
        f"sequence={value(summary.meta, 'sequence')} "
        f"reset={value(summary.meta, 'reset')} "
        f"previousFingerprint={value(summary.previous, 'fingerprint')} "
        f"previousActive={value(summary.previous, 'active')} "
        f"previousFailures={value(summary.previous, 'failureCount')} "
        f"previousFailureStage={value(summary.previous, 'failureStage')} "
        f"previousFailureAfter={value(summary.previous, 'failureAfter')} "
        f"previousFailureReset={value(summary.previous, 'failureReset')} "
        f"failures={value(summary.failure, 'count')} "
        f"failureReset={value(summary.failure, 'reset')} "
        f"safeMode={value(summary.failure, 'safeMode')} "
        f"pmicMode={value(summary.pmic, 'mode')} "
        f"pmicRailState={value(summary.pmic, 'railState')} "
        f"pmicDisplayRecovery={value(summary.pmic, 'displayRecovery')} "
        f"pmicDisplayChanged={value(summary.pmic, 'displayChanged')} "
        f"vbus={value(summary.pmic, 'vbus')} "
        f"battery={value(summary.pmic, 'battery')} "
        f"ldo={value(summary.pmic, 'ldo')} "
        f"ready={1 if summary.ready else 0} "
        f"sequenceMismatches={summary.sequence_mismatches} "
        f"bootDiscontinuities={summary.boot_discontinuities} "
        f"blockedWrites={summary.blocked_writes} "
        f"diagnosticErrors={summary.diagnostic_errors}"
    )


def validation_errors(
    summary: BootSummary,
    *,
    expected_target: str | None = None,
    expected_profile: str | None = None,
    expected_git: str | None = None,
    expected_reset: str | None = None,
    require_ready: bool = False,
    require_pmic_read_only: bool = False,
    require_pmic_display_enable_only: bool = False,
) -> list[str]:
    errors: list[str] = []
    if summary.sequence_mismatches:
        errors.append(
            "boot sequence mismatch observed: "
            f"{summary.sequence_mismatches} stage marker(s) do not match "
            f"BOOT_META sequence {summary.meta.get('sequence', 'missing')}"
        )
    if summary.boot_discontinuities:
        errors.append(
            "boot stream continued after ready marker: "
            f"{summary.boot_discontinuities} later boot marker(s) observed"
        )
    if expected_target and summary.meta.get("target") != expected_target:
        errors.append(
            f"target expected {expected_target}, got {summary.meta.get('target', 'missing')}"
        )
    if expected_profile and summary.meta.get("profile") != expected_profile:
        errors.append(
            "profile expected "
            f"{expected_profile}, got {summary.meta.get('profile', 'missing')}"
        )
    if expected_git and summary.meta.get("git") != expected_git:
        errors.append(
            f"git expected {expected_git}, got {summary.meta.get('git', 'missing')}"
        )
    if expected_reset and summary.meta.get("reset") != expected_reset:
        errors.append(
            f"reset expected {expected_reset}, got {summary.meta.get('reset', 'missing')}"
        )
    if require_ready and not summary.ready:
        errors.append("ready marker missing")
    if require_pmic_read_only:
        if summary.pmic.get("mode") != "read-only":
            errors.append(
                "PMIC read-only marker missing "
                f"(got {summary.pmic.get('mode', 'missing')})"
            )
        for field, label in (
            ("available", "PMIC probe"),
            ("statusRead", "PMIC status read"),
            ("ldoRead", "PMIC LDO-state read"),
        ):
            if summary.pmic.get(field) != "1":
                errors.append(
                    f"{label} required (got {summary.pmic.get(field, 'missing')})"
                )
    if require_pmic_display_enable_only:
        if summary.pmic.get("mode") != "display-enable-only":
            errors.append(
                "PMIC display-enable-only marker missing "
                f"(got {summary.pmic.get('mode', 'missing')})"
            )
        for field, label in (
            ("available", "PMIC probe"),
            ("statusRead", "PMIC status read"),
            ("ldoRead", "PMIC LDO-state read"),
            ("displayRecovery", "PMIC display recovery"),
        ):
            if summary.pmic.get(field) != "1":
                errors.append(
                    f"{label} required (got {summary.pmic.get(field, 'missing')})"
                )
        if summary.pmic.get("railState") != "display-enabled":
            errors.append(
                "PMIC display-enabled rail state required "
                f"(got {summary.pmic.get('railState', 'missing')})"
            )
        try:
            ldo_value = int(summary.pmic.get("ldo", ""), 0)
        except ValueError:
            errors.append(
                "PMIC LDO-state value required "
                f"(got {summary.pmic.get('ldo', 'missing')})"
            )
        else:
            if (ldo_value & 0x80) == 0:
                errors.append(
                    "PMIC 2.06 display-enable bit required "
                    f"(got {summary.pmic.get('ldo', 'missing')})"
                )
    if summary.blocked_writes:
        errors.append(f"blocked AXP2101 writes observed: {summary.blocked_writes}")
    if summary.diagnostic_errors:
        errors.append(f"boot diagnostic errors observed: {summary.diagnostic_errors}")
    return errors


def _resolve_port(requested: str | None, wait_seconds: float) -> str:
    deadline = time.monotonic() + wait_seconds
    while True:
        matches = sorted(glob.glob(requested or "/dev/cu.usbmodem*"))
        if len(matches) == 1:
            return matches[0]
        if len(matches) > 1:
            raise RuntimeError(
                "multiple USB modem ports found; pass --port explicitly: "
                + ", ".join(matches)
            )
        if time.monotonic() >= deadline:
            target = requested or "/dev/cu.usbmodem*"
            raise RuntimeError(f"timed out waiting for {target}")
        time.sleep(0.2)


def _open_serial(serial_module, port: str, baud: int):
    # Construct the pyserial object closed. Serial(port, ...) opens immediately
    # with pyserial's default asserted DTR/RTS state, which can reset or hold an
    # ESP32-S3 before callers get a chance to deassert those lines.
    device = serial_module.Serial(port=None, baudrate=baud, timeout=0.05)
    device.dtr = False
    device.rts = False
    device.port = port
    device.open()
    return device


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", help="serial device or glob; auto-detects one modem")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--duration", type=float, default=35.0)
    parser.add_argument("--wait-seconds", type=float, default=30.0)
    parser.add_argument(
        "--reset", action="store_true", help="pulse RTS once after opening the port"
    )
    parser.add_argument("--expected-target")
    parser.add_argument("--expected-profile")
    parser.add_argument("--expected-git")
    parser.add_argument("--expected-reset")
    parser.add_argument("--require-ready", action="store_true")
    pmic_gate = parser.add_mutually_exclusive_group()
    pmic_gate.add_argument("--require-pmic-read-only", action="store_true")
    pmic_gate.add_argument(
        "--require-pmic-display-enable-only", action="store_true"
    )
    args = parser.parse_args(argv)

    try:
        import serial
    except ImportError:
        print("capture_boot.py requires pyserial", file=sys.stderr)
        return 2

    try:
        port = _resolve_port(args.port, args.wait_seconds)
    except RuntimeError as error:
        print(f"BOOT_CAPTURE_ERROR {error}", file=sys.stderr)
        return 2

    print(f"BOOT_CAPTURE port={port} baud={args.baud} duration={args.duration:g}")
    decoder = codecs.getincrementaldecoder("utf-8")("replace")
    chunks: list[str] = []
    device = None
    try:
        device = _open_serial(serial, port, args.baud)
        if args.reset:
            device.rts = True
            time.sleep(0.25)
            device.rts = False

        deadline = time.monotonic() + args.duration
        while time.monotonic() < deadline:
            data = device.read(8192)
            if not data:
                continue
            text = decoder.decode(data)
            chunks.append(text)
            print(text, end="", flush=True)
        tail = decoder.decode(b"", final=True)
        if tail:
            chunks.append(tail)
            print(tail, end="", flush=True)
    except serial.SerialException as error:
        print(f"\nBOOT_CAPTURE_ERROR serial={error}", file=sys.stderr)
        return 2
    finally:
        if device is not None and device.is_open:
            device.close()

    summary = summarize("".join(chunks))
    print("\n" + format_summary(summary))
    errors = validation_errors(
        summary,
        expected_target=args.expected_target,
        expected_profile=args.expected_profile,
        expected_git=args.expected_git,
        expected_reset=args.expected_reset,
        require_ready=args.require_ready,
        require_pmic_read_only=args.require_pmic_read_only,
        require_pmic_display_enable_only=args.require_pmic_display_enable_only,
    )
    for error in errors:
        print(f"BOOT_CAPTURE_VALIDATION_ERROR {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
