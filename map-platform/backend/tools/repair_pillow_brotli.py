"""Repair Pillow's independent Brotli bundle and retain its wheel metadata.

Brotli 1.2.1 retains the 1.2.0 ABI. Keep the wheel's hashed SONAMEs and
$ORIGIN search path so FreeType continues to resolve the matching common
library rather than Ubuntu's older ABI-compatible-but-incomplete symbol set.
"""
from __future__ import annotations

import base64
import csv
import ctypes
import hashlib
import importlib.metadata
import io
from pathlib import Path
import shutil
import subprocess
import sys


def decoder_version(path: Path) -> int:
    # Probe in a child: overwriting an ELF mapped into this process is unsafe.
    return int(subprocess.check_output(
        [sys.executable, "-c",
         "import ctypes,sys; lib=ctypes.CDLL(sys.argv[1]); "
         "lib.BrotliDecoderVersion.restype=ctypes.c_uint32; "
         "print(lib.BrotliDecoderVersion())", str(path)], text=True,
    ).strip())


def repair(native_root: Path) -> None:
    distribution = importlib.metadata.distribution("Pillow")
    directory = Path(distribution.locate_file("pillow.libs"))
    decoders = list(directory.glob("libbrotlidec-*.so.*"))
    commons = list(directory.glob("libbrotlicommon-*.so.*"))
    if len(decoders) != 1 or len(commons) != 1:
        raise RuntimeError("Expected one independent Pillow Brotli decoder/common pair")
    decoder, common = decoders[0], commons[0]
    if decoder_version(decoder) != 0x1002000:
        raise RuntimeError("Repair requires the verified Brotli 1.2.0 ABI; refusing to replace another version")
    modified = {decoder.resolve(), common.resolve()}
    for destination, component in ((common, "common"), (decoder, "dec")):
        shutil.copy2(native_root / f"libbrotli{component}.so.1.2.1", destination)
        subprocess.run(
            [str(native_root / "patchelf"), "--set-soname", destination.name,
             "--set-rpath", "$ORIGIN", str(destination)], check=True,
        )
    subprocess.run(
        [str(native_root / "patchelf"), "--replace-needed", "libbrotlicommon.so.1",
         common.name, str(decoder)], check=True,
    )

    # Load only after replacing both libraries; verify the actual decoder,
    # since hashed wheel filenames intentionally retain their original names.
    library = ctypes.CDLL(str(decoder))
    library.BrotliDecoderVersion.restype = ctypes.c_uint32
    if library.BrotliDecoderVersion() != 0x1002001:
        raise RuntimeError("Pillow did not load Brotli 1.2.1")
    library.BrotliDecoderDecompress.argtypes = [
        ctypes.c_size_t, ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p,
    ]
    compressed = bytes.fromhex("8b098042726f746c69206465636f64657220736d6f6b6503")
    output = ctypes.create_string_buffer(128)
    size = ctypes.c_size_t(len(output))
    if (library.BrotliDecoderDecompress(len(compressed), compressed, ctypes.byref(size), output) != 1
            or output.raw[:size.value] != b"Brotli decoder smoke"):
        raise RuntimeError("Repaired Pillow Brotli decoder failed its decode check")

    records = [path for path in distribution.files or () if str(path).endswith(".dist-info/RECORD")]
    if len(records) != 1:
        raise RuntimeError("Pillow wheel RECORD is missing or ambiguous")
    record = Path(distribution.locate_file(records[0]))
    with record.open(newline="") as source:
        rows = list(csv.reader(source))
    updated = set()
    for row in rows:
        path = Path(distribution.locate_file(row[0])).resolve()
        if path in modified:
            data = path.read_bytes()
            digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
            row[1:3] = ["sha256=" + digest, str(len(data))]
            updated.add(path)
    if updated != modified:
        raise RuntimeError("Pillow wheel RECORD does not cover both repaired libraries")
    with record.open("w", newline="") as target:
        csv.writer(target).writerows(rows)

    # Exercise the same FreeType dependency chain used for map label rendering.
    from PIL import Image, ImageDraw, ImageFont
    font_paths = sorted(Path("/usr/share/fonts").rglob("*.ttf"))
    if not font_paths:
        raise RuntimeError("Map label fonts are missing")
    font = ImageFont.truetype(str(font_paths[0]), 20)
    image = Image.new("RGB", (240, 80), "white")
    ImageDraw.Draw(image).text((4, 4), "Bicino 42", font=font, fill="black")
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    buffer.seek(0)
    if Image.open(buffer).size != image.size:
        raise RuntimeError("Pillow image round trip failed")
    print("Pillow native Brotli 1.2.1, wheel RECORD, and font/image checks passed")


if __name__ == "__main__":
    repair(Path(sys.argv[1]))
