#!/usr/bin/env python3
"""Generate deterministic LVGL assets for the Bicino pre-connection UI."""

from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
from pathlib import Path
import sys

from PIL import Image
import qrcode
from qrcode.constants import ERROR_CORRECT_M


ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools"
OUTPUT = ROOT / "lib" / "images" / "src"
SOURCE_B64 = TOOLS / "preconnection-logo-source.png.b64"
MANIFEST = TOOLS / "preconnection-assets-manifest.json"

LOGO_SOURCE_REPOSITORY = "https://github.com/seichris/bicino"
LOGO_SOURCE_COMMIT = "a7b0bc0cdbf4e01b8afee9d614c8c8ffab884a9e"
LOGO_SOURCE_PATH = "public/images/bicino-logo.png"
LOGO_SOURCE_SHA256 = (
    "c37377cca05d4a9120a23c92ee5f19750b64ff206a8beb1f7863fc2ca1016612"
)
LOGO_SIZE = 36
BRAND_RED = (0xFF, 0x37, 0x2E)

QR_PAYLOAD = "https://bicino.com/app"
QR_VERSION = 2
QR_ERROR_CORRECTION = "M"
QR_BORDER_MODULES = 4
QR_MODULE_SCALE = 5
QR_MATRIX_MODULES = 25
QR_TOTAL_MODULES = QR_MATRIX_MODULES + QR_BORDER_MODULES * 2
QR_SIZE = QR_TOTAL_MODULES * QR_MODULE_SCALE


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def c_bytes(data: bytes) -> str:
    rows = []
    for offset in range(0, len(data), 12):
        chunk = data[offset : offset + 12]
        rows.append("  " + ", ".join(f"0x{value:02x}" for value in chunk) + ",")
    return "\n".join(rows)


def asset_header(symbol: str) -> bytes:
    macro = symbol.upper()
    return f'''#pragma once

#include <pgmspace.h>
#include "lvgl.h"

#ifndef LV_ATTRIBUTE_MEM_ALIGN
#define LV_ATTRIBUTE_MEM_ALIGN
#endif

#ifndef LV_ATTRIBUTE_IMAGE_{macro}
#define LV_ATTRIBUTE_IMAGE_{macro}
#endif

LV_IMAGE_DECLARE({symbol});
'''.encode()


def asset_source(symbol: str, color_format: str, width: int, height: int,
                 stride: int, data: bytes) -> bytes:
    macro = symbol.upper()
    return f'''#include "{symbol}.h"

const LV_ATTRIBUTE_MEM_ALIGN LV_ATTRIBUTE_LARGE_CONST
    LV_ATTRIBUTE_IMAGE_{macro} uint8_t {symbol}_map[] PROGMEM = {{
{c_bytes(data)}
}};

const lv_image_dsc_t {symbol} = {{
  {{
    LV_IMAGE_HEADER_MAGIC,
    {color_format},
    0,
    {width},
    {height},
    {stride},
  }},
  sizeof({symbol}_map),
  {symbol}_map,
  NULL,
}};
'''.encode()


