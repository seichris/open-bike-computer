"""Local, immutable one-degree OSM source shards for a pinned regional pilot.

Preparation scans the complete source once with a multi-extract config. A map
request reads only verified shards intersecting its source rectangles. The
building source index supplies relation closure beyond those rectangles.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from typing import Iterable

_SHA = re.compile(r"[0-9a-f]{64}")
_ALGORITHM = "osmium-smart-grid-v1"
MAX_GENERATION_CELLS = 256
MAX_GENERATION_BYTES = 32 * 1024 * 1024 * 1024
MAX_REQUEST_CELLS = 64
MAX_REQUEST_BYTES = 8 * 1024 * 1024 * 1024
MIN_FREE_BYTES = 16 * 1024 * 1024 * 1024


def _canonical(value: dict) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
                      allow_nan=False).encode("utf-8")


def _hash(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _identity(source_sha256: str, coverage: tuple[int, int, int, int]) -> dict:
    if not _SHA.fullmatch(source_sha256):
        raise ValueError("source shard snapshot SHA-256 is invalid")
    west, south, east, north = coverage
    if (any(type(value) is not int for value in coverage)
            or not -180 <= west < east <= 180
            or not -85 <= south < north <= 85
            or (east - west) * (north - south) > MAX_GENERATION_CELLS):
        raise ValueError("source shard coverage is invalid or too large")
    return {"schemaVersion": 1, "algorithm": _ALGORITHM,
            "sourceSnapshotSha256": source_sha256,
            "coverage": [west, south, east, north], "gridDegrees": 1}


def _root(cache_root: Path, source_sha256: str, coverage: tuple[int, int, int, int]) -> Path:
    identity = _identity(source_sha256, coverage)
    key = hashlib.sha256(_canonical(identity)).hexdigest()
    return cache_root / "source-shards-v1" / source_sha256 / key


def _name(lon: int, lat: int) -> str:
    return f"cell-{lon:+04d}-{lat:+03d}.osm.pbf"


def _read_manifest(path: Path, *, check_location: bool = True) -> dict:
    if path.is_symlink() or (check_location and path.parent.is_symlink()):
        raise ValueError("source shard manifest is a symlink")
    raw = path.read_bytes()
    manifest = json.loads(raw)
    if not isinstance(manifest, dict) or set(manifest) != {
        "schemaVersion", "algorithm", "sourceSnapshotSha256", "coverage",
        "gridDegrees", "shards", "manifestSha256",
    }:
        raise ValueError("source shard manifest fields are invalid")
    digest = manifest["manifestSha256"]
    body = {key: value for key, value in manifest.items() if key != "manifestSha256"}
    if (not isinstance(digest, str) or not _SHA.fullmatch(digest)
            or hashlib.sha256(_canonical(body)).hexdigest() != digest
            or _canonical(manifest) + b"\n" != raw):
        raise ValueError("source shard manifest identity is invalid")
    source_sha = manifest["sourceSnapshotSha256"]
    coverage = manifest["coverage"]
    if (not isinstance(coverage, list) or len(coverage) != 4
            or _identity(source_sha, tuple(coverage))
            != {key: body[key] for key in (
                "schemaVersion", "algorithm", "sourceSnapshotSha256", "coverage", "gridDegrees")}
            or (check_location and path.parent != _root(path.parents[3], source_sha, tuple(coverage)))):
        raise ValueError("source shard manifest location is invalid")
    shards = manifest["shards"]
    west, south, east, north = coverage
    expected = [(lon, lat) for lon in range(west, east) for lat in range(south, north)]
    if (not isinstance(shards, list) or len(shards) != len(expected)
            or [(entry.get("lon"), entry.get("lat")) for entry in shards
                if isinstance(entry, dict)] != expected):
        raise ValueError("source shard coverage is incomplete")
    for entry in shards:
        if (set(entry) != {"lon", "lat", "path", "bytes", "sha256"}
                or type(entry["lon"]) is not int or type(entry["lat"]) is not int
                or entry["path"] != _name(entry["lon"], entry["lat"])
                or type(entry["bytes"]) is not int or entry["bytes"] <= 0
                or not isinstance(entry["sha256"], str) or not _SHA.fullmatch(entry["sha256"])):
            raise ValueError("source shard entry is invalid")
    return manifest


def prepare_shards(source_pbf: Path, source_sha256: str, cache_root: Path,
                   coverage: tuple[int, int, int, int]) -> Path:
    """Publish one complete regional generation after every shard is sealed."""
    target = _root(cache_root, source_sha256, coverage)
    target.parent.mkdir(parents=True, exist_ok=True)
    with (target.parent / ".prepare.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if target.exists():
            manifest = _read_manifest(target / "manifest.json")
            if any(_hash(target / entry["path"]) != entry["sha256"] for entry in manifest["shards"]):
                raise ValueError("existing source shard generation is corrupt")
            return target / "manifest.json"
        if _hash(source_pbf) != source_sha256:
            raise ValueError("source PBF differs from the pinned snapshot")
        if shutil.disk_usage(target.parent).free < source_pbf.stat().st_size * 4 + MIN_FREE_BYTES:
            raise ValueError("insufficient local space for source shard preparation")
        west, south, east, north = coverage
        with tempfile.TemporaryDirectory(prefix=".shards-", dir=target.parent) as temporary:
            staged = Path(temporary) / "generation"
            staged.mkdir()
            cells = [(lon, lat) for lon in range(west, east) for lat in range(south, north)]
            config = {"directory": str(staged), "extracts": [
                {"output": _name(lon, lat), "output_format": "pbf",
                 "bbox": [lon, lat, lon + 1, lat + 1]}
                for lon, lat in cells
            ]}
            config_path = Path(temporary) / "extract.json"
            config_path.write_bytes(_canonical(config) + b"\n")
            subprocess.run(["osmium", "extract", "--strategy=smart",
                            "--option=types=multipolygon,building", "--config", str(config_path),
                            str(source_pbf), "--overwrite"], check=True)
            if _hash(source_pbf) != source_sha256:
                raise ValueError("source PBF changed during shard preparation")
            shards = []
            total_bytes = 0
            for lon, lat in cells:
                path = staged / _name(lon, lat)
                if not path.is_file() or path.is_symlink() or path.stat().st_size <= 0:
                    raise ValueError("source shard was not produced")
                total_bytes += path.stat().st_size
                if total_bytes > MAX_GENERATION_BYTES:
                    raise ValueError("regional source shard generation exceeds its byte limit")
                with path.open("rb") as stream:
                    os.fsync(stream.fileno())
                shards.append({"lon": lon, "lat": lat, "path": path.name,
                               "bytes": path.stat().st_size, "sha256": _hash(path)})
            body = {**_identity(source_sha256, coverage), "shards": shards}
            manifest = {**body, "manifestSha256": hashlib.sha256(_canonical(body)).hexdigest()}
            manifest_path = staged / "manifest.json"
            manifest_path.write_bytes(_canonical(manifest) + b"\n")
            with manifest_path.open("rb") as stream:
                os.fsync(stream.fileno())
            _read_manifest(manifest_path, check_location=False)
            directory = os.open(staged, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
            os.replace(staged, target)
            directory = os.open(target.parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        return target / "manifest.json"


def select_shards(cache_root: Path, source_sha256: str,
                  rectangles: Iterable[tuple[float, float, float, float]]) -> tuple[Path, ...]:
    if not _SHA.fullmatch(source_sha256):
        raise ValueError("source shard snapshot SHA-256 is invalid")
    requested = tuple(rectangles)
    if not requested or any(
        len(rectangle) != 4 or any(not math.isfinite(value) for value in rectangle)
        or rectangle[0] > rectangle[2] or rectangle[1] > rectangle[3]
        for rectangle in requested
    ):
        raise ValueError("source shard request bounds are invalid")
    root = cache_root / "source-shards-v1" / source_sha256
    for path in sorted(root.glob("*/manifest.json")):
        manifest = _read_manifest(path)
        west, south, east, north = manifest["coverage"]
        if any(rect[0] < west or rect[1] < south or rect[2] > east or rect[3] > north
               for rect in requested):
            continue
        selected = [entry for entry in manifest["shards"] if any(
            entry["lon"] <= rect[2] and entry["lon"] + 1 >= rect[0]
            and entry["lat"] <= rect[3] and entry["lat"] + 1 >= rect[1]
            for rect in requested
        )]
        if not selected or len(selected) > MAX_REQUEST_CELLS:
            raise ValueError("source shard request exceeds its cell limit")
        if sum(entry["bytes"] for entry in selected) > MAX_REQUEST_BYTES:
            raise ValueError("source shard request exceeds its byte limit")
        if shutil.disk_usage(root).free < sum(entry["bytes"] for entry in selected) + MIN_FREE_BYTES:
            raise ValueError("insufficient space to assemble source shards")
        paths = []
        for entry in selected:
            shard = path.parent / entry["path"]
            if (shard.is_symlink() or not shard.is_file()
                    or shard.stat().st_size != entry["bytes"]
                    or _hash(shard) != entry["sha256"]):
                raise ValueError("source shard differs from its sealed manifest")
            paths.append(shard)
        return tuple(paths)
    raise ValueError("no ready source shard generation covers this map")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-pbf", required=True, type=Path)
    parser.add_argument("--source-sha256", required=True)
    parser.add_argument("--cache-root", required=True, type=Path)
    for name in ("west", "south", "east", "north"):
        parser.add_argument(f"--{name}", required=True, type=int)
    args = parser.parse_args()
    manifest = prepare_shards(args.source_pbf, args.source_sha256, args.cache_root,
                              (args.west, args.south, args.east, args.north))
    print(json.dumps({"manifest": str(manifest)}, sort_keys=True, separators=(",", ":")))


if __name__ == "__main__":
    main()
