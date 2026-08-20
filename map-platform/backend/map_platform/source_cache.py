from __future__ import annotations

import hashlib
import json
import os
import fcntl
import shutil
import time
import urllib.request
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path

from .models import SourceRegion, utc_now_iso


class SourceCacheError(RuntimeError):
    """Raised when an OSM source PBF cannot be cached or verified."""


class SourceCacheCancelled(SourceCacheError):
    """Raised when an in-flight source cache operation is cancelled."""


class SourceCacheStorageError(SourceCacheError):
    """Raised before a source download would violate the disk reserve."""


@dataclass(frozen=True)
class CachedSource:
    region_id: str
    path: Path
    bytes: int
    sha256: str
    cached_at: str


def default_backend_data_root(repo_root: str | Path) -> Path:
    root = Path(repo_root)
    relocated = root / "map-platform" / "backend" / "data"
    legacy = root / "backend" / "data"
    metadata_entries = {".gitkeep", ".DS_Store"}

    def has_runtime_state(path: Path) -> bool:
        try:
            return any(child.name not in metadata_entries for child in path.iterdir())
        except FileNotFoundError:
            return False

    legacy_has_state = has_runtime_state(legacy)
    relocated_has_state = has_runtime_state(relocated)
    if legacy_has_state and relocated_has_state:
        raise RuntimeError(
            "both backend/data and map-platform/backend/data contain local "
            "runtime state; set MAP_PLATFORM_DATA_ROOT explicitly"
        )
    if legacy_has_state:
        return legacy
    return relocated