def generate_logo() -> tuple[bytes, bytes, dict[str, object]]:
    source = base64.b64decode(SOURCE_B64.read_text())
    if sha256(source) != LOGO_SOURCE_SHA256:
        raise RuntimeError("canonical Bicino logo source checksum changed")

    original = Image.open(io.BytesIO(source)).convert("RGBA")
    alpha_box = original.getchannel("A").getbbox()
    if alpha_box is None:
        raise RuntimeError("canonical Bicino logo contains no visible pixels")
    mark = original.crop(alpha_box)
    mark.thumbnail((LOGO_SIZE, LOGO_SIZE), Image.Resampling.LANCZOS)
    alpha = Image.new("L", (LOGO_SIZE, LOGO_SIZE), 0)
    alpha.paste(mark.getchannel("A"),
                ((LOGO_SIZE - mark.width) // 2,
                 (LOGO_SIZE - mark.height) // 2))

    rgb565 = ((BRAND_RED[0] >> 3) << 11) | ((BRAND_RED[1] >> 2) << 5) | (
        BRAND_RED[2] >> 3
    )
    color_plane = bytes((rgb565 & 0xFF, rgb565 >> 8)) * (LOGO_SIZE * LOGO_SIZE)
    data = color_plane + alpha.tobytes()
    header = asset_header("bicino_logo")
    source_file = asset_source(
        "bicino_logo", "LV_COLOR_FORMAT_RGB565A8", LOGO_SIZE, LOGO_SIZE,
        LOGO_SIZE * 2, data
    )
    metadata = {
        "source_repository": LOGO_SOURCE_REPOSITORY,
        "source_commit": LOGO_SOURCE_COMMIT,
        "source_path": LOGO_SOURCE_PATH,
        "source_sha256": LOGO_SOURCE_SHA256,
        "output_dimensions": [LOGO_SIZE, LOGO_SIZE],
        "color_rgb888": "#FF372E",
        "data_sha256": sha256(data),
    }
    return header, source_file, metadata


def generate_qr() -> tuple[bytes, bytes, dict[str, object]]:
    qr = qrcode.QRCode(
        version=QR_VERSION,
        error_correction=ERROR_CORRECT_M,
        box_size=1,
        border=QR_BORDER_MODULES,
    )
    qr.add_data(QR_PAYLOAD)
    qr.make(fit=False)
    if qr.version != QR_VERSION:
        raise RuntimeError(f"QR changed to unexpected version {qr.version}")
    matrix = qr.get_matrix()
    if len(matrix) != QR_TOTAL_MODULES or any(
        len(row) != QR_TOTAL_MODULES for row in matrix
    ):
        raise RuntimeError("QR matrix dimensions changed")
    if any(
        matrix[y][x]
        for y in range(QR_TOTAL_MODULES)
        for x in range(QR_TOTAL_MODULES)
        if x < QR_BORDER_MODULES
        or y < QR_BORDER_MODULES
        or x >= QR_TOTAL_MODULES - QR_BORDER_MODULES
        or y >= QR_TOTAL_MODULES - QR_BORDER_MODULES
    ):
        raise RuntimeError("QR quiet zone is not empty")

    expanded = [
        [matrix[y // QR_MODULE_SCALE][x // QR_MODULE_SCALE]
         for x in range(QR_SIZE)]
        for y in range(QR_SIZE)
    ]
    stride = (QR_SIZE + 7) // 8
    pixels = bytearray()
    for row in expanded:
        packed = bytearray([0xFF] * stride)
        for x, black in enumerate(row):
            if black:
                packed[x // 8] &= ~(1 << (7 - x % 8))
        pixels.extend(packed)

    # Indexed LVGL images begin with BGRA palette entries. Index 0 is black,
    # index 1 is white; the software I1 renderer consumes bits MSB first.
    palette = bytes((0, 0, 0, 255, 255, 255, 255, 255))
    data = palette + pixels
    header = asset_header("bicino_app_qr")
    source_file = asset_source(
        "bicino_app_qr", "LV_COLOR_FORMAT_I1", QR_SIZE, QR_SIZE, stride, data
    )
    metadata = {
        "payload": QR_PAYLOAD,
        "version": QR_VERSION,
        "error_correction": QR_ERROR_CORRECTION,
        "matrix_modules": QR_MATRIX_MODULES,
        "quiet_zone_modules": QR_BORDER_MODULES,
        "module_scale": QR_MODULE_SCALE,
        "output_dimensions": [QR_SIZE, QR_SIZE],
        "stride_bytes": stride,
        "palette_bgra": [[0, 0, 0, 255], [255, 255, 255, 255]],
        "data_sha256": sha256(data),
    }
    return header, source_file, metadata


def generated_files() -> dict[Path, bytes]:
    logo_h, logo_c, logo_metadata = generate_logo()
    qr_h, qr_c, qr_metadata = generate_qr()
    files = {
        OUTPUT / "bicino_logo.h": logo_h,
        OUTPUT / "bicino_logo.c": logo_c,
        OUTPUT / "bicino_app_qr.h": qr_h,
        OUTPUT / "bicino_app_qr.c": qr_c,
    }
    manifest = {
        "generator": "tools/generate_preconnection_assets.py",
        "logo": logo_metadata,
        "qr": qr_metadata,
        "outputs": {
            str(path.relative_to(ROOT)): sha256(content)
            for path, content in sorted(files.items())
        },
    }
    files[MANIFEST] = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
    return files


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check", action="store_true",
        help="fail if checked-in assets differ from deterministic output"
    )
    args = parser.parse_args()
    expected = generated_files()
    if args.check:
        stale = [
            path for path, content in expected.items()
            if not path.exists() or path.read_bytes() != content
        ]
        if stale:
            for path in stale:
                print(f"stale generated asset: {path.relative_to(ROOT)}", file=sys.stderr)
            return 1
        print("pre-connection assets are current")
        return 0

    for path, content in expected.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        print(f"wrote {path.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
