#!/usr/bin/env python3
"""Stage the per-layout OTA manifest channels for GitHub Pages.

``<target>/manifest.json`` is the legacy dual-3-MiB channel; apps that predate
the dual-4-MiB layout read only this path. ``<target>/dual4m/manifest.json`` is
the current channel. Devices keep their installed partition table after OTA, so
a release whose image no longer fits a dual-3-MiB slot with its 64 KiB reserve
must not replace the legacy channel: it keeps serving exactly the manifest it
serves now, and unmigrated devices retain a compatible route instead of being
stranded behind one oversized manifest. That live manifest must equal an
immutable, digest-verified published release that fits, so a channel rolled
back with Pages recovery is never re-advanced to a withdrawn release.
Manifests are copied byte-for-byte; nothing here signs or edits a release.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
import time
import urllib.request

from firmware_release_history import MAX_MANIFEST_BYTES, TARGETS, published_manifests

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "esp32" / "tools"))
import partition_layouts  # noqa: E402

LAYOUTS = partition_layouts.load()
LEGACY = LAYOUTS.legacy("production")
CURRENT = LAYOUTS.current("production")
CURRENT_CHANNEL = CURRENT.id.split("-")[2]
PAGES_URL = "https://seichris.github.io/open-bike-computer/firmware"


def manifest_fields(data: bytes, target: str) -> dict:
    if not 0 < len(data) <= MAX_MANIFEST_BYTES:
        raise ValueError("OTA manifest size is invalid")
    manifest = json.loads(data)
    size, build = manifest.get("size"), manifest.get("build")
    if (manifest.get("target") != target or type(size) is not int or type(build) is not int
            or size <= 0 or build <= 0):
        raise ValueError(f"OTA manifest for {target} is invalid")
    return manifest


def fits(manifest: dict, layout: partition_layouts.Layout) -> bool:
    return manifest["size"] <= layout.max_application_bytes


def live_legacy_manifests(pages_url: str) -> dict[str, bytes]:
    """Read the legacy channel GitHub Pages serves now, bounded and over HTTPS."""
    live = {}
    for target in TARGETS:
        url = f"{pages_url}/{target}/manifest.json?revalidate={int(time.time())}"
        if not url.startswith("https://"):
            raise ValueError("the live OTA channel must be read over HTTPS")
        request = urllib.request.Request(url, headers={"Cache-Control": "no-cache"})
        with urllib.request.urlopen(request, timeout=30) as response:
            if not response.url.startswith("https://"):
                raise ValueError("the live OTA channel redirected off HTTPS")
            live[target] = response.read(MAX_MANIFEST_BYTES + 1)
    return live


def channel_manifests(release: dict[str, bytes], history: list[dict] | None,
                      *, maximum_build: int,
                      live_legacy: dict[str, bytes] | None = None) -> dict[str, dict[str, bytes]]:
    """Return {target: {"legacy": bytes, "current": bytes}} for one release."""
    staged = {}
    for target in TARGETS:
        data = release[target]
        manifest = manifest_fields(data, target)
        if manifest["build"] != maximum_build:
            raise ValueError("release manifests disagree on the build")
        if not fits(manifest, CURRENT):
            raise ValueError(f"{target} image exceeds the {CURRENT.id} slot reserve")
        legacy = data
        if not fits(manifest, LEGACY):
            if history is None or live_legacy is None or target not in live_legacy:
                raise ValueError("the live legacy channel and release history are required")
            live = live_legacy[target]
            published = [
                record for record in history
                if record["manifests"].get(target) == live and record["build"] <= maximum_build
            ]
            if not published or not fits(manifest_fields(live, target), LEGACY):
                raise ValueError(
                    f"the live {target} legacy channel is not a published release that fits "
                    f"{LEGACY.id}; recover it explicitly before publishing an oversized image")
            legacy = live
        staged[target] = {"legacy": legacy, "current": data}
    return staged


def write_channels(public_dir: Path, staged: dict[str, dict[str, bytes]]) -> list[Path]:
    written = []
    for target, channels in staged.items():
        for path, data in ((public_dir / target / "manifest.json", channels["legacy"]),
                           (public_dir / target / CURRENT_CHANNEL / "manifest.json", channels["current"])):
            if path.exists() or path.is_symlink():
                raise ValueError("OTA channel manifests are create-only")
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open("xb") as stream:
                stream.write(data)
            written.append(path)
    return written


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--release-assets", type=Path, required=True)
    parser.add_argument("--public-dir", type=Path, required=True)
    parser.add_argument("--pages-url", default=PAGES_URL)
    args = parser.parse_args()
    try:
        release = {target: (args.release_assets / f"{target}.manifest.json").read_bytes()
                   for target in TARGETS}
        builds = {manifest_fields(release[target], target)["build"] for target in TARGETS}
        if len(builds) != 1:
            raise ValueError("release target builds disagree")
        build = builds.pop()
        # Only an image that outgrew the legacy slot keeps the live legacy
        # channel, which must be an immutable published release.
        history = live = None
        if not all(fits(manifest_fields(release[target], target), LEGACY) for target in TARGETS):
            history = published_manifests(args.repository)
            live = live_legacy_manifests(args.pages_url)
        staged = channel_manifests(release, history, maximum_build=build, live_legacy=live)
        for path in write_channels(args.public_dir, staged):
            channel = json.loads(path.read_bytes())
            print(f"Staged {path.relative_to(args.public_dir)} build={channel['build']} size={channel['size']}")
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:  # URLError is an OSError
        print(f"OTA channel staging failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
