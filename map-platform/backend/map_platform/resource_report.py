"""Read-only worker capability and memory/cgroup reporting."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import time
from typing import Any, Mapping


RESOURCE_REPORT_SCHEMA_VERSION = 1
WORKER_CAPABILITY_SCHEMA_VERSION = 1
# On supported 64-bit Linux kernels, an unlimited cgroup-v1 page counter is
# exported as PAGE_COUNTER_MAX * PAGE_SIZE: LONG_MAX rounded down by less than
# one base page (commonly 9223372036854771712). Keep the recognition window
# narrowly adjacent to signed 64-bit LONG_MAX so realistic multi-terabyte
# finite caps are never reinterpreted as unlimited. The wider-than-page margin
# tolerates kernel page-size and counter-export variations.
_CGROUP_V1_UNLIMITED_FLOOR_BYTES = (1 << 63) - (1 << 30)


class WorkerCapabilityError(RuntimeError):
    """The worker cannot safely execute resource-admitted chunked work."""


def worker_resource_report(
    *,
    cgroup_root: str | Path = "/sys/fs/cgroup",
    proc_root: str | Path = "/proc",
) -> dict[str, Any]:
    """Return bounded resource evidence without changing host state."""

    cgroup_root = Path(cgroup_root)
    proc_root = Path(proc_root)
    cgroup = _cgroup_memory(cgroup_root)
    process = _process_memory(proc_root / "self" / "status")
    host = _meminfo(proc_root / "meminfo")
    configured = _configured_memory_limit()
    capability = _worker_capability(
        cgroup=cgroup,
        configured_memory_limit_bytes=configured,
    )
    return {
        "schemaVersion": RESOURCE_REPORT_SCHEMA_VERSION,
        "reportedAtEpochSeconds": round(time.time(), 3),
        "workerId": os.environ.get("MAP_PLATFORM_WORKER_ID"),
        "cpuCount": os.cpu_count() or 1,
        "configuredMemoryLimitBytes": configured,
        "hostMemory": host,
        "cgroupMemory": {
            **cgroup,
            "configuredLimitBytes": configured,
        },
        "processMemory": process,
        "capability": capability,
    }


def worker_capability_snapshot() -> dict[str, Any]:
    """Return one validated capability snapshot for executable chunked work."""

    report = worker_resource_report()
    if report.get("schemaVersion") != RESOURCE_REPORT_SCHEMA_VERSION:
        raise WorkerCapabilityError("worker resource report schema is invalid")
    return validate_worker_capability(report.get("capability"))


def validate_worker_capability(capability: object) -> dict[str, Any]:
    """Validate identity and admission-critical fields without reinterpretation."""

    if not isinstance(capability, Mapping):
        raise WorkerCapabilityError("worker capability is missing")
    document = dict(capability)
    if document.get("schemaVersion") != WORKER_CAPABILITY_SCHEMA_VERSION:
        raise WorkerCapabilityError("worker capability schema is invalid")
    for field in ("workerClass", "resourcePool"):
        value = document.get(field)
        if not isinstance(value, str) or not value or len(value) > 128:
            raise WorkerCapabilityError(f"worker capability {field} is invalid")
    for field in ("cpuCount", "maxConcurrentTasks", "memoryLimitBytes"):
        value = document.get(field)
        if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
            raise WorkerCapabilityError(f"worker capability {field} is invalid")
    for field in ("configuredMemoryLimitBytes", "cgroupMemoryLimitBytes"):
        value = document.get(field)
        if value is not None and (
            isinstance(value, bool) or not isinstance(value, int) or value <= 0
        ):
            raise WorkerCapabilityError(f"worker capability {field} is invalid")
    identity = document.get("identitySha256")
    body = {key: value for key, value in document.items() if key != "identitySha256"}
    expected_identity = hashlib.sha256(
        json.dumps(
            body, sort_keys=True, separators=(",", ":"), ensure_ascii=False
        ).encode("utf-8")
    ).hexdigest()
    if identity != expected_identity:
        raise WorkerCapabilityError("worker capability identity is invalid")
    return document


def _worker_capability(
    *,
    cgroup: dict[str, Any],
    configured_memory_limit_bytes: int | None,
) -> dict[str, Any]:
    """Return stable worker admission fields plus their identity hash.

    Dynamic RSS/current/peak values intentionally stay outside this document;
    they belong to the evidence report, not to the worker class identity used
    for resource-model comparisons.
    """

    cpu_count = os.cpu_count() or 1
    cgroup_limit = cgroup.get("limitBytes")
    positive_limits = [
        value
        for value in (configured_memory_limit_bytes, cgroup_limit)
        if isinstance(value, int) and not isinstance(value, bool) and value > 0
    ]
    memory_limit = min(positive_limits) if positive_limits else None
    body = {
        "schemaVersion": WORKER_CAPABILITY_SCHEMA_VERSION,
        "workerClass": os.environ.get("MAP_PLATFORM_WORKER_CLASS", "default"),
        "resourcePool": os.environ.get(
            "MAP_PLATFORM_WORKER_RESOURCE_POOL", "default"
        ),
        "cpuCount": cpu_count,
        "memoryLimitBytes": memory_limit,
        "configuredMemoryLimitBytes": configured_memory_limit_bytes,
        "cgroupMemoryLimitBytes": cgroup_limit,
        "maxConcurrentTasks": _configured_max_concurrent_tasks(),
    }
    encoded = json.dumps(
        body, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    return {
        **body,
        "identitySha256": hashlib.sha256(encoded).hexdigest(),
    }


def _configured_memory_limit() -> int | None:
    raw = os.environ.get("MAP_PLATFORM_WORKER_MEMORY_LIMIT_BYTES")
    if raw is None or not raw.strip():
        return None
    try:
        value = int(raw)
    except ValueError as exc:
        raise WorkerCapabilityError(
            "MAP_PLATFORM_WORKER_MEMORY_LIMIT_BYTES must be a positive integer"
        ) from exc
    if value <= 0:
        raise WorkerCapabilityError(
            "MAP_PLATFORM_WORKER_MEMORY_LIMIT_BYTES must be a positive integer"
        )
    return value


def _configured_max_concurrent_tasks() -> int:
    raw = os.environ.get("MAP_PLATFORM_WORKER_MAX_CONCURRENT_TASKS")
    if raw is None or not raw.strip():
        return 1
    try:
        value = int(raw)
    except ValueError as exc:
        raise WorkerCapabilityError(
            "MAP_PLATFORM_WORKER_MAX_CONCURRENT_TASKS must be a positive integer"
        ) from exc
    if value <= 0:
        raise WorkerCapabilityError(
            "MAP_PLATFORM_WORKER_MAX_CONCURRENT_TASKS must be a positive integer"
        )
    return value


def _cgroup_memory(root: Path) -> dict[str, Any]:
    v2_max = root / "memory.max"
    v2_current = root / "memory.current"
    v2_peak = root / "memory.peak"
    if any(path.exists() for path in (v2_max, v2_current, v2_peak)):
        return {
            "version": 2,
            "limitBytes": _read_limit(v2_max),
            "currentBytes": _read_nonnegative(v2_current),
            "peakBytes": _read_nonnegative(v2_peak),
        }
    v1_root = root / "memory"
    return {
        "version": 1 if v1_root.exists() else None,
        "limitBytes": _read_cgroup_v1_limit(
            v1_root / "memory.limit_in_bytes"
        ),
        "currentBytes": _read_nonnegative(v1_root / "memory.usage_in_bytes"),
        "peakBytes": _read_nonnegative(v1_root / "memory.max_usage_in_bytes"),
    }


def _read_limit(path: Path) -> int | None:
    try:
        raw = path.read_text(encoding="ascii").strip()
    except (OSError, UnicodeError):
        return None
    if raw == "max":
        return None
    try:
        value = int(raw)
    except ValueError:
        return None
    return value if value > 0 else None


def _read_cgroup_v1_limit(path: Path) -> int | None:
    value = _read_nonnegative(path)
    if value is None or value >= _CGROUP_V1_UNLIMITED_FLOOR_BYTES:
        return None
    return value


def _read_nonnegative(path: Path) -> int | None:
    try:
        value = int(path.read_text(encoding="ascii").strip())
    except (OSError, UnicodeError, ValueError):
        return None
    return value if value >= 0 else None


def _process_memory(path: Path) -> dict[str, int | None]:
    values: dict[str, int | None] = {"rssBytes": None, "peakRssBytes": None}
    try:
        lines = path.read_text(encoding="ascii").splitlines()
    except (OSError, UnicodeError):
        return values
    for line in lines:
        key, separator, raw = line.partition(":")
        if not separator or key not in {"VmRSS", "VmHWM"}:
            continue
        parts = raw.split()
        if not parts:
            continue
        try:
            value = int(parts[0]) * (1024 if len(parts) < 2 or parts[1] == "kB" else 1)
        except ValueError:
            continue
        if key == "VmRSS":
            values["rssBytes"] = value
        else:
            values["peakRssBytes"] = value
    return values


def _meminfo(path: Path) -> dict[str, int | None]:
    values: dict[str, int | None] = {
        "totalBytes": None,
        "availableBytes": None,
    }
    try:
        lines = path.read_text(encoding="ascii").splitlines()
    except (OSError, UnicodeError):
        return values
    for line in lines:
        key, separator, raw = line.partition(":")
        if not separator or key not in {"MemTotal", "MemAvailable"}:
            continue
        parts = raw.split()
        if not parts:
            continue
        try:
            value = int(parts[0]) * (1024 if len(parts) < 2 or parts[1] == "kB" else 1)
        except ValueError:
            continue
        values["totalBytes" if key == "MemTotal" else "availableBytes"] = value
    return values
