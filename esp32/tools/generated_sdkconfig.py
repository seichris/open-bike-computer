from __future__ import annotations

import configparser
import hashlib
import json
import ntpath
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

from firmware_build_identity import FULL_GIT_SHA, firmware_git_identity


ENVIRONMENT_PATTERN = re.compile(r"^[A-Za-z0-9_-]+$")
GENERATED_BANNER = b"# Automatically generated file. DO NOT EDIT."
GENERATED_DESCRIPTION = b"Project Configuration"
CACHE_SCHEMA = 16
WAVESHARE_MCU = "esp32s3"
WAVESHARE_MEMORY_TYPE = "qio_opi"
WAVESHARE_PLATFORM_URL = (
    "https://github.com/pioarduino/platform-espressif32/releases/download/"
    "55.03.34/platform-espressif32.zip"
)
WAVESHARE_PLATFORM_ARCHIVE_SHA256 = (
    "16ba6095ed92eef98cb497df281bdcdf4cb4cd2f7d40671fb19df17f98517bb1"
)
WAVESHARE_PLATFORM_ARCHIVE_SIZE = 1_620_690
WAVESHARE_PLATFORM_PACKAGES = (
    (
        "framework-arduinoespressif32",
        "https://github.com/espressif/arduino-esp32/releases/download/3.3.4/"
        "esp32-3.3.4.tar.xz",
        "c1fad548ec31b3b3725290113f8cb4d84bdc020c7491e19b177cc720ea7a5a68",
        20_618_140,
    ),
    (
        "framework-arduinoespressif32-libs",
        "https://github.com/espressif/arduino-esp32/releases/download/3.3.4/"
        "esp32-3.3.4-libs.tar.xz",
        "d8ff1f3961acc80b16ca14e306ec9342865abb3e0e458e9aa8e4fe5807f11288",
        239_411_616,
    ),
    (
        "framework-espidf",
        "https://github.com/pioarduino/esp-idf/releases/download/"
        "v5.5.1.251106/esp-idf-v5.5.1.tar.xz",
        "2594d5de2db29f2c3a227597beb8b3892fe05566b3f7553c520187fda7cc47bb",
        42_371_864,
    ),
    (
        "toolchain-xtensa-esp-elf",
        "https://github.com/pioarduino/registry/releases/download/0.0.1/"
        "xtensa-esp-elf-14.2.0_20250730.zip",
        "5edc2f9ff942394a5eadc9175155eb63a630f0c9a84761554b057a2c6fa1c34b",
        1_602,
    ),
    (
        "tool-esptoolpy",
        "https://github.com/pioarduino/registry/releases/download/0.0.1/"
        "esptoolpy-v5.1.0.zip",
        "d693b0d75556f23cfc16005ab6e263b2dc9a16d310df8cd85d32ebc39b8e23b8",
        992,
    ),
    (
        "tool-esp_install",
        "https://github.com/pioarduino/esp_install/releases/download/v5.3.2/"
        "esp_install-v5.3.2.zip",
        "e96337b48b8b959369d29cf759518e637552895265c1aa2c03a878ae9805828a",
        52_991,
    ),
    (
        "contrib-piohome",
        "https://github.com/pioarduino/registry/releases/download/0.0.1/"
        "contrib-piohome-3.4.4.tar.gz",
        "94a46ef4f317d81d08496f45532b873989b231163cfbdb5ac06e2ba86518e9e9",
        922_895,
    ),
    (
        "tool-mklittlefs",
        "https://github.com/pioarduino/registry/releases/download/0.0.1/"
        "mklittlefs-3.2.0-new.zip",
        "8e085c236bcf77ae5fe150499626a2ab4419e095e32590f46602973acf60d2f4",
        1_315,
    ),
    (
        "tool-cmake",
        "https://github.com/pioarduino/registry/releases/download/0.0.1/"
        "cmake-4.0.3.zip",
        "10fbfcfb1ed89a8e95b6a55a01da33149836a50b6d40d7f2544bbada44b519d1",
        1_282,
    ),
    (
        "tool-esp-rom-elfs",
        "https://github.com/pioarduino/registry/releases/download/0.0.1/"
        "esp-rom-elfs-20241011.zip",
        "8f1f9041a44390650994499c95dd20851222a4bdaa162dd68f6cef5af3e39501",
        3_535_051,
    ),
    (
        "tool-ninja",
        "https://github.com/pioarduino/registry/releases/download/0.0.1/"
        "ninja-1.13.1.zip",
        "3067f4f1ba6dc022ecc548e43ad6cd08669d78e34f1ee439aeebd0a7672100f7",
        1_184,
    ),
    (
        "tool-scons",
        "https://github.com/pioarduino/scons/releases/download/4.8.1/"
        "scons-local-4.8.1.tar.gz",
        "289b1abf389b730ab5a1018ed9fc84e22d301e0d16c64548eb9db5bf8ba59d06",
        483_365,
    ),
)
WAVESHARE_PLATFORM_PACKAGES_SHA256 = hashlib.sha256(
    json.dumps(WAVESHARE_PLATFORM_PACKAGES, separators=(",", ":")).encode("utf-8")
).hexdigest()


