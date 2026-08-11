"""Strict, stdlib-only firmware host-runtime selection and verification."""

from __future__ import annotations

import hashlib
import json
import os
import platform
import re
import shutil
import stat
import sys
import tarfile
import tempfile
import time
import unicodedata
import urllib.request
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Callable, Mapping, Sequence


LOCK_SCHEMA = 1
INVENTORY_SCHEMA = 1
HANDOFF_ENV = "OPEN_BIKE_FIRMWARE_RUNTIME_HANDOFF"
PROVENANCE_ENV = "OPEN_BIKE_FIRMWARE_RUNTIME_PROVENANCE"
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
TARGET_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_-]{2,63}$")
LOCK_ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9.-]{2,63}$")
PRE_EXECUTION_INJECTION_ENV = {
    "PYTHONEXECUTABLE",
    "PYTHONHOME",
    "PYTHONINSPECT",
    "PYTHONPATH",
    "PYTHONPLATLIBDIR",
    "PYTHONSTARTUP",
    "PYTHONUSERBASE",
    "PYTHONWARNINGS",
}
SUPPORTED_TARGET_SHAPES = {
    "linux-x86_64-cp313": (
        "linux", "x86_64", "cp313", "manylinux_2_34_x86_64"
    ),
    "macos-arm64-cp313": (
        "macos", "arm64", "cp313", "macosx_11_0_arm64"
    ),
}


class FirmwareRuntimeError(RuntimeError):
    """Raised when the locked host runtime cannot be trusted."""


@dataclass(frozen=True)
class Artifact:
    url: str
    size: int
    sha256: str


@dataclass(frozen=True)
class SourceRepository:
    url: str
    commit: str


@dataclass(frozen=True)
class PythonArtifact(Artifact):
    license: str
    source: Artifact
    builder: SourceRepository


@dataclass(frozen=True)
class WheelArtifact:
    filename: str
    normalized_name: str
    version: str
    tags: tuple[str, ...]
    size: int
    sha256: str
    source_url: str
    source_sha256: str
    group: str


@dataclass(frozen=True)
class DistributionSet:
    sha256: str
    wheels: tuple[str, ...]


@dataclass(frozen=True)
class RuntimeContents:
    platformio_version: str
    wheels: tuple[WheelArtifact, ...]
    distribution_sets: Mapping[str, DistributionSet]
    platform_archive_sha256: str
    platform_packages_sha256: str


@dataclass(frozen=True)
class RuntimeTarget:
    target_id: str
    os_name: str
    architecture: str
    python_version: str
    abi: str
    minimum_platform_tag: str
    accepted: bool
    python: PythonArtifact
    bundle: Artifact | None
    contents: RuntimeContents | None


@dataclass(frozen=True)
class RuntimeLock:
    path: Path
    lock_set_id: str
    manifest_sha256: str
    targets: tuple[RuntimeTarget, ...]


@dataclass(frozen=True)
class RuntimePaths:
    root: Path
    python: Path
    pio: Path
    uv: Path
    wheelhouse: Path


@dataclass(frozen=True)
class RuntimeProvenance:
    lock_set_id: str
    manifest_sha256: str
    target: str
    bundle_sha256: str
    python_version: str
    python_executable_sha256: str
    tree_sha256: str
    pio_sha256: str
    uv_sha256: str
    platformio_version: str
    top_level_distribution_sha256: str
    pioarduino_root_distribution_sha256: str
    esp_idf_distribution_sha256: str
    uv_distribution_sha256: str
    esptool_distribution_sha256: str
    platform_archive_sha256: str
    platform_packages_sha256: str

    def as_json(self) -> dict[str, str]:
        return {
            "lockSetId": self.lock_set_id,
            "manifestSha256": self.manifest_sha256,
            "target": self.target,
            "bundleSha256": self.bundle_sha256,
            "pythonVersion": self.python_version,
            "pythonExecutableSha256": self.python_executable_sha256,
            "runtimeTreeSha256": self.tree_sha256,
            "pioSha256": self.pio_sha256,
            "uvSha256": self.uv_sha256,
            "platformioVersion": self.platformio_version,
            "topLevelDistributionSha256": self.top_level_distribution_sha256,
            "pioarduinoRootDistributionSha256": self.pioarduino_root_distribution_sha256,
            "espIdfDistributionSha256": self.esp_idf_distribution_sha256,
            "uvDistributionSha256": self.uv_distribution_sha256,
            "esptoolDistributionSha256": self.esptool_distribution_sha256,
            "platformArchiveSha256": self.platform_archive_sha256,
            "platformPackagesSha256": self.platform_packages_sha256,
        }


