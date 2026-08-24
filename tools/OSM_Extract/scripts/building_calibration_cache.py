"""Immutable source-snapshot building-height calibration cell artifacts."""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import time
import uuid
from typing import Any, Iterable, Mapping


CALIBRATION_CACHE_SCHEMA_VERSION = 1
CALIBRATION_ALGORITHM_VERSION = 1
CALIBRATION_CREATION_TOOL = "open-bike-building-calibration"
_SHA256 = re.compile(r"[0-9a-f]{64}")
_OBJECT_KEY = re.compile(r"[nwr][0-9]+")


class CalibrationCacheError(RuntimeError):
    def __init__(self, code: str, message: str):
        self.code = code
        super().__init__(message)


@dataclass(frozen=True)
class CalibrationIdentity:
    source_snapshot_sha256: str
    rules_sha256: str
    building_profile_version: int
    cell_size_meters: int
    halo_cells: int
    minimum_samples: int
    algorithm_version: int = CALIBRATION_ALGORITHM_VERSION

    def document(self) -> dict[str, Any]:
        if not _SHA256.fullmatch(str(self.source_snapshot_sha256 or "")):
            raise CalibrationCacheError("building_calibration_unavailable", "source snapshot identity is invalid")
        if not _SHA256.fullmatch(str(self.rules_sha256 or "")):
            raise CalibrationCacheError("building_calibration_unavailable", "building rules identity is invalid")
        numeric = (
            self.building_profile_version,
            self.cell_size_meters,
            self.halo_cells,
            self.minimum_samples,
            self.algorithm_version,
        )
        if any(isinstance(value, bool) or not isinstance(value, int) for value in numeric):
            raise CalibrationCacheError("building_calibration_unavailable", "calibration identity numeric values are invalid")
        if (
            self.building_profile_version <= 0
            or self.cell_size_meters <= 0
            or not 0 <= self.halo_cells <= 8
            or self.minimum_samples <= 0
            or self.algorithm_version != CALIBRATION_ALGORITHM_VERSION
        ):
            raise CalibrationCacheError("building_calibration_unavailable", "calibration identity policy is unsupported")
        return {
            "schemaVersion": CALIBRATION_CACHE_SCHEMA_VERSION,
            "sourceSnapshotSha256": self.source_snapshot_sha256,
            "rulesSha256": self.rules_sha256,
            "buildingProfileVersion": self.building_profile_version,
            "algorithmVersion": self.algorithm_version,
            "cellSizeMeters": self.cell_size_meters,
            "haloCells": self.halo_cells,
            "minimumSamples": self.minimum_samples,
            "creationTool": CALIBRATION_CREATION_TOOL,
        }

    @property
    def key(self) -> str:
        return hashlib.sha256(canonical_json(self.document())).hexdigest()


@dataclass(frozen=True)
class CalibrationSample:
    object_key: str
    building_class: str
    height_dm: int