class GeneratedSdkconfigError(RuntimeError):
    """Raised when a custom-core SDK config cannot be cleaned safely."""


def _is_generated_sdkconfig(path: Path) -> bool:
    if path.is_symlink() or not path.is_file():
        return False
    with path.open("rb") as stream:
        header = stream.read(512)
    return GENERATED_BANNER in header and GENERATED_DESCRIPTION in header


def _sdkconfig_paths(project_dir: Path, environment: str) -> tuple[Path, Path]:
    if not ENVIRONMENT_PATTERN.fullmatch(environment):
        raise GeneratedSdkconfigError(
            f"invalid PlatformIO environment for SDK config cleanup: {environment!r}"
        )
    return (
        project_dir / "sdkconfig.defaults",
        project_dir / f"sdkconfig.{environment}",
    )


def _file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _canonical_json_sha256(value: object) -> str:
    encoded = json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _cache_manifest_path(project_dir: Path) -> Path:
    return project_dir / ".pio" / "open-bike-build" / "sdkconfig-defaults.json"


def _tree_sha256(root: Path, *, allow_empty: bool = False) -> str:
    digest = hashlib.sha256()
    entries = sorted(root.rglob("*"))
    for path in entries:
        if path.is_symlink():
            raise GeneratedSdkconfigError(
                f"custom-core output contains a symlink: {path}"
            )
    files = [path for path in entries if path.is_file()]
    if not files and not allow_empty:
        raise GeneratedSdkconfigError(f"custom-core output tree is empty: {root}")
    for path in files:
        relative = path.relative_to(root).as_posix().encode("utf-8")
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        digest.update(bytes.fromhex(_file_sha256(path)))
    return digest.hexdigest()


def _execution_tree_sha256(root: Path) -> str:
    """Hash an executable package tree, including safe symlink semantics."""
    if root.is_symlink() or not root.is_dir():
        raise GeneratedSdkconfigError(f"execution tree is missing or unsafe: {root}")
    resolved_root = root.resolve()
    entries = sorted(root.rglob("*"))
    if not entries:
        raise GeneratedSdkconfigError(f"execution tree is empty: {root}")
    digest = hashlib.sha256()
    for path in entries:
        relative = path.relative_to(root).as_posix().encode("utf-8")
        metadata = path.lstat()
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        digest.update(stat.S_IMODE(metadata.st_mode).to_bytes(4, "big"))
        if path.is_symlink():
            target_text = os.readlink(path).encode("utf-8")
            try:
                target = path.resolve(strict=True)
            except OSError as error:
                raise GeneratedSdkconfigError(
                    f"execution tree contains a broken symlink: {path}"
                ) from error
            digest.update(b"L")
            digest.update(len(target_text).to_bytes(4, "big"))
            digest.update(target_text)
            if target.is_file():
                digest.update(b"F")
                digest.update(bytes.fromhex(_file_sha256(target)))
            elif target.is_dir():
                try:
                    target.relative_to(resolved_root)
                except ValueError as error:
                    raise GeneratedSdkconfigError(
                        "execution tree contains an external directory symlink: "
                        f"{path}"
                    ) from error
                digest.update(b"D")
            else:
                raise GeneratedSdkconfigError(
                    f"execution tree contains an unsafe symlink target: {path}"
                )
        elif path.is_file():
            digest.update(b"F")
            digest.update(bytes.fromhex(_file_sha256(path)))
        elif path.is_dir():
            digest.update(b"D")
        else:
            raise GeneratedSdkconfigError(
                f"execution tree contains a special file: {path}"
            )
    return digest.hexdigest()


