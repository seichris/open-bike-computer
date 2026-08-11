#!/usr/bin/env python3

import json
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from types import SimpleNamespace
from pathlib import Path
from unittest.mock import patch

from resolve_upload_port import (
    DeviceResolutionError,
    main,
    resolve_device_port,
)


def port(device, serial_number, *, vid=0x303A, pid=0x1001):
    return SimpleNamespace(
        device=device,
        serial_number=serial_number,
        vid=vid,
        pid=pid,
        description="USB JTAG/serial debug unit",
    )


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class ResolveUploadPortTests(unittest.TestCase):
    def test_waits_for_hardware_serial_and_returns_current_port(self):
        scans = iter(
            (
                [port("/dev/cu.other", "28:84:85:3B:75:98")],
                [port("/dev/cu.usbmodem901", "3c:dc:75:6e:f0:10")],
            )
        )
        clock = FakeClock()

        resolved = resolve_device_port(
            "3C:DC:75:6E:F0:10",
            5,
            list_ports_provider=lambda: next(scans),
            monotonic=clock.monotonic,
            sleeper=clock.sleep,
            poll_interval_seconds=0.5,
        )

        self.assertEqual(resolved.port, "/dev/cu.usbmodem901")
        self.assertEqual(resolved.serial_number, "3c:dc:75:6e:f0:10")
        self.assertEqual(clock.now, 0.5)

    def test_rejects_duplicate_hardware_serials(self):
        with self.assertRaisesRegex(DeviceResolutionError, "multiple ports"):
            resolve_device_port(
                "duplicate",
                0,
                list_ports_provider=lambda: [
                    port("/dev/cu.one", "duplicate"),
                    port("/dev/cu.two", "DUPLICATE"),
                ],
            )

    def test_timeout_names_the_missing_hardware_serial(self):
        clock = FakeClock()
        with self.assertRaisesRegex(
            DeviceResolutionError, "missing.*within 1 seconds"
        ):
            resolve_device_port(
                "missing",
                1,
                list_ports_provider=lambda: [],
                monotonic=clock.monotonic,
                sleeper=clock.sleep,
                poll_interval_seconds=0.25,
            )

    def test_cli_emits_machine_readable_resolution(self):
        output = StringIO()
        with patch(
            "resolve_upload_port.resolve_device_port",
            return_value=resolve_device_port(
                "serial",
                0,
                list_ports_provider=lambda: [port("/dev/cu.test", "serial")],
            ),
        ), redirect_stdout(output):
            result = main(["--device-serial", "serial", "--timeout", "3"])

        self.assertEqual(result, 0)
        payload = json.loads(output.getvalue())
        self.assertEqual(payload["schema"], 1)
        self.assertEqual(payload["port"], "/dev/cu.test")

    def test_cli_reports_resolution_failure(self):
        errors = StringIO()
        with patch(
            "resolve_upload_port.resolve_device_port",
            side_effect=DeviceResolutionError("not connected"),
        ), redirect_stderr(errors):
            result = main(["--device-serial", "serial", "--timeout", "0"])

        self.assertEqual(result, 1)
        self.assertIn("not connected", errors.getvalue())

    def test_cli_resolves_explicit_registry_name_and_reports_family(self):
        with tempfile.TemporaryDirectory() as directory:
            registry = (Path(directory) / "devices.json").resolve()
            registry.write_text(
                json.dumps(
                    {
                        "schema": 1,
                        "devices": [
                            {
                                "nickname": "desk-175",
                                "boardFamily": "WAVESHARE_AMOLED_175",
                                "serialNumber": "SERIAL",
                                "updatedAt": "2026-08-10T00:00:00Z",
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            registry.chmod(0o600)
            output = StringIO()
            with patch(
                "resolve_upload_port.resolve_device_port",
                return_value=resolve_device_port(
                    "serial", 0,
                    list_ports_provider=lambda: [port("/dev/cu.named", "serial")],
                ),
            ), redirect_stdout(output):
                result = main(
                    ["--device-name", "desk-175", "--device-registry", str(registry)]
                )
        self.assertEqual(result, 0)
        payload = json.loads(output.getvalue())
        self.assertEqual(payload["nickname"], "desk-175")
        self.assertEqual(payload["boardFamily"], "WAVESHARE_AMOLED_175")


if __name__ == "__main__":
    unittest.main()
