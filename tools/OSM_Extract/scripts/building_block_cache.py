"""Content-addressed cache for canonical FMB building block sections."""

from __future__ import annotations

from dataclasses import dataclass
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import time
from typing import Any, Callable, Mapping
import shapely

from building_calibration_cache import canonical_json


BUILDING_BLOCK_CACHE_SCHEMA_VERSION = 1
BUILDING_BLOCK_SIZE_METERS = 4096
BUILDING_BLOCK_CACHE_DIRECTORY = (
    f"building-block-v{BUILDING_BLOCK_CACHE_SCHEMA_VERSION}"
)
_SHA256_RE = re.compile(r"[0-9a-f]{64}")
_BLOCK_STATS_KEYS = {
    "recordCount",
    "pointCount",
    "emittedWallCount",
    "suppressedWallCount",
    "droppedHoleCount",
    "explicitHeightCount",
    "levelsHeightCount",
    "inheritedHeightCount",
    "localMedianHeightCount",
    "classDefaultHeightCount",
    "sectionBytes",
}


class BuildingBlockCacheError(RuntimeError):
    pass


@dataclass(frozen=True)
class BuildingBlockCacheEntry:
    section: bytes
    stats: dict[str, int]
    outcome: str
    lock_wait_seconds: float = 0.0


def load_building_block_cache_identity(path: str | Path) -> dict[str, Any]:
    try:
        value = json.loads(Path(path).read_bytes())
    except (OSError, TypeError, ValueError) as exc:
        raise BuildingBlockCacheError("building block cache identity is unavailable") from exc
    if not isinstance(value, dict):
        raise BuildingBlockCacheError("building block cache identity is invalid")
    identity_sha256 = value.get("cacheIdentitySha256")
    body = {key: item for key, item in value.items() if key != "cacheIdentitySha256"}
    hashes = (
        body.get("sourceSnapshotSha256"),
        body.get("rulesSha256"),
        body.get("calibration", {}).get("calibrationKey")
        if isinstance(body.get("calibration"), dict)
        else None,
        body.get("calibration", {}).get("manifestSha256")
        if isinstance(body.get("calibration"), dict)
        else None,
        body.get("calibration", {}).get("entrySetSha256")
        if isinstance(body.get("calibration"), dict)
        else None,
    )
    if (
        not _SHA256_RE.fullmatch(str(identity_sha256 or ""))
        or hashlib.sha256(canonical_json(body)).hexdigest() != identity_sha256
        or body.get("schemaVersion") != BUILDING_BLOCK_CACHE_SCHEMA_VERSION
        or body.get("blockSizeMeters") != BUILDING_BLOCK_SIZE_METERS
        or body.get("blockGridVersion") != 1
        or body.get("rendererFormatVersion") != 3
        or body.get("fmbVersion") != 4
        or body.get("buildingProfileVersion") != 1
        or body.get("selectionSemantics")
        != "complete_blocks_no_selection_edge_clipping"
        or not _positive_int(body.get("geometryBufferMeters"))
        or not _positive_int(body.get("relationRetryBufferMeters"))
        or not _positive_int(body.get("maxGeometryBufferMeters"))
        or not (
            body["geometryBufferMeters"]
            <= body["relationRetryBufferMeters"]
            <= body["maxGeometryBufferMeters"]
        )
        or any(not _SHA256_RE.fullmatch(str(item or "")) for item in hashes)
        or not _positive_int(body.get("normalizationAlgorithmVersion"))
        or not _positive_int(body.get("blockEncodingAlgorithmVersion"))
        or body.get("geometryEngine")
        != {"name": "shapely", "version": "2.0.7"}
        or shapely.__version__ != body["geometryEngine"]["version"]
        or not _positive_int(body.get("closureAlgorithmVersion"))
        or not _version_document(body.get("sourceIndex"))
        or not _version_document(body.get("calibration"))
    ):
        raise BuildingBlockCacheError("building block cache identity is invalid")
    return value