class SourceCache:
    def __init__(
        self,
        repo_root: str | Path,
        metadata_path: str | Path | None = None,
        data_root: str | Path | None = None,
        *,
        lock_stale_seconds: float = 3600.0,
    ):
        self.repo_root = Path(repo_root)
        self.data_root = (
            Path(data_root)
            if data_root
            else default_backend_data_root(self.repo_root)
        )
        self.metadata_path = (
            Path(metadata_path)
            if metadata_path
            else self.data_root / "source-cache.json"
        )
        self.metadata_path.parent.mkdir(parents=True, exist_ok=True)
        self.lock_stale_seconds = lock_stale_seconds

    def ensure(
        self,
        region: SourceRegion,
        *,
        force: bool = False,
        cancellation_check=None,
        minimum_free_bytes: int | None = None,
    ) -> CachedSource:
        if minimum_free_bytes is not None and (
            isinstance(minimum_free_bytes, bool)
            or not isinstance(minimum_free_bytes, int)
            or minimum_free_bytes <= 0
        ):
            raise SourceCacheStorageError(
                "source cache minimum free bytes must be positive"
            )
        target = self._target_path(region)
        target.parent.mkdir(parents=True, exist_ok=True)
        lock_path = target.with_suffix(target.suffix + ".lock")
        if target.exists() and not force:
            with self._lock(
                lock_path,
                cancellation_check=cancellation_check,
                exclusive=False,
            ):
                try:
                    cached = self._cached_source(
                        region,
                        target,
                        cancellation_check=cancellation_check,
                    )
                    self._verify_expected_checksum(region, cached.sha256)
                except SourceCacheCancelled:
                    raise
                except SourceCacheError:
                    pass
                else:
                    self._record(cached, cancellation_check=cancellation_check)
                    return cached
        with self._lock(
            lock_path,
            cancellation_check=cancellation_check,
            exclusive=True,
        ):
            if target.exists() and not force:
                cached = self._cached_source(
                    region,
                    target,
                    cancellation_check=cancellation_check,
                )
                try:
                    self._verify_expected_checksum(region, cached.sha256)
                except SourceCacheCancelled:
                    raise
                except SourceCacheError:
                    target.unlink()
                else:
                    self._record(cached, cancellation_check=cancellation_check)
                    return cached

            if not region.url:
                raise SourceCacheError(f"source region {region.id} has no download URL")

            tmp_path = target.with_suffix(target.suffix + ".tmp")
            if tmp_path.exists():
                tmp_path.unlink()

            # Per-source locks do not serialize different regions. Hold one
            # data-volume lock from admission through atomic publication so
            # concurrent cold downloads cannot each spend the same free bytes.
            # Calls without a configured reserve participate as well; otherwise
            # a legacy download could race a resource-admitted chunked build.
            storage_lock_path = self.data_root / ".source-cache-storage.lock"
            with self._lock(
                storage_lock_path,
                cancellation_check=cancellation_check,
                exclusive=True,
            ):
                self._require_download_capacity(
                    target.parent,
                    minimum_free_bytes=minimum_free_bytes,
                )

                try:
                    with urllib.request.urlopen(
                        region.url, timeout=60
                    ) as response, tmp_path.open("wb") as output:
                        headers = getattr(response, "headers", None)
                        content_length = (
                            headers.get("Content-Length")
                            if headers is not None
                            else None
                        )
                        if content_length is not None:
                            try:
                                incoming_bytes = int(content_length)
                            except ValueError as exc:
                                raise SourceCacheStorageError(
                                    "source response Content-Length is invalid"
                                ) from exc
                            if incoming_bytes < 0:
                                raise SourceCacheStorageError(
                                    "source response Content-Length is invalid"
                                )
                            self._require_download_capacity(
                                target.parent,
                                minimum_free_bytes=minimum_free_bytes,
                                incoming_bytes=incoming_bytes,
                            )
                        while True:
                            _raise_if_cancelled(cancellation_check)
                            chunk = response.read(1024 * 1024)
                            if not chunk:
                                break
                            self._require_download_capacity(
                                target.parent,
                                minimum_free_bytes=minimum_free_bytes,
                                incoming_bytes=len(chunk),
                            )
                            output.write(chunk)
                        _raise_if_cancelled(cancellation_check)
                except Exception as exc:
                    tmp_path.unlink(missing_ok=True)
                    if isinstance(exc, SourceCacheError):
                        raise
                    raise SourceCacheError(
                        f"failed to download source PBF for {region.id}: {exc}"
                    ) from exc

                cached = self._cached_source(
                    region,
                    tmp_path,
                    cancellation_check=cancellation_check,
                )
                self._verify_expected_checksum(region, cached.sha256)
                tmp_path.replace(target)
            cached = self._cached_source(
                region,
                target,
                cancellation_check=cancellation_check,
            )
            self._record(cached, cancellation_check=cancellation_check)
            return cached

    @staticmethod
    def _require_download_capacity(
        directory: Path,
        *,
        minimum_free_bytes: int | None,
        incoming_bytes: int = 0,
    ) -> None:
        if minimum_free_bytes is None:
            return
        try:
            free_bytes = shutil.disk_usage(directory).free
        except OSError as exc:
            raise SourceCacheStorageError(
                "source cache free space could not be measured"
            ) from exc
        required = minimum_free_bytes + incoming_bytes
        if free_bytes < required:
            raise SourceCacheStorageError(
                "source cache storage admission failed: "
                f"{free_bytes} free bytes is below {required} required bytes"
            )

    def refresh(self, regions: list[SourceRegion], *, force: bool = False) -> list[CachedSource]:
        return [self.ensure(region, force=force) for region in regions]

    @contextmanager
    def verified_lease(self, region: SourceRegion, *, cancellation_check=None):
        """Hold the source replacement lock while a resolved snapshot is used."""
        target = self._target_path(region)
        lock_path = target.with_suffix(target.suffix + ".lock")
        with self._lock(
            lock_path,
            cancellation_check=cancellation_check,
            exclusive=False,
        ):
            cached = self._cached_source(
                region,
                target,
                cancellation_check=cancellation_check,
            )
            self._verify_expected_checksum(region, cached.sha256)
            yield cached

    def metadata(self) -> dict[str, object]:
        if not self.metadata_path.exists():
            return {"sources": {}}
        return json.loads(self.metadata_path.read_text())

    def _target_path(self, region: SourceRegion) -> Path:
        if not region.local_path:
            raise SourceCacheError(f"source region {region.id} has no localPath")
        path = Path(region.local_path)
        if not path.is_absolute():
            parts = path.parts
            data_prefixes = (
                ("map-platform", "backend", "data"),
                ("backend", "data"),
            )
            matching_prefix = next(
                (
                    prefix
                    for prefix in data_prefixes
                    if parts[: len(prefix)] == prefix
                ),
                None,
            )
            if matching_prefix is not None:
                path = self.data_root.joinpath(*parts[len(matching_prefix) :])
            else:
                path = self.repo_root / path
        return path

    def _cached_source(
        self,
        region: SourceRegion,
        path: Path,
        *,
        cancellation_check=None,
    ) -> CachedSource:
        if not path.exists():
            raise SourceCacheError(f"cached source is missing: {path}")
        return CachedSource(
            region_id=region.id,
            path=path,
            bytes=path.stat().st_size,
            sha256=_hash_file(path, cancellation_check=cancellation_check),
            cached_at=utc_now_iso(),
        )

    def _record(self, cached: CachedSource, *, cancellation_check=None) -> None:
        metadata_lock = self.metadata_path.with_suffix(
            self.metadata_path.suffix + ".lock"
        )
        with self._lock(
            metadata_lock,
            cancellation_check=cancellation_check,
            exclusive=True,
        ):
            metadata = self.metadata()
            sources = dict(metadata.get("sources", {}))
            sources[cached.region_id] = {
                "path": str(cached.path),
                "bytes": cached.bytes,
                "sha256": cached.sha256,
                "cachedAt": cached.cached_at,
            }
            self.metadata_path.write_text(
                json.dumps({"sources": sources}, indent=2, sort_keys=True) + "\n"
            )

    def _verify_expected_checksum(self, region: SourceRegion, actual_sha256: str) -> None:
        if region.checksum and region.checksum.lower() != actual_sha256.lower():
            raise SourceCacheError(
                f"checksum mismatch for {region.id}: expected {region.checksum}, got {actual_sha256}"
            )

    @contextmanager
    def _lock(
        self,
        lock_path: Path,
        *,
        cancellation_check=None,
        exclusive: bool = True,
        timeout_seconds: float | None = None,
    ):
        deadline = (
            time.monotonic() + timeout_seconds
            if timeout_seconds is not None
            else None
        )
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        acquired = False
        while not acquired:
            if cancellation_check is not None and cancellation_check():
                os.close(fd)
                raise SourceCacheCancelled("source cache wait was cancelled")
            try:
                mode = fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH
                fcntl.flock(fd, mode | fcntl.LOCK_NB)
                acquired = True
            except BlockingIOError:
                if deadline is not None and time.monotonic() > deadline:
                    os.close(fd)
                    raise SourceCacheError(f"timed out waiting for source cache lock: {lock_path}")
                time.sleep(0.1)
        try:
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)


def _raise_if_cancelled(cancellation_check) -> None:
    if cancellation_check is not None and cancellation_check():
        raise SourceCacheCancelled("source cache operation was cancelled")


def _hash_file(path: Path, *, cancellation_check=None) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        while True:
            _raise_if_cancelled(cancellation_check)
            chunk = file.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    _raise_if_cancelled(cancellation_check)
    return digest.hexdigest()
