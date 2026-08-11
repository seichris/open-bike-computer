#!/usr/bin/env python3
"""Build a real PlatformIO firmware target across pioarduino bootstrap passes."""

from __future__ import annotations

import argparse
import configparser
import hashlib
import json
import math
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
import unicodedata
import zipfile
from contextlib import contextmanager
from pathlib import Path
from typing import Callable, Iterator, Sequence

from generated_sdkconfig import (
    FLASH_PLAN_PORT_PLACEHOLDER,
    GeneratedSdkconfigError,
    WAVESHARE_PLATFORM_ARCHIVE_SHA256,
    WAVESHARE_PLATFORM_ARCHIVE_SIZE,
    WAVESHARE_PLATFORM_PACKAGES,
    WAVESHARE_PLATFORM_PACKAGES_SHA256,
    WAVESHARE_PLATFORM_URL,
    current_source_identity,
    prepare_generated_sdkconfigs,
    record_generated_sdkconfig_defaults,
    require_validated_generated_sdkconfig_defaults,
)
from firmware_build_identity import (
    FULL_GIT_SHA,
    build_timestamp_from_source_date_epoch,
    git_commit_source_date_epoch,
    git_head_identity,
)
from firmware_runtime import (
    FirmwareRuntimeError,
    PROVENANCE_ENV,
    RuntimeProvenance,
    ensure_runtime_handoff,
    runtime_pio_path,
)
from pioarduino_custom_core import (
    correct_espidf_text,
    correct_penv_setup_text,
)


ENVIRONMENT_PATTERN = re.compile(r"^[A-Za-z0-9_-]+$")
COMPONENT_MANAGER_LEGACY_OVERRIDES = {
    "COMPONENT_MANAGER_JOB_TIMEOUT",
    "DEFAULT_COMPONENT_SERVICE_URL",
    "IGNORE_UNKNOWN_FILES_FOR_MANAGED_COMPONENTS",
}
ESP_IDF_SOURCE_OVERRIDES = {
    "CI_TESTING_IDF_VERSION",
    "EXTRA_COMPONENT_DIRS",
    "IDF_BUILD_V2",
    "IDF_GITHUB_ASSETS",
    "IDF_PATH",
    "IDF_TARGET",
    "IDF_TOOLS_PATH",
    "IDF_VERSION",
    "SDKCONFIG_DEFAULTS",
}
TOOLCHAIN_ENVIRONMENT_OVERRIDES = {
    "AR",
    "ARCHFLAGS",
    "AS",
    "CC",
    "CFLAGS",
    "CMAKE_ARGS",
    "CMAKE_GENERATOR",
    "CMAKE_GENERATOR_INSTANCE",
    "CMAKE_GENERATOR_PLATFORM",
    "CMAKE_GENERATOR_TOOLSET",
    "CMAKE_PREFIX_PATH",
    "CMAKE_PROJECT_INCLUDE",
    "CMAKE_PROJECT_INCLUDE_BEFORE",
    "CMAKE_TOOLCHAIN_FILE",
    "CPATH",
    "CPP",
    "CPPFLAGS",
    "CPLUS_INCLUDE_PATH",
    "CXX",
    "CXXFLAGS",
    "C_INCLUDE_PATH",
    "DYLD_INSERT_LIBRARIES",
    "GCC_EXEC_PREFIX",
    "LD",
    "LDFLAGS",
    "LD_LIBRARY_PATH",
    "LD_PRELOAD",
    "LIBRARY_PATH",
    "OBJCOPY",
    "OBJDUMP",
    "PYTHONHOME",
    "RANLIB",
    "SDKROOT",
    "STRIP",
    "VIRTUAL_ENV",
}
BUILD_ENVIRONMENT_PASSTHROUGH = {
    "ALL_PROXY",
    "CI",
    "COLORTERM",
    "COMSPEC",
    "GITHUB_ACTIONS",
    "GITHUB_WORKSPACE",
    "HOME",
    "HTTPS_PROXY",
    "HTTP_PROXY",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "LOGNAME",
    "NO_PROXY",
    "OPEN_BIKE_FIRMWARE_RUNTIME_PROVENANCE",
    "OPEN_BIKE_FIRMWARE_RUNTIME_BOOTSTRAP_MS",
    "OPEN_BIKE_FIRMWARE_WHEELHOUSE",
    "OPEN_BIKE_FIRMWARE_UV",
    "OPEN_BIKE_FIRMWARE_ESPTOOL_WHEEL",
    "OPEN_BIKE_FIRMWARE_PIOARDUINO_REQUIREMENTS",
    "OPEN_BIKE_FIRMWARE_ESP_IDF_REQUIREMENTS",
    "PATH",
    "PATHEXT",
    "RUNNER_ARCH",
    "RUNNER_OS",
    "SHELL",
    "SYSTEMROOT",
    "TEMP",
    "TERM",
    "TMP",
    "TMPDIR",
    "USER",
    "WINDIR",
    "all_proxy",
    "http_proxy",
    "https_proxy",
    "no_proxy",
}
PIOARDUINO_DUMMY_SIGNATURES = {
    "CMakeLists.txt": (
        'idf_component_register(SRCS "sketch.cpp" "arduino-lib-builder-gcc.c" '
        '"arduino-lib-builder-cpp.cpp" "arduino-lib-builder-as.S" '
        'INCLUDE_DIRS ".")'
    ),
    "sketch.cpp": "void setup()",
}
PIOARDUINO_DUMMY_REQUIRED_FILES = {
    "CMakeLists.txt",
    "idf_component.yml",
    "sketch.cpp",
    "arduino-lib-builder-gcc.c",
    "arduino-lib-builder-cpp.cpp",
    "arduino-lib-builder-as.S",
}
PLATFORMIO_CORE_PACKAGES = {"tool-scons"}
PIOARDUINO_BOOTSTRAP_PACKAGES = {
    "tool-cmake",
    "tool-esp-rom-elfs",
    "tool-esptoolpy",
    "tool-mklittlefs",
    "tool-ninja",
    "toolchain-xtensa-esp-elf",
}
PLATFORMIO_CORE_SCONS_PIOPM = json.dumps(
    {
        "type": "tool",
        "name": "tool-scons",
        "version": "4.40801.0",
        "spec": {
            "owner": "platformio",
            "id": 8192,
            "name": "tool-scons",
            "requirements": None,
            "uri": None,
        },
    },
    separators=(",", ":"),
)


class BuildError(RuntimeError):
    """Raised when a deterministic real-target build cannot be confirmed."""


