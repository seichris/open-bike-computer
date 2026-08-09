#!/usr/bin/env python3
"""Control an already-authorized Bicino remote-debug firmware session."""

from __future__ import annotations

import argparse
import getpass
import json
import os
from pathlib import Path
import stat
import struct
import sys
import time
from typing import Any
from urllib import error, parse, request
import zlib


TOKEN_ENV = "BICINO_DEVICE_DEBUG_TOKEN"
TOKEN_HEADER = "X-BikeComputer-Transfer-Token"
FRAME_HEADER = struct.Struct("<4sHHIIHHHBBII")
TARGET_DIMENSIONS = {
    "WAVESHARE_AMOLED_175": (466, 466),
    "WAVESHARE_AMOLED_206": (410, 502),
}


class DebugClientError(RuntimeError):
    pass


def _redact(message: str, token: str) -> str:
    return message.replace(token, "<redacted>") if token else message


def _load_session(path: Path) -> dict[str, Any]:
    mode = stat.S_IMODE(path.stat().st_mode)
    if mode & 0o077:
        raise DebugClientError(f"session file must be mode 0600, not {mode:04o}")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise DebugClientError(f"could not read session file: {exc}") from exc
    if not isinstance(payload, dict):
        raise DebugClientError("session file must contain a JSON object")
    return payload


def _session_values(args: argparse.Namespace) -> tuple[str, str]:
    stored: dict[str, Any] = {}
    if args.session_file:
        stored = _load_session(args.session_file)
    base_url = args.base_url or stored.get("baseUrl")
    if not isinstance(base_url, str) or not base_url:
        raise DebugClientError("provide --base-url or a session file with baseUrl")
    parsed = parse.urlsplit(base_url)
    if (
        parsed.scheme != "http"
        or not parsed.netloc
        or parsed.username is not None
        or parsed.password is not None
    ):
        raise DebugClientError("base URL must be an absolute http URL without credentials")
    base_url = parse.urlunsplit((parsed.scheme, parsed.netloc, parsed.path, "", ""))
    token = os.environ.get(TOKEN_ENV) or stored.get("token")
    if token is None:
        token = getpass.getpass("Transfer token: ")
    if not isinstance(token, str) or not token or any(character.isspace() for character in token):
        raise DebugClientError("transfer token is missing or invalid")
    return base_url.rstrip("/"), token


