from __future__ import annotations

import hashlib
import json
import re
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .models import MapJob, utc_now_iso

ALLOWED_PACK_FILE_RE = re.compile(r"^VECTMAP/[A-Za-z0-9._-]+/[A-Za-z0-9+._-]+/[A-Za-z0-9+._-]+\.fm[bp]$")


@dataclass(frozen=True)
class PipelineMetadata:
    osmium_version: str = "unknown"
    osm_extract_revision: str = "unknown"
    config_revision: str = "unknown"
    image_digest: str = "unknown"


def stable_map_id(job: MapJob) -> str:
    display_name = str(job.request.get("displayName", "custom-map"))
    slug = re.sub(r"[^a-zA-Z0-9]+", "-", display_name).strip("-").lower() or "custom-map"
    source = json.dumps(
        {
            "mode": job.geometry.mode.value,
            "bounds": job.geometry.bounds.to_list(),
            "geometry": job.geometry.geometry,
            "routePointCount": job.geometry.route_point_count,
            "corridorWidthM": job.geometry.corridor_width_m,
            "sourceRegion": job.source_region.id,
        },
        sort_keys=True,
        separators=(",", ":"),
    )
    digest = hashlib.sha256(source.encode("utf-8")).hexdigest()[:10]
    return f"{slug}-{digest}"


def hash_file(path: Path) -> str:
    sha = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            sha.update(chunk)
    return sha.hexdigest()


def collect_map_files(map_root: Path, map_id: str) -> list[dict[str, Any]]:
    files: list[dict[str, Any]] = []
    vectmap_root = map_root / "VECTMAP" / map_id
    for path in sorted(vectmap_root.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(map_root).as_posix()
        if not is_pack_map_file(relative):
            continue
        validate_pack_path(relative)
        files.append({"path": relative, "bytes": path.stat().st_size, "sha256": hash_file(path)})
    if not files:
        raise ValueError("map pack contains no .fmb or .fmp files")
    return files


def is_pack_map_file(relative_path: str) -> bool:
    return bool(ALLOWED_PACK_FILE_RE.match(relative_path))


def validate_pack_path(relative_path: str) -> None:
    if ".." in Path(relative_path).parts or relative_path.startswith("/"):
        raise ValueError(f"unsafe map pack path: {relative_path}")
    if not is_pack_map_file(relative_path):
        raise ValueError(f"unexpected map pack file path: {relative_path}")


def build_manifest(job: MapJob, map_root: Path, pipeline: PipelineMetadata) -> dict[str, Any]:
    map_id = job.map_id or stable_map_id(job)
    files = collect_map_files(map_root, map_id)
    return {
        "schemaVersion": 1,
        "mapId": map_id,
        "displayName": str(job.request.get("displayName", map_id)),
        "geometryType": job.geometry.mode.value,
        "bounds": job.geometry.bounds.to_list(),
        "createdAt": utc_now_iso(),
        "target": {
            "renderer": "esp32-fmb",
            "formatVersion": 1,
            "minFirmwareVersion": str(job.request.get("target", {}).get("firmwareVersion", "0.0.0")),
        },
        "source": {
            "provider": job.source_region.provider,
            "region": job.source_region.id,
            "publishedAt": job.source_region.published_at,
            "license": job.source_region.license,
            "url": job.source_region.url,
            "checksum": job.source_region.checksum,
        },
        "pipeline": {
            "osmiumVersion": pipeline.osmium_version,
            "osmExtractRevision": pipeline.osm_extract_revision,
            "configRevision": pipeline.config_revision,
            "imageDigest": pipeline.image_digest,
        },
        "files": files,
    }


def write_pack_archive(map_root: Path, manifest: dict[str, Any], archive_path: Path) -> Path:
    archive_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path = map_root / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    attribution_path = map_root / "ATTRIBUTION.txt"
    attribution_path.write_text(
        "Map data from OpenStreetMap contributors. OpenStreetMap data is available under the ODbL.\n"
    )
    license_dir = map_root / "LICENSES"
    license_dir.mkdir(exist_ok=True)
    (license_dir / "OpenStreetMap-ODbL.txt").write_text(
        "OpenStreetMap data is licensed under the Open Data Commons Open Database License (ODbL).\n"
    )

    archived_paths = {
        "manifest.json",
        "ATTRIBUTION.txt",
        "LICENSES/OpenStreetMap-ODbL.txt",
        *(file["path"] for file in manifest["files"]),
    }
    with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_STORED) as archive:
        for relative in sorted(archived_paths):
            path = map_root / relative
            archive.write(path, relative)
    return archive_path