def _duplicate_key_rejector(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            raise FirmwareRuntimeError(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def _canonical_json(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _strict_object(value: object, required: set[str], optional: set[str], label: str) -> dict[str, object]:
    if not isinstance(value, dict):
        raise FirmwareRuntimeError(f"{label} must be an object")
    keys = set(value)
    if not required <= keys or keys - required - optional:
        raise FirmwareRuntimeError(f"{label} has missing or unexpected fields")
    return value


def _artifact(value: object, label: str) -> Artifact:
    item = _strict_object(value, {"url", "size", "sha256"}, set(), label)
    url, size, digest = item["url"], item["size"], item["sha256"]
    if not isinstance(url, str) or not url.startswith("https://") or len(url) > 4096:
        raise FirmwareRuntimeError(f"{label} URL must be an exact HTTPS URL")
    if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
        raise FirmwareRuntimeError(f"{label} size must be positive")
    if not isinstance(digest, str) or SHA256_PATTERN.fullmatch(digest) is None:
        raise FirmwareRuntimeError(f"{label} SHA-256 is invalid")
    return Artifact(url, size, digest)


def _python_artifact(value: object, label: str) -> PythonArtifact:
    item = _strict_object(
        value,
        {"url", "size", "sha256", "license", "source", "builder"},
        set(),
        label,
    )
    archive = _artifact(
        {key: item[key] for key in ("url", "size", "sha256")}, label
    )
    license_expression = item["license"]
    if license_expression != "Python-2.0":
        raise FirmwareRuntimeError(f"{label} license must be Python-2.0")
    source = _artifact(item["source"], f"{label} source")
    builder = _strict_object(
        item["builder"], {"url", "commit"}, set(), f"{label} builder"
    )
    builder_url, builder_commit = builder["url"], builder["commit"]
    if (
        not isinstance(builder_url, str)
        or builder_url != "https://github.com/astral-sh/python-build-standalone"
        or not isinstance(builder_commit, str)
        or re.fullmatch(r"[0-9a-f]{40}", builder_commit) is None
    ):
        raise FirmwareRuntimeError(f"{label} builder provenance is invalid")
    return PythonArtifact(
        archive.url,
        archive.size,
        archive.sha256,
        license_expression,
        source,
        SourceRepository(builder_url, builder_commit),
    )


def _expanded_filename_tags(filename: str) -> set[str]:
    try:
        _, python_tags, abi_tags, platform_tags = filename[:-4].rsplit("-", 3)
    except ValueError as error:
        raise FirmwareRuntimeError("runtime wheel filename has no exact tags") from error
    return {
        f"{python_tag}-{abi_tag}-{platform_tag}"
        for python_tag in python_tags.split(".")
        for abi_tag in abi_tags.split(".")
        for platform_tag in platform_tags.split(".")
    }


def _wheel_tag_matches_target(
    tag: str, target_id: str, minimum_platform_tag: str
) -> bool:
    try:
        python_tag, abi_tag, platform_tag = tag.split("-", 2)
    except ValueError:
        return False
    if python_tag == "py3":
        python_compatible = abi_tag == "none"
    else:
        match = re.fullmatch(r"cp3(\d+)", python_tag)
        python_compatible = bool(
            match
            and (
                abi_tag == "cp313"
                and python_tag == "cp313"
                or abi_tag == "abi3"
                and int(match.group(1)) <= 13
            )
        )
    if not python_compatible:
        return False
    if platform_tag == "any":
        return abi_tag == "none"
    if target_id == "macos-arm64-cp313":
        minimum = re.fullmatch(r"macosx_(\d+)_(\d+)_arm64", minimum_platform_tag)
        candidate = re.fullmatch(
            r"macosx_(\d+)_(\d+)_(?:arm64|universal2)", platform_tag
        )
    else:
        minimum = re.fullmatch(
            r"manylinux_(\d+)_(\d+)_x86_64", minimum_platform_tag
        )
        candidate = re.fullmatch(
            r"manylinux_(\d+)_(\d+)_x86_64", platform_tag
        )
        if platform_tag == "manylinux2014_x86_64":
            candidate = re.fullmatch(
                r"manylinux_(\d+)_(\d+)_x86_64", "manylinux_2_17_x86_64"
            )
    return bool(
        minimum
        and candidate
        and (int(candidate.group(1)), int(candidate.group(2)))
        <= (int(minimum.group(1)), int(minimum.group(2)))
    )


def _runtime_contents(
    value: object, label: str, target_id: str, minimum_platform_tag: str
) -> RuntimeContents:
    root = _strict_object(
        value,
        {"platformioVersion", "wheels", "distributionSets", "platform"},
        set(),
        label,
    )
    version = root["platformioVersion"]
    if (
        not isinstance(version, str)
        or not version
        or any(character in version for character in "<>=~,* ")
    ):
        raise FirmwareRuntimeError(f"{label} PlatformIO version is not exact")
    raw_wheels = root["wheels"]
    if not isinstance(raw_wheels, list) or not raw_wheels:
        raise FirmwareRuntimeError(f"{label} must contain exact wheels")
    wheels: list[WheelArtifact] = []
    filenames: set[str] = set()
    normalized_versions: set[tuple[str, str]] = set()
    groups = {"top-level", "pioarduino-root", "esp-idf", "uv", "esptool"}
    for index, raw_wheel in enumerate(raw_wheels):
        wheel = _strict_object(
            raw_wheel,
            {
                "filename", "normalizedName", "version", "tags", "size",
                "sha256", "sourceUrl", "sourceSha256", "group",
            },
            set(),
            f"{label} wheel {index}",
        )
        filename = wheel["filename"]
        normalized_name = wheel["normalizedName"]
        wheel_version = wheel["version"]
        tags = wheel["tags"]
        group = wheel["group"]
        if (
            not isinstance(filename, str)
            or PurePosixPath(filename).name != filename
            or not filename.endswith(".whl")
            or filename in filenames
            or not isinstance(normalized_name, str)
            or re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", normalized_name) is None
            or not isinstance(wheel_version, str)
            or not wheel_version
            or any(character in wheel_version for character in "<>=~,* ")
            or (normalized_name, wheel_version) in normalized_versions
            or not isinstance(tags, list)
            or not tags
            or not all(isinstance(tag, str) and re.fullmatch(r"[A-Za-z0-9_.-]+", tag) for tag in tags)
            or not isinstance(group, str)
            or group not in groups
        ):
            raise FirmwareRuntimeError(f"{label} wheel {index} identity is invalid")
        if set(tags) != _expanded_filename_tags(filename):
            raise FirmwareRuntimeError(
                f"{label} wheel {index} tags disagree with its filename"
            )
        if not any(
            _wheel_tag_matches_target(tag, target_id, minimum_platform_tag)
            for tag in tags
        ):
            raise FirmwareRuntimeError(
                f"{label} wheel {index} is incompatible with {target_id}"
            )
        size, digest = wheel["size"], wheel["sha256"]
        source_url, source_digest = wheel["sourceUrl"], wheel["sourceSha256"]
        if (
            not isinstance(size, int) or isinstance(size, bool) or size <= 0
            or not isinstance(digest, str) or SHA256_PATTERN.fullmatch(digest) is None
            or not isinstance(source_url, str) or not source_url.startswith("https://")
            or not isinstance(source_digest, str) or SHA256_PATTERN.fullmatch(source_digest) is None
        ):
            raise FirmwareRuntimeError(f"{label} wheel {index} artifact is invalid")
        filenames.add(filename)
        normalized_versions.add((normalized_name, wheel_version))
        wheels.append(WheelArtifact(
            filename, normalized_name, wheel_version, tuple(tags), size, digest,
            source_url, source_digest, group,
        ))

    required_sets = {"topLevel", "pioarduinoRoot", "espIdf", "uv", "esptool"}
    raw_sets = _strict_object(
        root["distributionSets"], required_sets, set(), f"{label} distribution sets"
    )
    distribution_sets: dict[str, DistributionSet] = {}
    covered: set[str] = set()
    for name in sorted(required_sets):
        raw_set = _strict_object(
            raw_sets[name], {"sha256", "wheels"}, set(), f"{label} {name} set"
        )
        digest, members = raw_set["sha256"], raw_set["wheels"]
        if (
            not isinstance(digest, str) or SHA256_PATTERN.fullmatch(digest) is None
            or not isinstance(members, list) or not members
            or not all(isinstance(member, str) for member in members)
            or len(set(members)) != len(members)
            or not set(members) <= filenames
        ):
            raise FirmwareRuntimeError(f"{label} {name} distribution set is invalid")
        expected_digest = _sha256_bytes(_canonical_json(sorted(members)))
        if digest != expected_digest:
            raise FirmwareRuntimeError(f"{label} {name} distribution digest is invalid")
        covered.update(members)
        distribution_sets[name] = DistributionSet(digest, tuple(members))
    if covered != filenames:
        raise FirmwareRuntimeError(f"{label} has wheels outside its distribution sets")

    platform_value = _strict_object(
        root["platform"], {"archiveSha256", "packagesSha256"}, set(), f"{label} platform"
    )
    archive_sha = platform_value["archiveSha256"]
    packages_sha = platform_value["packagesSha256"]
    if (
        not isinstance(archive_sha, str) or SHA256_PATTERN.fullmatch(archive_sha) is None
        or not isinstance(packages_sha, str) or SHA256_PATTERN.fullmatch(packages_sha) is None
    ):
        raise FirmwareRuntimeError(f"{label} platform identity is invalid")
    return RuntimeContents(
        version, tuple(wheels), distribution_sets, archive_sha, packages_sha
    )


def load_lock(path: Path) -> RuntimeLock:
    if path.is_symlink() or not path.is_file():
        raise FirmwareRuntimeError(f"runtime lock is missing or unsafe: {path}")
    try:
        raw = path.read_bytes()
        value = json.loads(raw, object_pairs_hook=_duplicate_key_rejector)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise FirmwareRuntimeError(f"could not parse runtime lock: {error}") from error
    if raw != _canonical_json(value):
        raise FirmwareRuntimeError("runtime lock is not canonical UTF-8 JSON")
    root = _strict_object(value, {"schema", "lockSetId", "generator", "targets"}, set(), "runtime lock")
    if root["schema"] != LOCK_SCHEMA or isinstance(root["schema"], bool):
        raise FirmwareRuntimeError("unsupported runtime lock schema")
    lock_id = root["lockSetId"]
    if not isinstance(lock_id, str) or LOCK_ID_PATTERN.fullmatch(lock_id) is None:
        raise FirmwareRuntimeError("runtime lock-set ID is invalid")
    generator = _strict_object(root["generator"], {"version", "commit", "refreshInputsSha256", "licensesSha256"}, set(), "generator")
    if (
        not isinstance(generator["version"], str)
        or not isinstance(generator["commit"], str)
        or re.fullmatch(r"[0-9a-f]{40}", generator["commit"]) is None
        or not isinstance(generator["refreshInputsSha256"], str)
        or SHA256_PATTERN.fullmatch(generator["refreshInputsSha256"]) is None
        or not isinstance(generator["licensesSha256"], str)
        or SHA256_PATTERN.fullmatch(generator["licensesSha256"]) is None
    ):
        raise FirmwareRuntimeError("runtime lock generator identity is invalid")
    targets_value = root["targets"]
    if not isinstance(targets_value, list) or not targets_value:
        raise FirmwareRuntimeError("runtime lock must contain targets")
    targets: list[RuntimeTarget] = []
    seen: set[str] = set()
    for index, raw_target in enumerate(targets_value):
        target = _strict_object(
            raw_target,
            {"id", "os", "architecture", "pythonVersion", "abi", "minimumPlatformTag", "accepted", "python", "bundle", "contents"},
            set(), f"target {index}",
        )
        strings = {key: target[key] for key in ("id", "os", "architecture", "pythonVersion", "abi", "minimumPlatformTag")}
        if not all(isinstance(item, str) and item for item in strings.values()):
            raise FirmwareRuntimeError(f"target {index} has invalid string fields")
        target_id = strings["id"]
        if TARGET_PATTERN.fullmatch(target_id) is None or target_id in seen:
            raise FirmwareRuntimeError(f"target {index} ID is invalid or duplicate")
        expected_shape = SUPPORTED_TARGET_SHAPES.get(target_id)
        actual_shape = (
            strings["os"], strings["architecture"], strings["abi"],
            strings["minimumPlatformTag"],
        )
        if expected_shape is None or actual_shape != expected_shape:
            raise FirmwareRuntimeError(
                f"target {index} OS, architecture, ABI, or platform tag is invalid"
            )
        if re.fullmatch(r"3\.13\.\d+", strings["pythonVersion"]) is None:
            raise FirmwareRuntimeError(f"target {index} Python version is not CPython 3.13")
        seen.add(target_id)
        accepted = target["accepted"]
        if not isinstance(accepted, bool):
            raise FirmwareRuntimeError(f"target {index} accepted must be boolean")
        python_artifact = _python_artifact(
            target["python"], f"target {index} Python"
        )
        bundle_value = target["bundle"]
        bundle = None if bundle_value is None else _artifact(bundle_value, f"target {index} bundle")
        contents_value = target["contents"]
        contents = None if contents_value is None else _runtime_contents(
            contents_value,
            f"target {index} contents",
            target_id,
            strings["minimumPlatformTag"],
        )
        if accepted and (bundle is None or contents is None):
            raise FirmwareRuntimeError(f"accepted target {target_id} has no bundle or content contract")
        if not accepted and (bundle is not None or contents is not None):
            raise FirmwareRuntimeError(f"unaccepted target {target_id} must not advertise runtime contents")
        targets.append(RuntimeTarget(target_id, strings["os"], strings["architecture"], strings["pythonVersion"], strings["abi"], strings["minimumPlatformTag"], accepted, python_artifact, bundle, contents))
    return RuntimeLock(path.resolve(), lock_id, _sha256_bytes(raw), tuple(targets))


def host_target_id(*, system: str | None = None, machine: str | None = None) -> str:
    system = (system or platform.system()).lower()
    machine = (machine or platform.machine()).lower()
    aliases = {"darwin": "macos", "linux": "linux", "arm64": "arm64", "aarch64": "arm64", "x86_64": "x86_64", "amd64": "x86_64"}
    os_name, architecture = aliases.get(system), aliases.get(machine)
    if os_name is None or architecture is None:
        return f"unsupported-{system}-{machine}"
    return f"{os_name}-{architecture}-cp313"


def select_target(lock: RuntimeLock, target_id: str | None = None) -> RuntimeTarget:
    requested = target_id or host_target_id()
    matches = [target for target in lock.targets if target.target_id == requested]
    if len(matches) != 1:
        supported = ", ".join(target.target_id for target in lock.targets)
        raise FirmwareRuntimeError(f"unsupported firmware runtime target {requested}; supported targets: {supported}")
    target = matches[0]
    if not target.accepted or target.bundle is None:
        raise FirmwareRuntimeError(
            f"firmware runtime target {requested} has no accepted bundle; run the maintainer refresh workflow and review its offline evidence"
        )
    if target_id is None and target.target_id == "linux-x86_64-cp313":
        libc_name, libc_version = platform.libc_ver()
        match = re.fullmatch(r"(\d+)\.(\d+)(?:\.\d+)?", libc_version)
        if (
            libc_name.lower() != "glibc"
            or match is None
            or (int(match.group(1)), int(match.group(2))) < (2, 34)
        ):
            observed = f"{libc_name or 'unknown'} {libc_version or 'unknown'}"
            raise FirmwareRuntimeError(
                "unsupported firmware runtime host C library "
                f"{observed}; linux-x86_64-cp313 requires glibc 2.34 or newer"
            )
    return target


def default_cache_root() -> Path:
    override = os.environ.get("OPEN_BIKE_FIRMWARE_RUNTIME_CACHE")
    if override:
        return Path(override).expanduser()
    if sys.platform == "darwin":
        return Path.home() / "Library/Caches/OpenBikeComputer/firmware-runtime"
    cache_home = os.environ.get("XDG_CACHE_HOME")
    return (Path(cache_home) if cache_home else Path.home() / ".cache") / "open-bike-computer/firmware-runtime"


def _require_current_owner(path: Path, label: str) -> None:
    if hasattr(os, "getuid") and path.lstat().st_uid != os.getuid():
        raise FirmwareRuntimeError(f"{label} has the wrong owner: {path}")


def _safe_subtree(root: Path, parts: Sequence[str], *, create: bool = False) -> Path:
    root = root.expanduser()
    if not root.is_absolute():
        raise FirmwareRuntimeError("runtime cache root must be absolute")
    current = Path(root.anchor)
    for component in root.parts[1:]:
        current /= component
        if os.path.lexists(current):
            info = current.lstat()
            if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
                label = "root" if current == root else "ancestor"
                raise FirmwareRuntimeError(
                    f"unsafe runtime cache {label}: {current}"
                )
        elif create:
            try:
                current.mkdir(mode=0o700)
            except FileExistsError:
                pass
            info = current.lstat()
            if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
                label = "root" if current == root else "ancestor"
                raise FirmwareRuntimeError(
                    f"unsafe runtime cache {label}: {current}"
                )
        else:
            # A descendant cannot exist below the first missing component.
            current = root
            break
    if os.path.lexists(root):
        _require_current_owner(root, "runtime cache root")
    for part in parts:
        if part in {"", ".", ".."} or "/" in part or "\\" in part:
            raise FirmwareRuntimeError("unsafe runtime cache path component")
        current /= part
        if os.path.lexists(current):
            if current.is_symlink() or not current.is_dir():
                raise FirmwareRuntimeError(f"unsafe runtime cache directory: {current}")
            _require_current_owner(current, "runtime cache directory")
        elif create:
            current.mkdir(mode=0o700)
            _require_current_owner(current, "runtime cache directory")
    return current


def _safe_project_subtree(
    project_dir: Path, parts: Sequence[str], *, create: bool
) -> Path:
    current = project_dir.resolve()
    if not current.is_dir():
        raise FirmwareRuntimeError("firmware project directory is missing")
    _require_current_owner(current, "firmware project directory")
    for part in parts:
        if part in {"", ".", ".."} or "/" in part or "\\" in part:
            raise FirmwareRuntimeError("unsafe project-private runtime path component")
        current /= part
        if os.path.lexists(current):
            if current.is_symlink() or not current.is_dir():
                raise FirmwareRuntimeError(
                    f"unsafe project-private runtime directory: {current}"
                )
            _require_current_owner(current, "project-private runtime directory")
        elif create:
            current.mkdir(mode=0o700)
            _require_current_owner(current, "project-private runtime directory")
    return current


def download_verified(artifact: Artifact, destination: Path, *, opener: Callable[..., object] = urllib.request.urlopen) -> None:
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary: str | None = None
    digest = hashlib.sha256()
    total = 0
    try:
        descriptor, temporary = tempfile.mkstemp(prefix=f".{destination.name}.", dir=destination.parent)
        with os.fdopen(descriptor, "wb") as output, opener(artifact.url, timeout=60) as response:
            while True:
                chunk = response.read(min(1024 * 1024, artifact.size + 1 - total))
                if not chunk:
                    break
                total += len(chunk)
                if total > artifact.size:
                    raise FirmwareRuntimeError("runtime download exceeded its locked size")
                digest.update(chunk)
                output.write(chunk)
            output.flush()
            os.fsync(output.fileno())
        if total != artifact.size or digest.hexdigest() != artifact.sha256:
            raise FirmwareRuntimeError("runtime download size or SHA-256 did not match the lock")
        os.replace(temporary, destination)
        temporary = None
    except OSError as error:
        raise FirmwareRuntimeError(f"could not obtain locked runtime bundle: {error}") from error
    finally:
        if temporary is not None:
            try:
                Path(temporary).unlink()
            except OSError:
                pass


def _safe_member_path(name: str) -> PurePosixPath:
    if not name or "\\" in name or unicodedata.normalize("NFC", name) != name:
        raise FirmwareRuntimeError("runtime bundle contains an invalid or noncanonical path")
    path = PurePosixPath(name)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        raise FirmwareRuntimeError("runtime bundle contains path traversal")
    return path


def _load_inventory(archive: tarfile.TarFile) -> dict[str, dict[str, object]]:
    matches = [member for member in archive.getmembers() if member.name == "inventory.json"]
    if len(matches) != 1 or not matches[0].isreg() or matches[0].size > 16 * 1024 * 1024:
        raise FirmwareRuntimeError("runtime bundle has no unique safe inventory")
    stream = archive.extractfile(matches[0])
    if stream is None:
        raise FirmwareRuntimeError("runtime bundle inventory could not be read")
    raw = stream.read(matches[0].size + 1)
    try:
        value = json.loads(raw, object_pairs_hook=_duplicate_key_rejector)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise FirmwareRuntimeError("runtime bundle inventory is invalid") from error
    if raw != _canonical_json(value):
        raise FirmwareRuntimeError("runtime bundle inventory is not canonical")
    root = _strict_object(value, {"schema", "files"}, set(), "runtime inventory")
    if root["schema"] != INVENTORY_SCHEMA:
        raise FirmwareRuntimeError("unsupported runtime inventory schema")
    files = root["files"]
    if not isinstance(files, list) or not files:
        raise FirmwareRuntimeError("runtime inventory must list files")
    result: dict[str, dict[str, object]] = {}
    casefolded: dict[str, str] = {}
    for item in files:
        entry = _strict_object(item, {"path", "size", "sha256", "executable"}, set(), "inventory file")
        name, size, digest, executable = entry["path"], entry["size"], entry["sha256"], entry["executable"]
        if not isinstance(name, str):
            raise FirmwareRuntimeError("inventory path must be a string")
        normalized = str(_safe_member_path(name))
        collision = casefolded.get(normalized.casefold())
        if normalized == "inventory.json" or normalized in result or collision is not None:
            detail = collision or normalized
            raise FirmwareRuntimeError(
                "runtime inventory contains duplicate or case-colliding paths: "
                f"{detail!r} and {normalized!r}"
            )
        if normalized.lower().endswith((".zip", ".tar", ".tar.gz", ".tgz", ".tar.xz")):
            raise FirmwareRuntimeError("runtime inventory contains a nested archive")
        if not isinstance(size, int) or isinstance(size, bool) or size < 0 or not isinstance(digest, str) or SHA256_PATTERN.fullmatch(digest) is None or not isinstance(executable, bool):
            raise FirmwareRuntimeError("runtime inventory file metadata is invalid")
        result[normalized] = entry
        casefolded[normalized.casefold()] = normalized
    return result


def extract_verified_bundle(bundle: Path, destination: Path) -> None:
    if bundle.is_symlink() or not bundle.is_file():
        raise FirmwareRuntimeError("locked runtime bundle is missing or unsafe")
    try:
        archive = tarfile.open(bundle, mode="r:gz")
    except (OSError, tarfile.TarError) as error:
        raise FirmwareRuntimeError(f"could not open runtime bundle: {error}") from error
    with archive:
        inventory = _load_inventory(archive)
        members: dict[str, tarfile.TarInfo] = {}
        casefolded: dict[str, str] = {}
        for member in archive.getmembers():
            name = str(_safe_member_path(member.name))
            collision = casefolded.get(name.casefold())
            if name in members or collision is not None:
                detail = collision or name
                raise FirmwareRuntimeError(
                    "runtime bundle contains duplicate or case-colliding paths: "
                    f"{detail!r} and {name!r}"
                )
            members[name] = member
            casefolded[name.casefold()] = name
            if name == "inventory.json":
                continue
            if not member.isfile():
                raise FirmwareRuntimeError(
                    "runtime bundle contains a link, directory, or special file"
                )
        archive_files = {name for name, member in members.items() if member.isfile() and name != "inventory.json"}
        if archive_files != set(inventory):
            raise FirmwareRuntimeError("runtime bundle files do not exactly match inventory")
        destination.mkdir(mode=0o700)
        for name in sorted(inventory):
            member = members[name]
            entry = inventory[name]
            if member.size != entry["size"]:
                raise FirmwareRuntimeError(f"runtime member size mismatch: {name}")
            output_path = destination.joinpath(*PurePosixPath(name).parts)
            output_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            stream = archive.extractfile(member)
            if stream is None:
                raise FirmwareRuntimeError(f"runtime member could not be read: {name}")
            digest = hashlib.sha256()
            total = 0
            with output_path.open("xb") as output:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    total += len(chunk)
                    if total > member.size:
                        raise FirmwareRuntimeError(f"runtime member exceeded size: {name}")
                    digest.update(chunk)
                    output.write(chunk)
            if total != member.size or digest.hexdigest() != entry["sha256"]:
                raise FirmwareRuntimeError(f"runtime member digest mismatch: {name}")
            output_path.chmod(0o555 if entry["executable"] else 0o444)
        (destination / "inventory.json").write_bytes(_canonical_json({"schema": INVENTORY_SCHEMA, "files": [inventory[name] for name in sorted(inventory)]}))
        (destination / "inventory.json").chmod(0o444)


def _runtime_paths(root: Path) -> RuntimePaths:
    return RuntimePaths(
        root,
        root / "python/bin/python3",
        root / "bin/pio",
        # pioarduino derives the external uv executable from PYTHONEXE's
        # directory and passes that exact path back to its dependency setup.
        # Select the content-pinned executable installed beside CPython, not
        # the convenience shell wrapper in bin/, so the strict path identity
        # check cannot fall through to an ambient uv.
        root / "python/bin/uv",
        root / "wheelhouse",
    )


def _verify_runtime_tree(
    root: Path, target: RuntimeTarget, *, require_read_only: bool = False
) -> RuntimeProvenance:
    inventory_path = root / "inventory.json"
    if root.is_symlink() or not root.is_dir() or inventory_path.is_symlink() or not inventory_path.is_file():
        raise FirmwareRuntimeError("accepted runtime tree is missing or unsafe")
    _require_current_owner(root, "accepted runtime root")
    try:
        value = json.loads(inventory_path.read_bytes(), object_pairs_hook=_duplicate_key_rejector)
    except (OSError, json.JSONDecodeError) as error:
        raise FirmwareRuntimeError("accepted runtime inventory is invalid") from error
    if inventory_path.read_bytes() != _canonical_json(value):
        raise FirmwareRuntimeError("accepted runtime inventory changed")
    if stat.S_IMODE(inventory_path.stat().st_mode) != 0o444:
        raise FirmwareRuntimeError("accepted runtime inventory permissions changed")
    files = _strict_object(value, {"schema", "files"}, set(), "runtime inventory")["files"]
    if not isinstance(files, list):
        raise FirmwareRuntimeError("accepted runtime inventory is invalid")
    expected: dict[str, dict[str, object]] = {}
    casefolded: set[str] = set()
    for item in files:
        entry = _strict_object(item, {"path", "size", "sha256", "executable"}, set(), "inventory file")
        if not isinstance(entry["path"], str):
            raise FirmwareRuntimeError("accepted runtime path is invalid")
        name = str(_safe_member_path(entry["path"]))
        if name in expected or name.casefold() in casefolded:
            raise FirmwareRuntimeError("accepted runtime inventory has duplicate paths")
        expected[name] = entry
        casefolded.add(name.casefold())
    actual_files: set[str] = set()
    actual_directories: set[str] = set()
    for path in root.rglob("*"):
        info = path.lstat()
        if (
            path.is_symlink()
            or (not path.is_file() and not path.is_dir())
            or (path.is_file() and info.st_nlink != 1)
        ):
            raise FirmwareRuntimeError("accepted runtime contains a link or special file")
        _require_current_owner(path, "accepted runtime member")
        if path.is_file() and path != inventory_path:
            actual_files.add(path.relative_to(root).as_posix())
        elif path.is_dir():
            actual_directories.add(path.relative_to(root).as_posix())
    if actual_files != set(expected):
        raise FirmwareRuntimeError("accepted runtime tree has missing or extra files")
    expected_directories = {
        parent.as_posix()
        for name in expected
        for parent in PurePosixPath(name).parents
        if parent.as_posix() != "."
    }
    if actual_directories != expected_directories:
        raise FirmwareRuntimeError("accepted runtime tree has missing or extra directories")
    digest = hashlib.sha256()
    for name in sorted(expected):
        path = root.joinpath(*PurePosixPath(name).parts)
        entry = expected[name]
        if path.stat().st_size != entry["size"] or _file_sha256(path) != entry["sha256"]:
            raise FirmwareRuntimeError(f"accepted runtime member changed: {name}")
        expected_mode = 0o555 if entry["executable"] else 0o444
        if stat.S_IMODE(path.stat().st_mode) != expected_mode:
            raise FirmwareRuntimeError(
                f"accepted runtime member permissions changed: {name}"
            )
        digest.update(name.encode("utf-8") + b"\0" + str(entry["size"]).encode("ascii") + b"\0" + str(entry["sha256"]).encode("ascii") + b"\n")
    if require_read_only:
        if stat.S_IMODE(root.stat().st_mode) != 0o555:
            raise FirmwareRuntimeError("accepted runtime root permissions changed")
        for name in actual_directories:
            directory = root.joinpath(*PurePosixPath(name).parts)
            if stat.S_IMODE(directory.stat().st_mode) != 0o555:
                raise FirmwareRuntimeError(
                    f"accepted runtime directory permissions changed: {name}"
                )
    paths = _runtime_paths(root)
    for executable in (paths.python, paths.pio, paths.uv):
        if executable.is_symlink() or not executable.is_file() or not os.access(executable, os.X_OK):
            raise FirmwareRuntimeError(f"locked runtime executable is missing or unsafe: {executable}")
    wheels = tuple(paths.wheelhouse.glob("*.whl")) if paths.wheelhouse.is_dir() else ()
    if not wheels or any(path.is_symlink() or not path.is_file() for path in wheels):
        raise FirmwareRuntimeError("locked runtime wheelhouse is missing or unsafe")
    if target.bundle is None or target.contents is None:
        raise FirmwareRuntimeError("runtime target has no accepted bundle contract")
    expected_wheels = {wheel.filename: wheel for wheel in target.contents.wheels}
    actual_wheels = {wheel.name: wheel for wheel in wheels}
    if set(actual_wheels) != set(expected_wheels):
        raise FirmwareRuntimeError("locked runtime wheelhouse changed from the lock")
    for name, wheel in expected_wheels.items():
        path = actual_wheels[name]
        if path.stat().st_size != wheel.size or _file_sha256(path) != wheel.sha256:
            raise FirmwareRuntimeError(f"locked runtime wheel changed: {name}")
    sets = target.contents.distribution_sets
    return RuntimeProvenance(
        "", "", target.target_id, target.bundle.sha256, target.python_version,
        _file_sha256(paths.python), digest.hexdigest(), _file_sha256(paths.pio),
        _file_sha256(paths.uv), target.contents.platformio_version,
        sets["topLevel"].sha256, sets["pioarduinoRoot"].sha256,
        sets["espIdf"].sha256, sets["uv"].sha256,
        sets["esptool"].sha256, target.contents.platform_archive_sha256,
        target.contents.platform_packages_sha256,
    )


def _mark_tree_read_only(root: Path) -> None:
    for path in sorted(root.rglob("*"), key=lambda item: len(item.parts), reverse=True):
        if path.is_file():
            path.chmod(0o555 if os.access(path, os.X_OK) else 0o444)
        elif path.is_dir():
            path.chmod(0o555)
    root.chmod(0o555)


def _remove_owned_runtime_tree(root: Path) -> None:
    if root.is_symlink() or not root.is_dir():
        raise FirmwareRuntimeError(f"refusing to remove unsafe runtime tree: {root}")
    _require_current_owner(root, "runtime tree")
    entries = sorted(root.rglob("*"), key=lambda item: len(item.parts))
    if any(
        path.is_symlink()
        or (not path.is_file() and not path.is_dir())
        or (path.is_file() and path.lstat().st_nlink != 1)
        for path in entries
    ):
        raise FirmwareRuntimeError(
            f"refusing to remove runtime tree containing an unsafe entry: {root}"
        )
    for path in entries:
        _require_current_owner(path, "runtime tree member")
    root.chmod(0o700)
    for path in entries:
        path.chmod(0o700 if path.is_dir() else 0o600)
    shutil.rmtree(root)


def ensure_shared_runtime(lock: RuntimeLock, target: RuntimeTarget, *, cache_root: Path | None = None) -> Path:
    if target.bundle is None:
        raise FirmwareRuntimeError("runtime target has no bundle")
    root = cache_root or default_cache_root()
    base = _safe_subtree(root, ("locks", lock.lock_set_id, target.target_id), create=True)
    archive = base / f"{target.bundle.sha256}.tar.gz"
    if os.path.lexists(archive):
        if (
            archive.is_symlink()
            or not archive.is_file()
            or archive.lstat().st_nlink != 1
            or archive.stat().st_size != target.bundle.size
            or _file_sha256(archive) != target.bundle.sha256
        ):
            raise FirmwareRuntimeError("cached runtime bundle is corrupt; use --repair-runtime")
        _require_current_owner(archive, "cached runtime bundle")
    else:
        download_verified(target.bundle, archive)
        _require_current_owner(archive, "cached runtime bundle")
    archive.chmod(0o444)
    if stat.S_IMODE(archive.stat().st_mode) != 0o444:
        raise FirmwareRuntimeError("cached runtime bundle permissions changed")
    accepted = base / target.bundle.sha256
    if os.path.lexists(accepted):
        provenance = _verify_runtime_tree(accepted, target, require_read_only=True)
        if not provenance.tree_sha256:
            raise AssertionError("verified runtime tree has no digest")
        return accepted
    staging = Path(tempfile.mkdtemp(prefix=f".{target.bundle.sha256}.", dir=base))
    published = False
    try:
        staging.rmdir()
        extract_verified_bundle(archive, staging)
        _verify_runtime_tree(staging, target)
        os.replace(staging, accepted)
        published = True
        _mark_tree_read_only(accepted)
        _verify_runtime_tree(accepted, target, require_read_only=True)
    except Exception:
        cleanup = accepted if published else staging
        if cleanup.exists() and not cleanup.is_symlink():
            _remove_owned_runtime_tree(cleanup)
        raise
    return accepted


def repair_runtime(lock: RuntimeLock, target: RuntimeTarget, project_dir: Path, *, cache_root: Path | None = None) -> None:
    if target.bundle is None:
        raise FirmwareRuntimeError("runtime target has no accepted bundle")
    root = cache_root or default_cache_root()
    base = _safe_subtree(root, ("locks", lock.lock_set_id, target.target_id), create=False)
    for candidate in (base / target.bundle.sha256, base / f"{target.bundle.sha256}.tar.gz"):
        if os.path.lexists(candidate):
            if candidate.is_symlink() or candidate.parent != base:
                raise FirmwareRuntimeError(f"refusing unsafe runtime repair target: {candidate}")
            _require_current_owner(candidate, "runtime repair target")
            if candidate.is_dir():
                _remove_owned_runtime_tree(candidate)
            elif candidate.is_file():
                if candidate.lstat().st_nlink != 1:
                    raise FirmwareRuntimeError(
                        f"refusing hard-linked runtime repair target: {candidate}"
                    )
                candidate.unlink()
            else:
                raise FirmwareRuntimeError(f"refusing unsafe runtime repair target: {candidate}")
    root_private = _safe_project_subtree(
        project_dir, (".pio", "open-bike-build", "host-runtime"), create=False
    )
    private = root_private / lock.lock_set_id / target.target_id
    if os.path.lexists(private):
        if private.is_symlink() or not private.is_dir() or root_private.resolve() not in private.resolve().parents:
            raise FirmwareRuntimeError("refusing unsafe private runtime repair target")
        _remove_owned_runtime_tree(private)


def _hydrate_private(shared: Path, project_dir: Path, lock: RuntimeLock, target: RuntimeTarget) -> Path:
    if target.bundle is None:
        raise FirmwareRuntimeError("runtime target has no bundle")
    parent = _safe_project_subtree(
        project_dir,
        (".pio", "open-bike-build", "host-runtime", lock.lock_set_id),
        create=True,
    )
    destination = parent / target.target_id
    if os.path.lexists(destination):
        _verify_runtime_tree(destination, target, require_read_only=True)
        return destination
    staging = Path(tempfile.mkdtemp(prefix=f".{target.target_id}.", dir=parent))
    published = False
    try:
        staging.rmdir()
        shutil.copytree(shared, staging, symlinks=False)
        _verify_runtime_tree(staging, target)
        # copytree preserves the accepted shared root's read-only mode. macOS
        # refuses to rename that directory even though its parent is writable,
        # so restore write permission only on our private staging root. The
        # published tree is locked again immediately after the atomic rename.
        staging.chmod(0o700)
        os.replace(staging, destination)
        published = True
        _mark_tree_read_only(destination)
        _verify_runtime_tree(destination, target, require_read_only=True)
    except Exception:
        cleanup = destination if published else staging
        if cleanup.exists() and not cleanup.is_symlink():
            _remove_owned_runtime_tree(cleanup)
        raise
    return destination


def ensure_runtime_handoff(
    argv: Sequence[str], project_dir: Path, *,
    lock_path: Path | None = None,
    cache_root: Path | None = None,
    execve: Callable[[str, Sequence[str], Mapping[str, str]], object] = os.execve,
) -> RuntimeProvenance:
    bootstrap_start = time.monotonic()
    injection = sorted(
        name
        for name, value in os.environ.items()
        if value
        and (
            name in PRE_EXECUTION_INJECTION_ENV
            or name.startswith("DYLD_")
            or name.startswith("LD_")
        )
    )
    if injection:
        raise FirmwareRuntimeError(
            "pre-execution runtime injection variables are not allowed: "
            + ", ".join(injection)
        )
    lock = load_lock(lock_path or project_dir / "tools/firmware-runtime/lock-v1.json")
    target = select_target(lock)
    if "--repair-runtime" in argv and HANDOFF_ENV not in os.environ:
        repair_runtime(lock, target, project_dir, cache_root=cache_root)
    shared = ensure_shared_runtime(lock, target, cache_root=cache_root)
    private = _hydrate_private(shared, project_dir, lock, target)
    provenance = _verify_runtime_tree(private, target, require_read_only=True)
    provenance = RuntimeProvenance(
        lock.lock_set_id, lock.manifest_sha256, provenance.target,
        provenance.bundle_sha256, provenance.python_version,
        provenance.python_executable_sha256, provenance.tree_sha256,
        provenance.pio_sha256, provenance.uv_sha256,
        provenance.platformio_version,
        provenance.top_level_distribution_sha256,
        provenance.pioarduino_root_distribution_sha256,
        provenance.esp_idf_distribution_sha256,
        provenance.uv_distribution_sha256,
        provenance.esptool_distribution_sha256,
        provenance.platform_archive_sha256,
        provenance.platform_packages_sha256,
    )
    paths = _runtime_paths(private)
    esptool_wheels = tuple(sorted(paths.wheelhouse.glob("esptool-*.whl")))
    if len(esptool_wheels) != 1:
        raise FirmwareRuntimeError(
            "locked runtime must contain exactly one esptool wheel"
        )
    marker = os.environ.get(HANDOFF_ENV)
    expected_marker = _sha256_bytes(_canonical_json(provenance.as_json()))
    if marker == expected_marker:
        if Path(sys.executable).resolve() != paths.python.resolve():
            raise FirmwareRuntimeError("runtime handoff marker does not match the executing Python")
        os.environ[PROVENANCE_ENV] = json.dumps(provenance.as_json(), sort_keys=True, separators=(",", ":"))
        return provenance
    environment = dict(os.environ)
    environment[HANDOFF_ENV] = expected_marker
    environment[PROVENANCE_ENV] = json.dumps(provenance.as_json(), sort_keys=True, separators=(",", ":"))
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    environment["PYTHONNOUSERSITE"] = "1"
    environment["OPEN_BIKE_FIRMWARE_WHEELHOUSE"] = str(paths.wheelhouse)
    environment["OPEN_BIKE_FIRMWARE_UV"] = str(paths.uv)
    environment["OPEN_BIKE_FIRMWARE_ESPTOOL_WHEEL"] = str(esptool_wheels[0])
    requirements = paths.root / "requirements"
    pioarduino_requirements = requirements / "pioarduino-root.txt"
    esp_idf_requirements = requirements / "esp-idf.txt"
    for path in (pioarduino_requirements, esp_idf_requirements):
        if path.is_symlink() or not path.is_file():
            raise FirmwareRuntimeError(
                f"locked runtime requirements are missing or unsafe: {path.name}"
            )
    environment["OPEN_BIKE_FIRMWARE_PIOARDUINO_REQUIREMENTS"] = str(
        pioarduino_requirements
    )
    environment["OPEN_BIKE_FIRMWARE_ESP_IDF_REQUIREMENTS"] = str(
        esp_idf_requirements
    )
    environment["OPEN_BIKE_FIRMWARE_RUNTIME_BOOTSTRAP_MS"] = str(
        max(0, round((time.monotonic() - bootstrap_start) * 1000))
    )
    environment["PATH"] = os.pathsep.join((str(paths.root / "bin"), str(paths.root / "python/bin"), "/usr/bin", "/bin"))
    command = (str(paths.python), str(Path(__file__).resolve().with_name("build_firmware.py")), *argv)
    execve(str(paths.python), command, environment)
    raise AssertionError("runtime re-exec unexpectedly returned")


def runtime_pio_path(project_dir: Path, provenance: RuntimeProvenance) -> Path:
    path = project_dir / ".pio/open-bike-build/host-runtime" / provenance.lock_set_id / provenance.target / "bin/pio"
    if path.is_symlink() or not path.is_file() or _file_sha256(path) != provenance.pio_sha256:
        raise FirmwareRuntimeError("locked private PlatformIO executable changed")
    return path
