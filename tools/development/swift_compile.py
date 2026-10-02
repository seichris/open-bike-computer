#!/usr/bin/env python3
"""Compile a registered Swift source graph with caller-supplied flags."""
import argparse
import json
import platform
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def sources(group, registry):
    values = []
    active = set()
    def visit(name):
        if name in active:
            raise ValueError("cyclic Swift source group: " + name)
        active.add(name)
        entry = registry[name]
        for parent in entry.get("groups", []):
            visit(parent)
        values.extend(entry.get("sources", []))
        active.remove(name)
    visit(group)
    return list(dict.fromkeys(values))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("group")
    parser.add_argument("flags", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    registry = json.loads((Path(__file__).with_name("swift-sources.json")).read_text())
    files = sources(args.group, registry["groups"])
    flags = args.flags[1:] if args.flags[:1] == ["--"] else args.flags
    compiler = ["xcrun", "swiftc"] if platform.system() == "Darwin" else ["swiftc"]
    return subprocess.run([*compiler, *flags, *(str(ROOT / f) for f in files)]).returncode


if __name__ == "__main__":
    raise SystemExit(main())