class DebugClient:
    def __init__(self, base_url: str, token: str, timeout: float = 8.0) -> None:
        self.base_url = base_url
        self.token = token
        self.timeout = timeout
        self._event_sequence = time.monotonic_ns() & 0xFFFFFFFF
        self.identity: dict[str, Any] | None = None
        # Accessory credentials must never be forwarded through a developer's
        # ambient HTTP(S)_PROXY configuration.
        self._opener = request.build_opener(request.ProxyHandler({}))

    def _request(
        self,
        path: str,
        *,
        method: str = "GET",
        body: dict[str, Any] | None = None,
        allow_no_content: bool = False,
    ) -> bytes | None:
        data = None
        headers = {TOKEN_HEADER: self.token, "Cache-Control": "no-store"}
        if body is not None:
            data = json.dumps(body, separators=(",", ":")).encode("utf-8")
            headers["Content-Type"] = "application/json"
        outgoing = request.Request(
            self.base_url + path, data=data, headers=headers, method=method
        )
        try:
            with self._opener.open(outgoing, timeout=self.timeout) as response:
                if allow_no_content and response.status == 204:
                    return None
                return response.read()
        except error.HTTPError as exc:
            detail = exc.read(2048).decode("utf-8", errors="replace")
            try:
                parsed = json.loads(detail)
                if isinstance(parsed, dict):
                    error_body = parsed.get("error")
                    if isinstance(error_body, dict):
                        detail = error_body.get("code", detail)
            except json.JSONDecodeError:
                pass
            raise DebugClientError(f"HTTP {exc.code}: {detail}") from exc
        except (error.URLError, TimeoutError, OSError) as exc:
            raise DebugClientError(f"request failed: {exc}") from exc

    def info(self, *, refresh: bool = True) -> dict[str, Any]:
        if self.identity is not None and not refresh:
            return self.identity
        raw = self._request("/device-debug/v1/info")
        try:
            result = json.loads((raw or b"").decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise DebugClientError("device returned invalid info JSON") from exc
        if not isinstance(result, dict):
            raise DebugClientError("device info must be a JSON object")
        target = result.get("target")
        dimensions = (result.get("width"), result.get("height"))
        if target not in TARGET_DIMENSIONS or TARGET_DIMENSIONS[target] != dimensions:
            raise DebugClientError(
                f"unexpected target identity or dimensions: {target!r} {dimensions!r}"
            )
        device_id = result.get("deviceId")
        if not isinstance(device_id, str) or not device_id:
            raise DebugClientError("device info has no stable device identity")
        self.identity = result
        return result

    def frame(self, after: int = 0) -> tuple[dict[str, int], bytes]:
        if isinstance(after, bool) or not isinstance(after, int) or not (0 <= after <= 0xFFFFFFFF):
            raise DebugClientError("after must be a uint32 frame sequence")
        raw = self._request(
            f"/device-debug/v1/frame?after={after}", allow_no_content=True
        )
        if raw is None:
            raise DebugClientError("device has no newer frame")
        if len(raw) < FRAME_HEADER.size:
            raise DebugClientError("frame response is shorter than its header")
        (
            magic,
            header_bytes,
            flags,
            sequence,
            captured_at_ms,
            width,
            height,
            stride,
            pixel_format,
            orientation,
            payload_bytes,
            expected_crc,
        ) = FRAME_HEADER.unpack_from(raw)
        if (
            magic != b"BCF1"
            or header_bytes < FRAME_HEADER.size
            or flags != 0
            or pixel_format != 1
            or orientation != 0
            or stride < width * 2
            or payload_bytes != stride * height
            or len(raw) != header_bytes + payload_bytes
        ):
            raise DebugClientError("frame metadata is invalid or unsupported")
        info = self.info(refresh=False)
        if (width, height) != (info["width"], info["height"]):
            raise DebugClientError("frame dimensions do not match the validated device")
        payload = raw[header_bytes:]
        if zlib.crc32(payload) & 0xFFFFFFFF != expected_crc:
            raise DebugClientError("frame CRC mismatch")
        return {
            "sequence": sequence,
            "capturedAtMs": captured_at_ms,
            "width": width,
            "height": height,
            "stride": stride,
        }, payload

    def _next_sequence(self) -> int:
        self._event_sequence = (self._event_sequence + 1) & 0xFFFFFFFF
        return self._event_sequence

    def pointer(self, phase: str, x: int, y: int) -> None:
        info = self.info(refresh=False)
        if not (0 <= x < info["width"] and 0 <= y < info["height"]):
            raise DebugClientError("pointer coordinate is outside the validated display")
        self._request(
            "/device-debug/v1/pointer",
            method="POST",
            body={
                "schema": 1,
                "eventSequence": self._next_sequence(),
                "pointerId": 0,
                "phase": phase,
                "x": x,
                "y": y,
            },
        )

    def wake(self) -> None:
        self._request("/device-debug/v1/display/wake", method="POST")

    def exit(self) -> None:
        self._request("/device-debug/v1/session/exit", method="POST")


def _png_chunk(kind: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload))
        + kind
        + payload
        + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
    )


def write_rgb565_png(
    output: Path, width: int, height: int, stride: int, pixels: bytes
) -> None:
    if (
        width <= 0
        or height <= 0
        or stride < width * 2
        or len(pixels) != stride * height
    ):
        raise DebugClientError("RGB565 input dimensions or length are invalid")
    compressor = zlib.compressobj(level=6)
    compressed: list[bytes] = []
    for y in range(height):
        source = memoryview(pixels)[y * stride : y * stride + width * 2]
        row = bytearray(1 + width * 3)
        row[0] = 0
        for x in range(width):
            value = source[x * 2] | (source[x * 2 + 1] << 8)
            offset = 1 + x * 3
            row[offset] = ((value >> 11) & 0x1F) * 255 // 31
            row[offset + 1] = ((value >> 5) & 0x3F) * 255 // 63
            row[offset + 2] = (value & 0x1F) * 255 // 31
        compressed.append(compressor.compress(row))
    compressed.append(compressor.flush())
    png = bytearray(b"\x89PNG\r\n\x1a\n")
    png += _png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += _png_chunk(b"IDAT", b"".join(compressed))
    png += _png_chunk(b"IEND", b"")
    output.write_bytes(png)
    if output.stat().st_size < 64 or output.read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
        raise DebugClientError("PNG output validation failed")