class CalibrationCache:
    def __init__(self, root: str | Path, identity: CalibrationIdentity):
        self.root = Path(root)
        self.identity = identity
        self.identity_document = identity.document()
        self.key = identity.key
        self.key_root = (
            self.root
            / f"building-calibration-v{CALIBRATION_CACHE_SCHEMA_VERSION}"
            / identity.source_snapshot_sha256
            / identity.rules_sha256
            / f"algorithm-{identity.algorithm_version}"
            / self.key
        )
        self._cell_cache: dict[tuple[int, int], bytes] = {}
        self._median_cache: dict[tuple[int, int, str], float | None] = {}
        self._lookup_diagnostics = {"lookups": 0, "underThreshold": 0}
        self._manifest_cells: dict[tuple[int, int], str] | None = None
        # A complete source snapshot proves that every source-derived domain
        # cell was materialized.  Cells outside that derived domain are
        # therefore known-empty, rather than missing/corrupt cache inputs.
        # Incomplete (lazy) manifests must continue to fail closed for an
        # unbound lookup.
        self._complete_source_snapshot = False
        self._complete_domain_cells: frozenset[tuple[int, int]] | None = None

    @classmethod
    def from_manifest(cls, path: str | Path) -> "CalibrationCache":
        path = Path(path)
        try:
            value = json.loads(path.read_bytes())
        except (OSError, ValueError) as exc:
            raise CalibrationCacheError("building_calibration_unavailable", "calibration manifest is unavailable") from exc
        digest = value.pop("manifestSha256", None)
        if not _SHA256.fullmatch(str(digest or "")) or hashlib.sha256(canonical_json(value)).hexdigest() != digest:
            raise CalibrationCacheError("building_calibration_unavailable", "calibration manifest identity is invalid")
        identity = CalibrationIdentity(
            source_snapshot_sha256=value.get("sourceSnapshotSha256"),
            rules_sha256=value.get("rulesSha256"),
            building_profile_version=value.get("buildingProfileVersion"),
            cell_size_meters=value.get("cellSizeMeters"),
            halo_cells=value.get("haloCells"),
            minimum_samples=value.get("minimumSamples"),
            algorithm_version=value.get("algorithmVersion"),
        )
        cache = cls(path.parent, identity)
        cache.key_root = path.parent
        if value.get("calibrationKey") != cache.key:
            raise CalibrationCacheError("building_calibration_unavailable", "calibration manifest key is invalid")
        manifest = cache._read_manifest(validate_cells=True, bind_reader=True)
        cache._complete_source_snapshot = manifest["completeSourceSnapshot"]
        cache._complete_domain_cells = frozenset(cache._manifest_cells or ())
        return cache

    def cell_path(self, cell: tuple[int, int]) -> Path:
        cell = self._validate_cell_coordinate(cell)
        cells_root = self.key_root / "cells"
        path = cells_root / str(cell[0]) / f"{cell[1]}.json"
        if cells_root.resolve() not in path.resolve().parents:
            raise CalibrationCacheError("building_calibration_unavailable", "calibration cell path escapes cache root")
        return path

    def load_cell(self, cell: tuple[int, int]) -> dict[str, Any]:
        cell = self._validate_cell_coordinate(cell)
        if cell in self._cell_cache:
            return json.loads(self._cell_cache[cell])
        return self._load_cell_disk(cell)

    def validate_complete_generation(self) -> dict[str, Any]:
        """Return a sealed full-source manifest after validating every cell."""
        manifest = self._read_manifest(validate_cells=True)
        if not manifest["completeSourceSnapshot"]:
            raise CalibrationCacheError(
                "building_calibration_unavailable",
                "calibration generation is not complete for the source snapshot",
            )
        return manifest

    def _load_cell_disk(self, cell: tuple[int, int]) -> dict[str, Any]:
        path = self.cell_path(cell)
        try:
            raw = path.read_bytes()
            value = json.loads(raw)
        except FileNotFoundError as exc:
            raise CalibrationCacheError("building_calibration_unavailable", f"calibration cell {cell[0]},{cell[1]} is missing") from exc
        except (OSError, ValueError) as exc:
            raise CalibrationCacheError("building_calibration_unavailable", f"calibration cell {cell[0]},{cell[1]} is corrupt") from exc
        self._validate_cell(value, cell)
        if self._manifest_cells is not None:
            expected_hash = self._manifest_cells.get(cell)
            if expected_hash is None or value["entrySha256"] != expected_hash:
                raise CalibrationCacheError("building_calibration_unavailable", "calibration cell is not bound by the manifest")
        encoded = canonical_json(value)
        self._cell_cache[cell] = encoded
        return json.loads(encoded)

    def local_median_meters(self, cell: tuple[int, int], building_class: str) -> float | None:
        cell = self._validate_cell_coordinate(cell)
        lookup_key = (cell[0], cell[1], building_class)
        if lookup_key in self._median_cache:
            return self._median_cache[lookup_key]
        self._lookup_diagnostics["lookups"] += 1
        histogram: Counter[int] = Counter()
        for x in range(cell[0] - self.identity.halo_cells, cell[0] + self.identity.halo_cells + 1):
            for y in range(cell[1] - self.identity.halo_cells, cell[1] + self.identity.halo_cells + 1):
                neighbor = (x, y)
                if self._is_known_empty_cell(neighbor):
                    continue
                entry = self.load_cell(neighbor)
                class_entry = entry["classes"].get(building_class)
                if class_entry:
                    histogram.update({int(height): int(count) for height, count in class_entry["heightHistogramDm"].items()})
        count = sum(histogram.values())
        if count < self.identity.minimum_samples:
            self._lookup_diagnostics["underThreshold"] += 1
            self._median_cache[lookup_key] = None
            return None
        lower_index = (count - 1) // 2
        upper_index = count // 2
        lower = upper = None
        seen = 0
        for height, occurrences in sorted(histogram.items()):
            next_seen = seen + occurrences
            if lower is None and lower_index < next_seen:
                lower = height
            if upper_index < next_seen:
                upper = height
                break
            seen = next_seen
        assert lower is not None and upper is not None
        median_dm = (lower + upper + 1) // 2
        result = median_dm / 10.0
        self._median_cache[lookup_key] = result
        return result

    def can_resolve_cell(self, cell: tuple[int, int]) -> bool:
        """Return whether a local-median lookup is valid for ``cell``.

        Complete source manifests are sparse by design: the manifest lists
        every source-derived cell, while cells outside that domain are
        proven-empty.  Lazy manifests cannot make that proof and therefore
        only allow explicitly bound cells.
        """
        cell = self._validate_cell_coordinate(cell)
        if self._manifest_cells is None:
            raise CalibrationCacheError(
                "building_calibration_unavailable",
                "calibration cache is not bound to a manifest",
            )
        return self._complete_source_snapshot or cell in self._manifest_cells

    def _is_known_empty_cell(self, cell: tuple[int, int]) -> bool:
        if not self._complete_source_snapshot:
            return False
        bound = self._manifest_cells or self._complete_domain_cells
        return bound is not None and cell not in bound

    def lookup_diagnostics(self) -> dict[str, int]:
        return dict(self._lookup_diagnostics)

    def bound_cells(self) -> tuple[tuple[int, int], ...]:
        if self._manifest_cells is None:
            raise CalibrationCacheError(
                "building_calibration_unavailable",
                "calibration cache is not bound to a manifest",
            )
        return tuple(sorted(self._manifest_cells))

    def materialize_cells(
        self,
        requested_cells: Iterable[tuple[int, int]],
        samples_by_cell: Mapping[tuple[int, int], Iterable[CalibrationSample]],
        rejections_by_cell: Mapping[tuple[int, int], Mapping[str, int]] | None = None,
        *,
        lock_timeout_seconds: float | None = None,
        stale_lock_seconds: float = 900.0,
        complete_source_snapshot: bool = False,
        complete_domain_cells: Iterable[tuple[int, int]] | None = None,
    ) -> dict[str, int]:
        del stale_lock_seconds
        requested = tuple(sorted({self._validate_cell_coordinate(cell) for cell in requested_cells}))
        domain = self._validated_complete_domain(
            requested, complete_source_snapshot, complete_domain_cells
        )
        try:
            self.key_root.mkdir(parents=True, exist_ok=True)
            with _CacheLock(self.key_root / ".write.lock", timeout_seconds=lock_timeout_seconds):
                return self._materialize_locked(
                    requested,
                    samples_by_cell,
                    rejections_by_cell=rejections_by_cell or {},
                    complete_domain=domain,
                )
        except CalibrationCacheError:
            raise
        except OSError as exc:
            raise CalibrationCacheError("building_calibration_unavailable", "calibration cache materialization failed") from exc

    def materialize_with_builder(
        self,
        requested_cells: Iterable[tuple[int, int]],
        builder,
        *,
        lock_timeout_seconds: float | None = None,
        complete_source_snapshot: bool = False,
        complete_domain_cells: Iterable[tuple[int, int]] | None = None,
    ) -> tuple[dict[str, int], Any]:
        """Single-flight miss discovery and expensive source population."""
        requested = tuple(sorted({self._validate_cell_coordinate(cell) for cell in requested_cells}))
        domain = self._validated_complete_domain(
            requested, complete_source_snapshot, complete_domain_cells
        )
        try:
            self.key_root.mkdir(parents=True, exist_ok=True)
            with _CacheLock(self.key_root / ".write.lock", timeout_seconds=lock_timeout_seconds):
                valid, corrupt = self._classify_cells(requested)
                missing = tuple(cell for cell in requested if cell not in valid)
                if not missing:
                    self._write_manifest(requested, complete_domain=domain)
                    return {
                        "requested": len(requested), "hits": len(valid),
                        "misses": 0, "rebuilt": 0,
                    }, None
                samples_by_cell, rejections_by_cell, builder_result = builder(missing)
                metrics = self._materialize_locked(
                    requested,
                    samples_by_cell,
                    rejections_by_cell=rejections_by_cell,
                    known_valid=valid,
                    known_corrupt=corrupt,
                    complete_domain=domain,
                )
                return metrics, builder_result
        except CalibrationCacheError:
            raise
        except OSError as exc:
            raise CalibrationCacheError("building_calibration_unavailable", "calibration cache build failed") from exc

    def materialize_complete_with_builders(
        self,
        domain_builder,
        cell_builder,
        *,
        lock_timeout_seconds: float | None = None,
    ) -> tuple[dict[str, int], Any]:
        """Derive and materialize a complete source domain under one lock."""
        try:
            self.key_root.mkdir(parents=True, exist_ok=True)
            with _CacheLock(self.key_root / ".write.lock", timeout_seconds=lock_timeout_seconds):
                requested = tuple(
                    sorted(
                        {
                            self._validate_cell_coordinate(cell)
                            for cell in domain_builder()
                        }
                    )
                )
                domain = self._validated_complete_domain(requested, True, requested)
                valid, corrupt = self._classify_cells(requested)
                missing = tuple(cell for cell in requested if cell not in valid)
                if not missing:
                    self._write_manifest(requested, complete_domain=domain)
                    return {
                        "requested": len(requested),
                        "hits": len(valid),
                        "misses": 0,
                        "rebuilt": 0,
                    }, None
                samples_by_cell, rejections_by_cell, builder_result = cell_builder(missing)
                metrics = self._materialize_locked(
                    requested,
                    samples_by_cell,
                    rejections_by_cell=rejections_by_cell,
                    known_valid=valid,
                    known_corrupt=corrupt,
                    complete_domain=domain,
                )
                return metrics, builder_result
        except CalibrationCacheError:
            raise
        except OSError as exc:
            raise CalibrationCacheError(
                "building_calibration_unavailable", "complete calibration cache build failed"
            ) from exc

    def materialize_complete_with_snapshot_builder(
        self,
        snapshot_builder,
        *,
        lock_timeout_seconds: float | None = None,
    ) -> tuple[dict[str, int], Any]:
        """Build the full domain and samples in one source scan under one lock."""
        try:
            self.key_root.mkdir(parents=True, exist_ok=True)
            with _CacheLock(self.key_root / ".write.lock", timeout_seconds=lock_timeout_seconds):
                try:
                    sealed = self.validate_complete_generation()
                except CalibrationCacheError:
                    pass
                else:
                    cell_count = len(sealed["cells"])
                    return {
                        "requested": cell_count,
                        "hits": cell_count,
                        "misses": 0,
                        "rebuilt": 0,
                    }, None
                domain_cells, samples_by_cell, rejections_by_cell, builder_result = (
                    snapshot_builder()
                )
                requested = tuple(
                    sorted(
                        {
                            self._validate_cell_coordinate(cell)
                            for cell in domain_cells
                        }
                    )
                )
                domain = self._validated_complete_domain(requested, True, requested)
                valid, corrupt = self._classify_cells(requested)
                if len(valid) == len(requested):
                    self._write_manifest(requested, complete_domain=domain)
                    return {
                        "requested": len(requested),
                        "hits": len(valid),
                        "misses": 0,
                        "rebuilt": 0,
                    }, builder_result
                return self._materialize_locked(
                    requested,
                    samples_by_cell,
                    rejections_by_cell=rejections_by_cell,
                    known_valid=valid,
                    known_corrupt=corrupt,
                    complete_domain=domain,
                ), builder_result
        except CalibrationCacheError:
            raise
        except OSError as exc:
            raise CalibrationCacheError(
                "building_calibration_unavailable", "complete calibration snapshot build failed"
            ) from exc

    def _classify_cells(self, requested):
        valid: set[tuple[int, int]] = set()
        corrupt: set[tuple[int, int]] = set()
        for cell in requested:
            self._cell_cache.pop(cell, None)
            try:
                self.load_cell(cell)
                valid.add(cell)
            except CalibrationCacheError:
                if self.cell_path(cell).exists():
                    corrupt.add(cell)
        return valid, corrupt

    def _materialize_locked(
        self,
        requested,
        samples_by_cell,
        *,
        rejections_by_cell=None,
        known_valid=None,
        known_corrupt=None,
        complete_domain=None,
    ):
        valid, corrupt = (
            (set(known_valid), set(known_corrupt))
            if known_valid is not None
            else self._classify_cells(requested)
        )
        for cell in requested:
            if cell in valid:
                continue
            path = self.cell_path(cell)
            if cell in corrupt:
                os.replace(path, path.with_name(f"{path.name}.corrupt-{uuid.uuid4().hex}"))
            entry = self._cell_entry(
                cell,
                samples_by_cell.get(cell, ()),
                (rejections_by_cell or {}).get(cell, {}),
            )
            atomic_write_json(path, entry)
            self._cell_cache[cell] = canonical_json(entry)
        self._median_cache.clear()
        self._write_manifest(requested, complete_domain=complete_domain)
        return {
            "requested": len(requested),
            "hits": len(valid),
            "misses": len(requested) - len(valid) - len(corrupt),
            "rebuilt": len(corrupt),
        }

    def _validated_complete_domain(self, requested, claimed_complete, domain_cells):
        if not claimed_complete:
            if domain_cells is not None:
                raise CalibrationCacheError("building_calibration_unavailable", "complete calibration domain was supplied without completeness")
            return None
        if domain_cells is None:
            raise CalibrationCacheError("building_calibration_unavailable", "complete source snapshot requires a derived cell domain")
        domain = tuple(sorted({self._validate_cell_coordinate(cell) for cell in domain_cells}))
        if not domain:
            raise CalibrationCacheError("building_calibration_unavailable", "complete source snapshot has an empty cell domain")
        if domain != requested:
            raise CalibrationCacheError("building_calibration_unavailable", "materialized cells do not match the complete source domain")
        return domain

    def _cell_entry(
        self,
        cell: tuple[int, int],
        samples: Iterable[CalibrationSample],
        rejected_tags: Mapping[str, int] | None = None,
    ) -> dict[str, Any]:
        normalized = sorted(samples, key=lambda sample: (sample.object_key, sample.building_class, sample.height_dm))
        if any(
            not _OBJECT_KEY.fullmatch(sample.object_key)
            or not sample.building_class
            or isinstance(sample.height_dm, bool)
            or not isinstance(sample.height_dm, int)
            or not 1 <= sample.height_dm <= 65_535
            for sample in normalized
        ):
            raise CalibrationCacheError("building_calibration_unavailable", "calibration sample is invalid")
        identities = [sample.object_key for sample in normalized]
        if len(identities) != len(set(identities)):
            raise CalibrationCacheError("building_calibration_unavailable", "calibration sample identity is duplicated")
        by_class: dict[str, list[CalibrationSample]] = {}
        for sample in normalized:
            by_class.setdefault(sample.building_class, []).append(sample)
        classes = {}
        for building_class, class_samples in sorted(by_class.items()):
            if not re.fullmatch(r"[a-z0-9_-]+", building_class):
                raise CalibrationCacheError("building_calibration_unavailable", "calibration building class is invalid")
            heights = sorted(sample.height_dm for sample in class_samples)
            median = (heights[(len(heights) - 1) // 2] + heights[len(heights) // 2] + 1) // 2
            sample_rows = [[sample.object_key, sample.height_dm] for sample in class_samples]
            classes[building_class] = {
                "sampleCount": len(class_samples),
                "medianDm": median,
                "minimumDm": heights[0],
                "maximumDm": heights[-1],
                "sampleDigestSha256": hashlib.sha256(canonical_json(sample_rows)).hexdigest(),
                "sampleRows": sample_rows,
                "heightHistogramDm": {
                    str(height): count
                    for height, count in sorted(Counter(heights).items())
                },
            }
        rejected_tags = dict(sorted((rejected_tags or {}).items()))
        if any(
            not isinstance(key, str)
            or not isinstance(count, int)
            or isinstance(count, bool)
            or count < 0
            for key, count in rejected_tags.items()
        ):
            raise CalibrationCacheError("building_calibration_unavailable", "calibration rejection diagnostics are invalid")
        body = {
            **self.identity_document,
            "calibrationKey": self.key,
            "cellX": cell[0],
            "cellY": cell[1],
            "sampleCount": len(normalized),
            "rejectedTags": rejected_tags,
            "classes": classes,
        }
        return {**body, "entrySha256": hashlib.sha256(canonical_json(body)).hexdigest()}

    def _validate_cell_coordinate(self, cell) -> tuple[int, int]:
        if (
            not isinstance(cell, (tuple, list))
            or len(cell) != 2
            or any(isinstance(value, bool) or not isinstance(value, int) for value in cell)
        ):
            raise CalibrationCacheError("building_calibration_unavailable", "calibration cell coordinate is invalid")
        limit = (
            math.ceil(20_037_509 / self.identity.cell_size_meters)
            + self.identity.halo_cells
            + 1
        )
        normalized = (cell[0], cell[1])
        if any(not -limit <= value <= limit for value in normalized):
            raise CalibrationCacheError("building_calibration_unavailable", "calibration cell coordinate is outside Web Mercator")
        return normalized

    def _validate_cell(self, value: Any, expected_cell: tuple[int, int]) -> None:
        if not isinstance(value, dict):
            raise CalibrationCacheError("building_calibration_unavailable", "calibration cell is not an object")
        expected_keys = set(self.identity_document) | {
            "calibrationKey", "cellX", "cellY", "sampleCount", "rejectedTags",
            "classes", "entrySha256",
        }
        if set(value) != expected_keys:
            raise CalibrationCacheError("building_calibration_unavailable", "calibration cell schema is invalid")
        digest = value.get("entrySha256")
        body = {key: item for key, item in value.items() if key != "entrySha256"}
        if (
            not _SHA256.fullmatch(str(digest or ""))
            or hashlib.sha256(canonical_json(body)).hexdigest() != digest
            or any(value.get(key) != expected for key, expected in self.identity_document.items())
            or value.get("calibrationKey") != self.key
            or (value.get("cellX"), value.get("cellY")) != expected_cell
            or not isinstance(value.get("classes"), dict)
        ):
            raise CalibrationCacheError("building_calibration_unavailable", "calibration cell identity is invalid")
        total = 0
        global_sample_identities: set[str] = set()
        for building_class, class_entry in value["classes"].items():
            if (
                not isinstance(building_class, str)
                or not re.fullmatch(r"[a-z0-9_-]+", building_class)
                or not isinstance(class_entry, dict)
            ):
                raise CalibrationCacheError("building_calibration_unavailable", "calibration class entry is invalid")
            histogram = class_entry.get("heightHistogramDm")
            sample_rows = class_entry.get("sampleRows")
            if not isinstance(histogram, dict) or not isinstance(sample_rows, list):
                raise CalibrationCacheError("building_calibration_unavailable", "calibration histogram is invalid")
            try:
                parsed_histogram = {
                    int(height): count for height, count in histogram.items()
                }
            except (TypeError, ValueError) as exc:
                raise CalibrationCacheError("building_calibration_unavailable", "calibration histogram is invalid") from exc
            if any(str(height) not in histogram for height in parsed_histogram):
                raise CalibrationCacheError("building_calibration_unavailable", "calibration histogram keys are not canonical")
            if any(
                not isinstance(count, int) or isinstance(count, bool) or count <= 0
                for count in parsed_histogram.values()
            ):
                raise CalibrationCacheError("building_calibration_unavailable", "calibration histogram counts are invalid")
            if any(
                not isinstance(row, list)
                or len(row) != 2
                or not _OBJECT_KEY.fullmatch(str(row[0]))
                or isinstance(row[1], bool)
                or not isinstance(row[1], int)
                for row in sample_rows
            ):
                raise CalibrationCacheError("building_calibration_unavailable", "calibration sample rows are invalid")
            if sample_rows != sorted(sample_rows, key=lambda row: (row[0], row[1])):
                raise CalibrationCacheError("building_calibration_unavailable", "calibration sample rows are not canonical")
            row_identities = [row[0] for row in sample_rows]
            if (
                len(row_identities) != len(set(row_identities))
                or global_sample_identities.intersection(row_identities)
            ):
                raise CalibrationCacheError("building_calibration_unavailable", "calibration sample rows are duplicated")
            global_sample_identities.update(row_identities)
            derived_histogram = Counter(row[1] for row in sample_rows)
            heights = sorted(row[1] for row in sample_rows)
            histogram_count = len(sample_rows)
            derived_median = (
                (heights[(len(heights) - 1) // 2] + heights[len(heights) // 2] + 1) // 2
                if heights else None
            )
            if (
                not heights
                or histogram_count != class_entry.get("sampleCount")
                or dict(sorted(derived_histogram.items())) != parsed_histogram
                or any(not 1 <= height <= 65_535 for height in heights)
                or class_entry.get("minimumDm") != heights[0]
                or class_entry.get("maximumDm") != heights[-1]
                or class_entry.get("medianDm") != derived_median
                or not _SHA256.fullmatch(str(class_entry.get("sampleDigestSha256") or ""))
                or hashlib.sha256(canonical_json(sample_rows)).hexdigest()
                != class_entry.get("sampleDigestSha256")
            ):
                raise CalibrationCacheError("building_calibration_unavailable", "calibration histogram counts are invalid")
            total += histogram_count
        rejected = value.get("rejectedTags")
        if (
            total != value.get("sampleCount")
            or not isinstance(rejected, dict)
            or any(
                not isinstance(key, str)
                or not isinstance(count, int)
                or isinstance(count, bool)
                or count < 0
                for key, count in rejected.items()
            )
        ):
            raise CalibrationCacheError("building_calibration_unavailable", "calibration cell sample total is invalid")

    def _read_manifest(self, *, validate_cells: bool, bind_reader: bool = False) -> dict[str, Any]:
        path = self.key_root / "manifest.json"
        try:
            raw = json.loads(path.read_bytes())
        except (OSError, ValueError) as exc:
            raise CalibrationCacheError("building_calibration_unavailable", "calibration manifest is unavailable") from exc
        digest = raw.get("manifestSha256")
        body = {key: value for key, value in raw.items() if key != "manifestSha256"}
        expected_keys = set(self.identity_document) | {
            "calibrationKey", "completeSourceSnapshot", "completeDomainCellCount",
            "completeDomainSha256", "cells", "manifestSha256",
        }
        if (
            set(raw) != expected_keys
            or not _SHA256.fullmatch(str(digest or ""))
            or hashlib.sha256(canonical_json(body)).hexdigest() != digest
            or any(raw.get(key) != value for key, value in self.identity_document.items())
            or raw.get("calibrationKey") != self.key
            or not isinstance(raw.get("completeSourceSnapshot"), bool)
            or not isinstance(raw.get("cells"), list)
        ):
            raise CalibrationCacheError("building_calibration_unavailable", "calibration manifest identity is invalid")
        previous = None
        manifest_cells: dict[tuple[int, int], str] = {}
        for cell_entry in raw["cells"]:
            if not isinstance(cell_entry, dict) or set(cell_entry) != {"x", "y", "entrySha256"}:
                raise CalibrationCacheError("building_calibration_unavailable", "calibration manifest cell is invalid")
            cell = self._validate_cell_coordinate((cell_entry["x"], cell_entry["y"]))
            if previous is not None and cell <= previous:
                raise CalibrationCacheError("building_calibration_unavailable", "calibration manifest cells are not canonical")
            previous = cell
            if not _SHA256.fullmatch(str(cell_entry["entrySha256"] or "")):
                raise CalibrationCacheError("building_calibration_unavailable", "calibration manifest cell hash is invalid")
            manifest_cells[cell] = cell_entry["entrySha256"]
        complete = raw["completeSourceSnapshot"]
        domain_count = raw["completeDomainCellCount"]
        domain_sha = raw["completeDomainSha256"]
        if complete:
            coordinates = tuple(manifest_cells)
            if (
                isinstance(domain_count, bool)
                or not isinstance(domain_count, int)
                or domain_count != len(coordinates)
                or not _SHA256.fullmatch(str(domain_sha or ""))
                or domain_sha != _cell_domain_sha256(coordinates)
            ):
                raise CalibrationCacheError("building_calibration_unavailable", "complete calibration domain is invalid")
        elif domain_count is not None or domain_sha is not None:
            raise CalibrationCacheError("building_calibration_unavailable", "incomplete calibration manifest declares a complete domain")
        if validate_cells:
            previous_binding = self._manifest_cells
            self._manifest_cells = manifest_cells
            sample_identities: set[str] = set()
            try:
                for cell, expected_hash in manifest_cells.items():
                    self._cell_cache.pop(cell, None)
                    entry = self._load_cell_disk(cell)
                    if entry["entrySha256"] != expected_hash:
                        raise CalibrationCacheError("building_calibration_unavailable", "calibration manifest cell content changed")
                    entry_identities = _entry_sample_identities(entry)
                    if sample_identities.intersection(entry_identities):
                        raise CalibrationCacheError(
                            "building_calibration_unavailable",
                            "calibration sample identity appears in multiple cells",
                        )
                    sample_identities.update(entry_identities)
            except Exception:
                self._manifest_cells = previous_binding
                raise
        if bind_reader:
            self._manifest_cells = manifest_cells
        elif validate_cells:
            self._manifest_cells = previous_binding
        return raw

    def _write_manifest(
        self,
        requested_cells: tuple[tuple[int, int], ...],
        *,
        complete_domain: tuple[tuple[int, int], ...] | None,
    ) -> None:
        existing_cells: set[tuple[int, int]] = set()
        existing_complete = False
        existing_domain_count = None
        existing_domain_sha = None
        path = self.key_root / "manifest.json"
        if path.is_file():
            try:
                existing = self._read_manifest(validate_cells=False)
                existing_cells.update((entry["x"], entry["y"]) for entry in existing["cells"])
                existing_complete = existing["completeSourceSnapshot"]
                existing_domain_count = existing["completeDomainCellCount"]
                existing_domain_sha = existing["completeDomainSha256"]
            except CalibrationCacheError:
                os.replace(path, path.with_name(f"{path.name}.corrupt-{uuid.uuid4().hex}"))
        if existing_complete and complete_domain is not None:
            if (
                existing_domain_count != len(complete_domain)
                or existing_domain_sha != _cell_domain_sha256(complete_domain)
                or existing_cells != set(complete_domain)
            ):
                raise CalibrationCacheError("building_calibration_unavailable", "complete calibration domain changed")
        if (
            existing_complete
            and complete_domain is None
            and not set(requested_cells).issubset(existing_cells)
        ):
            raise CalibrationCacheError(
                "building_calibration_unavailable",
                "calibration request is outside the complete source domain",
            )
        if complete_domain is not None and not existing_cells.issubset(complete_domain):
            raise CalibrationCacheError("building_calibration_unavailable", "complete calibration domain excludes existing cells")
        existing_cells.update(requested_cells)
        if complete_domain is not None and existing_cells != set(complete_domain):
            raise CalibrationCacheError("building_calibration_unavailable", "complete calibration manifest is missing domain cells")
        cell_records = []
        sample_identities: set[str] = set()
        previous_binding = self._manifest_cells
        self._manifest_cells = None
        try:
            for cell in sorted(existing_cells):
                self._cell_cache.pop(cell, None)
                entry = self._load_cell_disk(cell)
                entry_identities = _entry_sample_identities(entry)
                if sample_identities.intersection(entry_identities):
                    raise CalibrationCacheError(
                        "building_calibration_unavailable",
                        "calibration sample identity appears in multiple cells",
                    )
                sample_identities.update(entry_identities)
                cell_records.append(
                    {"x": cell[0], "y": cell[1], "entrySha256": entry["entrySha256"]}
                )
        except Exception:
            self._manifest_cells = previous_binding
            raise
        complete_source_snapshot = existing_complete or complete_domain is not None
        if existing_complete:
            domain_count = existing_domain_count
            domain_sha = existing_domain_sha
        elif complete_domain is not None:
            domain_count = len(complete_domain)
            domain_sha = _cell_domain_sha256(complete_domain)
        else:
            domain_count = None
            domain_sha = None
        manifest = {
            **self.identity_document,
            "calibrationKey": self.key,
            "completeSourceSnapshot": complete_source_snapshot,
            "completeDomainCellCount": domain_count,
            "completeDomainSha256": domain_sha,
            "cells": cell_records,
        }
        manifest["manifestSha256"] = hashlib.sha256(canonical_json(manifest)).hexdigest()
        atomic_write_json(path, manifest)
        self._manifest_cells = None
        self._complete_source_snapshot = complete_source_snapshot
        self._complete_domain_cells = (
            frozenset(existing_cells) if complete_source_snapshot else None
        )


class _CacheLock:
    def __init__(self, path: Path, *, timeout_seconds: float | None):
        self.path = path
        self.timeout_seconds = timeout_seconds
        self.descriptor = None

    def __enter__(self):
        started = time.monotonic()
        self.descriptor = os.open(self.path, os.O_CREAT | os.O_RDWR, 0o600)
        while True:
            try:
                fcntl.flock(self.descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except BlockingIOError:
                if (
                    self.timeout_seconds is not None
                    and time.monotonic() - started >= self.timeout_seconds
                ):
                    os.close(self.descriptor)
                    self.descriptor = None
                    raise CalibrationCacheError("building_calibration_unavailable", "timed out waiting for calibration cache lock")
                time.sleep(0.05)

    def __exit__(self, exc_type, exc, traceback):
        if self.descriptor is not None:
            fcntl.flock(self.descriptor, fcntl.LOCK_UN)
            os.close(self.descriptor)
            self.descriptor = None


def atomic_write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    payload = canonical_json(value) + b"\n"
    try:
        with temporary.open("xb") as output:
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode()


def _cell_domain_sha256(cells: Iterable[tuple[int, int]]) -> str:
    return hashlib.sha256(canonical_json([list(cell) for cell in cells])).hexdigest()


def _entry_sample_identities(entry: Mapping[str, Any]) -> set[str]:
    return {
        row[0]
        for class_entry in entry["classes"].values()
        for row in class_entry["sampleRows"]
    }


def calibration_cell_for_bounds(
    bounds: tuple[float, float, float, float],
    cell_size_meters: int,
) -> tuple[int, int]:
    """Assign complete OSM geometry to a stable projected-bounds midpoint cell."""
    if (
        len(bounds) != 4
        or any(not isinstance(value, (int, float)) or not math.isfinite(value) for value in bounds)
        or bounds[2] < bounds[0]
        or bounds[3] < bounds[1]
        or isinstance(cell_size_meters, bool)
        or not isinstance(cell_size_meters, int)
        or cell_size_meters <= 0
    ):
        raise CalibrationCacheError("building_calibration_unavailable", "calibration geometry bounds are invalid")
    return (
        math.floor((bounds[0] + bounds[2]) / (2 * cell_size_meters)),
        math.floor((bounds[1] + bounds[3]) / (2 * cell_size_meters)),
    )
