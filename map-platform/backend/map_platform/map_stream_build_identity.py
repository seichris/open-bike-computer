from __future__ import annotations

import hashlib
import json
import platform
import re
import subprocess
import sys
import sysconfig
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

from .strict_json import load_strict_json


SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
PINNED_IMAGE_PATTERN = re.compile(r"[^@\s]+@(sha256:[0-9a-f]{64})")
WORKER_SOURCE_ROOTS = (
    "map-platform/backend/map_platform",
    "map-platform/backend/config",
    "map-platform/backend/pyproject.toml",
    "map-platform/backend/Dockerfile",
    "map-platform/backend/tools/generate_map_stream_build_identity.py",
    "tools/OSM_Extract/conf",
    "tools/OSM_Extract/scripts",
)


@dataclass(frozen=True)
class MapStreamBuildIdentity:
    producer_build_sha256: str


def image_digest_from_reference(reference: str) -> str:
    match = PINNED_IMAGE_PATTERN.fullmatch(reference)
    if not match:
        raise ValueError("map stream worker image must use an immutable OCI digest")
    return match.group(1)


def producer_build_sha256(
    inputs: Iterable[tuple[str, Path]],
    *,
    dependency_inventory: bytes,
    system_package_inventory: bytes,
    platform_inventory: bytes,
) -> str:
    """Hash the worker component from build-owned inputs, never caller labels."""
    digest = hashlib.sha256()
    seen_names: set[str] = set()
    for logical_name, path in sorted(inputs, key=lambda value: value[0]):
        if logical_name in seen_names or not logical_name or "\0" in logical_name:
            raise ValueError("map stream build input names must be unique and non-empty")
        seen_names.add(logical_name)
        if not path.is_file():
            raise ValueError(f"map stream build input is not a file: {logical_name}")
        data = path.read_bytes()
        encoded_name = logical_name.encode("utf-8")
        digest.update(b"file\0")
        digest.update(len(encoded_name).to_bytes(8, "big"))
        digest.update(encoded_name)
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)
    if not seen_names:
        raise ValueError("map stream build identity requires source inputs")
    for label, inventory in (
        (b"python-dependencies", dependency_inventory),
        (b"system-packages", system_package_inventory),
        (b"native-platform", platform_inventory),
    ):
        if not inventory:
            raise ValueError("map stream build identity requires dependency inventories")
        digest.update(b"inventory\0")
        digest.update(label)
        digest.update(b"\0")
        digest.update(len(inventory).to_bytes(8, "big"))
        digest.update(inventory)
    return digest.hexdigest()


def worker_source_inputs(repo_root: Path) -> list[tuple[str, Path]]:
    inputs: list[tuple[str, Path]] = []
    for relative_root in WORKER_SOURCE_ROOTS:
        path = repo_root / relative_root
        if path.is_file():
            inputs.append((relative_root, path))
            continue
        if not path.is_dir():
            raise ValueError(f"missing worker source input: {relative_root}")
        for child in sorted(path.rglob("*")):
            if child.is_file() and "__pycache__" not in child.parts and child.suffix != ".pyc":
                inputs.append((child.relative_to(repo_root).as_posix(), child))
    return inputs


def command_inventory(command: list[str]) -> bytes:
    completed = subprocess.run(
        command,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    lines = completed.stdout.decode("utf-8").splitlines()
    return ("\n".join(sorted(line for line in lines if line)) + "\n").encode("utf-8")


def native_platform_inventory() -> bytes:
    values = {
        "byteorder": sys.byteorder,
        "machine": platform.machine(),
        "platform": sysconfig.get_platform(),
        "pythonImplementation": platform.python_implementation(),
        "pythonVersion": platform.python_version(),
        "system": platform.system(),
    }
    try:
        values["debianArchitecture"] = subprocess.check_output(
            ["dpkg", "--print-architecture"],
            stderr=subprocess.PIPE,
            text=True,
        ).strip()
    except (OSError, subprocess.CalledProcessError) as exc:
        raise ValueError("worker build identity requires native architecture") from exc
    if not values["machine"] or not values["platform"] or not values["debianArchitecture"]:
        raise ValueError("worker build identity requires native architecture")
    return (json.dumps(values, sort_keys=True, separators=(",", ":")) + "\n").encode(
        "utf-8"
    )


def derive_producer_build_sha256(repo_root: Path) -> str:
    return producer_build_sha256(
        worker_source_inputs(repo_root.resolve()),
        dependency_inventory=command_inventory(
            [sys.executable, "-m", "pip", "freeze", "--all"]
        ),
        system_package_inventory=command_inventory(
            ["dpkg-query", "-W", "-f=${Package}:${Architecture}=${Version}\\n"]
        ),
        platform_inventory=native_platform_inventory(),
    )


def load_map_stream_build_identity(path: Path) -> MapStreamBuildIdentity:
    document = load_strict_json(
        path,
        description="map stream build identity",
    )
    if not isinstance(document, dict) or set(document) != {
        "schemaVersion",
        "producerBuildSha256",
    }:
        raise ValueError("map stream build identity has invalid fields")
    build_sha256 = document["producerBuildSha256"]
    if (
        type(document["schemaVersion"]) is not int
        or document["schemaVersion"] != 1
        or not isinstance(build_sha256, str)
        or not SHA256_PATTERN.fullmatch(build_sha256)
    ):
        raise ValueError("map stream build identity is invalid")
    return MapStreamBuildIdentity(producer_build_sha256=build_sha256)


def require_hashed_worker_runtime(
    repo_root: Path,
    runtime_package_root: Path,
) -> None:
    expected_root = (
        repo_root / "map-platform" / "backend" / "map_platform"
    ).resolve()
    if runtime_package_root.resolve() != expected_root:
        raise ValueError(
            "map stream worker runtime is not executing from the hashed source tree"
        )


def verify_map_stream_build_identity(path: Path, repo_root: Path) -> MapStreamBuildIdentity:
    require_hashed_worker_runtime(repo_root, Path(__file__).resolve().parent)
    identity = load_map_stream_build_identity(path)
    if identity.producer_build_sha256 != derive_producer_build_sha256(repo_root):
        raise ValueError("map stream build identity does not match the running worker")
    return identity
