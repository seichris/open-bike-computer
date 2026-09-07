#!/usr/bin/env python3
"""Validate an exact production boot checkpoint in owner-authenticated device logs.

This validates a captured record, not its physical origin or flash-byte equality.
The operator must separately bind the capture to the intended device and boot.
"""

import argparse
import json
import re
from pathlib import Path


def validate(record, *, target, git_sha, version, build, boot_sequence, ota):
    if record.get("schema") != 1 or record.get("source") != "firmware" or record.get("category") != "boot" or record.get("event") != "acceptance":
        raise ValueError("not a firmware boot acceptance record")
    fields = record.get("fields", {})
    expected = {"schemaVersion": 1, "firmwareTarget": target,
                "firmwareProfile": target + "_PRODUCTION", "firmwareGitSha": git_sha,
                "firmwareVersion": version, "firmwareBuild": build, "bootSequence": boot_sequence, "ready": True}
    if any(type(fields.get(key)) is not type(value) or fields.get(key) != value
           for key, value in expected.items()):
        raise ValueError("boot identity/profile/readiness mismatch")
    # A USB-installed first image has no OTA state record; an OTA trial must
    # actually be VALID. Never qualify pending/invalid/aborted/unknown OTA boots.
    if fields.get("otaState") not in (("valid",) if ota else ("valid", "undefined", "untracked")):
        raise ValueError("boot is not confirmed")
    return fields


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate diagnostic field")
        result[key] = value
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--target", choices=("WAVESHARE_AMOLED_175", "WAVESHARE_AMOLED_206"), required=True)
    parser.add_argument("--git-sha", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", type=int, required=True)
    parser.add_argument("--boot-sequence", type=int, required=True)
    parser.add_argument("--ota", action="store_true", help="require a confirmed OTA trial, not a first USB boot")
    args = parser.parse_args()
    if re.fullmatch(r"[0-9a-f]{40}", args.git_sha) is None or args.build <= 0 or args.boot_sequence <= 0:
        raise ValueError("expected identity and boot must be explicit")
    matches = []
    with args.log.open("rb") as stream:
        while line := stream.readline(4097):
            if len(line) > 4096:
                raise ValueError("oversized diagnostic record")
            record = json.loads(line, object_pairs_hook=unique_object)
            if record.get("event") == "acceptance" and record.get("fields", {}).get("bootSequence") == args.boot_sequence:
                matches.append(validate(record, target=args.target, git_sha=args.git_sha,
                                        version=args.version, build=args.build, boot_sequence=args.boot_sequence, ota=args.ota))
    if len(matches) != 1:
        raise ValueError("require exactly one matching boot acceptance checkpoint")
    print(json.dumps(matches[0], sort_keys=True))


if __name__ == "__main__":
    main()
