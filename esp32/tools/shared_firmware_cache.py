"""Verified immutable core transport between private firmware worktrees.

The shared cache never executes code and never holds mutable PlatformIO state.
An import verifies the original archive, rebases text launchers/configuration,
then publishes and verifies a new project-private core entry before use.
"""

from __future__ import annotations

import fcntl
import gzip
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path

from firmware_runtime import _safe_subtree
import generated_sdkconfig as core


ARCHIVE_FIELDS = {
    "coreArchiveFilename", "coreArchiveSize", "coreArchiveSha256",
    "coreArchiveInventorySha256", "coreArchiveEntryCount",
}


def default_build_cache_root() -> Path:
    override = os.environ.get("OPEN_BIKE_FIRMWARE_BUILD_CACHE")
    if override:
        return Path(override).expanduser()
    if sys.platform == "darwin":
        return Path.home() / "Library/Caches/OpenBikeComputer/firmware-builds"
    return Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "open-bike-computer/firmware-builds"


@contextmanager
def _store(environment: str, request_key: str, namespace: str = "cores-v1"):
    if (
        core.ENVIRONMENT_PATTERN.fullmatch(environment) is None
        or core.re.fullmatch(r"[0-9a-f]{64}", request_key) is None
        or namespace not in {"cores-v1", "downloads-v1"}
    ):
        raise core.GeneratedSdkconfigError("invalid shared-cache environment")
    cache_root = _safe_subtree(default_build_cache_root(), (), create=True)
    # The full-root creation loop tolerates another publisher creating parents.
    root = _safe_subtree(cache_root / namespace / environment, (), create=True)
    for owned in (cache_root, root.parent, root):
        if owned.stat().st_uid != os.getuid() or owned.stat().st_mode & 0o022:
            raise core.GeneratedSdkconfigError("unsafe shared core cache ownership or permissions")
    if root.stat().st_mode & 0o022:
        raise core.GeneratedSdkconfigError("shared core cache is writable by another user")
    lock = root / ".lock"
    descriptor = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1
            or metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o600
        ):
            raise core.GeneratedSdkconfigError("unsafe shared core cache lock")
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield root / request_key
    finally:
        os.close(descriptor)


def _load_transport(entry: Path, project: Path, environment: str, request_key: str):
    metadata_path = entry / "transport.json"
    if entry.is_symlink() or not entry.is_dir() or stat.S_IMODE(entry.stat().st_mode) != 0o555:
        raise core.GeneratedSdkconfigError("unsafe shared core transport")
    core_dir = entry / "core"
    if {p.name for p in entry.iterdir()} != {"transport.json", "core"}:
        raise core.GeneratedSdkconfigError("shared core transport has missing or extra files")
    if (
        metadata_path.is_symlink() or not metadata_path.is_file()
        or metadata_path.stat().st_size > 1024 * 1024
        or metadata_path.stat().st_uid != os.getuid()
        or metadata_path.stat().st_nlink != 1
        or stat.S_IMODE(metadata_path.stat().st_mode) != 0o444
        or entry.stat().st_uid != os.getuid()
    ):
        raise core.GeneratedSdkconfigError("unsafe shared core transport metadata")
    value = core._load_manifest(metadata_path)
    if not isinstance(value, dict) or set(value) != {
        "schema", "requestKey", "coreInputKey", "sourceProjectDir", "files",
    }:
        raise core.GeneratedSdkconfigError("invalid shared core transport metadata")
    origin = value.get("sourceProjectDir")
    key = value.get("coreInputKey")
    if (
        type(value.get("schema")) is not int or value.get("schema") != 1 or value.get("requestKey") != request_key
        or not isinstance(key, str) or core.re.fullmatch(r"[0-9a-f]{64}", key) is None
        or not isinstance(origin, str) or not Path(origin).is_absolute()
        or ".." in Path(origin).parts or Path(origin) == Path("/")
        or not isinstance(value.get("files"), dict)
    ):
        raise core.GeneratedSdkconfigError("shared core transport identity changed")
    manifest = core._validate_core_cache_entry(project, environment, key, entry_dir=core_dir)
    files = {p.name: (manifest["coreArchiveSha256"] if p.name == core.CORE_ARCHIVE_FILENAME else core._file_sha256(p)) for p in core_dir.iterdir()}
    if files != value["files"]:
        raise core.GeneratedSdkconfigError("shared core transport digest changed")
    return manifest, Path(origin), core_dir