def _hold(client: DebugClient, x: int, y: int, duration_ms: int) -> None:
    client.pointer("down", x, y)
    started = time.monotonic()
    try:
        while (time.monotonic() - started) * 1000 < duration_ms:
            time.sleep(min(0.45, max(0.01, duration_ms / 1000)))
            if (time.monotonic() - started) * 1000 < duration_ms:
                client.pointer("move", x, y)
        client.pointer("up", x, y)
    except BaseException:
        try:
            client.pointer("cancel", x, y)
        except DebugClientError:
            pass
        raise


def _run(args: argparse.Namespace, client: DebugClient) -> None:
    if args.command == "info":
        print(json.dumps(client.info(), indent=2, sort_keys=True))
        return
    if args.command == "wake":
        client.wake()
        print("wake requested")
        return
    if args.command == "exit":
        client.exit()
        print("session exit acknowledged")
        return

    info = client.info()
    if args.command == "screenshot":
        metadata, pixels = client.frame()
        write_rgb565_png(
            args.output,
            metadata["width"],
            metadata["height"],
            metadata["stride"],
            pixels,
        )
        print(f"wrote frame {metadata['sequence']} to {args.output}")
    elif args.command == "tap":
        _hold(client, args.x, args.y, 60)
    elif args.command == "long-press":
        if args.duration_ms <= 0:
            raise DebugClientError("long-press duration must be positive")
        _hold(client, args.x, args.y, args.duration_ms)
    elif args.command == "swipe":
        if args.duration_ms <= 0:
            raise DebugClientError("swipe duration must be positive")
        duration = max(40, args.duration_ms)
        steps = max(2, duration // 40)
        client.pointer("down", args.x1, args.y1)
        try:
            for index in range(1, steps):
                time.sleep(duration / steps / 1000)
                x = round(args.x1 + (args.x2 - args.x1) * index / steps)
                y = round(args.y1 + (args.y2 - args.y1) * index / steps)
                client.pointer("move", x, y)
            time.sleep(duration / steps / 1000)
            client.pointer("up", args.x2, args.y2)
        except BaseException:
            try:
                client.pointer("cancel", args.x2, args.y2)
            except DebugClientError:
                pass
            raise
    _ = info


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", help="device transfer base URL (token excluded)")
    parser.add_argument("--session-file", type=Path, help="mode-0600 JSON session file")
    parser.add_argument("--timeout", type=float, default=8.0)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("info")
    screenshot = commands.add_parser("screenshot")
    screenshot.add_argument("--output", required=True, type=Path)
    for name in ("tap", "long-press"):
        command = commands.add_parser(name)
        command.add_argument("x", type=int)
        command.add_argument("y", type=int)
        if name == "long-press":
            command.add_argument("--duration-ms", type=int, default=800)
    swipe = commands.add_parser("swipe")
    for coordinate in ("x1", "y1", "x2", "y2"):
        swipe.add_argument(coordinate, type=int)
    swipe.add_argument("--duration-ms", type=int, default=400)
    commands.add_parser("wake")
    commands.add_parser("exit")
    return parser


def main() -> int:
    args = _parser().parse_args()
    token = ""
    try:
        base_url, token = _session_values(args)
        if args.timeout <= 0:
            raise DebugClientError("timeout must be positive")
        _run(args, DebugClient(base_url, token, args.timeout))
        return 0
    except (DebugClientError, OSError, ValueError, EOFError) as exc:
        print(f"device_debug: {_redact(str(exc), token)}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