def _load_manifest(path: Path) -> dict[str, object] | None:
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    return manifest if isinstance(manifest, dict) else None


def current_source_identity(project_dir: Path, environment: str) -> str:
    try:
        repo_root = Path(
            subprocess.check_output(
                ["git", "rev-parse", "--show-toplevel"],
                cwd=project_dir,
                stderr=subprocess.DEVNULL,
                text=True,
            ).strip()
        ).resolve()
        allowed = recognized_generated_sdkconfigs(project_dir, environment)
        return firmware_git_identity(repo_root, allowed_untracked_paths=allowed)
    except (OSError, subprocess.CalledProcessError, GeneratedSdkconfigError):
        return "unidentified"


def _managed_components_sha256(project_dir: Path) -> str | None:
    root = project_dir / "managed_components"
    if not os.path.lexists(root):
        return None
    if root.is_symlink() or not root.is_dir():
        raise GeneratedSdkconfigError(
            f"unsafe ESP-IDF managed-components artifact: {root}"
        )
    return _tree_sha256(root, allow_empty=True)


def _remove_managed_components(project_dir: Path) -> bool:
    """Remove only an ESP-IDF Component Manager-owned generated tree."""
    root = project_dir / "managed_components"
    if not os.path.lexists(root):
        return False
    if root.is_symlink() or not root.is_dir():
        raise GeneratedSdkconfigError(
            f"refusing to remove unsafe managed-components artifact: {root}"
        )
    if _is_tracked(project_dir, root):
        raise GeneratedSdkconfigError(
            f"refusing to remove tracked managed-components content: {root}"
        )
    children = list(root.iterdir())
    for child in children:
        if (
            child.is_symlink()
            or not child.is_dir()
            or (child / ".component_hash").is_symlink()
            or not (child / ".component_hash").is_file()
        ):
            raise GeneratedSdkconfigError(
                "refusing to remove unrecognized managed-components content: "
                f"{child}"
            )
    shutil.rmtree(root)
    return True


def _library_dependencies_root(project_dir: Path, environment: str) -> Path:
    _sdkconfig_paths(project_dir, environment)
    root = _resolve_platformio_dir(
        project_dir,
        os.environ.get("PLATFORMIO_LIBDEPS_DIR"),
        project_dir / ".pio" / "libdeps",
    )
    return root / environment


def _library_dependencies_sha256(
    project_dir: Path, environment: str
) -> str | None:
    root = _library_dependencies_root(project_dir, environment)
    if not os.path.lexists(root):
        return None
    if root.is_symlink() or not root.is_dir():
        raise GeneratedSdkconfigError(
            f"unsafe PlatformIO library-dependency artifact: {root}"
        )
    return _tree_sha256(root, allow_empty=True)


def _remove_library_dependencies(project_dir: Path, environment: str) -> bool:
    root = _library_dependencies_root(project_dir, environment)
    for parent in (root.parent,):
        if parent.is_symlink():
            raise GeneratedSdkconfigError(
                f"refusing to clean library dependencies through symlink: {parent}"
            )
    if not os.path.lexists(root):
        return False
    if root.is_symlink() or not root.is_dir():
        raise GeneratedSdkconfigError(
            f"refusing to remove unsafe library-dependency artifact: {root}"
        )
    shutil.rmtree(root)
    return True


def _firmware_artifact_hashes(
    project_dir: Path, environment: str
) -> dict[str, str]:
    build_dir = project_dir / ".pio" / "build" / environment
    artifacts = {
        "firmwareElfSha256": build_dir / "firmware.elf",
        "firmwareBinSha256": build_dir / "firmware.bin",
        "bootloaderBinSha256": build_dir / "bootloader.bin",
        "partitionTableBinSha256": build_dir / "partitions.bin",
    }
    for path in artifacts.values():
        if path.is_symlink() or not path.is_file():
            raise GeneratedSdkconfigError(
                f"verified firmware artifact is missing or unsafe: {path}"
            )
    return {key: _file_sha256(path) for key, path in artifacts.items()}