def _resolved_device_port(
    project_dir: Path,
    manifest: dict[str, object],
    device_serial: str,
    timeout_seconds: float,
    *,
    runner: Callable[..., subprocess.CompletedProcess] = subprocess.run,
) -> str:
    """Resolve a stable USB hardware serial using the attested private Python."""
    requested = device_serial.strip()
    if (
        not requested
        or not requested.isprintable()
        or "\0" in requested
        or len(requested) > 255
    ):
        raise BuildError("device serial must not be empty or invalid")
    if not math.isfinite(timeout_seconds) or timeout_seconds < 0:
        raise BuildError("device timeout must be a finite nonnegative value")

    core_attestation = manifest.get("coreAttestation")
    if not isinstance(core_attestation, dict):
        raise BuildError("verified build provenance is missing its core attestation")
    core_dir_value = core_attestation.get("coreDir")
    if not isinstance(core_dir_value, str):
        raise BuildError("verified core attestation is missing its core directory")
    core_dir = Path(core_dir_value)
    manifest_environment = manifest.get("environment")
    if not isinstance(manifest_environment, str):
        raise BuildError("verified build provenance is missing its environment")
    expected_core_dir = (
        project_dir / ".pio/open-bike-build/platformio" / manifest_environment
    ).resolve()
    if core_dir != expected_core_dir:
        raise BuildError("verified core attestation references another core directory")
    private_python = core_dir / (
        "penv/Scripts/python.exe" if os.name == "nt" else "penv/bin/python"
    )
    resolver = project_dir / "tools/resolve_upload_port.py"
    if (
        not private_python.is_file()
        or not os.access(private_python, os.X_OK)
        or resolver.is_symlink()
        or not resolver.is_file()
    ):
        raise BuildError("verified upload device resolver is missing or unsafe")

    command = (
        str(private_python),
        str(resolver),
        "--device-serial",
        requested,
        "--timeout",
        f"{timeout_seconds:g}",
    )
    try:
        result = runner(
            command,
            cwd=project_dir,
            capture_output=True,
            text=True,
        )
    except OSError as error:
        raise BuildError(f"could not run the upload device resolver: {error}") from error
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "unknown error").strip()
        raise BuildError(f"could not resolve upload device {requested!r}: {detail}")
    try:
        resolved = json.loads(result.stdout)
    except (TypeError, json.JSONDecodeError) as error:
        raise BuildError("upload device resolver returned invalid output") from error
    if not isinstance(resolved, dict) or resolved.get("schema") != 1:
        raise BuildError("upload device resolver returned an unsupported result")
    port = resolved.get("port")
    actual_serial = resolved.get("serialNumber")
    if (
        not isinstance(port, str)
        or not port.strip()
        or not port.isprintable()
        or "\0" in port
        or len(port) > 4096
        or not isinstance(actual_serial, str)
        or not actual_serial.isprintable()
        or actual_serial.strip().casefold() != requested.casefold()
    ):
        raise BuildError("upload device resolver returned a mismatched device")
    vid = resolved.get("vid")
    pid = resolved.get("pid")
    description = resolved.get("description")
    usb_identity = f" vid={vid!s} pid={pid!s} description={description!r}"
    print(
        f"FIRMWARE_UPLOAD_DEVICE serial={actual_serial}"
        f" port={port}{usb_identity}",
        flush=True,
    )
    return port


def _verified_flash_command(
    upload_port: str,
    manifest: dict[str, object],
) -> tuple[str, ...]:
    """Bind the requested port into the already-attested PlatformIO plan."""
    flash_plan = manifest.get("flashPlan")
    if not isinstance(flash_plan, dict):
        raise BuildError("verified build provenance is missing its flash plan")
    command = flash_plan.get("command")
    if not isinstance(command, list) or not all(
        isinstance(token, str) for token in command
    ):
        raise BuildError("verified build provenance has an invalid flash command")
    if command.count(FLASH_PLAN_PORT_PLACEHOLDER) != 1:
        raise BuildError(
            "verified build provenance has an invalid upload-port placeholder"
        )
    return tuple(
        upload_port if token == FLASH_PLAN_PORT_PLACEHOLDER else token
        for token in command
    )


def _ensure_private_directory(project_dir: Path, relative: Path) -> Path:
    current = project_dir
    for part in relative.parts:
        current /= part
        if os.path.lexists(current):
            if current.is_symlink() or not current.is_dir():
                raise BuildError(
                    f"refusing to use unsafe deterministic-build directory: {current}"
                )
        else:
            current.mkdir()
    return current


def _file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _pinned_nested_scons_piopm() -> str:
    """Return pioarduino's exact URL identity for the verified SCons bytes."""
    package = next(
        (entry for entry in WAVESHARE_PLATFORM_PACKAGES if entry[0] == "tool-scons"),
        None,
    )
    if package is None:
        raise BuildError("missing tracked platform package pin: tool-scons")
    _, url, _, _ = package
    return json.dumps(
        {
            "type": "tool",
            "name": "tool-scons",
            "version": "4.40801.0",
            "spec": {
                "owner": "platformio",
                "id": None,
                "name": "tool-scons",
                "requirements": None,
                "uri": url,
            },
        },
        separators=(",", ":"),
    )


def _reject_source_affecting_environment() -> None:
    allowed = {
        "PLATFORMIO_CORE_DIR",
        "PLATFORMIO_HOME_DIR",
    }
    forbidden = sorted(
        key
        for key, value in os.environ.items()
        if key.startswith("PLATFORMIO_") and key not in allowed and value
    )
    forbidden.extend(
        key
        for key, value in os.environ.items()
        if key.startswith("IDF_COMPONENT_") and value
    )
    forbidden.extend(
        key
        for key in (
            *sorted(COMPONENT_MANAGER_LEGACY_OVERRIDES),
            *sorted(ESP_IDF_SOURCE_OVERRIDES),
            *sorted(TOOLCHAIN_ENVIRONMENT_OVERRIDES),
            "ICENAV3_LAT",
            "ICENAV3_LON",
        )
        if os.environ.get(key)
    )
    forbidden = sorted(set(forbidden))
    if forbidden:
        raise BuildError(
            "source-affecting ambient build overrides are not allowed; use a "
            "tracked PlatformIO environment instead: " + ", ".join(forbidden)
        )


def _download_verified_archive(
    downloads: Path,
    *,
    label: str,
    url: str,
    sha256: str,
    size: int,
    filename: str,
) -> Path:
    archive = downloads / filename
    if os.path.lexists(archive):
        if archive.is_symlink() or not archive.is_file():
            raise BuildError(f"unsafe cached {label} archive: {archive}")
        try:
            archive_matches = (
                archive.stat().st_size == size and _file_sha256(archive) == sha256
            )
        except OSError as error:
            raise BuildError(f"could not verify cached {label} archive: {error}") from error
        if not archive_matches:
            archive.unlink()

    if archive.exists():
        return archive

    temporary_name: str | None = None
    try:
        with urllib.request.urlopen(url, timeout=60) as response:
            with tempfile.NamedTemporaryFile(
                mode="wb",
                dir=downloads,
                prefix=f".{archive.name}.",
                delete=False,
            ) as stream:
                temporary_name = stream.name
                downloaded = 0
                while True:
                    chunk = response.read(65536)
                    if not chunk:
                        break
                    downloaded += len(chunk)
                    if downloaded > size:
                        raise BuildError(f"{label} archive exceeds its tracked size")
                    stream.write(chunk)
        temporary = Path(temporary_name)
        if temporary.stat().st_size != size:
            raise BuildError(f"downloaded {label} archive has the wrong size")
        if _file_sha256(temporary) != sha256:
            raise BuildError(
                f"downloaded {label} archive does not match the tracked SHA-256"
            )
        os.replace(temporary, archive)
        temporary_name = None
    except (OSError, urllib.error.URLError, ValueError) as error:
        raise BuildError(f"could not download the pinned {label} archive: {error}") from error
    finally:
        if temporary_name is not None:
            try:
                Path(temporary_name).unlink()
            except OSError:
                pass
    return archive


def _tree_digest_without_marker(root: Path, marker_name: str) -> str:
    digest = hashlib.sha256()
    files: list[Path] = []
    for path in sorted(root.rglob("*")):
        if path.is_symlink() or (not path.is_file() and not path.is_dir()):
            raise BuildError(f"verified platform staging contains an unsafe entry: {path}")
        if path.is_file() and path != root / marker_name:
            files.append(path)
    if not files:
        raise BuildError("verified platform staging is empty")
    for path in files:
        relative = path.relative_to(root).as_posix().encode("utf-8")
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        digest.update(b"x" if path.stat().st_mode & 0o111 else b"-")
        digest.update(bytes.fromhex(_file_sha256(path)))
    return digest.hexdigest()


