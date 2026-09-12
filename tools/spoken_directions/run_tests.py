#!/usr/bin/env python3
"""Compile isolated host tools and compare Swift output with the C++ decoder.

No firmware build, device access, speech synthesis, or audio playback. Generated
synthetic PCM and binaries stay in a unique temporary directory and are removed.
"""
from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import shlex
import struct
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent


def run(*args: str | Path) -> str:
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"host command failed: {args[0]}\n{result.stdout}\n{result.stderr}")
    if result.stdout:
        print(result.stdout, end="", flush=True)
    return result.stdout


def suite(cpp_only: bool = False, sanitize: bool = False) -> None:
    with tempfile.TemporaryDirectory(prefix="bicino-spoken-codec-") as temporary:
        root = Path(temporary)
        flags = ["-std=c++17", "-Wall", "-Wextra", "-Werror", "-O2"]
        if sanitize:
            flags += ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
        compiler = shlex.split(os.environ.get("CXX", "c++"))
        run(*compiler, *flags, HERE / "test_decoder.cpp", "-o", root / "tests")
        run(root / "tests")
        if cpp_only:
            return
        run(*compiler, *flags, HERE / "decode.cpp", "-o", root / "decode")
        swift = ["xcrun", "swiftc"] if os.uname().sysname == "Darwin" else ["swiftc"]
        for entry, output in [("test_encoder.swift", "swift-tests"), ("encode.swift", "encode")]:
            run(*swift, "-O", "-warnings-as-errors", "-parse-as-library",
                HERE / "SpokenAssetEncoder.swift", HERE / entry, "-o", root / output)
        run(root / "swift-tests")
        report = []
        for count in [1,2,3,159,160,161,319,320,321,48_000,128_000]:
            # Integer triangle wave: deterministic on every host, owned test
            # signal, deliberately NOT evidence of spoken intelligibility.
            source = [min(i % 200, 200 - i % 200) * 400 - 20_000 for i in range(count)]
            pcm = root / f"{count}.pcm"
            encoded = root / f"{count}.bsa0"
            decoded = root / f"{count}.decoded"
            pcm.write_bytes(struct.pack(f"<{count}h", *source))
            run(root / "encode", pcm, encoded)
            run(root / "decode", encoded, decoded)
            actual = struct.unpack(f"<{count}h", decoded.read_bytes())
            # Every independently decodable block reproduces its first sample.
            if not all(actual[i] == source[i] for i in range(0, count, 160)):
                raise AssertionError("block predictor did not round-trip")
            rms = math.sqrt(sum((a - b) ** 2 for a, b in zip(source, actual)) / count)
            if rms >= 100:
                raise AssertionError("synthetic triangle regression, not a speech-quality gate")
            report.append({"frames": count, "pcm_mono_bytes": count * 2,
                           "pcm_stereo_bytes": count * 4,
                           "candidate_bytes": encoded.stat().st_size,
                           "synthetic_rms_error": round(rms, 3),
                           "fits_proposed_64KiB_asset": encoded.stat().st_size <= 65536})
            # Existing destinations must be preserved byte-for-byte.
            for program, src, dst in [("encode", pcm, encoded), ("decode", encoded, decoded)]:
                before = dst.read_bytes()
                result = subprocess.run([root / program, src, dst], capture_output=True)
                if result.returncode == 0 or dst.read_bytes() != before:
                    raise AssertionError("CLI overwrote an existing destination")
        print(json.dumps({"evidence": "host_synthetic_only", "measurements": report}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cpp-only", action="store_true")
    parser.add_argument("--sanitize", action="store_true")
    args = parser.parse_args()
    suite(args.cpp_only, args.sanitize)
