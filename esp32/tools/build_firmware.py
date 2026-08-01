#!/usr/bin/env python3
"""Build a real PlatformIO firmware target across pioarduino bootstrap passes."""

from __future__ import annotations

import argparse
import configparser
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request
from contextlib import contextmanager
from pathlib import Path
from typing import Callable, Iterator, Sequence

from generated_sdkconfig import (
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
from firmware_build_identity import FULL_GIT_SHA


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
        "PLATFORMIO_CMD",
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
            f"platform = {archive.as_uri()}{package_override.rstrip()}",
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
    store_root = _ensure_private_directory(
        project_dir, Path(".pio/open-bike-build/platformio") / environment
    )
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
            "IDF_TOOLS_PATH": str(store_root),
            "OPEN_BIKE_DETERMINISTIC_BUILD": "1",
            "OPEN_BIKE_EXPECTED_GIT_SHA": expected_identity,
            "OPEN_BIKE_PINNED_SCONS_PIOPM": _pinned_nested_scons_piopm(),
            "OPEN_BIKE_VERIFIED_PROJECT_CONFIG": str(verified_config),
            "OPEN_BIKE_PLATFORM_ARCHIVE_SHA256": _file_sha256(platform_archive),
            "OPEN_BIKE_PLATFORM_PACKAGES_SHA256": (
                WAVESHARE_PLATFORM_PACKAGES_SHA256
            ),
        }
    )
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

    print(
        f"{marker} schema=1 environment={environment} git={source_identity} "
        f"uploadEligible={1 if manifest else 0} "
        f"firmwareBinSha256={value('firmwareBinSha256')} "
        f"firmwareElfSha256={value('firmwareElfSha256')} "
        f"bootloaderBinSha256={value('bootloaderBinSha256')} "
        f"partitionTableBinSha256={value('partitionTableBinSha256')} "
        f"bootApp0Sha256={value('bootApp0Sha256')} "
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

    project_dir = project_dir.resolve()
    if max_passes < 1:
        raise BuildError("max_passes must be at least 1")
    _validate_environment(project_dir, environment)
    _reject_source_affecting_environment()
    expected_identity = current_source_identity(project_dir, environment)

    firmware_elf = project_dir / ".pio" / "build" / environment / "firmware.elf"
    firmware_bin = project_dir / ".pio" / "build" / environment / "firmware.bin"

    with _project_build_lock(project_dir):
        verified_config, platform_archive = _verified_platformio_project_config(
            project_dir
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
            _reset_profile_build_cache(project_dir, environment)
            toolchain_ready_before_pass = _pioarduino_toolchain_bootstrap_ready(
                project_dir, environment
            )
            for pass_number in range(1, max_passes + 1):
                print(
                    f"=== PlatformIO real-target build: {environment} "
                    f"(pass {pass_number}/{max_passes}) ===",
                    flush=True,
                )
                try:
                    result = runner(command, cwd=project_dir)
                except OSError as error:
                    raise BuildError(
                        f"could not run {pio_command!r}: {error}"
                    ) from error

                if os.path.lexists(project_dir / ".dummy"):
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

                try:
                    manifest_path = record_generated_sdkconfig_defaults(
                        project_dir, environment
                    )
                except GeneratedSdkconfigError as error:
                    raise BuildError(str(error)) from error
                manifest = None
                if manifest_path is not None:
                    try:
                        loaded = json.loads(manifest_path.read_text(encoding="utf-8"))
                    except (OSError, UnicodeError, json.JSONDecodeError) as error:
                        raise BuildError(
                            f"could not read recorded build provenance: {error}"
                        ) from error
                    if not isinstance(loaded, dict):
                        raise BuildError("recorded build provenance is not an object")
                    manifest = loaded
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
    upload_port: str,
    *,
    pio_command: str = "pio",
    runner: Callable[..., subprocess.CompletedProcess] = subprocess.run,
) -> None:
    """Upload a verified build without weakening its source-identity gate."""
    project_dir = project_dir.resolve()
    _validate_environment(project_dir, environment)
    _reject_source_affecting_environment()
    if not environment.startswith("WAVESHARE_AMOLED_"):
        raise BuildError(
            "verified upload is limited to attested WAVESHARE_AMOLED profiles"
        )
    if not upload_port.strip():
        raise BuildError("upload port must not be empty")

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
        command: Sequence[str] = (
            pio_command,
            "run",
            "--project-conf",
            str(verified_config),
            "-e",
            environment,
            "-t",
            "nobuild",
            "-t",
            "upload",
            "--upload-port",
            upload_port,
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
            _print_provenance(
                "FIRMWARE_UPLOAD_PROVENANCE",
                environment,
                expected_identity,
                manifest,
            )
            try:
                result = runner(command, cwd=project_dir)
            except OSError as error:
                raise BuildError(f"could not run {pio_command!r}: {error}") from error
    if result.returncode != 0:
        raise BuildError(
            f"PlatformIO exited with status {result.returncode} while uploading "
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
        "--pio",
        default=os.environ.get("PLATFORMIO_CMD", "pio"),
        help="PlatformIO executable (default: pio or PLATFORMIO_CMD)",
    )
    parser.add_argument(
        "--upload-port",
        help=(
            "after a verified build, upload through the same deterministic "
            "identity boundary"
        ),
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _parse_args(argv)
    try:
        build_firmware(args.project_dir, args.environment, pio_command=args.pio)
        if args.upload_port is not None:
            upload_firmware(
                args.project_dir,
                args.environment,
                args.upload_port,
                pio_command=args.pio,
            )
    except BuildError as error:
        print(f"Firmware build failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