def _copy_file(source: Path, destination: Path) -> None:
    # APFS clones avoid duplicating multi-gigabyte immutable archives locally.
    if sys.platform == "darwin":
        result = subprocess.run(["/bin/cp", "-c", str(source), str(destination)], capture_output=True)
        if result.returncode == 0:
            return
    shutil.copyfile(source, destination)


def _validate_download(entry: Path, sha256: str, size: int) -> Path:
    payload = entry / "archive"
    if (
        entry.is_symlink() or not entry.is_dir()
        or entry.stat().st_uid != os.getuid()
        or stat.S_IMODE(entry.stat().st_mode) != 0o555
        or {p.name for p in entry.iterdir()} != {"archive"}
        or payload.is_symlink() or not payload.is_file()
        or payload.stat().st_uid != os.getuid() or payload.stat().st_nlink != 1
        or stat.S_IMODE(payload.stat().st_mode) != 0o444
        or payload.stat().st_size != size or core._file_sha256(payload) != sha256
    ):
        raise core.GeneratedSdkconfigError("shared pinned download is corrupt or unsafe")
    return payload


def restore_shared_download(destination: Path, sha256: str, size: int) -> bool:
    with _store("archives", sha256, "downloads-v1") as entry:
        if not os.path.lexists(entry):
            return False
        payload = _validate_download(entry, sha256, size)
        temporary = destination.with_name(f".{destination.name}.{os.getpid()}.restore")
        if os.path.lexists(temporary):
            raise core.GeneratedSdkconfigError("unsafe private download restoration path")
        try:
            _copy_file(payload, temporary)
            temporary.chmod(0o600)
            if temporary.stat().st_size != size or core._file_sha256(temporary) != sha256:
                raise core.GeneratedSdkconfigError("restored pinned download changed")
            os.replace(temporary, destination)
        finally:
            if temporary.exists():
                temporary.unlink()
    return True


def publish_shared_download(source: Path, sha256: str, size: int) -> None:
    with _store("archives", sha256, "downloads-v1") as entry:
        if os.path.lexists(entry):
            _validate_download(entry, sha256, size)
            return
        temporary = Path(tempfile.mkdtemp(prefix=f".{sha256}.", dir=entry.parent))
        try:
            payload = temporary / "archive"
            _copy_file(source, payload)
            payload.chmod(0o444)
            temporary.chmod(0o555)
            _validate_download(temporary, sha256, size)
            temporary.chmod(0o700)
            os.rename(temporary, entry)
            entry.chmod(0o555)
        finally:
            if temporary.exists():
                temporary.chmod(0o700)
                shutil.rmtree(temporary)


