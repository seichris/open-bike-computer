from __future__ import annotations

import hashlib
import json
import os
import shutil
import time
import urllib.request
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path

from .models import SourceRegion, utc_now_iso


class SourceCacheError(RuntimeError):
    """Raised when an OSM source PBF cannot be cached or verified."""


@dataclass(frozen=True)
class CachedSource:
    region_id: str
    path: Path
    bytes: int
    sha256: str
    cached_at: str


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
        self.data_root = Path(data_root) if data_root else self.repo_root / "backend" / "data"
        self.metadata_path = Path(metadata_path) if metadata_path else self.repo_root / "backend" / "data" / "source-cache.json"
        self.metadata_path.parent.mkdir(parents=True, exist_ok=True)
        self.lock_stale_seconds = lock_stale_seconds

    def ensure(self, region: SourceRegion, *, force: bool = False) -> CachedSource:
        target = self._target_path(region)
        target.parent.mkdir(parents=True, exist_ok=True)
        lock_path = target.with_suffix(target.suffix + ".lock")
        with self._lock(lock_path):
            if target.exists() and not force:
                cached = self._cached_source(region, target)
                try:
                    self._verify_expected_checksum(region, cached.sha256)
                except SourceCacheError:
                    target.unlink()
                else:
                    self._record(cached)
                    return cached

            if not region.url:
                raise SourceCacheError(f"source region {region.id} has no download URL")

            tmp_path = target.with_suffix(target.suffix + ".tmp")
            if tmp_path.exists():
                tmp_path.unlink()

            try:
                with urllib.request.urlopen(region.url, timeout=60) as response, tmp_path.open("wb") as output:
                    shutil.copyfileobj(response, output)
            except Exception as exc:
                tmp_path.unlink(missing_ok=True)
                raise SourceCacheError(f"failed to download source PBF for {region.id}: {exc}") from exc

            cached = self._cached_source(region, tmp_path)
            self._verify_expected_checksum(region, cached.sha256)
            tmp_path.replace(target)
            cached = self._cached_source(region, target)
            self._record(cached)
            return cached

    def refresh(self, regions: list[SourceRegion], *, force: bool = False) -> list[CachedSource]:
        return [self.ensure(region, force=force) for region in regions]

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
            if len(parts) >= 2 and parts[0] == "backend" and parts[1] == "data":
                path = self.data_root.joinpath(*parts[2:])
            else:
                path = self.repo_root / path
        return path

    def _cached_source(self, region: SourceRegion, path: Path) -> CachedSource:
        if not path.exists():
            raise SourceCacheError(f"cached source is missing: {path}")
        return CachedSource(
            region_id=region.id,
            path=path,
            bytes=path.stat().st_size,
            sha256=_hash_file(path),
            cached_at=utc_now_iso(),
        )

    def _record(self, cached: CachedSource) -> None:
        metadata = self.metadata()
        sources = dict(metadata.get("sources", {}))
        sources[cached.region_id] = {
            "path": str(cached.path),
            "bytes": cached.bytes,
            "sha256": cached.sha256,
            "cachedAt": cached.cached_at,
        }
        self.metadata_path.write_text(json.dumps({"sources": sources}, indent=2, sort_keys=True) + "\n")

    def _verify_expected_checksum(self, region: SourceRegion, actual_sha256: str) -> None:
        if region.checksum and region.checksum.lower() != actual_sha256.lower():
            raise SourceCacheError(
                f"checksum mismatch for {region.id}: expected {region.checksum}, got {actual_sha256}"
            )

    @contextmanager
    def _lock(self, lock_path: Path):
        deadline = time.monotonic() + 60
        fd: int | None = None
        while fd is None:
            try:
                fd = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                os.write(fd, str(os.getpid()).encode("utf-8"))
            except FileExistsError:
                _remove_stale_lock(lock_path, self.lock_stale_seconds)
                if time.monotonic() > deadline:
                    raise SourceCacheError(f"timed out waiting for source cache lock: {lock_path}")
                time.sleep(0.1)
        try:
            yield
        finally:
            if fd is not None:
                os.close(fd)
            lock_path.unlink(missing_ok=True)


def _hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _remove_stale_lock(lock_path: Path, stale_seconds: float) -> None:
    try:
        age_seconds = time.time() - lock_path.stat().st_mtime
    except FileNotFoundError:
        return
    if age_seconds > stale_seconds:
        lock_path.unlink(missing_ok=True)
