"""Operator views of fulfillment jobs, cached OSM extracts, and generated packs."""

from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
import logging
from pathlib import Path
from threading import Lock
from urllib.error import HTTPError
from urllib.request import Request

from .artifacts import ZIP_STORED_FORMAT
from .building_storage_admission import DEFAULT_BUILDING_STORAGE_RESERVE_BYTES
from .jobs import MapJobService
from .limits import ACTIVE_STATUSES
from .models import Bounds, JobStatus, MapJob, SourceRegion
from .source_cache import SourceCache, SourceCacheError, source_file_revision
from .source_http import open_geofabrik_url, validate_geofabrik_url

logger = logging.getLogger(__name__)

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


def _source_cache_path(cache: SourceCache, metadata: dict) -> Path | None:
    if not isinstance(metadata, dict) or not isinstance(metadata.get("path"), str):
        return None
    path = Path(metadata["path"])
    if not path.name.endswith(".osm.pbf") or not source_file_revision(path):
        return None
    try:
        source_root = cache.data_root.resolve() / "source-pbf"
        resolved = path.resolve()
    except (OSError, RuntimeError):
        return None
    return path if resolved.is_relative_to(source_root) else None


class SourceOperationConflict(RuntimeError):
    pass


class SourceOperations:
    def __init__(self, service: MapJobService, cache: SourceCache):
        self.service = service
        self.cache = cache
        self.lock = Lock()
        self.active: str | None = None
        self.failed: dict[str, str] = {}

    def status(self, source_id: str, revision: str | None) -> str | None:
        with self.lock:
            if self.active == source_id:
                return "updating"
            return "failed" if revision and self.failed.get(source_id) == revision else None

    def _source(self, source_id: str, revision: str):
        jobs, failures = self.service.store.list_with_failures()
        if failures:
            raise SourceOperationConflict("Map jobs could not be checked. Try again.")
        if any(job.source_region.id == source_id and job.status in ACTIVE_STATUSES for job in jobs):
            raise SourceOperationConflict("This extract is in use by a map build. Try again after it finishes.")
        metadata = self.cache.metadata().get("sources", {}).get(source_id, {})
        path = _source_cache_path(self.cache, metadata)
        if path is None or revision != source_file_revision(path):
            raise SourceOperationConflict("The cached extract changed. Reload and try again.")
        regions = {region.id: region for region in self.service.source_index.regions}
        regions.update({job.source_region.id: job.source_region for job in jobs})
        region = regions.get(source_id)
        return path, _source_row(source_id, metadata, region), region

    def begin_update(self, source_id: str, revision: str) -> SourceRegion:
        path, source, region = self._source(source_id, revision)
        if source is None or _upstream_version(source)[0] != "newer":
            raise SourceOperationConflict("A newer extract could not be confirmed. Reload and try again.")
        if region is None:
            region = SourceRegion(
                id=source_id, provider="geofabrik", name=source["name"],
                url=source["sourceUrl"], bounds=Bounds(-180, -90, 180, 90),
            )
        with self.lock:
            if self.active is not None:
                raise SourceOperationConflict("An extract is already updating. Try again when it finishes.")
            if revision != source_file_revision(path):
                raise SourceOperationConflict("The cached extract changed. Reload and try again.")
            self.active = source_id
            self.failed.pop(source_id, None)
        return replace(region, url=source["sourceUrl"], local_path=str(path))

    def refresh(self, region: SourceRegion, revision: str) -> None:
        try:
            self.cache.ensure(
                region, force=True,
                minimum_free_bytes=DEFAULT_BUILDING_STORAGE_RESERVE_BYTES,
            )
        except (SourceCacheError, OSError, ValueError):
            logger.warning("Operator source update failed for %s", region.id, exc_info=True)
            with self.lock:
                self.failed[region.id] = revision
        finally:
            with self.lock:
                self.active = None

    def delete(self, source_id: str, revision: str) -> None:
        _, source, _ = self._source(source_id, revision)
        if source is None or _upstream_version(source)[0] not in {"newer", "unknown"}:
            raise SourceOperationConflict("This extract's update status no longer permits deletion.")
        with self.service.store.lock_job_creation(), self.lock:
            if self.active == source_id:
                raise SourceOperationConflict("Wait for this extract to finish updating.")
            path, _, _ = self._source(source_id, revision)
            if not self.cache.delete_cached_file(path, revision=revision):
                raise SourceOperationConflict("The cached extract changed. Reload and try again.")
            self.failed.pop(source_id, None)


def operator_zip(job: MapJob):
    if job.client_installation_id is not None or job.status != JobStatus.READY or not job.map_id:
        return None
    return next((artifact for artifact in job.artifacts if artifact.format == ZIP_STORED_FORMAT), None)


def production_inventory(
    jobs: list[MapJob],
    cache: SourceCache,
    configured_regions: list[SourceRegion],
    *,
    check_upstream: bool = False,
    source_operations: SourceOperations | None = None,
) -> dict:
    regions = {region.id: region for region in configured_regions}
    regions.update({job.source_region.id: job.source_region for job in jobs})
    sources = []
    for region_id, metadata in sorted(cache.metadata().get("sources", {}).items()):
        row = _source_row(region_id, metadata, regions.get(region_id))
        if row is None:
            continue
        path = _source_cache_path(cache, metadata)
        row["revision"] = source_file_revision(path) if path is not None else None
        row["operationStatus"] = (
            source_operations.status(region_id, row["revision"]) if source_operations else None
        )
        sources.append(row)
    if check_upstream and sources:
        with ThreadPoolExecutor(max_workers=6) as pool:
            for source, (status, modified) in zip(sources, pool.map(_upstream_version, sources)):
                source["updateStatus"] = status
                source["upstreamLastModified"] = modified
    for source in sources:
        del source["etag"]

    packs = {}
    for job in sorted(jobs, key=lambda job: job.finished_at or job.updated_at, reverse=True):
        if job.status != JobStatus.READY or not job.map_id:
            continue
        downloadable = operator_zip(job) is not None
        if job.map_id in packs and (packs[job.map_id]["zipJobId"] or not downloadable):
            continue
        packs[job.map_id] = {
            "mapId": job.map_id,
            "zipJobId": job.job_id if downloadable else None,
            "name": job.artifact_display_name,
            "sourceName": job.source_region.name,
            "bounds": job.geometry.bounds.to_list(),
            "readyAt": job.finished_at or job.updated_at,
            "bytes": job.pack_bytes,
            "formats": [artifact.format for artifact in job.artifacts],
        }
    return {"sources": sources, "packs": list(packs.values())}