def publish_shared_core(project: Path, environment: str) -> None:
    if core.FULL_GIT_SHA.fullmatch(core.current_source_identity(project, environment)) is None:
        return
    request_key = core.core_request_key(project, environment)
    key = core.core_input_key(project, environment)
    if request_key is None or key is None:
        return
    source = core._core_cache_entry_dir(project, environment, key)
    with _store(environment, request_key) as entry:
        if os.path.lexists(entry):
            # A producer never consumes this entry. Consumers always verify it
            # before restoring; avoid rehashing an unused archive on warm builds.
            return
        manifest = core._validate_core_cache_entry(project, environment, key)
        temporary = Path(tempfile.mkdtemp(prefix=f".{request_key}.", dir=entry.parent))
        try:
            destination = temporary / "core"
            destination.mkdir()
            files = {}
            for path in source.iterdir():
                if path.name == "manifest.json":
                    continue
                output = destination / path.name
                if path.name == core.CORE_ARCHIVE_FILENAME:
                    # Keep transport compact on disk and in Actions caches.
                    # The member inventory remains identical to the verified
                    # original; the compressed byte stream gets its own digest.
                    with path.open("rb") as original, output.open("xb") as target:
                        with gzip.GzipFile(filename="", fileobj=target, mode="wb", compresslevel=1, mtime=0) as compressed:
                            shutil.copyfileobj(original, compressed, length=1024 * 1024)
                else:
                    _copy_file(path, output)
                output.chmod(0o444)
                files[path.name] = core._file_sha256(output)
            archive = destination / core.CORE_ARCHIVE_FILENAME
            metadata_manifest = destination / "manifest.json"
            core._atomic_json(metadata_manifest, {
                **manifest,
                "coreArchiveSize": archive.stat().st_size,
                "coreArchiveSha256": files[core.CORE_ARCHIVE_FILENAME],
            })
            metadata_manifest.chmod(0o444)
            files["manifest.json"] = core._file_sha256(metadata_manifest)
            destination.chmod(0o555)
            metadata = temporary / "transport.json"
            core._atomic_json(metadata, {
                "schema": 1, "requestKey": request_key, "coreInputKey": key,
                "sourceProjectDir": str(project), "files": files,
            })
            metadata.chmod(0o444)
            # Validate before atomic publication; never replace another writer.
            temporary.chmod(0o555)
            _load_transport(temporary, project, environment, request_key)
            temporary.chmod(0o700)
            os.rename(temporary, entry)
            entry.chmod(0o555)
        finally:
            if temporary.exists():
                temporary.chmod(0o700)
                if (temporary / "core").exists():
                    (temporary / "core").chmod(0o700)
                shutil.rmtree(temporary)
    print(f"FIRMWARE_SHARED_CORE_CACHE schema=1 status=published environment={environment}", flush=True)


def restore_shared_core(project: Path, environment: str) -> bool:
    request_key = core.core_request_key(project, environment)
    if request_key is None:
        return False
    started = time.monotonic()
    with _store(environment, request_key) as entry:
        if not os.path.lexists(entry):
            print(f"FIRMWARE_SHARED_CORE_CACHE schema=1 status=miss environment={environment}", flush=True)
            return False
        manifest, origin, source = _load_transport(entry, project, environment, request_key)
        for path in core._sdkconfig_paths(project, environment):
            if os.path.lexists(path) and (path.is_symlink() or not core._is_generated_sdkconfig(path) or core._is_tracked(project, path)):
                raise core.GeneratedSdkconfigError("shared core cannot replace user SDK configuration")
        rebound = core._hydrate_core_cache_entry(
            project, environment, manifest["coreInputKey"], manifest,
            entry_dir=source, relocate_from=origin,
        )
        key = core.core_input_key(project, environment)
        if key != manifest["coreInputKey"]:
            raise core.GeneratedSdkconfigError("relocated core input identity changed")
        local = core._core_cache_entry_dir(project, environment, key)
        if os.path.lexists(local):
            core._validate_core_cache_entry(project, environment, key)
        else:
            base = {name: value for name, value in rebound.items() if name not in ARCHIVE_FIELDS}
            core._publish_core_cache_entry(project, environment, key, base)
        if not core._active_core_matches(project, environment, core._validate_core_cache_entry(project, environment, key)):
            raise core.GeneratedSdkconfigError("imported core differs from its private cache")
    elapsed = round((time.monotonic() - started) * 1000)
    print(f"FIRMWARE_SHARED_CORE_CACHE schema=1 status=hit environment={environment} restoreMs={elapsed}", flush=True)
    return True
