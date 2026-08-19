"""Deterministic global-to-chunk planning for large target-3 maps.

The module is intentionally execution-free.  It turns one global output block
set into bounded child plans, retaining enough measured workload information to
let a later coordinator lease and execute those children.  Unknown closure or
resource measurements are represented explicitly and never treated as a safe
zero.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from typing import Any, Mapping, Sequence

from .building_scope import (
    BUILDING_MAX_RELATION_OBJECTS_PER_JOB,
    BUILDING_MAX_SOURCE_AREA_M2,
    GlobalBuildingPlan,
    canonical_json,
    rectangle_union_area,
)
from .reuse import MAP_BLOCK_SIZE_METERS, MapBlock


BUILDING_CHUNK_POLICY_VERSION = 1
BUILDING_CHUNK_PLAN_SCHEMA_VERSION = 1


class BuildingChunkPlanningError(ValueError):
    """A global plan cannot be partitioned under the reviewed policy."""

    def __init__(self, code: str, message: str):
        self.code = code
        super().__init__(message)


@dataclass(frozen=True)
class BuildingChunkPolicy:
    """Targets and hard ceilings applied to every internal building chunk."""

    policy_version: int = BUILDING_CHUNK_POLICY_VERSION
    source_area_target_m2: int = 800_000_000
    source_area_hard_m2: int = BUILDING_MAX_SOURCE_AREA_M2
    closure_objects_target: int = 350_000
    closure_objects_hard: int = BUILDING_MAX_RELATION_OBJECTS_PER_JOB
    wall_time_target_seconds: int = 600
    wall_time_hard_seconds: int = 1_800
    max_missing_building_blocks: int = 48
    split_depth_limit: int = 16

    def validate(self) -> None:
        values = (
            self.policy_version,
            self.source_area_target_m2,
            self.source_area_hard_m2,
            self.closure_objects_target,
            self.closure_objects_hard,
            self.wall_time_target_seconds,
            self.wall_time_hard_seconds,
            self.max_missing_building_blocks,
            self.split_depth_limit,
        )
        if any(isinstance(value, bool) or not isinstance(value, int) for value in values):
            raise BuildingChunkPlanningError(
                "building_chunk_policy_invalid",
                "chunk policy values must be integers",
            )
        if self.policy_version != BUILDING_CHUNK_POLICY_VERSION:
            raise BuildingChunkPlanningError(
                "building_chunk_policy_invalid",
                "unsupported chunk policy version",
            )
        if not (
            0 < self.source_area_target_m2 <= self.source_area_hard_m2
            and 0 < self.closure_objects_target <= self.closure_objects_hard
            and 0 < self.wall_time_target_seconds <= self.wall_time_hard_seconds
            and self.max_missing_building_blocks > 0
            and self.split_depth_limit > 0
        ):
            raise BuildingChunkPlanningError(
                "building_chunk_policy_invalid",
                "chunk targets and ceilings are inconsistent",
            )

    def to_document(self) -> dict[str, int]:
        self.validate()
        return {
            "policyVersion": self.policy_version,
            "sourceAreaTargetM2": self.source_area_target_m2,
            "sourceAreaHardM2": self.source_area_hard_m2,
            "closureObjectsTarget": self.closure_objects_target,
            "closureObjectsHard": self.closure_objects_hard,
            "wallTimeTargetSeconds": self.wall_time_target_seconds,
            "wallTimeHardSeconds": self.wall_time_hard_seconds,
            "maxMissingBuildingBlocks": self.max_missing_building_blocks,
            "splitDepthLimit": self.split_depth_limit,
        }


@dataclass(frozen=True)
class BlockWorkload:
    """Read-only workload evidence for one global output block."""

    block: MapBlock
    closure_objects: int | None = None
    estimated_peak_memory_bytes: int | None = None
    estimated_wall_seconds: int | None = None
    cache_hit: bool = False

    def validate(self) -> None:
        if not isinstance(self.block, MapBlock):
            raise BuildingChunkPlanningError(
                "building_workload_invalid", "workload block is invalid"
            )
        for name in (
            "closure_objects",
            "estimated_peak_memory_bytes",
            "estimated_wall_seconds",
        ):
            value = getattr(self, name)
            if value is not None and (
                isinstance(value, bool) or not isinstance(value, int) or value < 0
            ):
                raise BuildingChunkPlanningError(
                    "building_workload_invalid",
                    f"{name} must be a non-negative integer or null",
                )
        if not isinstance(self.cache_hit, bool):
            raise BuildingChunkPlanningError(
                "building_workload_invalid", "cache_hit must be boolean"
            )

    def to_document(self) -> dict[str, Any]:
        self.validate()
        return {
            "block": [self.block.x, self.block.y],
            "closureObjects": self.closure_objects,
            "estimatedPeakMemoryBytes": self.estimated_peak_memory_bytes,
            "estimatedWallSeconds": self.estimated_wall_seconds,
            "cacheHit": self.cache_hit,
        }


@dataclass(frozen=True)
class ChunkWorkload:
    blocks: tuple[MapBlock, ...]
    source_area_m2: int
    closure_objects: int | None
    estimated_peak_memory_bytes: int | None
    estimated_wall_seconds: int | None
    cache_hit_count: int
    missing_block_count: int
    target_violations: tuple[str, ...]
    hard_violations: tuple[str, ...]
    requires_exact_workload_scan: bool

    @property
    def admissible(self) -> bool:
        return not self.hard_violations and not self.requires_exact_workload_scan

    def to_document(self) -> dict[str, Any]:
        return {
            "blocks": [[block.x, block.y] for block in self.blocks],
            "sourceAreaM2": self.source_area_m2,
            "closureObjects": self.closure_objects,
            "estimatedPeakMemoryBytes": self.estimated_peak_memory_bytes,
            "estimatedWallSeconds": self.estimated_wall_seconds,
            "cacheHitCount": self.cache_hit_count,
            "missingBlockCount": self.missing_block_count,
            "targetViolations": list(self.target_violations),
            "hardViolations": list(self.hard_violations),
            "requiresExactWorkloadScan": self.requires_exact_workload_scan,
        }


@dataclass(frozen=True)
class BuildingChunkPlan:
    chunk_id: str
    blocks: tuple[MapBlock, ...]
    split_depth: int
    workload: ChunkWorkload

    def to_document(self) -> dict[str, Any]:
        return {
            "chunkId": self.chunk_id,
            "splitDepth": self.split_depth,
            "workload": self.workload.to_document(),
        }


@dataclass(frozen=True)
class BuildingPartitionPlan:
    global_plan_sha256: str
    policy: BuildingChunkPolicy
    chunks: tuple[BuildingChunkPlan, ...]
    cache_hit_blocks: tuple[MapBlock, ...]
    _canonical_payload: bytes
    sha256: str

    @property
    def document(self) -> dict[str, Any]:
        return json.loads(self._canonical_payload)

    def canonical_bytes(self) -> bytes:
        return self._canonical_payload

    def write(self, path) -> None:
        if hashlib.sha256(self._canonical_payload).hexdigest() != self.sha256:
            raise BuildingChunkPlanningError(
                "building_chunk_plan_invalid",
                "partition plan identity changed before serialization",
            )
        path.write_bytes(
            canonical_json(
                {**json.loads(self._canonical_payload), "partitionPlanSha256": self.sha256}
            )
            + b"\n"
        )


def partition_global_building_plan(
    global_plan: GlobalBuildingPlan,
    *,
    workloads: Mapping[MapBlock, BlockWorkload] | None = None,
    policy: BuildingChunkPolicy | None = None,
    worker_memory_limit_bytes: int | None = None,
) -> BuildingPartitionPlan:
    """Partition a global block set deterministically by measured resources.

    When exact closure evidence is absent, the returned leaves are explicitly
    marked ``requiresExactWorkloadScan``.  They are useful shadow-plan output,
    but cannot be leased for execution.
    """

    if not isinstance(global_plan, GlobalBuildingPlan):
        raise BuildingChunkPlanningError(
            "building_global_plan_invalid", "global plan is invalid"
        )
    policy = policy or BuildingChunkPolicy()
    policy.validate()
    if worker_memory_limit_bytes is not None and (
        isinstance(worker_memory_limit_bytes, bool)
        or not isinstance(worker_memory_limit_bytes, int)
        or worker_memory_limit_bytes <= 0
    ):
        raise BuildingChunkPlanningError(
            "building_chunk_policy_invalid",
            "worker memory limit must be a positive integer or null",
        )
    if workloads is not None:
        unknown_blocks = set(workloads) - set(global_plan.output_blocks)
        if unknown_blocks:
            raise BuildingChunkPlanningError(
                "building_workload_invalid",
                "workload map contains blocks outside the global plan",
            )
    workload_map: dict[MapBlock, BlockWorkload] = {}
    for block in global_plan.output_blocks:
        workload = (workloads or {}).get(block)
        if workload is None:
            workload = BlockWorkload(block=block)
        workload.validate()
        if workload.block != block:
            raise BuildingChunkPlanningError(
                "building_workload_invalid",
                "workload map key does not match workload block",
            )
        workload_map[block] = workload

    pending = tuple(
        block for block in global_plan.output_blocks if not workload_map[block].cache_hit
    )
    cache_hits = tuple(
        block for block in global_plan.output_blocks if workload_map[block].cache_hit
    )
    chunks: list[BuildingChunkPlan] = []
    for component in _connected_components(pending):
        _partition_component(
            component,
            depth=0,
            global_plan=global_plan,
            workloads=workload_map,
            policy=policy,
            worker_memory_limit_bytes=worker_memory_limit_bytes,
            output=chunks,
        )
    chunks.sort(key=lambda chunk: (chunk.blocks[0], chunk.chunk_id))
    document = {
        "schemaVersion": BUILDING_CHUNK_PLAN_SCHEMA_VERSION,
        "globalPlanSha256": global_plan.sha256,
        "policy": policy.to_document(),
        "workerMemoryLimitBytes": worker_memory_limit_bytes,
        "cacheHitBlocks": [[block.x, block.y] for block in cache_hits],
        "chunks": [chunk.to_document() for chunk in chunks],
    }
    encoded = canonical_json(document)
    return BuildingPartitionPlan(
        global_plan_sha256=global_plan.sha256,
        policy=policy,
        chunks=tuple(chunks),
        cache_hit_blocks=cache_hits,
        _canonical_payload=encoded,
        sha256=hashlib.sha256(encoded).hexdigest(),
    )


def _partition_component(
    blocks: Sequence[MapBlock],
    *,
    depth: int,
    global_plan: GlobalBuildingPlan,
    workloads: Mapping[MapBlock, BlockWorkload],
    policy: BuildingChunkPolicy,
    worker_memory_limit_bytes: int | None,
    output: list[BuildingChunkPlan],
) -> None:
    ordered = tuple(sorted(blocks))
    workload = _measure_chunk(ordered, global_plan, workloads, policy, worker_memory_limit_bytes)
    should_split = bool(workload.target_violations or workload.hard_violations)
    if (
        not should_split
        or len(ordered) == 1
        or depth >= policy.split_depth_limit
    ):
        output.append(
            BuildingChunkPlan(
                chunk_id=_chunk_id(global_plan.sha256, ordered, depth),
                blocks=ordered,
                split_depth=depth,
                workload=workload,
            )
        )
        return
    left, right = _best_cut(
        ordered,
        global_plan,
        workloads,
        policy,
        worker_memory_limit_bytes,
    )
    if not left or not right:
        output.append(
            BuildingChunkPlan(
                chunk_id=_chunk_id(global_plan.sha256, ordered, depth),
                blocks=ordered,
                split_depth=depth,
                workload=workload,
            )
        )
        return
    _partition_component(
        left,
        depth=depth + 1,
        global_plan=global_plan,
        workloads=workloads,
        policy=policy,
        worker_memory_limit_bytes=worker_memory_limit_bytes,
        output=output,
    )
    _partition_component(
        right,
        depth=depth + 1,
        global_plan=global_plan,
        workloads=workloads,
        policy=policy,
        worker_memory_limit_bytes=worker_memory_limit_bytes,
        output=output,
    )


def _measure_chunk(
    blocks: Sequence[MapBlock],
    global_plan: GlobalBuildingPlan,
    workloads: Mapping[MapBlock, BlockWorkload],
    policy: BuildingChunkPolicy,
    worker_memory_limit_bytes: int | None,
) -> ChunkWorkload:
    block_set = tuple(sorted(blocks))
    buffer_meters = int(
        global_plan.document["chunkPolicy"].get(
            "geometryBufferMeters", 256
        )
    )
    rectangles = tuple(
        (
            block.x * MAP_BLOCK_SIZE_METERS - buffer_meters,
            block.y * MAP_BLOCK_SIZE_METERS - buffer_meters,
            (block.x + 1) * MAP_BLOCK_SIZE_METERS + buffer_meters,
            (block.y + 1) * MAP_BLOCK_SIZE_METERS + buffer_meters,
        )
        for block in block_set
    )
    source_area = rectangle_union_area(rectangles)
    values = [workloads[block] for block in block_set]
    closure_values = [value.closure_objects for value in values]
    memory_values = [value.estimated_peak_memory_bytes for value in values]
    wall_values = [value.estimated_wall_seconds for value in values]
    closure_objects = (
        sum(value for value in closure_values if value is not None)
        if all(value is not None for value in closure_values)
        else None
    )
    peak_memory = (
        sum(value for value in memory_values if value is not None)
        if all(value is not None for value in memory_values)
        else None
    )
    wall_seconds = (
        sum(value for value in wall_values if value is not None)
        if all(value is not None for value in wall_values)
        else None
    )
    target_violations: list[str] = []
    hard_violations: list[str] = []
    if source_area > policy.source_area_target_m2:
        target_violations.append("source_area")
    if source_area > policy.source_area_hard_m2:
        hard_violations.append("source_area")
    if closure_objects is None:
        requires_scan = True
    else:
        requires_scan = False
        if closure_objects > policy.closure_objects_target:
            target_violations.append("closure_objects")
        if closure_objects > policy.closure_objects_hard:
            hard_violations.append("closure_objects")
    if peak_memory is not None and worker_memory_limit_bytes is not None:
        if peak_memory > int(worker_memory_limit_bytes * 0.70):
            target_violations.append("estimated_peak_memory")
        if peak_memory > int(worker_memory_limit_bytes * 0.85):
            hard_violations.append("estimated_peak_memory")
    elif worker_memory_limit_bytes is not None:
        requires_scan = True
    if wall_seconds is None:
        requires_scan = True
    else:
        if wall_seconds > policy.wall_time_target_seconds:
            target_violations.append("wall_time")
        if wall_seconds > policy.wall_time_hard_seconds:
            hard_violations.append("wall_time")
    missing_count = len(block_set)
    cache_hit_count = sum(1 for value in values if value.cache_hit)
    if missing_count > policy.max_missing_building_blocks:
        target_violations.append("missing_building_blocks")
    return ChunkWorkload(
        blocks=block_set,
        source_area_m2=source_area,
        closure_objects=closure_objects,
        estimated_peak_memory_bytes=peak_memory,
        estimated_wall_seconds=wall_seconds,
        cache_hit_count=cache_hit_count,
        missing_block_count=missing_count,
        target_violations=tuple(sorted(set(target_violations))),
        hard_violations=tuple(sorted(set(hard_violations))),
        requires_exact_workload_scan=requires_scan,
    )


def _best_cut(
    blocks: Sequence[MapBlock],
    global_plan: GlobalBuildingPlan,
    workloads: Mapping[MapBlock, BlockWorkload],
    policy: BuildingChunkPolicy,
    worker_memory_limit_bytes: int | None,
) -> tuple[tuple[MapBlock, ...], tuple[MapBlock, ...]]:
    ordered = tuple(sorted(blocks))
    x_span = max(block.x for block in ordered) - min(block.x for block in ordered)
    y_span = max(block.y for block in ordered) - min(block.y for block in ordered)
    axis = "x" if x_span >= y_span else "y"
    coordinates = sorted({getattr(block, axis) for block in ordered})
    candidates: list[tuple[tuple[Any, ...], tuple[MapBlock, ...], tuple[MapBlock, ...]]] = []
    for coordinate in coordinates[:-1]:
        left = tuple(
            block for block in ordered if getattr(block, axis) <= coordinate
        )
        right = tuple(
            block for block in ordered if getattr(block, axis) > coordinate
        )
        if not left or not right:
            continue
        left_workload = _measure_chunk(
            left, global_plan, workloads, policy, worker_memory_limit_bytes
        )
        right_workload = _measure_chunk(
            right, global_plan, workloads, policy, worker_memory_limit_bytes
        )
        score = (
            max(
                _normalized_load(left_workload, policy),
                _normalized_load(right_workload, policy),
            ),
            abs(len(left) - len(right)),
            _boundary_gap(left, right),
            coordinate,
        )
        candidates.append((score, tuple(sorted(left)), tuple(sorted(right))))
    if not candidates:
        return (), ()
    _, left, right = min(candidates, key=lambda value: value[0])
    return left, right


def _normalized_load(workload: ChunkWorkload, policy: BuildingChunkPolicy) -> float:
    loads = [workload.source_area_m2 / policy.source_area_target_m2]
    if workload.closure_objects is not None:
        loads.append(workload.closure_objects / policy.closure_objects_target)
    if workload.estimated_wall_seconds is not None:
        loads.append(workload.estimated_wall_seconds / policy.wall_time_target_seconds)
    return max(loads)


def _boundary_gap(left: Sequence[MapBlock], right: Sequence[MapBlock]) -> int:
    return min(
        abs(a.x - b.x) + abs(a.y - b.y)
        for a in left
        for b in right
    )


def _connected_components(blocks: Sequence[MapBlock]) -> tuple[tuple[MapBlock, ...], ...]:
    remaining = set(blocks)
    components: list[tuple[MapBlock, ...]] = []
    while remaining:
        seed = min(remaining)
        remaining.remove(seed)
        pending = [seed]
        component = [seed]
        while pending:
            current = pending.pop()
            neighbors = {
                MapBlock(current.x + dx, current.y + dy)
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))
            }
            for neighbor in sorted(neighbors & remaining):
                remaining.remove(neighbor)
                pending.append(neighbor)
                component.append(neighbor)
        components.append(tuple(sorted(component)))
    return tuple(sorted(components, key=lambda value: value[0]))


def _chunk_id(global_plan_sha256: str, blocks: Sequence[MapBlock], depth: int) -> str:
    body = {
        "globalPlanSha256": global_plan_sha256,
        "blocks": [[block.x, block.y] for block in sorted(blocks)],
        "splitDepth": depth,
    }
    digest = hashlib.sha256(canonical_json(body)).hexdigest()
    return f"chunk-{digest[:24]}"