def _has_unsupported_project_overrides(project_dir: Path) -> bool:
    config = configparser.RawConfigParser(interpolation=None)
    try:
        with (project_dir / "platformio.ini").open(encoding="utf-8") as stream:
            config.read_file(stream)
    except (OSError, UnicodeError, configparser.Error):
        return True
    return any(
        config.has_option("platformio", option)
        for option in (
            "core_dir",
            "home_dir",
            "packages_dir",
            "platforms_dir",
            "globallib_dir",
            "workspace_dir",
            "build_dir",
            "build_cache_dir",
            "libdeps_dir",
            "include_dir",
            "src_dir",
            "lib_dir",
            "boards_dir",
            "extra_configs",
        )
    )


def _resolve_platformio_dir(
    project_dir: Path, configured: str | None, fallback: Path
) -> Path:
    path = Path(configured).expanduser() if configured else fallback
    if not path.is_absolute():
        path = project_dir / path
    return path.resolve()


def _default_platformio_core_dir() -> Path:
    default = Path(os.path.expanduser("~")) / ".platformio"
    if sys.platform.startswith("win"):
        drive = ntpath.splitdrive(str(default))[0]
        legacy = Path(f"{drive}\\.platformio")
        if os.path.isdir(legacy):
            return legacy
    return default


def _core_attestation(
    project_dir: Path, environment: str
) -> dict[str, object] | None:
    if not environment.startswith("WAVESHARE_"):
        return None
    if _has_unsupported_project_overrides(project_dir):
        return None
    configured_core = os.environ.get("PLATFORMIO_CORE_DIR") or os.environ.get(
        "PLATFORMIO_HOME_DIR"
    )
    core_dir = _resolve_platformio_dir(
        project_dir,
        configured_core,
        _default_platformio_core_dir(),
    )
    configured_packages = os.environ.get("PLATFORMIO_PACKAGES_DIR")
    configured_platforms = os.environ.get("PLATFORMIO_PLATFORMS_DIR")
    configured_globallib = os.environ.get("PLATFORMIO_GLOBALLIB_DIR")
    configured_boards = os.environ.get("PLATFORMIO_BOARDS_DIR")
    package_root = _resolve_platformio_dir(
        project_dir, configured_packages, core_dir / "packages"
    )
    platforms_root = _resolve_platformio_dir(
        project_dir, configured_platforms, core_dir / "platforms"
    )
    globallib_root = _resolve_platformio_dir(
        project_dir, configured_globallib, core_dir / "lib"
    )
    boards_root = _resolve_platformio_dir(
        project_dir, configured_boards, core_dir / "boards"
    )
    platform_root = platforms_root / "espressif32"
    framework_root = package_root / "framework-arduinoespressif32"
    libs_root = package_root / "framework-arduinoespressif32-libs"
    mcu_root = libs_root / WAVESHARE_MCU
    tools_root = core_dir / "tools"
    penv_root = core_dir / "penv"
    evidence_paths = {
        "frameworkPackageSha256": framework_root / "package.json",
        "bootApp0Sha256": framework_root / "tools/partitions/boot_app0.bin",
        "frameworkLibsPackageSha256": libs_root / "package.json",
        "frameworkSdkconfigSha256": libs_root / WAVESHARE_MCU / "sdkconfig",
        "platformManifestSha256": platform_root / "platform.json",
        "platformPackageSha256": platform_root / ".piopm",
        "arduinoBuilderSha256": platform_root / "builder/frameworks/arduino.py",
        "espidfBuilderSha256": platform_root / "builder/frameworks/espidf.py",
        "boardManifestSha256": (
            platform_root / "boards/esp32-s3-devkitc-1.json"
        ),
    }
    for path in evidence_paths.values():
        if path.is_symlink() or not path.is_file():
            return None
    if (
        framework_root.is_symlink()
        or not framework_root.is_dir()
        or libs_root.is_symlink()
        or not libs_root.is_dir()
        or mcu_root.is_symlink()
        or not mcu_root.is_dir()
        or platform_root.is_symlink()
        or not platform_root.is_dir()
        or tools_root.is_symlink()
        or not tools_root.is_dir()
        or penv_root.is_symlink()
        or not penv_root.is_dir()
        or globallib_root.is_symlink()
        or not globallib_root.is_dir()
        or boards_root.is_symlink()
        or not boards_root.is_dir()
    ):
        return None
    try:
        evidence = {key: _file_sha256(path) for key, path in evidence_paths.items()}
        evidence["frameworkSourceTreeSha256"] = _tree_sha256(framework_root)
        evidence["mcuCoreTreeSha256"] = _tree_sha256(mcu_root)
        evidence["platformTreeSha256"] = _tree_sha256(platform_root)
        evidence["packagesTreeSha256"] = _execution_tree_sha256(package_root)
        evidence["toolsTreeSha256"] = _execution_tree_sha256(tools_root)
        evidence["penvTreeSha256"] = _execution_tree_sha256(penv_root)
        evidence["globalLibrariesTreeSha256"] = _tree_sha256(
            globallib_root, allow_empty=True
        )
        evidence["coreBoardsTreeSha256"] = _tree_sha256(
            boards_root, allow_empty=True
        )
    except (OSError, GeneratedSdkconfigError):
        return None
    evidence.update(
        {
            "coreDir": str(core_dir),
            "packagesDir": str(package_root),
            "platformsDir": str(platforms_root),
            "globalLibrariesDir": str(globallib_root),
            "coreBoardsDir": str(boards_root),
            "environment": environment,
            "mcu": WAVESHARE_MCU,
            "memoryType": WAVESHARE_MEMORY_TYPE,
            "platformArchiveSha256": WAVESHARE_PLATFORM_ARCHIVE_SHA256,
            "platformPackagesSha256": WAVESHARE_PLATFORM_PACKAGES_SHA256,
        }
    )
    return evidence


