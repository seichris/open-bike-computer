#!/usr/bin/env python3
"""Gate publication/channel recovery against the complete published firmware history."""

import argparse
import hashlib
import json
import re
import subprocess
import urllib.request
from pathlib import Path

TARGETS = ("WAVESHARE_AMOLED_175", "WAVESHARE_AMOLED_206")
MAX_MANIFEST_BYTES = 2048


def build_number(value):
    if type(value) is not int or not 0 < value <= 0xFFFFFFFF:
        raise ValueError("firmware build must be a positive uint32")
    return value


def validate_build(candidate, published, *, recovery=False, allow_older=False):
    candidate = build_number(candidate)
    previous = max((build_number(value) for value in published), default=0)
    if (not recovery and candidate <= previous) or (recovery and candidate < previous and not allow_older):
        raise ValueError(f"build {candidate} does not advance published build {previous}")


def published_builds(repository):
    pages = json.loads(subprocess.check_output([
        "gh", "api", f"repos/{repository}/releases?per_page=100", "--paginate", "--slurp"
    ], timeout=120))
    builds = []
    for release in (release for page in pages for release in page):
        if release.get("draft"):
            continue
        assets = release.get("assets", [])
        manifests = {target: [asset for asset in assets if asset["name"] == f"{target}.manifest.json"]
                     for target in TARGETS}
        if not any(manifests.values()):
            continue  # Runtime and unrelated releases do not allocate firmware builds.
        pair = []
        for target in TARGETS:
            if len(manifests[target]) != 1:
                raise ValueError("published firmware release has an incomplete target pair")
            asset = manifests[target][0]
            url = asset["browser_download_url"]
            expected = f"https://github.com/{repository}/releases/download/{release['tag_name']}/{target}.manifest.json"
            if url != expected or not 0 < asset["size"] <= MAX_MANIFEST_BYTES:
                raise ValueError("published manifest asset identity/size is invalid")
            with urllib.request.urlopen(url, timeout=30) as response:
                if not response.url.startswith("https://"):
                    raise ValueError("published manifest transport is not HTTPS")
                data = response.read(MAX_MANIFEST_BYTES + 1)
            if len(data) != asset["size"] or asset.get("digest") != "sha256:" + hashlib.sha256(data).hexdigest():
                raise ValueError("published manifest does not match GitHub's asset digest")
            manifest = json.loads(data)
            if manifest.get("target") != target:
                raise ValueError("published manifest target mismatch")
            pair.append(build_number(manifest.get("build")))
        if pair[0] != pair[1]:
            raise ValueError("published target build numbers disagree")
        builds.append(pair[0])
    return builds


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    inputs = parser.add_mutually_exclusive_group(required=True)
    inputs.add_argument("--candidate", type=Path)
    inputs.add_argument("--recovery-assets", type=Path)
    parser.add_argument("--allow-older", action="store_true")
    args = parser.parse_args()
    if re.fullmatch(r"[\w.-]+/[\w.-]+", args.repository) is None:
        raise ValueError("invalid repository")
    if args.candidate:
        if args.allow_older:
            raise ValueError("older builds are only allowed for explicit Pages recovery")
        build = json.loads(args.candidate.read_text())["firmwareVersion"]["build"]
    else:
        pair = [json.loads((args.recovery_assets / f"{target}.manifest.json").read_text())
                for target in TARGETS]
        if any(value["target"] != target for target, value in zip(TARGETS, pair)) or pair[0]["build"] != pair[1]["build"]:
            raise ValueError("recovery target pair does not agree")
        build = pair[0]["build"]
    validate_build(build, published_builds(args.repository),
                   recovery=args.recovery_assets is not None, allow_older=args.allow_older)
    print(f"Firmware history accepted build={build} recovery={args.recovery_assets is not None} allowOlder={args.allow_older}")


if __name__ == "__main__":
    main()
