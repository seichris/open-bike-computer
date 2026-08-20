"""Bounded, lease-aware retention for derived building block caches."""

from __future__ import annotations

import fcntl
import os
import re
from contextlib import contextmanager
from pathlib import Path
import shutil
import time
from typing import Iterable, Iterator


BUILDING_BLOCK_CACHE_DIRECTORY = "building-block-v1"
DEFAULT_BUILDING_BLOCK_CACHE_RETENTION_DAYS = 14
DEFAULT_BUILDING_BLOCK_CACHE_MAX_BYTES = 20 * 1024 * 1024 * 1024
_SHA256 = re.compile(r"[0-9a-f]{64}")


def building_block_cache_namespace_lease_path(namespace: Path) -> Path:
    """Return the stable lease inode shared by readers, writers, and eviction."""

    return namespace.parent / f".{namespace.name}.lease.lock"


@contextmanager
def building_block_cache_namespace_lease(
    namespace: Path,
    *,
    exclusive: bool,
    nonblocking: bool = False,
    create_parent: bool = False,
) -> Iterator[None]:
    """Fence one cache namespace for its complete read, write, or removal."""

    lease_path = building_block_cache_namespace_lease_path(namespace)
    if create_parent:
        lease_path.parent.mkdir(parents=True, exist_ok=True)
    operation = fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH
    if nonblocking:
        operation |= fcntl.LOCK_NB
    with lease_path.open("a+b") as lease:
        fcntl.flock(lease.fileno(), operation)
        try:
            yield
        finally:
            fcntl.flock(lease.fileno(), fcntl.LOCK_UN)


def prune_building_block_cache(
    building_cache_root: Path,
    *,
    older_than_days: int = DEFAULT_BUILDING_BLOCK_CACHE_RETENTION_DAYS,
    max_bytes: int = DEFAULT_BUILDING_BLOCK_CACHE_MAX_BYTES,
    max_items: int = 100,
    protected_cache_identity_sha256s: Iterable[str] = (),
    protect_all: bool = False,
    now: float | None = None,
) -> dict[str, int]:
    if (
        isinstance(older_than_days, bool)
        or not isinstance(older_than_days, int)
        or older_than_days < 1
        or isinstance(max_bytes, bool)
        or not isinstance(max_bytes, int)
        or max_bytes < 1
        or isinstance(max_items, bool)
        or not isinstance(max_items, int)
        or max_items < 1
        or not isinstance(protect_all, bool)
    ):
        raise ValueError("building block cache retention settings are invalid")
    protected_identities = frozenset(protected_cache_identity_sha256s)
    if any(
        not isinstance(identity, str) or not _SHA256.fullmatch(identity)
        for identity in protected_identities
    ):
        raise ValueError("protected building block cache identity is invalid")
    cache_root = building_cache_root / BUILDING_BLOCK_CACHE_DIRECTORY
    if not cache_root.exists():
        return {
            "removedNamespaces": 0,
            "removedBytes": 0,
            "retainedBytes": 0,
            "skippedLeasedNamespaces": 0,
        }
    current_time = time.time() if now is None else now
    cutoff = current_time - older_than_days * 86_400
    resolved_cache_root = cache_root.resolve()
    candidates = []
    for namespace in cache_root.glob("*/*/*"):
        if not namespace.is_dir() or namespace.is_symlink():
            continue
        try:
            namespace.relative_to(cache_root)
            if resolved_cache_root not in namespace.resolve().parents:
                continue
            access_path = namespace / ".last-access"
            accessed_at = (
                access_path.stat().st_mtime
                if access_path.is_file()
                else namespace.stat().st_mtime
            )
            size = _directory_size(namespace)
        except OSError:
            continue
        candidates.append((accessed_at, str(namespace), namespace, size))
    candidates.sort()
    retained_bytes = sum(item[3] for item in candidates)
    selected: list[tuple[float, str, Path, int]] = []
    selected_paths: set[Path] = set()
    for candidate in candidates:
        if (
            not protect_all
            and candidate[2].name not in protected_identities
            and candidate[0] < cutoff
        ):
            selected.append(candidate)
            selected_paths.add(candidate[2])
    projected_bytes = retained_bytes - sum(item[3] for item in selected)
    if projected_bytes > max_bytes:
        for candidate in candidates:
            if (
                protect_all
                or candidate[2].name in protected_identities
                or candidate[2] in selected_paths
            ):
                continue
            selected.append(candidate)
            selected_paths.add(candidate[2])
            projected_bytes -= candidate[3]
            if projected_bytes <= max_bytes:
                break

    removed_namespaces = 0
    removed_bytes = 0
    skipped_leased = 0
    for _accessed_at, _name, namespace, measured_size in selected[:max_items]:
        # This is deliberately outside the removable namespace, matching the
        # cache reader/writer. The locked inode therefore remains stable for
        # the full eviction even if another process recreates the namespace.
        try:
            try:
                lease = building_block_cache_namespace_lease(
                    namespace,
                    exclusive=True,
                    nonblocking=True,
                    create_parent=True,
                )
                with lease:
                    if namespace.exists():
                        shutil.rmtree(namespace)
                        removed_namespaces += 1
                        removed_bytes += measured_size
            except BlockingIOError:
                skipped_leased += 1
                continue
        except FileNotFoundError:
            continue
    return {
        "removedNamespaces": removed_namespaces,
        "removedBytes": removed_bytes,
        "retainedBytes": max(0, retained_bytes - removed_bytes),
        "skippedLeasedNamespaces": skipped_leased,
    }


def _directory_size(path: Path) -> int:
    total = 0
    for root, directories, files in os.walk(path, followlinks=False):
        directories[:] = [
            name for name in directories if not (Path(root) / name).is_symlink()
        ]
        for name in files:
            file_path = Path(root) / name
            if file_path.is_symlink():
                continue
            try:
                total += file_path.stat().st_size
            except FileNotFoundError:
                continue
    return total