def _is_tracked(project_dir: Path, path: Path) -> bool:
    try:
        tracked = subprocess.run(
            ["git", "ls-files", "--error-unmatch", "--", path.name],
            cwd=project_dir,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except OSError as error:
        raise GeneratedSdkconfigError(
            f"could not verify SDK configuration ownership: {error}"
        ) from error
    if tracked.returncode == 0:
        return True
    if tracked.returncode == 1:
        return False
    raise GeneratedSdkconfigError(
        "could not verify SDK configuration ownership: "
        f"git ls-files exited with status {tracked.returncode}"
    )


def _cached_defaults_match(
    project_dir: Path, defaults: Path, environment: str
) -> bool:
    manifest_path = _cache_manifest_path(project_dir)
    platformio_ini = project_dir / "platformio.ini"
    if (
        not manifest_path.is_file()
        or manifest_path.is_symlink()
        or not platformio_ini.is_file()
        or platformio_ini.is_symlink()
    ):
        return False
    manifest = _load_manifest(manifest_path)
    if manifest is None:
        return False
    current_core = _core_attestation(project_dir, environment)
    try:
        managed_components_sha = _managed_components_sha256(project_dir)
        library_dependencies_sha = _library_dependencies_sha256(
            project_dir, environment
        )
    except GeneratedSdkconfigError:
        return False
    source_identity = current_source_identity(project_dir, environment)
    return (
        manifest.get("schema") == CACHE_SCHEMA
        and "environmentSdkconfigSha256" in manifest
        and "managedComponentsSha256" in manifest
        and "libraryDependenciesSha256" in manifest
        and manifest.get("platformArchiveSha256")
        == WAVESHARE_PLATFORM_ARCHIVE_SHA256
        and manifest.get("platformPackagesSha256")
        == WAVESHARE_PLATFORM_PACKAGES_SHA256
        and FULL_GIT_SHA.fullmatch(source_identity) is not None
        and manifest.get("sourceIdentity") == source_identity
        and manifest.get("managedComponentsSha256") == managed_components_sha
        and manifest.get("libraryDependenciesSha256")
        == library_dependencies_sha
        and manifest.get("sdkconfigDefaultsSha256") == _file_sha256(defaults)
        and manifest.get("platformioIniSha256") == _file_sha256(platformio_ini)
        and current_core is not None
        and manifest.get("coreAttestation") == current_core
        and manifest.get("coreAttestationSha256")
        == _canonical_json_sha256(current_core)
        and manifest.get("bootApp0Sha256")
        == current_core.get("bootApp0Sha256")
    )


def recognized_generated_sdkconfigs(
    project_dir: Path, environment: str
) -> tuple[Path, ...]:
    """Return generated configs, rejecting unsafe active path occupants.

    pioarduino leaves one ``sdkconfig.<environment>`` per profile. All
    recognized generated profiles are build artifacts, but only the defaults
    and selected environment can affect this build. An unrecognized occupant
    at either active path is therefore an error; unrelated manual profiles are
    preserved and remain visible to firmware identity.
    """
    active_paths = _sdkconfig_paths(project_dir, environment)
    candidates = list(active_paths)
    candidates.extend(
        path
        for path in sorted(project_dir.glob("sdkconfig.*"))
        if path not in active_paths
    )
    recognized: list[Path] = []
    for path in candidates:
        if not os.path.lexists(path):
            continue
        if not _is_generated_sdkconfig(path):
            if path in active_paths:
                raise GeneratedSdkconfigError(
                    f"unrecognized SDK configuration cannot be allowlisted: {path}"
                )
            continue
        recognized.append(path)
    return tuple(recognized)


def remove_generated_sdkconfigs(
    project_dir: Path, environment: str
) -> tuple[Path, ...]:
    """Remove only recognized pioarduino SDK configs for a deterministic build."""
    removed = list(recognized_generated_sdkconfigs(project_dir, environment))
    for path in removed:
        if _is_tracked(project_dir, path):
            raise GeneratedSdkconfigError(
                f"refusing to remove tracked SDK configuration: {path}"
            )
    for path in removed:
        path.unlink()
    return tuple(removed)


def prepare_generated_sdkconfigs(
    project_dir: Path, environment: str
) -> tuple[Path, ...]:
    """Keep only a helper-validated defaults cache; remove profile outputs.

    The pinned pioarduino platform uses ``sdkconfig.defaults`` as its custom-core
    cache key. Removing a known-good file forces a shared framework reinstall,
    while trusting an arbitrary untracked file can hide effective build input.
    Preserve it only when its exact contents and ``platformio.ini`` match the
    helper-owned record from a previous successful real-target build.
    """
    defaults, _ = _sdkconfig_paths(project_dir, environment)
    recognized = list(recognized_generated_sdkconfigs(project_dir, environment))
    for path in recognized:
        if _is_tracked(project_dir, path):
            raise GeneratedSdkconfigError(
                f"refusing to use tracked SDK configuration as generated state: {path}"
            )

    cache_valid = defaults in recognized and _cached_defaults_match(
        project_dir, defaults, environment
    )
    preserved: list[Path] = []
    for path in recognized:
        if path == defaults and cache_valid:
            preserved.append(path)
            continue
        path.unlink()
    if not cache_valid:
        _remove_managed_components(project_dir)
        _remove_library_dependencies(project_dir, environment)
    return tuple(preserved)


def require_validated_generated_sdkconfig_defaults(
    project_dir: Path, environment: str
) -> dict[str, object]:
    """Require the recorded custom-core state immediately before upload."""
    if not environment.startswith("WAVESHARE_AMOLED_"):
        return {}
    defaults, environment_config = _sdkconfig_paths(project_dir, environment)
    if not os.path.lexists(defaults) or not _is_generated_sdkconfig(defaults):
        raise GeneratedSdkconfigError(
            "refusing AMOLED upload without generated sdkconfig.defaults from "
            "the verified build"
        )
    if _is_tracked(project_dir, defaults):
        raise GeneratedSdkconfigError(
            f"refusing AMOLED upload with tracked SDK configuration: {defaults}"
        )
    if not _cached_defaults_match(project_dir, defaults, environment):
        raise GeneratedSdkconfigError(
            "refusing AMOLED upload because generated SDK config or installed "
            "custom-core state changed after the verified build"
        )
    manifest_path = _cache_manifest_path(project_dir)
    manifest = _load_manifest(manifest_path)
    if manifest is None:
        raise GeneratedSdkconfigError(
            "refusing AMOLED upload without an object SDK configuration cache"
        )
    current_artifacts = _firmware_artifact_hashes(project_dir, environment)
    for key, current_hash in current_artifacts.items():
        if manifest.get(key) != current_hash:
            raise GeneratedSdkconfigError(
                "refusing AMOLED upload because the verified firmware artifact "
                f"changed after the build: {key}"
            )
    expected_environment_hash = manifest.get("environmentSdkconfigSha256")
    if expected_environment_hash is None:
        if os.path.lexists(environment_config):
            raise GeneratedSdkconfigError(
                "refusing AMOLED upload because an environment SDK "
                "configuration appeared after the verified build"
            )
    else:
        if not _is_generated_sdkconfig(environment_config):
            raise GeneratedSdkconfigError(
                "refusing AMOLED upload without the generated environment SDK "
                "configuration recorded by the verified build"
            )
        if _is_tracked(project_dir, environment_config):
            raise GeneratedSdkconfigError(
                "refusing AMOLED upload with tracked environment SDK "
                f"configuration: {environment_config}"
            )
        if expected_environment_hash != _file_sha256(environment_config):
            raise GeneratedSdkconfigError(
                "refusing AMOLED upload because the generated environment SDK "
                "configuration changed after the verified build"
            )
    return manifest


def record_generated_sdkconfig_defaults(
    project_dir: Path, environment: str
) -> Path | None:
    """Record the generated defaults after a successful real-target build."""
    defaults, environment_config = _sdkconfig_paths(project_dir, environment)
    recognized_generated_sdkconfigs(project_dir, environment)
    if not os.path.lexists(defaults):
        return None
    if not _is_generated_sdkconfig(defaults):
        raise GeneratedSdkconfigError(
            f"cannot cache unrecognized SDK configuration: {defaults}"
        )
    if _is_tracked(project_dir, defaults):
        raise GeneratedSdkconfigError(
            f"refusing to cache tracked SDK configuration: {defaults}"
        )

    platformio_ini = project_dir / "platformio.ini"
    if platformio_ini.is_symlink() or not platformio_ini.is_file():
        raise GeneratedSdkconfigError(
            f"cannot fingerprint PlatformIO configuration: {platformio_ini}"
        )
    core_attestation = _core_attestation(project_dir, environment)
    source_identity = current_source_identity(project_dir, environment)
    if core_attestation is None or FULL_GIT_SHA.fullmatch(source_identity) is None:
        manifest_path = _cache_manifest_path(project_dir)
        if manifest_path.is_file() or manifest_path.is_symlink():
            manifest_path.unlink()
        return None
    managed_components_sha = _managed_components_sha256(project_dir)
    library_dependencies_sha = _library_dependencies_sha256(
        project_dir, environment
    )
    firmware_artifacts = _firmware_artifact_hashes(project_dir, environment)
    manifest = {
        "schema": CACHE_SCHEMA,
        "sourceIdentity": source_identity,
        "managedComponentsSha256": managed_components_sha,
        "libraryDependenciesSha256": library_dependencies_sha,
        "sdkconfigDefaultsSha256": _file_sha256(defaults),
        "platformioIniSha256": _file_sha256(platformio_ini),
        "platformArchiveSha256": WAVESHARE_PLATFORM_ARCHIVE_SHA256,
        "platformPackagesSha256": WAVESHARE_PLATFORM_PACKAGES_SHA256,
        "coreAttestation": core_attestation,
        "coreAttestationSha256": _canonical_json_sha256(core_attestation),
        "bootApp0Sha256": core_attestation["bootApp0Sha256"],
        "environmentSdkconfigSha256": None,
        **firmware_artifacts,
    }
    if os.path.lexists(environment_config):
        if not _is_generated_sdkconfig(environment_config):
            raise GeneratedSdkconfigError(
                f"cannot cache unrecognized SDK configuration: {environment_config}"
            )
        if _is_tracked(project_dir, environment_config):
            raise GeneratedSdkconfigError(
                "refusing to cache tracked environment SDK configuration: "
                f"{environment_config}"
            )
        manifest["environmentSdkconfigSha256"] = _file_sha256(environment_config)
    manifest_path = _cache_manifest_path(project_dir)
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    if manifest_path.parent.is_symlink() or not manifest_path.parent.is_dir():
        raise GeneratedSdkconfigError(
            f"unsafe SDK configuration cache directory: {manifest_path.parent}"
        )
    temporary_name = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=manifest_path.parent,
            prefix=f".{manifest_path.name}.",
            delete=False,
        ) as stream:
            temporary_name = stream.name
            json.dump(manifest, stream, sort_keys=True)
            stream.write("\n")
        os.replace(temporary_name, manifest_path)
    except OSError as error:
        if temporary_name is not None:
            try:
                Path(temporary_name).unlink()
            except OSError:
                pass
        raise GeneratedSdkconfigError(
            f"could not record SDK configuration cache: {error}"
        ) from error
    return manifest_path
