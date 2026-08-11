#!/usr/bin/env python3
"""Resolve one USB serial device by its stable hardware serial number."""

from __future__ import annotations

import argparse
import json
import math
import sys
import time
from collections.abc import Callable, Iterable, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from device_registry import (
    DeviceRegistryError,
    default_registry_path,
    resolve_device_name,
)


class DeviceResolutionError(RuntimeError):
    """Raised when a hardware serial cannot be mapped to exactly one port."""


class PortInfo(Protocol):
    device: str
    serial_number: str | None
    vid: int | None
    pid: int | None
    description: str | None


@dataclass(frozen=True)
class ResolvedDevice:
    port: str
    serial_number: str
    vid: int | None
    pid: int | None
    description: str | None

    def as_json(self) -> dict[str, object]:
        return {
            "schema": 1,
            "port": self.port,
            "serialNumber": self.serial_number,
            "vid": self.vid,
            "pid": self.pid,
            "description": self.description,
        }


def _normalized_serial(value: str) -> str:
    return value.strip().casefold()


def resolve_device_port(
    serial_number: str,
    timeout_seconds: float,
    *,
    list_ports_provider: Callable[[], Iterable[PortInfo]] | None = None,
    monotonic: Callable[[], float] = time.monotonic,
    sleeper: Callable[[float], None] = time.sleep,
    poll_interval_seconds: float = 0.25,
) -> ResolvedDevice:
    """Wait for exactly one port whose USB serial matches ``serial_number``."""
    requested = serial_number.strip()
    if (
        not requested
        or not requested.isprintable()
        or "\0" in requested
        or len(requested) > 255
    ):
        raise DeviceResolutionError("device serial must not be empty or invalid")
    if not math.isfinite(timeout_seconds) or timeout_seconds < 0:
        raise DeviceResolutionError("device timeout must be a finite nonnegative value")
    if poll_interval_seconds <= 0:
        raise DeviceResolutionError("device poll interval must be positive")

    if list_ports_provider is None:
        try:
            from serial.tools import list_ports
        except ImportError as error:
            raise DeviceResolutionError(
                "hardware-serial resolution requires pyserial"
            ) from error
        list_ports_provider = list_ports.comports

    expected = _normalized_serial(requested)
    deadline = monotonic() + timeout_seconds
    while True:
        matches = [
            port
            for port in list_ports_provider()
            if port.serial_number is not None
            and _normalized_serial(port.serial_number) == expected
        ]
        if len(matches) > 1:
            ports = ", ".join(sorted(port.device for port in matches))
            raise DeviceResolutionError(
                f"device serial {requested!r} matched multiple ports: {ports}"
            )
        if len(matches) == 1:
            match = matches[0]
            port = str(match.device).strip()
            if (
                not port
                or not port.isprintable()
                or "\0" in port
                or len(port) > 4096
            ):
                raise DeviceResolutionError(
                    f"device serial {requested!r} resolved to an invalid port"
                )
            return ResolvedDevice(
                port=port,
                serial_number=str(match.serial_number),
                vid=match.vid,
                pid=match.pid,
                description=match.description,
            )
        remaining = deadline - monotonic()
        if remaining <= 0:
            raise DeviceResolutionError(
                f"device serial {requested!r} did not appear within "
                f"{timeout_seconds:g} seconds"
            )
        sleeper(min(poll_interval_seconds, remaining))


def _parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    selector = parser.add_mutually_exclusive_group(required=True)
    selector.add_argument("--device-serial")
    selector.add_argument("--device-name")
    parser.add_argument("--device-registry", type=Path, default=default_registry_path())
    parser.add_argument("--timeout", type=float, default=60.0)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _parse_args(argv)
    try:
        entry = None
        serial = args.device_serial
        if args.device_name is not None:
            entry = resolve_device_name(args.device_name, args.device_registry)
            serial = entry.serial
        if serial is None:
            raise AssertionError("validated selector did not resolve")
        resolved = resolve_device_port(serial, args.timeout)
    except (DeviceResolutionError, DeviceRegistryError) as error:
        print(f"Device resolution failed: {error}", file=sys.stderr)
        return 1
    result = resolved.as_json()
    if entry is not None:
        result["nickname"] = entry.nickname
        result["boardFamily"] = entry.board_family
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