def _runtime_stage_identity() -> tuple[dict[str, object], str]:
    raw = os.environ.get(PROVENANCE_ENV)
    try:
        provenance = json.loads(raw) if raw else None
    except json.JSONDecodeError as error:
        raise BuildError("locked runtime provenance is invalid") from error
    if not isinstance(provenance, dict) or not provenance:
        raise BuildError("locked runtime provenance is missing before platform staging")
    if (
        provenance.get("platformArchiveSha256")
        != WAVESHARE_PLATFORM_ARCHIVE_SHA256
        or provenance.get("platformPackagesSha256")
        != WAVESHARE_PLATFORM_PACKAGES_SHA256
    ):
        raise BuildError(
            "locked runtime platform identity does not match the firmware pins"
        )
    encoded = json.dumps(
        provenance, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return provenance, hashlib.sha256(encoded).hexdigest()


def _stage_verified_platform(project_dir: Path, archive: Path) -> Path:
    """Extract and transform the pinned platform before any of its code runs."""
    marker_name = ".open-bike-runtime-transform.json"
    provenance, runtime_identity = _runtime_stage_identity()
    parent = _ensure_private_directory(
        project_dir,
        Path(".pio/open-bike-build/platform-staging")
        / WAVESHARE_PLATFORM_ARCHIVE_SHA256,
    )
    destination = parent / runtime_identity
    expected_marker = {
        "schema": 1,
        "platformArchiveSha256": WAVESHARE_PLATFORM_ARCHIVE_SHA256,
        "runtimeProvenance": provenance,
    }

    def validate_existing(root: Path) -> None:
        marker = root / marker_name
        if root.is_symlink() or not root.is_dir() or marker.is_symlink() or not marker.is_file():
            raise BuildError("verified platform staging is missing or unsafe")
        try:
            value = json.loads(marker.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise BuildError("verified platform transform marker is invalid") from error
        if not isinstance(value, dict):
            raise BuildError("verified platform transform marker is invalid")
        tree_digest = value.get("platformTreeSha256")
        if (
            set(value) != {*expected_marker, "platformTreeSha256"}
            or stat.S_IMODE(root.stat().st_mode) != 0o755
            or stat.S_IMODE(marker.stat().st_mode) != 0o444
            or {key: value.get(key) for key in expected_marker} != expected_marker
            or not isinstance(tree_digest, str)
            or re.fullmatch(r"[0-9a-f]{64}", tree_digest) is None
            or tree_digest != _tree_digest_without_marker(root, marker_name)
        ):
            raise BuildError("verified platform staging changed after pre-execution transform")
        for path in root.rglob("*"):
            expected_modes = {0o755} if path.is_dir() else {0o444, 0o555}
            if stat.S_IMODE(path.stat().st_mode) not in expected_modes:
                raise BuildError(
                    "verified platform staging permissions changed after "
                    "pre-execution transform"
                )

    if os.path.lexists(destination):
        validate_existing(destination)
        return destination

    temporary = Path(tempfile.mkdtemp(prefix=f".{runtime_identity}.", dir=parent))
    try:
        temporary.rmdir()
        extraction_root = temporary / "platform"
        extraction_root.mkdir(parents=True)
        try:
            with zipfile.ZipFile(archive) as bundle:
                names: set[str] = set()
                casefolded: set[str] = set()
                root_name: str | None = None
                for member in bundle.infolist():
                    name = member.filename
                    if (
                        not name
                        or "\\" in name
                        or unicodedata.normalize("NFC", name) != name
                        or member.flag_bits & 0x1
                    ):
                        raise BuildError("pinned platform archive has an unsafe member name")
                    relative = Path(name)
                    if (
                        relative.is_absolute()
                        or any(part in {"", ".", ".."} for part in relative.parts)
                        or len(relative.parts) < 1
                    ):
                        raise BuildError("pinned platform archive contains path traversal")
                    unix_mode = member.external_attr >> 16
                    if unix_mode and stat.S_ISLNK(unix_mode):
                        raise BuildError("pinned platform archive contains a symlink")
                    normalized = relative.as_posix().rstrip("/")
                    if normalized in names or normalized.casefold() in casefolded:
                        raise BuildError("pinned platform archive contains duplicate paths")
                    names.add(normalized)
                    casefolded.add(normalized.casefold())
                    if root_name is None:
                        root_name = relative.parts[0]
                    if relative.parts[0] != root_name:
                        raise BuildError("pinned platform archive has multiple roots")
                    output_relative = Path(*relative.parts[1:])
                    if not output_relative.parts:
                        continue
                    output = extraction_root / output_relative
                    if member.is_dir():
                        output.mkdir(parents=True, exist_ok=True)
                        continue
                    output.parent.mkdir(parents=True, exist_ok=True)
                    with bundle.open(member) as source, output.open("xb") as target:
                        shutil.copyfileobj(source, target)
                    if output.stat().st_size != member.file_size:
                        raise BuildError("pinned platform member size changed during extraction")
                    output.chmod((unix_mode & 0o777) or 0o644)
        except (OSError, zipfile.BadZipFile) as error:
            raise BuildError(f"could not stage the pinned PlatformIO platform: {error}") from error

        patches = (
            (
                extraction_root / "builder/frameworks/espidf.py",
                correct_espidf_text,
                "nested PlatformIO and ESP-IDF resolver",
            ),
            (
                extraction_root / "builder/penv_setup.py",
                correct_penv_setup_text,
                "Python resolver",
            ),
        )
        for path, transform, label in patches:
            if path.is_symlink() or not path.is_file():
                raise BuildError(f"pinned pioarduino {label} source is missing")
            try:
                corrected = transform(path.read_text(encoding="utf-8"))
            except (OSError, UnicodeError, ValueError) as error:
                raise BuildError(f"pinned pioarduino {label} transform failed: {error}") from error
            path.write_text(corrected, encoding="utf-8")

        tree_digest = _tree_digest_without_marker(extraction_root, marker_name)
        marker = {**expected_marker, "platformTreeSha256": tree_digest}
        (extraction_root / marker_name).write_text(
            json.dumps(marker, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        os.replace(extraction_root, destination)
        temporary.rmdir()
        for path in sorted(
            destination.rglob("*"), key=lambda item: len(item.parts), reverse=True
        ):
            path.chmod(0o755 if path.is_dir() else (
                0o555 if os.access(path, os.X_OK) else 0o444
            ))
        # PlatformIO copies source modes into a private package-install staging
        # directory and must create its own .piopm metadata there. Keep source
        # files immutable and content-attested, but leave directories traversable
        # and writable so the private copy does not inherit an unusable 0555 root.
        destination.chmod(0o755)
        validate_existing(destination)
    except Exception:
        if temporary.exists() and not temporary.is_symlink():
            for path in temporary.rglob("*"):
                if not path.is_symlink():
                    path.chmod(0o700 if path.is_dir() else 0o600)
            shutil.rmtree(temporary)
        raise
    return destination


def _verified_platformio_project_config(project_dir: Path) -> tuple[Path, Path]:
    """Content-pin the platform and its tracked PlatformIO package archives."""
    source_config = project_dir / "platformio.ini"
    if source_config.is_symlink() or not source_config.is_file():
        raise BuildError(f"unsafe PlatformIO project file: {source_config}")
    try:
        source_text = source_config.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise BuildError(f"could not read PlatformIO project file: {error}") from error
    if WAVESHARE_PLATFORM_URL not in source_text:
        raise BuildError(
            "tracked PlatformIO configuration does not contain the pinned "
            "Waveshare platform release URL"
        )

    downloads = _ensure_private_directory(
        project_dir, Path(".pio/open-bike-build/downloads")
    )
    archive = _download_verified_archive(
        downloads,
        label="Waveshare platform",
        url=WAVESHARE_PLATFORM_URL,
        sha256=WAVESHARE_PLATFORM_ARCHIVE_SHA256,
        size=WAVESHARE_PLATFORM_ARCHIVE_SIZE,
        filename=(
            "platform-espressif32-55.03.34-"
            f"{WAVESHARE_PLATFORM_ARCHIVE_SHA256}.zip"
        ),
    )

    staged_platform = _stage_verified_platform(project_dir, archive)

    package_downloads = _ensure_private_directory(
        project_dir, Path(".pio/open-bike-build/downloads/platform-packages")
    )
    verified_packages: list[tuple[str, Path]] = []
    for name, url, sha256, size in WAVESHARE_PLATFORM_PACKAGES:
        suffix = ".tar.xz" if url.endswith(".tar.xz") else (
            ".tar.gz" if url.endswith(".tar.gz") else ".zip"
        )
        package = _download_verified_archive(
            package_downloads,
            label=name,
            url=url,
            sha256=sha256,
            size=size,
            filename=f"{name}-{sha256}{suffix}",
        )
        verified_packages.append((name, package))

    configs = _ensure_private_directory(
        project_dir, Path(".pio/open-bike-build/config")
    )
    def write_verified_config(path: Path, excluded: set[str]) -> None:
        package_override = "\nplatform_packages =\n" + "".join(
            f"  {name} @ {package.as_uri()}\n"
            for name, package in verified_packages
            if name not in excluded
        )
        verified_text = source_text.replace(
            f"platform = {WAVESHARE_PLATFORM_URL}",
            f"platform = {staged_platform.as_uri()}{package_override.rstrip()}",
        )
        if WAVESHARE_PLATFORM_URL in verified_text:
            raise BuildError(
                "could not replace every Waveshare platform URL with verified content"
            )
        temporary_name = None
        try:
            with tempfile.NamedTemporaryFile(
                mode="w",
                encoding="utf-8",
                dir=configs,
                prefix=f".{path.name}.",
                delete=False,
            ) as stream:
                temporary_name = stream.name
                stream.write(
                    "; Generated by tools/build_firmware.py from tracked platformio.ini.\n"
                )
                stream.write(verified_text)
            os.replace(temporary_name, path)
        except OSError as error:
            if temporary_name is not None:
                try:
                    Path(temporary_name).unlink()
                except OSError:
                    pass
            raise BuildError(
                f"could not write verified PlatformIO config: {error}"
            ) from error

    verified_config = configs / "platformio-verified.ini"
    bootstrap_config = configs / "platformio-bootstrap.ini"
    write_verified_config(bootstrap_config, PLATFORMIO_CORE_PACKAGES)
    write_verified_config(
        verified_config,
        PLATFORMIO_CORE_PACKAGES | PIOARDUINO_BOOTSTRAP_PACKAGES,
    )
    return verified_config, archive


def _verified_platform_package_archive(project_dir: Path, name: str) -> Path:
    package = next(
        (entry for entry in WAVESHARE_PLATFORM_PACKAGES if entry[0] == name),
        None,
    )
    if package is None:
        raise BuildError(f"missing tracked platform package pin: {name}")
    _, url, sha256, size = package
    suffix = ".tar.xz" if url.endswith(".tar.xz") else (
        ".tar.gz" if url.endswith(".tar.gz") else ".zip"
    )
    archive = (
        project_dir
        / ".pio/open-bike-build/downloads/platform-packages"
        / f"{name}-{sha256}{suffix}"
    )
    if (
        archive.is_symlink()
        or not archive.is_file()
        or archive.stat().st_size != size
        or _file_sha256(archive) != sha256
    ):
        raise BuildError(f"verified {name} archive changed before installation")
    return archive


def _seed_pinned_scons_package(
    project_dir: Path, environment: str, archive: Path | None = None
) -> None:
    """Install the exact SCons runtime before PlatformIO can resolve a range."""
    if archive is None:
        archive = _verified_platform_package_archive(project_dir, "tool-scons")
    packages = (
        project_dir
        / ".pio/open-bike-build/platformio"
        / environment
        / "packages"
    )
    target = packages / "tool-scons"
    if os.path.lexists(target):
        raise BuildError(f"refusing to replace existing SCons package: {target}")
    temporary = Path(tempfile.mkdtemp(prefix=".tool-scons.", dir=packages))
    try:
        with tarfile.open(archive, mode="r:gz") as bundle:
            for member in bundle.getmembers():
                relative = Path(member.name)
                if (
                    relative.is_absolute()
                    or not relative.parts
                    or any(part in ("", ".", "..") for part in relative.parts)
                    or member.issym()
                    or member.islnk()
                    or member.isdev()
                ):
                    raise BuildError(
                        f"unsafe path in pinned SCons archive: {member.name!r}"
                    )
                destination = temporary / relative
                if member.isdir():
                    destination.mkdir(parents=True, exist_ok=True)
                    continue
                if not member.isfile():
                    raise BuildError(
                        f"unsupported entry in pinned SCons archive: {member.name!r}"
                    )
                destination.parent.mkdir(parents=True, exist_ok=True)
                source = bundle.extractfile(member)
                if source is None:
                    raise BuildError(
                        f"could not read pinned SCons archive entry: {member.name!r}"
                    )
                with source, destination.open("xb") as output:
                    shutil.copyfileobj(source, output)
                destination.chmod(member.mode & 0o777)

        manifest = temporary / "package.json"
        try:
            metadata = json.loads(manifest.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise BuildError(f"invalid pinned SCons package manifest: {error}") from error
        if metadata.get("name") != "tool-scons" or metadata.get("version") != "4.40801.0":
            raise BuildError("pinned SCons package manifest has an unexpected identity")
        runtime = temporary / "scons-local-4.8.1/SCons/Script/__init__.py"
        if runtime.is_symlink() or not runtime.is_file():
            raise BuildError("pinned SCons archive is missing its runtime")
        (temporary / ".piopm").write_text(
            PLATFORMIO_CORE_SCONS_PIOPM,
            encoding="utf-8",
        )
        os.replace(temporary, target)
    except (OSError, tarfile.TarError) as error:
        raise BuildError(f"could not install the pinned SCons package: {error}") from error
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)


@contextmanager
def _project_build_lock(project_dir: Path) -> Iterator[None]:
    lock_root = _ensure_private_directory(
        project_dir, Path(".pio/open-bike-build/locks")
    )
    lock_dir = lock_root / "deterministic-build.lock"
    try:
        lock_dir.mkdir()
    except FileExistsError as error:
        raise BuildError(
            "another deterministic build/upload owns this project lock; if no "
            f"process is running, remove the stale lock directory: {lock_dir}"
        ) from error
    try:
        yield
    finally:
        try:
            lock_dir.rmdir()
        except OSError as error:
            raise BuildError(f"could not release profile build lock: {error}") from error


@contextmanager
def _deterministic_build_environment(
    project_dir: Path,
    environment: str,
    expected_identity: str,
    platform_archive: Path,
    verified_config: Path,
) -> Iterator[None]:
    commit_identity = expected_identity.removeprefix("dirty-")
    try:
        if FULL_GIT_SHA.fullmatch(commit_identity) is None:
            commit_identity = git_head_identity(project_dir)
        source_date_epoch = git_commit_source_date_epoch(
            project_dir, commit_identity
        )
        build_timestamp = build_timestamp_from_source_date_epoch(
            source_date_epoch
        )
    except ValueError as error:
        raise BuildError(
            "deterministic firmware build requires a Git-derived build clock: "
            f"{error}"
        ) from error

    store_root = _ensure_private_directory(
        project_dir, Path(".pio/open-bike-build/platformio") / environment
    )
    config_root = _ensure_private_directory(
        project_dir, Path(".pio/open-bike-build/config")
    )
    isolated_git_config = config_root / "gitconfig-empty"
    if isolated_git_config.is_symlink() or (
        isolated_git_config.exists() and not isolated_git_config.is_file()
    ):
        raise BuildError(
            f"refusing to replace unsafe isolated Git config: {isolated_git_config}"
        )
    try:
        isolated_git_config.write_text("", encoding="utf-8")
    except OSError as error:
        raise BuildError(f"could not write isolated Git config: {error}") from error
    for child in (
        "packages",
        "platforms",
        "lib",
        "globallib",
        "boards",
        "libdeps",
        "cache",
        "build-cache",
        "component-cache",
    ):
        _ensure_private_directory(
            project_dir,
            Path(".pio/open-bike-build/platformio") / environment / child,
        )

    previous = dict(os.environ)
    passthrough = {
        key: value
        for key, value in previous.items()
        if key in BUILD_ENVIRONMENT_PASSTHROUGH or key.startswith("LC_")
    }
    os.environ.clear()
    os.environ.update(passthrough)
    os.environ.update(
        {
            "PLATFORMIO_CORE_DIR": str(store_root),
            "PLATFORMIO_PACKAGES_DIR": str(store_root / "packages"),
            "PLATFORMIO_PLATFORMS_DIR": str(store_root / "platforms"),
            "PLATFORMIO_GLOBALLIB_DIR": str(store_root / "lib"),
            "PLATFORMIO_BOARDS_DIR": str(store_root / "boards"),
            "PLATFORMIO_LIBDEPS_DIR": str(store_root / "libdeps"),
            "PLATFORMIO_CACHE_DIR": str(store_root / "cache"),
            "PLATFORMIO_BUILD_CACHE_DIR": str(store_root / "build-cache"),
            "IDF_COMPONENT_CACHE_PATH": str(store_root / "component-cache"),
            "IDF_COMPONENT_CHECK_NEW_VERSION": "0",
            "IDF_COMPONENT_STRICT_CHECKSUM": "1",
            "IDF_COMPONENT_VERIFY_SSL": "1",
            "PIP_NO_INDEX": "1",
            "PIP_DISABLE_PIP_VERSION_CHECK": "1",
            "UV_NO_INDEX": "1",
            "IDF_TOOLS_PATH": str(store_root),
            "GIT_CONFIG_GLOBAL": str(isolated_git_config),
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0",
            "OPEN_BIKE_DETERMINISTIC_BUILD": "1",
            "OPEN_BIKE_EXPECTED_GIT_SHA": expected_identity,
            "SOURCE_DATE_EPOCH": source_date_epoch,
            "OPEN_BIKE_BUILD_TIMESTAMP": build_timestamp,
            "OPEN_BIKE_PINNED_SCONS_PIOPM": _pinned_nested_scons_piopm(),
            "OPEN_BIKE_VERIFIED_PROJECT_CONFIG": str(verified_config),
            "OPEN_BIKE_PLATFORM_ARCHIVE_SHA256": _file_sha256(platform_archive),
            "OPEN_BIKE_PLATFORM_PACKAGES_SHA256": (
                WAVESHARE_PLATFORM_PACKAGES_SHA256
            ),
        }
    )
    wheelhouse = os.environ.get("OPEN_BIKE_FIRMWARE_WHEELHOUSE")
    if wheelhouse:
        wheelhouse_path = Path(wheelhouse)
        if wheelhouse_path.is_symlink() or not wheelhouse_path.is_dir():
            raise BuildError("locked firmware wheelhouse is missing or unsafe")
        os.environ["PIP_FIND_LINKS"] = str(wheelhouse_path)
        os.environ["UV_FIND_LINKS"] = str(wheelhouse_path)
    try:
        yield
    finally:
        os.environ.clear()
        os.environ.update(previous)


def _reset_profile_platformio_store(
    project_dir: Path, environment: str
) -> None:
    relative = Path(".pio/open-bike-build/platformio") / environment
    store_root = project_dir / relative
    if os.path.lexists(store_root):
        if store_root.is_symlink() or not store_root.is_dir():
            raise BuildError(
                f"refusing to reset unsafe deterministic-build store: {store_root}"
            )
        shutil.rmtree(store_root)
    _ensure_private_directory(project_dir, relative)
    for child in (
        "packages",
        "platforms",
        "lib",
        "globallib",
        "boards",
        "libdeps",
        "cache",
        "build-cache",
        "component-cache",
    ):
        _ensure_private_directory(project_dir, relative / child)


def _reset_profile_build_cache(project_dir: Path, environment: str) -> None:
    """Remove compiler-cache output before accepting an existing core store."""
    relative = (
        Path(".pio/open-bike-build/platformio") / environment / "build-cache"
    )
    cache_dir = project_dir / relative
    if os.path.lexists(cache_dir):
        if cache_dir.is_symlink() or not cache_dir.is_dir():
            raise BuildError(
                f"refusing to reset unsafe deterministic build cache: {cache_dir}"
            )
        shutil.rmtree(cache_dir)
    _ensure_private_directory(project_dir, relative)


def _select_profile_build_cache(
    project_dir: Path,
    environment: str,
    phase: str,
    identity: str,
) -> Path:
    if phase not in {"bootstrap", "application"}:
        raise BuildError(f"invalid compiler-cache phase: {phase}")
    safe_identity = hashlib.sha256(identity.encode("utf-8")).hexdigest()
    relative = (
        Path(".pio/open-bike-build/platformio")
        / environment
        / "build-cache"
        / phase
        / safe_identity
    )
    selected = _ensure_private_directory(project_dir, relative)
    os.environ["PLATFORMIO_BUILD_CACHE_DIR"] = str(selected)
    return selected


def _reset_profile_override_inputs(project_dir: Path, environment: str) -> None:
    """Remove private global-library and board overrides before use."""
    for child, label in (
        ("lib", "global-library override"),
        ("globallib", "legacy global-library override"),
        ("boards", "core-board override"),
    ):
        relative = Path(".pio/open-bike-build/platformio") / environment / child
        target = project_dir / relative
        if os.path.lexists(target):
            if target.is_symlink() or not target.is_dir():
                raise BuildError(
                    f"refusing to reset unsafe deterministic {label}: {target}"
                )
            shutil.rmtree(target)
        _ensure_private_directory(project_dir, relative)


def _print_provenance(
    marker: str,
    environment: str,
    source_identity: str,
    manifest: dict[str, object] | None,
) -> None:
    def value(key: str) -> object:
        if manifest is None:
            return "missing"
        result = manifest.get(key)
        return "absent" if result is None else result

    runtime = (
        manifest.get("runtimeProvenance")
        if isinstance(manifest, dict)
        and isinstance(manifest.get("runtimeProvenance"), dict)
        else {}
    )

    def runtime_value(key: str) -> object:
        result = runtime.get(key)
        return "missing" if result is None else result

    core = (
        manifest.get("coreAttestation")
        if isinstance(manifest, dict)
        and isinstance(manifest.get("coreAttestation"), dict)
        else {}
    )
    phases = (
        manifest.get("phaseTimingsMs")
        if isinstance(manifest, dict)
        and isinstance(manifest.get("phaseTimingsMs"), dict)
        else {}
    )

    def nested_value(values: dict[str, object], key: str) -> object:
        result = values.get(key)
        return "missing" if result is None else result

    print(
        f"{marker} schema=1 environment={environment} git={source_identity} "
        f"uploadEligible={1 if manifest else 0} "
        f"coreCache={value('coreCache')} "
        f"coreInputKey={value('coreInputKey')} "
        f"runtimeLockSetId={runtime_value('lockSetId')} "
        f"runtimeManifestSha256={runtime_value('manifestSha256')} "
        f"runtimeTarget={runtime_value('target')} "
        f"runtimeBundleSha256={runtime_value('bundleSha256')} "
        f"runtimeTreeSha256={runtime_value('runtimeTreeSha256')} "
        f"runtimePythonSha256={runtime_value('pythonExecutableSha256')} "
        f"runtimePioSha256={runtime_value('pioSha256')} "
        f"runtimeUvSha256={runtime_value('uvSha256')} "
        f"runtimePythonVersion={runtime_value('pythonVersion')} "
        f"runtimePlatformioVersion={runtime_value('platformioVersion')} "
        f"runtimeTopLevelDistributionsSha256={runtime_value('topLevelDistributionSha256')} "
        f"runtimePioarduinoRootDistributionsSha256={runtime_value('pioarduinoRootDistributionSha256')} "
        f"runtimeEspIdfDistributionsSha256={runtime_value('espIdfDistributionSha256')} "
        f"runtimeUvDistributionsSha256={runtime_value('uvDistributionSha256')} "
        f"runtimeEsptoolDistributionsSha256={runtime_value('esptoolDistributionSha256')} "
        f"runtimeBootstrapMs={os.environ.get('OPEN_BIKE_FIRMWARE_RUNTIME_BOOTSTRAP_MS', 'missing')} "
        f"runtimePioarduinoPenvTreeSha256={nested_value(core, 'penvTreeSha256')} "
        f"runtimeEspIdfVenvTreeSha256={nested_value(core, 'espIdfPythonEnvTreeSha256')} "
        f"runtimeTransformedPlatformTreeSha256={nested_value(core, 'platformTreeSha256')} "
        f"phasePlatformPreparationMs={nested_value(phases, 'platformPreparation')} "
        f"phaseCustomCoreBootstrapMs={nested_value(phases, 'customCoreBootstrap')} "
        f"phaseApplicationCompileMs={nested_value(phases, 'applicationCompile')} "
        f"phaseApplicationBuildMs={nested_value(phases, 'applicationBuild')} "
        f"phaseLinkMs={nested_value(phases, 'link')} "
        f"phaseAttestationMs={nested_value(phases, 'attestation')} "
        f"phaseTotalMs={nested_value(phases, 'total')} "
        f"sourceDateEpoch={value('sourceDateEpoch')} "
        f"buildTimestamp={value('buildTimestamp')} "
        f"firmwareBinSha256={value('firmwareBinSha256')} "
        f"firmwareElfSha256={value('firmwareElfSha256')} "
        f"bootloaderBinSha256={value('bootloaderBinSha256')} "
        f"partitionTableBinSha256={value('partitionTableBinSha256')} "
        f"bootApp0Sha256={value('bootApp0Sha256')} "
        f"flashPlanSha256={value('flashPlanSha256')} "
        f"coreAttestationSha256={value('coreAttestationSha256')} "
        f"platformArchiveSha256={value('platformArchiveSha256')} "
        f"platformPackagesSha256={value('platformPackagesSha256')} "
        f"libraryDependenciesSha256={value('libraryDependenciesSha256')} "
        f"managedComponentsSha256={value('managedComponentsSha256')}",
        flush=True,
    )


def _validate_environment(project_dir: Path, environment: str) -> None:
    if not ENVIRONMENT_PATTERN.fullmatch(environment):
        raise BuildError(f"invalid PlatformIO environment: {environment!r}")

    config_path = project_dir / "platformio.ini"
    if not config_path.is_file():
        raise BuildError(f"PlatformIO project file is missing: {config_path}")

    config = configparser.ConfigParser(interpolation=None)
    config.read(config_path)
    if not config.has_section(f"env:{environment}"):
        raise BuildError(f"unknown PlatformIO environment: {environment}")


def _is_pioarduino_dummy(dummy_dir: Path) -> bool:
    if dummy_dir.is_symlink() or not dummy_dir.is_dir():
        return False
    if not all(
        (dummy_dir / name).is_file()
        for name in PIOARDUINO_DUMMY_REQUIRED_FILES
    ):
        return False
    for name, signature in PIOARDUINO_DUMMY_SIGNATURES.items():
        if signature not in (dummy_dir / name).read_text(encoding="utf-8"):
            return False
    return True


def _remove_pioarduino_dummy(project_dir: Path) -> bool:
    dummy_dir = project_dir / ".dummy"
    if not os.path.lexists(dummy_dir):
        return False
    if not _is_pioarduino_dummy(dummy_dir):
        raise BuildError(
            f"refusing to remove unrecognized project artifact: {dummy_dir}"
        )
    shutil.rmtree(dummy_dir)
    return True


def _remove_environment_build(project_dir: Path, environment: str) -> None:
    pio_dir = project_dir / ".pio"
    build_root = pio_dir / "build"
    target_dir = build_root / environment
    for parent in (pio_dir, build_root):
        if parent.is_symlink():
            raise BuildError(f"refusing to clean through symlink: {parent}")
    if not os.path.lexists(target_dir):
        return
    if target_dir.is_symlink() or not target_dir.is_dir():
        raise BuildError(f"refusing to remove unexpected build artifact: {target_dir}")
    shutil.rmtree(target_dir)


def _pioarduino_toolchain_bootstrap_ready(
    project_dir: Path, environment: str
) -> bool:
    """Return whether pioarduino finished its first-pass Xtensa install.

    On a fresh private PlatformIO core, pioarduino first installs the tiny
    content-pinned tool wrapper, uses that wrapper to fetch and checksum the
    host-specific compiler, and replaces the wrapper in ``packages``. That
    first SCons invocation can still hold the obsolete wrapper specification
    and fail to resolve the newly installed compiler directory. A subsequent
    invocation resolves the completed package normally. Only accept that
    retry when the expected replacement package and compiler are positively
    present; an arbitrary failed build must still fail closed.
    """
    if not environment.startswith("WAVESHARE_AMOLED_"):
        return False
    package = (
        project_dir
        / ".pio"
        / "open-bike-build"
        / "platformio"
        / environment
        / "packages"
        / "toolchain-xtensa-esp-elf"
    )
    if package.is_symlink() or not package.is_dir():
        return False
    required_files = (
        package / ".piopm",
        package / "package.json",
        package / "bin" / "xtensa-esp-elf-gcc",
    )
    return (
        not (package / "tools.json").exists()
        and all(
            not path.is_symlink() and path.is_file()
            for path in required_files
        )
        and os.access(required_files[-1], os.X_OK)
    )


def _record_build_phase_timings(
    manifest_path: Path, timings: dict[str, int]
) -> dict[str, object]:
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise BuildError("recorded build manifest is missing or unsafe")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise BuildError(f"could not read recorded build provenance: {error}") from error
    if not isinstance(manifest, dict) or any(
        not isinstance(value, int) or isinstance(value, bool) or value < 0
        for value in timings.values()
    ):
        raise BuildError("recorded build provenance or phase timings are invalid")
    manifest["phaseTimingsMs"] = timings
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=manifest_path.parent,
            prefix=f".{manifest_path.name}.", delete=False,
        ) as stream:
            temporary_name = stream.name
            json.dump(manifest, stream, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_name, manifest_path)
        temporary_name = None
    except OSError as error:
        raise BuildError(f"could not record build phase timings: {error}") from error
    finally:
        if temporary_name is not None:
            try:
                Path(temporary_name).unlink()
            except OSError:
                pass
    return manifest


def _consume_link_timing(project_dir: Path, environment: str) -> int | None:
    path = (
        project_dir
        / ".pio/open-bike-build/phase-timings"
        / f"{environment}-link.json"
    )
    if not os.path.lexists(path):
        return None
    if path.is_symlink() or not path.is_file():
        raise BuildError("firmware link timing evidence is unsafe")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        path.unlink()
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise BuildError(f"firmware link timing evidence is invalid: {error}") from error
    if (
        not isinstance(value, dict)
        or set(value) != {"schema", "environment", "linkMs"}
        or value.get("schema") != 1
        or value.get("environment") != environment
        or not isinstance(value.get("linkMs"), int)
        or isinstance(value.get("linkMs"), bool)
        or value["linkMs"] < 0
    ):
        raise BuildError("firmware link timing evidence is invalid")
    return value["linkMs"]


def build_firmware(
    project_dir: Path,
    environment: str,
    *,
    pio_command: str = "pio",
    max_passes: int = 3,
    runner: Callable[..., subprocess.CompletedProcess] = subprocess.run,
) -> Path:
    """Build ``environment`` and return its verified firmware ELF path.

    pioarduino may use the first PlatformIO invocation to compile a custom
    Arduino core. During that invocation it replaces the project source with a
    generated ``.dummy`` sketch. PlatformIO can either return success for that
    sketch or fail later when an external source filter also defines Arduino's
    entry points. In both cases a clean second invocation is required.
    """

    build_started = time.monotonic()
    project_dir = project_dir.resolve()
    if max_passes < 1:
        raise BuildError("max_passes must be at least 1")
    _validate_environment(project_dir, environment)
    _reject_source_affecting_environment()
    expected_identity = current_source_identity(project_dir, environment)

    firmware_elf = project_dir / ".pio" / "build" / environment / "firmware.elf"
    firmware_bin = project_dir / ".pio" / "build" / environment / "firmware.bin"

    with _project_build_lock(project_dir):
        _ensure_private_directory(
            project_dir, Path(".pio/open-bike-build/phase-timings")
        )
        platform_prepare_started = time.monotonic()
        verified_config, platform_archive = _verified_platformio_project_config(
            project_dir
        )
        platform_prepare_ms = round(
            (time.monotonic() - platform_prepare_started) * 1000
        )
        command: Sequence[str] = (
            pio_command,
            "run",
            "--project-conf",
            str(verified_config),
            "-e",
            environment,
        )
        bootstrap_command: Sequence[str] = (
            pio_command,
            "run",
            "--project-conf",
            str(verified_config.with_name("platformio-bootstrap.ini")),
            "-e",
            environment,
        )
        with _deterministic_build_environment(
            project_dir,
            environment,
            expected_identity,
            platform_archive,
            verified_config,
        ):
            _remove_pioarduino_dummy(project_dir)
            _remove_environment_build(project_dir, environment)
            _reset_profile_override_inputs(project_dir, environment)
            try:
                preserved_sdkconfigs = prepare_generated_sdkconfigs(
                    project_dir, environment
                )
            except GeneratedSdkconfigError as error:
                raise BuildError(str(error)) from error
            if not preserved_sdkconfigs:
                _reset_profile_platformio_store(project_dir, environment)
                _seed_pinned_scons_package(
                    project_dir,
                    environment,
                )
                command = bootstrap_command
            if preserved_sdkconfigs:
                _select_profile_build_cache(
                    project_dir, environment, "application", expected_identity
                )
            else:
                _select_profile_build_cache(
                    project_dir,
                    environment,
                    "bootstrap",
                    f"{environment}:{WAVESHARE_PLATFORM_ARCHIVE_SHA256}",
                )
            toolchain_ready_before_pass = _pioarduino_toolchain_bootstrap_ready(
                project_dir, environment
            )
            custom_core_bootstrap_ms = 0
            application_compile_ms = 0
            application_build_ms = 0
            link_ms = 0
            for pass_number in range(1, max_passes + 1):
                print(
                    f"=== PlatformIO real-target build: {environment} "
                    f"(pass {pass_number}/{max_passes}) ===",
                    flush=True,
                )
                _consume_link_timing(project_dir, environment)
                pass_started = time.monotonic()
                try:
                    result = runner(command, cwd=project_dir)
                except OSError as error:
                    raise BuildError(
                        f"could not run {pio_command!r}: {error}"
                    ) from error
                pass_elapsed_ms = round((time.monotonic() - pass_started) * 1000)

                if os.path.lexists(project_dir / ".dummy"):
                    custom_core_bootstrap_ms += pass_elapsed_ms
                    toolchain_ready_after_pass = (
                        _pioarduino_toolchain_bootstrap_ready(
                            project_dir, environment
                        )
                    )
                    if (
                        not toolchain_ready_before_pass
                        and toolchain_ready_after_pass
                    ):
                        command = (
                            pio_command,
                            "run",
                            "--project-conf",
                            str(verified_config),
                            "-e",
                            environment,
                        )
                        toolchain_ready_before_pass = True
                        _select_profile_build_cache(
                            project_dir,
                            environment,
                            "application",
                            expected_identity,
                        )
                    else:
                        command = (
                            pio_command,
                            "run",
                            "--project-conf",
                            str(verified_config),
                            "-e",
                            environment,
                        )
                        _select_profile_build_cache(
                            project_dir,
                            environment,
                            "application",
                            expected_identity,
                        )
                    _remove_pioarduino_dummy(project_dir)
                    _remove_environment_build(project_dir, environment)
                    if pass_number == max_passes:
                        raise BuildError(
                            "pioarduino custom-core bootstrap did not converge after "
                            f"{max_passes} passes"
                        )
                    print(
                        "Detected pioarduino custom-core bootstrap; rebuilding the "
                        "real firmware target.",
                        flush=True,
                    )
                    continue

                if result.returncode != 0:
                    toolchain_ready_after_pass = (
                        _pioarduino_toolchain_bootstrap_ready(
                            project_dir, environment
                        )
                    )
                    if (
                        not toolchain_ready_before_pass
                        and toolchain_ready_after_pass
                        and pass_number < max_passes
                    ):
                        custom_core_bootstrap_ms += pass_elapsed_ms
                        _remove_environment_build(project_dir, environment)
                        toolchain_ready_before_pass = True
                        command = (
                            pio_command,
                            "run",
                            "--project-conf",
                            str(verified_config),
                            "-e",
                            environment,
                        )
                        _select_profile_build_cache(
                            project_dir,
                            environment,
                            "application",
                            expected_identity,
                        )
                        print(
                            "Detected completed pioarduino toolchain bootstrap; "
                            "retrying the real firmware target.",
                            flush=True,
                        )
                        continue
                    raise BuildError(
                        "PlatformIO exited with status "
                        f"{result.returncode} while building {environment}"
                    )
                observed_link_ms = _consume_link_timing(project_dir, environment)
                bounded_link_ms = min(pass_elapsed_ms, observed_link_ms or 0)
                link_ms += bounded_link_ms
                application_compile_ms += pass_elapsed_ms - bounded_link_ms
                application_build_ms += pass_elapsed_ms
                if firmware_elf.is_symlink() or not firmware_elf.is_file():
                    raise BuildError(
                        "PlatformIO returned success without the expected real-target "
                        f"artifact: {firmware_elf}"
                    )
                if firmware_bin.is_symlink() or not firmware_bin.is_file():
                    raise BuildError(
                        "PlatformIO returned success without the expected flash "
                        f"artifact: {firmware_bin}"
                    )
                if current_source_identity(project_dir, environment) != expected_identity:
                    raise BuildError(
                        "firmware source identity changed during the deterministic build"
                    )

                attestation_started = time.monotonic()
                try:
                    manifest_path = record_generated_sdkconfig_defaults(
                        project_dir, environment
                    )
                except GeneratedSdkconfigError as error:
                    raise BuildError(str(error)) from error
                attestation_ms = round(
                    (time.monotonic() - attestation_started) * 1000
                )
                manifest = None
                if manifest_path is not None:
                    manifest = _record_build_phase_timings(
                        manifest_path,
                        {
                            "runtimeBootstrap": int(os.environ.get(
                                "OPEN_BIKE_FIRMWARE_RUNTIME_BOOTSTRAP_MS", "0"
                            )),
                            "platformPreparation": platform_prepare_ms,
                            "customCoreBootstrap": custom_core_bootstrap_ms,
                            "applicationCompile": application_compile_ms,
                            "applicationBuild": application_build_ms,
                            "link": link_ms,
                            "attestation": attestation_ms,
                            "total": round((time.monotonic() - build_started) * 1000),
                        },
                    )
                if (
                    environment.startswith("WAVESHARE_AMOLED_")
                    and FULL_GIT_SHA.fullmatch(expected_identity) is not None
                    and manifest is None
                ):
                    _print_provenance(
                        "FIRMWARE_BUILD_PROVENANCE",
                        environment,
                        expected_identity,
                        None,
                    )
                    raise BuildError(
                        "clean Waveshare build did not produce upload-eligible "
                        "core and generated-state attestation"
                    )
                _print_provenance(
                    "FIRMWARE_BUILD_PROVENANCE",
                    environment,
                    expected_identity,
                    manifest,
                )
                print(f"Verified real firmware artifact: {firmware_elf}", flush=True)
                return firmware_elf

    raise AssertionError("unreachable")


def upload_firmware(
    project_dir: Path,
    environment: str,
    upload_port: str | None = None,
    *,
    device_serial: str | None = None,
    device_timeout: float = 60.0,
    runner: Callable[..., subprocess.CompletedProcess] = subprocess.run,
    resolver_runner: Callable[..., subprocess.CompletedProcess] = subprocess.run,
) -> None:
    """Upload the exact verified images without asking PlatformIO to rebuild."""
    project_dir = project_dir.resolve()
    _validate_environment(project_dir, environment)
    _reject_source_affecting_environment()
    if not environment.startswith("WAVESHARE_AMOLED_"):
        raise BuildError(
            "verified upload is limited to attested WAVESHARE_AMOLED profiles"
        )
    if (upload_port is None) == (device_serial is None):
        raise BuildError("provide exactly one upload port or device serial")
    if upload_port is not None and (not upload_port.strip() or "\0" in upload_port):
        raise BuildError("upload port must not be empty")
    if device_serial is not None and (
        not device_serial.strip()
        or not device_serial.strip().isprintable()
        or "\0" in device_serial
    ):
        raise BuildError("device serial must not be empty")

    firmware_elf = project_dir / ".pio" / "build" / environment / "firmware.elf"
    if firmware_elf.is_symlink() or not firmware_elf.is_file():
        raise BuildError(
            "refusing to upload without a verified real-target artifact: "
            f"{firmware_elf}"
        )
    expected_identity = current_source_identity(project_dir, environment)
    if FULL_GIT_SHA.fullmatch(expected_identity) is None:
        raise BuildError(
            "refusing AMOLED upload without an exact clean Git source identity"
        )

    with _project_build_lock(project_dir):
        verified_config, platform_archive = _verified_platformio_project_config(
            project_dir
        )
        with _deterministic_build_environment(
            project_dir,
            environment,
            expected_identity,
            platform_archive,
            verified_config,
        ):
            _reset_profile_override_inputs(project_dir, environment)
            try:
                manifest = require_validated_generated_sdkconfig_defaults(
                    project_dir, environment
                )
            except GeneratedSdkconfigError as error:
                raise BuildError(str(error)) from error
            # The attested private esptool environment must remain reusable after
            # both successful uploads and connection failures. Importing pyserial
            # can otherwise create new bytecode inside the attested penv and make
            # an unchanged build fail its next validation.
            os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
            resolved_port = upload_port
            if device_serial is not None:
                resolved_port = _resolved_device_port(
                    project_dir,
                    manifest,
                    device_serial,
                    device_timeout,
                    runner=resolver_runner,
                )
            if resolved_port is None:
                raise AssertionError("validated upload selector did not resolve")
            command: Sequence[str] = _verified_flash_command(
                resolved_port,
                manifest,
            )
            _print_provenance(
                "FIRMWARE_UPLOAD_PROVENANCE",
                environment,
                expected_identity,
                manifest,
            )
            try:
                result = runner(command, cwd=project_dir)
            except OSError as error:
                raise BuildError(
                    f"could not run the verified esptool uploader: {error}"
                ) from error
    if result.returncode != 0:
        raise BuildError(
            f"esptool exited with status {result.returncode} while uploading "
            f"{environment}"
        )


def _parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("environment", help="PlatformIO environment to build")
    parser.add_argument(
        "--project-dir",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="PlatformIO project directory (default: esp32/)",
    )
    parser.add_argument(
        "--repair-runtime",
        action="store_true",
        help="safely recreate only the exact locked runtime target before building",
    )
    upload_selector = parser.add_mutually_exclusive_group()
    upload_selector.add_argument(
        "--upload-port",
        help=(
            "after a verified build, upload through the same deterministic "
            "identity boundary"
        ),
    )
    upload_selector.add_argument(
        "--device-serial",
        help=(
            "resolve the upload port immediately before flashing from this stable "
            "USB hardware serial"
        ),
    )
    parser.add_argument(
        "--device-timeout",
        type=float,
        default=60.0,
        help="seconds to wait for --device-serial to appear (default: 60)",
    )
    parser.add_argument(
        "--upload-only",
        action="store_true",
        help="revalidate and upload an existing attested build without rebuilding",
    )
    return parser.parse_args(argv)


def main(
    argv: Sequence[str] | None = None,
    *,
    runtime_handoff: Callable[
        [Sequence[str], Path], RuntimeProvenance | None
    ] = ensure_runtime_handoff,
) -> int:
    raw_arguments = tuple(sys.argv[1:] if argv is None else argv)
    args = _parse_args(raw_arguments)
    try:
        device_serial = args.device_serial
        try:
            runtime = runtime_handoff(raw_arguments, args.project_dir.resolve())
            pio_command = (
                "unit-test-pio"
                if runtime is None
                else str(runtime_pio_path(args.project_dir.resolve(), runtime))
            )
        except FirmwareRuntimeError as error:
            raise BuildError(str(error)) from error
        if args.upload_only and args.upload_port is None and device_serial is None:
            raise BuildError(
                "--upload-only requires --upload-port or --device-serial"
            )
        if device_serial is None and args.device_timeout != 60.0:
            raise BuildError("--device-timeout requires --device-serial")
        if not math.isfinite(args.device_timeout) or args.device_timeout < 0:
            raise BuildError("device timeout must be a finite nonnegative value")
        if not args.upload_only:
            build_firmware(args.project_dir, args.environment, pio_command=pio_command)
        if args.upload_port is not None or device_serial is not None:
            upload_options: dict[str, object] = {
                "device_serial": device_serial,
                "device_timeout": args.device_timeout,
            }
            upload_firmware(
                args.project_dir,
                args.environment,
                args.upload_port,
                **upload_options,
            )
    except BuildError as error:
        print(f"Firmware build failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
