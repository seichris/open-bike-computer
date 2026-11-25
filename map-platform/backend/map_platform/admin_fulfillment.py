"""Operator views of fulfillment jobs, cached OSM extracts, and generated packs."""

from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request

from .jobs import MapJobService
from .limits import ACTIVE_STATUSES
from .models import JobStatus, MapJob, SourceRegion
from .source_cache import SourceCache
from .source_http import open_geofabrik_url, validate_geofabrik_url

# Version a preset ID when changing its coverage or renderer profile.
CITY_PRESETS = {
    "buenos-aires-v1": {
        "countryCode": "AR",
        "locations": ["Buenos Aires", "Ciudad de Buenos Aires", "Ciudad Autónoma de Buenos Aires", "CABA"],
        "request": {
            "mode": "custom_bbox",
            "displayName": "Buenos Aires",
            "bbox": [-58.68, -34.77, -58.27, -34.43],
            "target": {"renderer": "esp32-fmb", "rendererFormatVersion": 2},
            "labels": {
                "profileVersion": 1,
                "preferredLanguages": ["es"],
                "internationalFallback": "en",
            },
        },
    },
}


def _job_status(job: MapJob) -> dict:
    return {
        "jobId": job.job_id,
        "status": job.status.value,
        "mapId": job.map_id,
        "updatedAt": job.updated_at,
        "errorCode": (job.error_code or "map_build_failed") if job.status == JobStatus.FAILED else None,
    }


def _preset_job(jobs: list[MapJob], preset: dict) -> MapJob | None:
    # Public creation always binds an app installation. Matching unowned
    # requests also includes older CLI jobs without a persisted partition.
    matching = [
        job for job in jobs
        if job.client_installation_id is None and job.request == preset["request"]
    ]
    return max(matching, key=lambda job: (job.created_at, job.job_id), default=None)


def fulfillment_maps(jobs: list[MapJob]) -> dict:
    presets = []
    for preset_id, preset in CITY_PRESETS.items():
        job = _preset_job(jobs, preset)
        presets.append({
            "id": preset_id,
            "name": preset["request"]["displayName"],
            "countryCode": preset["countryCode"],
            "locations": preset["locations"],
            "bounds": preset["request"]["bbox"],
            "job": _job_status(job) if job else None,
        })
    return {"presets": presets}


def queue_fulfillment_map(service: MapJobService, preset_id: str) -> dict:
    preset = CITY_PRESETS[preset_id]
    with service.store.lock_job_creation():
        jobs, failures = service.store.list_with_failures()
        existing = _preset_job(jobs, preset)
        if existing and (existing.status in ACTIVE_STATUSES or existing.status == JobStatus.READY):
            return _job_status(existing)
        if failures:
            # An unreadable record could already contain the requested build.
            raise RuntimeError("map job records could not be read")
        job = service.create_job(dict(preset["request"]), admission_partition="operator")
        return _job_status(job)


def _http_date(value: str | None) -> datetime | None:
    try:
        if not value:
            return None
        parsed = parsedate_to_datetime(value)
        return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
    except (TypeError, ValueError, OverflowError):
        return None


def _safe_source_url(value: object) -> str | None:
    if isinstance(value, str):
        try:
            return validate_geofabrik_url(value)
        except ValueError:
            pass
    return None


def _upstream_version(source: dict) -> tuple[str, str | None]:
    url = source["sourceUrl"]
    if not url:
        return "unknown", None
    request = Request(url, method="HEAD")
    if source["etag"]:
        request.add_header("If-None-Match", source["etag"])
    if source["lastModified"]:
        request.add_header("If-Modified-Since", source["lastModified"])
    try:
        with open_geofabrik_url(request, timeout=4) as response:
            modified = response.headers.get("Last-Modified")
            etag = response.headers.get("ETag")
    except HTTPError as exc:
        with exc:
            if exc.code == 304:
                return "current", source["lastModified"]
        return "unavailable", None
    except (OSError, ValueError):
        return "unavailable", None

    cached_date = _http_date(source["lastModified"])
    upstream_date = _http_date(modified)
    if upstream_date and cached_date and upstream_date > cached_date:
        return "newer", modified
    if etag and source["etag"]:
        return ("current" if etag == source["etag"] else "changed"), modified
    if upstream_date and cached_date:
        return ("current" if upstream_date == cached_date else "changed"), modified
    return "unknown", modified


def _source_row(region_id: str, metadata: dict, region: SourceRegion | None) -> dict | None:
    if not isinstance(metadata, dict) or not isinstance(metadata.get("path"), str):
        return None
    try:
        path = Path(metadata["path"])
        if not path.is_file():
            return None
        size = path.stat().st_size
    except OSError:
        return None
    return {
        "id": region_id,
        "name": region.name if region else region_id.removeprefix("geofabrik-"),
        "sourceUrl": _safe_source_url(metadata.get("sourceUrl") or (region.url if region else None)),
        "bytes": size,
        "downloadedAt": metadata.get("downloadedAt") or metadata.get("cachedAt"),
        "validatedAt": metadata.get("validatedAt"),
        "sourcePublishedAt": metadata.get("sourcePublishedAt"),
        "lastModified": metadata.get("lastModified"),
        "etag": metadata.get("etag"),
        "updateStatus": "unchecked",
        "upstreamLastModified": None,
    }


def production_inventory(
    jobs: list[MapJob],
    cache: SourceCache,
    configured_regions: list[SourceRegion],
    *,
    check_upstream: bool = False,
) -> dict:
    regions = {region.id: region for region in configured_regions}
    regions.update({job.source_region.id: job.source_region for job in jobs})
    sources = [
        row
        for region_id, metadata in sorted(cache.metadata().get("sources", {}).items())
        if (row := _source_row(region_id, metadata, regions.get(region_id))) is not None
    ]
    if check_upstream and sources:
        with ThreadPoolExecutor(max_workers=6) as pool:
            for source, (status, modified) in zip(sources, pool.map(_upstream_version, sources)):
                source["updateStatus"] = status
                source["upstreamLastModified"] = modified
    for source in sources:
        del source["etag"]

    packs = {}
    for job in sorted(jobs, key=lambda job: job.finished_at or job.updated_at, reverse=True):
        if job.status != JobStatus.READY or not job.map_id or job.map_id in packs:
            continue
        packs[job.map_id] = {
            "mapId": job.map_id,
            "name": job.artifact_display_name,
            "sourceName": job.source_region.name,
            "bounds": job.geometry.bounds.to_list(),
            "readyAt": job.finished_at or job.updated_at,
            "bytes": job.pack_bytes,
            "formats": [artifact.format for artifact in job.artifacts],
        }
    return {"sources": sources, "packs": list(packs.values())}
