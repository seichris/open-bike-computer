"""Reject locale/stream runtime dependencies in a linked remote-debug image.

These dependencies reserve scarce internal RAM at boot, even if no debug HTTP
request has run. Check the ELF rather than only the serializer's source text.
"""
import argparse
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--elf", required=True, type=Path)
    parser.add_argument("--nm", required=True, type=Path)
    args = parser.parse_args()
    symbols = subprocess.check_output(
        [str(args.nm.resolve()), "--demangle", str(args.elf.resolve())], text=True
    )
    if not symbols.strip():
        raise SystemExit("The linked firmware has no symbols to verify.")
    forbidden = [line.strip() for line in symbols.splitlines()
                 if any(name in line for name in (
                     "std::locale::", "std::basic_ostringstream<",
                     "std::__cxx11::basic_ostringstream<"))]
    print(json.dumps({"ok": not forbidden, "forbiddenSymbols": forbidden}))
    return 1 if forbidden else 0


if __name__ == "__main__":
    raise SystemExit(main())
