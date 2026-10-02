import argparse
import importlib.util
import os
from pathlib import Path
import struct
import tempfile
import unittest
import zlib
import json
from unittest import mock


MODULE_PATH = Path(__file__).parents[1] / "device_debug.py"
SPEC = importlib.util.spec_from_file_location("device_debug", MODULE_PATH)
assert SPEC and SPEC.loader
device_debug = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(device_debug)

TEST_TOKEN = "b" * 32
TEST_TLS_SHA256 = "a" * 64


class StubClient(device_debug.DebugClient):
    def __init__(self, response: bytes):
        super().__init__(
            "https://192.0.2.1:8080", TEST_TOKEN, TEST_TLS_SHA256
        )
        self.response = response
        self.last_request = None
        self.identity = {
            "target": "WAVESHARE_AMOLED_206",
            "deviceId": "abc",
            "width": 2,
            "height": 1,
            "viewRotation": 0,
        }

    def _request(self, *args, **kwargs):
        self.last_request = (args, kwargs)
        return self.response


class DeviceDebugCliTests(unittest.TestCase):
    def test_frame_validation(self):
        payload = bytes((0x00, 0xF8, 0xE0, 0x07))
        header = device_debug.FRAME_HEADER.pack(
            b"BCF1", 32, 0, 7, 9, 2, 1, 4, 1, 0, len(payload), zlib.crc32(payload)
        )
        metadata, decoded = StubClient(header + payload).frame()
        self.assertEqual(metadata["sequence"], 7)
        self.assertEqual(decoded, payload)

    def test_frame_capture_floor_is_validated_and_encoded(self):
        payload = bytes((0x00, 0xF8, 0xE0, 0x07))
        header = device_debug.FRAME_HEADER.pack(
            b"BCF1", 32, 0, 7, 9, 2, 1, 4, 1, 0, len(payload), zlib.crc32(payload)
        )
        client = StubClient(header + payload)
        client.frame(6, captured_at_or_after=1234)
        self.assertEqual(
            client.last_request,
            (("/device-debug/v1/frame?after=6&capturedAtOrAfter=1234",),
             {"allow_no_content": True}),
        )
        with self.assertRaisesRegex(device_debug.DebugClientError, "uint32"):
            client.frame(captured_at_or_after=-1)

    def test_frame_crc_rejected(self):
        payload = bytes((0x00, 0xF8, 0xE0, 0x07))
        header = device_debug.FRAME_HEADER.pack(
            b"BCF1", 32, 0, 7, 9, 2, 1, 4, 1, 0, len(payload), 0
        )
        with self.assertRaisesRegex(device_debug.DebugClientError, "CRC"):
            StubClient(header + payload).frame()

    def test_rgb565_png_is_valid(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "frame.png"
            device_debug.write_rgb565_png(
                output, 2, 1, 4, bytes((0x00, 0xF8, 0xE0, 0x07))
            )
            png = output.read_bytes()
            self.assertEqual(png[:8], b"\x89PNG\r\n\x1a\n")
            self.assertEqual(struct.unpack(">II", png[16:24]), (2, 1))
            offset = 8
            idat = bytearray()
            while offset < len(png):
                length = struct.unpack(">I", png[offset : offset + 4])[0]
                kind = png[offset + 4 : offset + 8]
                payload = png[offset + 8 : offset + 8 + length]
                if kind == b"IDAT":
                    idat.extend(payload)
                offset += 12 + length
            self.assertEqual(
                zlib.decompress(idat),
                b"\x00\xff\x00\x00\x00\xff\x00",
                "RGB565 red/green fixtures decode to exact RGB888 pixels",
            )

    def test_rgb565_png_rejects_invalid_payload_length(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(device_debug.DebugClientError, "length"):
                device_debug.write_rgb565_png(
                    Path(directory) / "frame.png", 2, 1, 4, b"\x00\x00"
                )

    def test_rgb565_png_applies_validated_panel_rotation(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "rotated.png"
            device_debug.write_rgb565_png(
                output,
                2,
                1,
                4,
                bytes((0x00, 0xF8, 0xE0, 0x07)),
                1,
            )
            png = output.read_bytes()
            self.assertEqual(struct.unpack(">II", png[16:24]), (1, 2))
            offset = 8
            idat = bytearray()
            while offset < len(png):
                length = struct.unpack(">I", png[offset : offset + 4])[0]
                if png[offset + 4 : offset + 8] == b"IDAT":
                    idat.extend(png[offset + 8 : offset + 8 + length])
                offset += 12 + length
            self.assertEqual(
                zlib.decompress(idat),
                b"\x00\x00\xff\x00\x00\xff\x00\x00",
                "quarter-turn output matches the browser's panel transform",
            )

    def test_session_file_permissions_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            session = Path(directory) / "session.json"
            session.write_text("{}", encoding="utf-8")
            session.chmod(0o644)
            with self.assertRaisesRegex(device_debug.DebugClientError, "0600"):
                device_debug._load_session(session)

    def test_session_requires_https_token_and_tls_pin(self):
        with tempfile.TemporaryDirectory() as directory:
            session = Path(directory) / "session.json"
            session.write_text(
                json.dumps(
                    {
                        "baseUrl": "https://192.0.2.1:8080",
                        "token": TEST_TOKEN,
                        "tlsCertificateSha256": TEST_TLS_SHA256,
                    }
                ),
                encoding="utf-8",
            )
            session.chmod(0o600)
            args = argparse.Namespace(
                session_file=session,
                base_url=None,
                tls_sha256=None,
            )
            with mock.patch.dict(os.environ, {}, clear=True):
                self.assertEqual(
                    device_debug._session_values(args),
                    (
                        "https://192.0.2.1:8080",
                        TEST_TOKEN,
                        TEST_TLS_SHA256,
                    ),
                )
            args.base_url = "http://192.0.2.1:8080"
            with mock.patch.dict(os.environ, {}, clear=True):
                with self.assertRaisesRegex(
                    device_debug.DebugClientError, "HTTPS origin"
                ):
                    device_debug._session_values(args)

    def test_redirects_are_never_followed(self):
        handler = device_debug._NoRedirectHandler()
        self.assertIsNone(
            handler.redirect_request(None, None, 302, "Found", {}, "https://other")
        )

    def test_client_cannot_be_constructed_for_plaintext(self):
        with self.assertRaisesRegex(device_debug.DebugClientError, "HTTPS origin"):
            device_debug.DebugClient(
                "http://192.0.2.1:8080", TEST_TOKEN, TEST_TLS_SHA256
            )

    def test_token_redaction(self):
        self.assertEqual(
            device_debug._redact("failed with abc123", "abc123"),
            "failed with <redacted>",
        )

    def test_frame_sequence_bounds_fail_closed(self):
        with self.assertRaisesRegex(device_debug.DebugClientError, "uint32"):
            StubClient(b"").frame(-1)
        with self.assertRaisesRegex(device_debug.DebugClientError, "uint32"):
            StubClient(b"").frame(0x1_0000_0000)

    def test_device_identity_mismatch_fails_before_input(self):
        client = StubClient(
            json.dumps(
                {
                    "target": "WAVESHARE_AMOLED_206",
                    "deviceId": "abc",
                    "width": 2,
                    "height": 1,
                    "viewRotation": 0,
                }
            ).encode()
        )
        client.identity = None
        with self.assertRaisesRegex(device_debug.DebugClientError, "identity"):
            client.info()

    def test_interrupted_hold_attempts_cancel(self):
        phases = []

        class InterruptingClient:
            def pointer(self, phase, _x, _y):
                phases.append(phase)
                if phase == "up":
                    raise KeyboardInterrupt()

        with self.assertRaises(KeyboardInterrupt):
            device_debug._hold(InterruptingClient(), 3, 4, 0)
        self.assertEqual(phases, ["down", "up", "cancel"])

    def test_boot_uses_dedicated_short_press_route(self):
        calls = []
        client = device_debug.DebugClient(
            "https://192.0.2.1:8080", TEST_TOKEN, TEST_TLS_SHA256
        )
        client._request = lambda path, **kwargs: calls.append((path, kwargs))
        client.boot()
        self.assertEqual(
            calls,
            [("/device-debug/v1/button/boot", {"method": "POST"})],
        )

    def test_pointer_sequence_continues_across_cli_processes(self):
        calls = []
        info = {
            "target": "WAVESHARE_AMOLED_206",
            "deviceId": "abc",
            "width": 410,
            "height": 502,
            "viewRotation": 0,
            "counters": {
                "pointerLastSequence": 41,
                "pointerSequenceInitialized": True,
            },
        }
        client = device_debug.DebugClient(
            "https://192.0.2.1:8080", TEST_TOKEN, TEST_TLS_SHA256
        )

        def fake_request(path, **kwargs):
            calls.append((path, kwargs))
            if path.endswith("/info"):
                return json.dumps(info).encode()
            return b"{}"

        client._request = fake_request
        client.pointer("down", 10, 20)
        pointer_body = calls[-1][1]["body"]
        self.assertEqual(pointer_body["eventSequence"], 42)

    def test_metrics_requires_shared_schema_and_identity(self):
        client = StubClient(
            json.dumps(
                {
                    "ok": True,
                    "schema": 1,
                    "sequence": 9,
                    "timestampMs": 10,
                    "window": {},
                    "identity": {},
                    "tuning": {"profile": "current"},
                    "memory": {},
                    "render": {},
                    "ui": {},
                    "displayFlush": {},
                    "gps": {},
                    "routeReplay": {},
                    "remoteDebug": {},
                }
            ).encode()
        )
        self.assertEqual(client.metrics()["sequence"], 9)
        client.response = b'{"ok":true,"schema":2}'
        with self.assertRaisesRegex(device_debug.DebugClientError, "schema"):
            client.metrics()

    def test_begin_renderer_window_sends_exact_fixture_identity(self):
        calls = []
        client = device_debug.DebugClient(
            "https://192.0.2.1:8080", TEST_TOKEN, TEST_TLS_SHA256
        )

        def fake_request(path, **kwargs):
            calls.append((path, kwargs))
            return b'{"ok":true,"requestId":17}'

        client._request = fake_request
        request_id = client.begin_renderer_window(
            profile="medium",
            run_id="run-17",
            repeat=2,
            map_fixture_id="shanghai-map",
            map_fixture_sha256="a" * 64,
            route_fixture_id="shanghai-route",
            route_fixture_sha256="b" * 64,
        )
        self.assertEqual(request_id, 17)
        self.assertEqual(calls[0][0], "/device-debug/v1/metrics/window")
        self.assertEqual(calls[0][1]["method"], "POST")
        self.assertEqual(calls[0][1]["body"]["profile"], "medium")
        self.assertEqual(
            calls[0][1]["body"]["routeFixture"]["sha256"], "b" * 64
        )


if __name__ == "__main__":
    unittest.main()
