#!/usr/bin/env python3
"""Capture ESP32 USB serial and summarize the structured boot contract."""

from __future__ import annotations

import argparse
import codecs
import glob
import sys
import time
from dataclasses import dataclass


def _fields(line: str, marker: str) -> dict[str, str] | None:
    if not line.startswith(f"{marker} "):
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
    blocked_writes: int
    diagnostic_errors: int


def summarize(capture: str) -> BootSummary:
    lines = capture.splitlines()
    latest_boot_index = 0
    for index, line in enumerate(lines):
        if _fields(line.strip(), "BOOT_META") is not None:
            latest_boot_index = index
    latest_boot = "\n".join(lines[latest_boot_index:])

    ready = False
    for line in latest_boot.splitlines():
        stage = _fields(line.strip(), "BOOT_STAGE")
        if stage and stage.get("event") == "ready" and stage.get("name") == "ready":
            ready = True

    return BootSummary(
        meta=_latest(latest_boot, "BOOT_META"),
        previous=_latest(latest_boot, "BOOT_PREVIOUS"),
        failure=_latest(latest_boot, "BOOT_FAILURE"),
        pmic=_latest(latest_boot, "BOOT_PMIC"),
        ready=ready,
        blocked_writes=sum(
            line.strip().startswith("AXP_WRITE_BLOCKED ") for line in lines
        ),
        diagnostic_errors=sum(
            line.strip().startswith("BOOT_DIAGNOSTICS_ERROR ") for line in lines
        ),
    )


def format_summary(summary: BootSummary) -> str:
    def value(fields: dict[str, str], key: str) -> str:
        return fields.get(key, "missing")

    return (
        "BOOT_CAPTURE_SUMMARY schema=1 "
        f"target={value(summary.meta, 'target')} "
        f"git={value(summary.meta, 'git')} "
        f"reset={value(summary.meta, 'reset')} "
        f"previousActive={value(summary.previous, 'active')} "
        f"failures={value(summary.failure, 'count')} "
        f"safeMode={value(summary.failure, 'safeMode')} "
        f"pmicMode={value(summary.pmic, 'mode')} "
        f"vbus={value(summary.pmic, 'vbus')} "
        f"battery={value(summary.pmic, 'battery')} "
        f"ldo={value(summary.pmic, 'ldo')} "
        f"ready={1 if summary.ready else 0} "
        f"blockedWrites={summary.blocked_writes} "
        f"diagnosticErrors={summary.diagnostic_errors}"
    )


def validation_errors(
    summary: BootSummary,
    *,
    expected_target: str | None = None,
    expected_git: str | None = None,
    require_ready: bool = False,
    require_pmic_read_only: bool = False,
) -> list[str]:
    errors: list[str] = []
    if expected_target and summary.meta.get("target") != expected_target:
        errors.append(
            f"target expected {expected_target}, got {summary.meta.get('target', 'missing')}"
        )
    if expected_git and summary.meta.get("git") != expected_git:
        errors.append(
            f"git expected {expected_git}, got {summary.meta.get('git', 'missing')}"
        )
    if require_ready and not summary.ready:
        errors.append("ready marker missing")
    if require_pmic_read_only and summary.pmic.get("mode") != "read-only":
        errors.append(
            "PMIC read-only marker missing "
            f"(got {summary.pmic.get('mode', 'missing')})"
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
    parser.add_argument("--expected-git")
    parser.add_argument("--require-ready", action="store_true")
    parser.add_argument("--require-pmic-read-only", action="store_true")
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
    try:
        device = serial.Serial(port, args.baud, timeout=0.05)
        # Never leave control lines asserted: that can reset or hold the S3's
        # USB CDC/JTAG serial path and make a healthy boot look silent.
        device.dtr = False
        device.rts = False
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
        device.close()
    except serial.SerialException as error:
        print(f"\nBOOT_CAPTURE_ERROR serial={error}", file=sys.stderr)
        return 2

    summary = summarize("".join(chunks))
    print("\n" + format_summary(summary))
    errors = validation_errors(
        summary,
        expected_target=args.expected_target,
        expected_git=args.expected_git,
        require_ready=args.require_ready,
        require_pmic_read_only=args.require_pmic_read_only,
    )
    for error in errors:
        print(f"BOOT_CAPTURE_VALIDATION_ERROR {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