class BuildingBlockCache:
    def __init__(self, root: str | Path, identity: Mapping[str, Any]):
        self.root = Path(root)
        self.identity = dict(identity)
        self._access_recorded = False
        identity_sha256 = self.identity.get("cacheIdentitySha256")
        if not _SHA256_RE.fullmatch(str(identity_sha256 or "")):
            raise BuildingBlockCacheError("building block cache identity is invalid")
        self.namespace = (
            self.root
            / BUILDING_BLOCK_CACHE_DIRECTORY
            / self.identity["sourceSnapshotSha256"]
            / self.identity["rulesSha256"]
            / identity_sha256
        )
        try:
            self.namespace.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            raise BuildingBlockCacheError(
                "building block cache namespace is unavailable"
            ) from exc

    def load(self, min_x: int, min_y: int) -> BuildingBlockCacheEntry | None:
        with self._namespace_lease():
            result = self._load_unleased(min_x, min_y)
            self._touch_access_marker()
            return result

    def _load_unleased(
        self,
        min_x: int,
        min_y: int,
    ) -> BuildingBlockCacheEntry | None:
        block_x, block_y = self._block_coordinates(min_x, min_y)
        manifest_path = self._manifest_path(block_x, block_y)
        try:
            manifest = json.loads(manifest_path.read_bytes())
            section = self._validate_manifest(manifest, block_x, block_y)
        except (OSError, TypeError, ValueError, BuildingBlockCacheError):
            return None
        return BuildingBlockCacheEntry(
            section=section,
            stats=dict(manifest["stats"]),
            outcome="hit",
        )

    def materialize(
        self,
        min_x: int,
        min_y: int,
        builder: Callable[[], tuple[bytes, Mapping[str, int]]],
    ) -> BuildingBlockCacheEntry:
        with self._namespace_lease():
            block_x, block_y = self._block_coordinates(min_x, min_y)
            lock_path = self.namespace / "locks" / f"{block_x}_{block_y}.lock"
            lock_path.parent.mkdir(parents=True, exist_ok=True)
            started = time.perf_counter()
            with lock_path.open("a+b") as lock_file:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
                wait_seconds = time.perf_counter() - started
                existing = self._load_unleased(min_x, min_y)
                if existing is not None:
                    self._touch_access_marker()
                    return BuildingBlockCacheEntry(
                        section=existing.section,
                        stats=existing.stats,
                        outcome="race_hit",
                        lock_wait_seconds=wait_seconds,
                    )
                section, raw_stats = builder()
                if not isinstance(section, bytes) or not section:
                    raise BuildingBlockCacheError("building block section is invalid")
                stats = self._validate_stats(raw_stats, len(section))
                section_sha256 = hashlib.sha256(section).hexdigest()
                relative_section_path = f"sections/{section_sha256}.bin"
                section_path = self.namespace / relative_section_path
                if not self._valid_section_file(section_path, section_sha256, len(section)):
                    self._atomic_write(section_path, section)
                body = {
                    "schemaVersion": BUILDING_BLOCK_CACHE_SCHEMA_VERSION,
                    "cacheIdentitySha256": self.identity["cacheIdentitySha256"],
                    "block": {
                        "x": block_x,
                        "y": block_y,
                        "boundsMeters": [
                            min_x,
                            min_y,
                            min_x + BUILDING_BLOCK_SIZE_METERS,
                            min_y + BUILDING_BLOCK_SIZE_METERS,
                        ],
                    },
                    "section": {
                        "path": relative_section_path,
                        "bytes": len(section),
                        "sha256": section_sha256,
                    },
                    "stats": stats,
                }
                manifest = {
                    **body,
                    "manifestSha256": hashlib.sha256(canonical_json(body)).hexdigest(),
                }
                self._atomic_write(
                    self._manifest_path(block_x, block_y),
                    canonical_json(manifest) + b"\n",
                )
                published = self._load_unleased(min_x, min_y)
                if published is None:
                    raise BuildingBlockCacheError("building block cache publication failed")
                self._touch_access_marker()
                return BuildingBlockCacheEntry(
                    section=published.section,
                    stats=published.stats,
                    outcome="built",
                    lock_wait_seconds=wait_seconds,
                )

    def _validate_manifest(
        self,
        manifest: Any,
        block_x: int,
        block_y: int,
    ) -> bytes:
        if not isinstance(manifest, dict):
            raise BuildingBlockCacheError("building block manifest is invalid")
        expected_keys = {
            "schemaVersion",
            "cacheIdentitySha256",
            "block",
            "section",
            "stats",
            "manifestSha256",
        }
        body = {
            key: value for key, value in manifest.items() if key != "manifestSha256"
        }
        block = manifest.get("block")
        section = manifest.get("section")
        min_x = block_x * BUILDING_BLOCK_SIZE_METERS
        min_y = block_y * BUILDING_BLOCK_SIZE_METERS
        if (
            set(manifest) != expected_keys
            or manifest.get("schemaVersion") != BUILDING_BLOCK_CACHE_SCHEMA_VERSION
            or manifest.get("cacheIdentitySha256")
            != self.identity["cacheIdentitySha256"]
            or not _SHA256_RE.fullmatch(str(manifest.get("manifestSha256") or ""))
            or hashlib.sha256(canonical_json(body)).hexdigest()
            != manifest["manifestSha256"]
            or not isinstance(block, dict)
            or set(block) != {"x", "y", "boundsMeters"}
            or block.get("x") != block_x
            or block.get("y") != block_y
            or block.get("boundsMeters")
            != [
                min_x,
                min_y,
                min_x + BUILDING_BLOCK_SIZE_METERS,
                min_y + BUILDING_BLOCK_SIZE_METERS,
            ]
            or not isinstance(section, dict)
            or set(section) != {"path", "bytes", "sha256"}
            or not _SHA256_RE.fullmatch(str(section.get("sha256") or ""))
            or not _positive_int(section.get("bytes"))
            or section.get("path") != f"sections/{section['sha256']}.bin"
        ):
            raise BuildingBlockCacheError("building block manifest is invalid")
        stats = self._validate_stats(manifest.get("stats"), section["bytes"])
        if stats != manifest["stats"]:
            raise BuildingBlockCacheError("building block statistics are not canonical")
        section_path = self.namespace / section["path"]
        try:
            namespace_root = self.namespace.resolve()
            resolved_section_path = section_path.resolve()
            if namespace_root not in resolved_section_path.parents:
                raise BuildingBlockCacheError(
                    "building block section escapes the cache namespace"
                )
            payload = resolved_section_path.read_bytes()
        except (OSError, ValueError) as exc:
            raise BuildingBlockCacheError("building block section is unavailable") from exc
        if (
            len(payload) != section["bytes"]
            or hashlib.sha256(payload).hexdigest() != section["sha256"]
        ):
            raise BuildingBlockCacheError("building block section is corrupt")
        return payload

    @staticmethod
    def _validate_stats(value: Any, section_bytes: int) -> dict[str, int]:
        if (
            not isinstance(value, Mapping)
            or set(value) != _BLOCK_STATS_KEYS
            or any(
                isinstance(item, bool) or not isinstance(item, int) or item < 0
                for item in value.values()
            )
            or value.get("sectionBytes") != section_bytes
            or sum(
                value[key]
                for key in (
                    "explicitHeightCount",
                    "levelsHeightCount",
                    "inheritedHeightCount",
                    "localMedianHeightCount",
                    "classDefaultHeightCount",
                )
            )
            != value.get("recordCount")
        ):
            raise BuildingBlockCacheError("building block statistics are invalid")
        return {key: int(value[key]) for key in sorted(_BLOCK_STATS_KEYS)}

    @staticmethod
    def _block_coordinates(min_x: int, min_y: int) -> tuple[int, int]:
        if (
            isinstance(min_x, bool)
            or not isinstance(min_x, int)
            or isinstance(min_y, bool)
            or not isinstance(min_y, int)
            or min_x % BUILDING_BLOCK_SIZE_METERS
            or min_y % BUILDING_BLOCK_SIZE_METERS
        ):
            raise BuildingBlockCacheError("building block coordinates are invalid")
        return min_x // BUILDING_BLOCK_SIZE_METERS, min_y // BUILDING_BLOCK_SIZE_METERS

    def _manifest_path(self, block_x: int, block_y: int) -> Path:
        return self.namespace / "blocks" / f"{block_x}_{block_y}.json"

    @contextmanager
    def _namespace_lease(self):
        # The lease must outlive the removable namespace. Keeping it inside
        # the namespace would let a retention sweep unlink the locked inode
        # and a new writer acquire a different lock while deletion is active.
        lease_path = self.namespace.parent / f".{self.namespace.name}.lease.lock"
        with lease_path.open("a+b") as lease:
            fcntl.flock(lease.fileno(), fcntl.LOCK_SH)
            yield

    def _touch_access_marker(self) -> None:
        if self._access_recorded:
            return
        marker = self.namespace / ".last-access"
        try:
            marker.touch(exist_ok=True)
        except OSError:
            # A valid read-only cache entry is still safe to consume. Misses
            # will fail explicitly when publication requires write access.
            pass
        self._access_recorded = True

    @staticmethod
    def _valid_section_file(path: Path, sha256: str, size: int) -> bool:
        try:
            payload = path.read_bytes()
        except OSError:
            return False
        return len(payload) == size and hashlib.sha256(payload).hexdigest() == sha256

    @staticmethod
    def _atomic_write(path: Path, payload: bytes) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
        temporary_path = Path(temporary)
        try:
            with os.fdopen(descriptor, "wb") as output:
                output.write(payload)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary_path, path)
            directory = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            try:
                temporary_path.unlink()
            except FileNotFoundError:
                pass


def _positive_int(value: Any) -> bool:
    return not isinstance(value, bool) and isinstance(value, int) and value > 0


def _version_document(value: Any) -> bool:
    return (
        isinstance(value, dict)
        and _positive_int(value.get("algorithmVersion"))
    )
