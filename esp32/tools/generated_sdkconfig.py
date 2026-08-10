from __future__ import annotations

import configparser
import hashlib
import json
import ntpath
import os
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

from firmware_build_identity import (
    FULL_GIT_SHA,
    build_timestamp_from_source_date_epoch,
    firmware_git_identity,
    git_commit_source_date_epoch,
)


ENVIRONMENT_PATTERN = re.compile(r"^[A-Za-z0-9_-]+$")
GENERATED_BANNER = b"# Automatically generated file. DO NOT EDIT."
GENERATED_DESCRIPTION = b"Project Configuration"
CACHE_SCHEMA = 20
FLASH_PLAN_SCHEMA = 2
FLASH_PLAN_FILENAME = "open-bike-flash-plan.json"
FLASH_PLAN_PORT_PLACEHOLDER = "__OPEN_BIKE_UPLOAD_PORT__"
FLASH_PLAN_APP_OFFSET_PLACEHOLDER = "__OPEN_BIKE_APP_OFFSET__"
FLASH_PLAN_MAX_BYTES = 1024 * 1024
ESP_PARTITION_TABLE_MAX_BYTES = 0xC00
ESP_PARTITION_ENTRY = struct.Struct("<HBBII16sI")
ESP_PARTITION_MAGIC = 0x50AA
ESP_PARTITION_MD5_MAGIC = 0xEBEB
ESP_PARTITION_END_MAGIC = 0xFFFF
ESP_PARTITION_TYPE_APP = 0x00
ESP_PARTITION_SUBTYPE_FACTORY = 0x00
ESP_PARTITION_SUBTYPE_OTA_0 = 0x10
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


def _runtime_provenance() -> dict[str, object] | None:
    raw = os.environ.get("OPEN_BIKE_FIRMWARE_RUNTIME_PROVENANCE")
    if not raw:
        return None
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        return None
    required = {
        "lockSetId",
        "manifestSha256",
        "target",
        "bundleSha256",
        "pythonVersion",
        "pythonExecutableSha256",
        "runtimeTreeSha256",
        "pioSha256",
        "uvSha256",
        "platformioVersion",
        "topLevelDistributionSha256",
        "pioarduinoRootDistributionSha256",
        "espIdfDistributionSha256",
        "uvDistributionSha256",
        "esptoolDistributionSha256",
        "platformArchiveSha256",
        "platformPackagesSha256",
    }
    if not isinstance(value, dict) or set(value) != required:
        return None
    if not all(isinstance(value[key], str) and value[key] for key in required):
        return None
    for key in required - {
        "lockSetId", "target", "pythonVersion", "platformioVersion"
    }:
        if re.fullmatch(r"[0-9a-f]{64}", value[key]) is None:
            return None
    if (
        value["platformArchiveSha256"] != WAVESHARE_PLATFORM_ARCHIVE_SHA256
        or value["platformPackagesSha256"]
        != WAVESHARE_PLATFORM_PACKAGES_SHA256
    ):
        return None
    return value


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
    esptool_uploader = penv_root / (
        "Scripts/esptool.exe" if os.name == "nt" else "bin/esptool"
    )
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
        "esptoolUploaderSha256": esptool_uploader,
    }
    for path in evidence_paths.values():
        if path.is_symlink() or not path.is_file():
            return None
    if not os.access(esptool_uploader, os.X_OK):
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


def _path_is_within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
    except ValueError:
        return False
    return True


def _application_partition_from_partition_table(path: Path) -> tuple[int, int]:
    """Return the slot PlatformIO must use for the application image."""
    if path.is_symlink() or not path.is_file():
        raise GeneratedSdkconfigError(
            f"verified partition table is missing or unsafe: {path}"
        )
    try:
        table = path.read_bytes()
    except OSError as error:
        raise GeneratedSdkconfigError(
            f"could not read verified partition table: {error}"
        ) from error
    if (
        not table
        or len(table) > ESP_PARTITION_TABLE_MAX_BYTES
        or len(table) % ESP_PARTITION_ENTRY.size != 0
    ):
        raise GeneratedSdkconfigError(
            "verified partition table has an invalid size"
        )

    factory_partitions: list[tuple[int, int]] = []
    ota_0_partitions: list[tuple[int, int]] = []
    found_end = False
    for entry_start in range(0, len(table), ESP_PARTITION_ENTRY.size):
        magic, kind, subtype, offset, size, _, _ = ESP_PARTITION_ENTRY.unpack_from(
            table, entry_start
        )
        if magic == ESP_PARTITION_END_MAGIC:
            found_end = True
            break
        if magic == ESP_PARTITION_MD5_MAGIC:
            continue
        if magic != ESP_PARTITION_MAGIC:
            raise GeneratedSdkconfigError(
                "verified partition table contains an invalid entry"
            )
        if offset == 0 or size == 0 or offset + size > 0x1_0000_0000:
            raise GeneratedSdkconfigError(
                "verified partition table contains an invalid range"
            )
        if kind != ESP_PARTITION_TYPE_APP:
            continue
        if offset % 0x10000 != 0:
            raise GeneratedSdkconfigError(
                "verified partition table contains a misaligned application slot"
            )
        if subtype == ESP_PARTITION_SUBTYPE_FACTORY:
            factory_partitions.append((offset, size))
        elif subtype == ESP_PARTITION_SUBTYPE_OTA_0:
            ota_0_partitions.append((offset, size))

    if not found_end:
        raise GeneratedSdkconfigError(
            "verified partition table has no end marker"
        )
    selected_partitions = ota_0_partitions or factory_partitions
    if len(selected_partitions) != 1:
        raise GeneratedSdkconfigError(
            "verified partition table does not identify exactly one bootable "
            "application slot"
        )
    return selected_partitions[0]


def _parse_esptool_options(
    tokens: tuple[str, ...],
    *,
    value_options: set[str],
    flag_options: set[str],
    label: str,
) -> dict[str, str | bool]:
    parsed: dict[str, str | bool] = {}
    index = 0
    while index < len(tokens):
        option = tokens[index]
        if option in flag_options:
            if option in parsed:
                raise GeneratedSdkconfigError(
                    f"verified esptool {label} repeats {option}"
                )
            parsed[option] = True
            index += 1
            continue
        if option not in value_options or index + 1 >= len(tokens):
            raise GeneratedSdkconfigError(
                f"verified esptool {label} contains an unsupported argument: "
                f"{option}"
            )
        if option in parsed:
            raise GeneratedSdkconfigError(
                f"verified esptool {label} repeats {option}"
            )
        parsed[option] = tokens[index + 1]
        index += 2
    expected = value_options | flag_options
    if set(parsed) != expected:
        missing = ", ".join(sorted(expected - set(parsed)))
        raise GeneratedSdkconfigError(
            f"verified esptool {label} is missing required options: {missing}"
        )
    return parsed


def _validated_flash_plan(
    project_dir: Path,
    environment: str,
    core_attestation: dict[str, object],
) -> dict[str, object]:
    """Validate and normalize PlatformIO's resolved esptool command."""
    build_dir = project_dir / ".pio" / "build" / environment
    plan_path = build_dir / FLASH_PLAN_FILENAME
    if plan_path.is_symlink() or not plan_path.is_file():
        raise GeneratedSdkconfigError(
            f"verified PlatformIO flash plan is missing or unsafe: {plan_path}"
        )
    try:
        if plan_path.stat().st_size > FLASH_PLAN_MAX_BYTES:
            raise GeneratedSdkconfigError(
                "verified PlatformIO flash plan exceeds its size limit"
            )
        raw_plan = json.loads(plan_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise GeneratedSdkconfigError(
            f"could not read verified PlatformIO flash plan: {error}"
        ) from error
    if not isinstance(raw_plan, dict):
        raise GeneratedSdkconfigError(
            "verified PlatformIO flash plan is not an object"
        )
    if raw_plan.get("schema") != FLASH_PLAN_SCHEMA:
        raise GeneratedSdkconfigError(
            "verified PlatformIO flash plan has an unsupported schema"
        )
    if raw_plan.get("environment") != environment:
        raise GeneratedSdkconfigError(
            "verified PlatformIO flash plan references another environment"
        )
    if raw_plan.get("uploadPortPlaceholder") != FLASH_PLAN_PORT_PLACEHOLDER:
        raise GeneratedSdkconfigError(
            "verified PlatformIO flash plan has an invalid port placeholder"
        )

    core_dir_value = core_attestation.get("coreDir")
    expected_uploader_hash = core_attestation.get("esptoolUploaderSha256")
    if not isinstance(core_dir_value, str) or not isinstance(
        expected_uploader_hash, str
    ):
        raise GeneratedSdkconfigError(
            "verified core attestation is missing its esptool uploader"
        )
    core_dir = Path(core_dir_value).resolve()
    expected_core_dir = (
        project_dir / ".pio/open-bike-build/platformio" / environment
    ).resolve()
    if core_dir != expected_core_dir:
        raise GeneratedSdkconfigError(
            "verified core attestation references another core directory"
        )
    expected_uploader = core_dir / (
        "penv/Scripts/esptool.exe" if os.name == "nt" else "penv/bin/esptool"
    )
    uploader_value = raw_plan.get("uploader")
    if not isinstance(uploader_value, str):
        raise GeneratedSdkconfigError(
            "verified PlatformIO flash plan has an invalid uploader"
        )
    uploader = Path(uploader_value)
    if (
        not uploader.is_absolute()
        or uploader != uploader.resolve()
        or uploader != expected_uploader
        or uploader.is_symlink()
        or not uploader.is_file()
        or not os.access(uploader, os.X_OK)
        or _file_sha256(uploader) != expected_uploader_hash
    ):
        raise GeneratedSdkconfigError(
            "verified PlatformIO flash plan references an unattested uploader"
        )

    raw_command = raw_plan.get("command")
    if (
        not isinstance(raw_command, list)
        or not 2 <= len(raw_command) <= 256
        or not all(
            isinstance(token, str)
            and token
            and "\0" not in token
            and len(token) <= 4096
            for token in raw_command
        )
    ):
        raise GeneratedSdkconfigError(
            "verified PlatformIO flash plan has an invalid command"
        )
    command = tuple(raw_command)
    if command[0] != str(uploader):
        raise GeneratedSdkconfigError(
            "verified PlatformIO flash command does not invoke its uploader"
        )
    if command.count(FLASH_PLAN_PORT_PLACEHOLDER) != 1:
        raise GeneratedSdkconfigError(
            "verified PlatformIO flash command has an invalid port placeholder"
        )
    if command.count(FLASH_PLAN_APP_OFFSET_PLACEHOLDER) != 1:
        raise GeneratedSdkconfigError(
            "verified PlatformIO flash command has an invalid application-offset "
            "placeholder"
        )
    if command.count("--port") != 1:
        raise GeneratedSdkconfigError(
            "verified PlatformIO flash command has an invalid port option"
        )
    port_index = command.index("--port")
    if (
        port_index + 1 >= len(command)
        or command[port_index + 1] != FLASH_PLAN_PORT_PLACEHOLDER
    ):
        raise GeneratedSdkconfigError(
            "verified PlatformIO flash command does not bind the upload port"
        )
    if command.count("write-flash") != 1:
        raise GeneratedSdkconfigError(
            "verified PlatformIO flash command is not a single write-flash action"
        )

    raw_platformio_parameters = raw_plan.get("platformioFlashParameters")
    if (
        not isinstance(raw_platformio_parameters, dict)
        or set(raw_platformio_parameters) != {"mode", "frequency", "size"}
        or not all(
            isinstance(value, str)
            and value
            and "\0" not in value
            and len(value) <= 64
            for value in raw_platformio_parameters.values()
        )
    ):
        raise GeneratedSdkconfigError(
            "verified PlatformIO flash plan has invalid resolved flash parameters"
        )
    raw_platformio_app_offset = raw_plan.get("platformioAppOffset")
    if (
        not isinstance(raw_platformio_app_offset, str)
        or "\0" in raw_platformio_app_offset
        or len(raw_platformio_app_offset) > 64
    ):
        raise GeneratedSdkconfigError(
            "verified PlatformIO flash plan has an invalid resolved application "
            "offset"
        )

    application_offset, application_partition_size = (
        _application_partition_from_partition_table(
            build_dir / "partitions.bin"
        )
    )
    if raw_platformio_app_offset:
        try:
            reported_application_offset = int(raw_platformio_app_offset, 0)
        except ValueError as error:
            raise GeneratedSdkconfigError(
                "verified PlatformIO flash plan has an invalid resolved application "
                "offset"
            ) from error
        if reported_application_offset != application_offset:
            raise GeneratedSdkconfigError(
                "PlatformIO's resolved application offset does not match the "
                "verified partition table"
            )

    raw_images = raw_plan.get("images")
    if not isinstance(raw_images, list) or not 1 <= len(raw_images) <= 32:
        raise GeneratedSdkconfigError(
            "verified PlatformIO flash plan has an invalid image set"
        )
    project_root = project_dir.resolve()
    normalized_images: list[dict[str, object]] = []
    raw_command_tail: list[str] = []
    normalized_command_tail: list[str] = []
    offsets: set[int] = set()
    image_ranges: list[tuple[int, int, Path]] = []
    application_images = 0
    for raw_image in raw_images:
        if not isinstance(raw_image, dict):
            raise GeneratedSdkconfigError(
                "verified PlatformIO flash plan contains an invalid image"
            )
        offset_token = raw_image.get("offset")
        path_value = raw_image.get("path")
        if not isinstance(offset_token, str) or not isinstance(path_value, str):
            raise GeneratedSdkconfigError(
                "verified PlatformIO flash plan contains invalid image fields"
            )
        raw_command_tail.extend((offset_token, path_value))
        if offset_token == FLASH_PLAN_APP_OFFSET_PLACEHOLDER:
            application_images += 1
            offset = application_offset
            normalized_offset_token = hex(application_offset)
        else:
            try:
                offset = int(offset_token, 0)
            except ValueError as error:
                raise GeneratedSdkconfigError(
                    "verified PlatformIO flash plan contains an invalid image offset"
                ) from error
            normalized_offset_token = offset_token
        if offset < 0 or offset > 0xFFFFFFFF or offset in offsets:
            raise GeneratedSdkconfigError(
                "verified PlatformIO flash plan contains a duplicate or out-of-range "
                "image offset"
            )
        offsets.add(offset)
        image = Path(path_value)
        if (
            not image.is_absolute()
            or image != image.resolve()
            or image.is_symlink()
            or not image.is_file()
            or not (
                _path_is_within(image, project_root)
                or _path_is_within(image, core_dir)
            )
        ):
            raise GeneratedSdkconfigError(
                f"verified PlatformIO flash image is missing or unsafe: {image}"
            )
        if (
            offset_token == FLASH_PLAN_APP_OFFSET_PLACEHOLDER
            and image != (build_dir / "firmware.bin").resolve()
        ):
            raise GeneratedSdkconfigError(
                "verified PlatformIO application-offset placeholder does not "
                "reference the firmware image"
            )
        try:
            size = image.stat().st_size
        except OSError as error:
            raise GeneratedSdkconfigError(
                f"could not inspect verified PlatformIO flash image: {error}"
            ) from error
        if size <= 0:
            raise GeneratedSdkconfigError(
                f"verified PlatformIO flash image is empty: {image}"
            )
        if (
            offset_token == FLASH_PLAN_APP_OFFSET_PLACEHOLDER
            and size > application_partition_size
        ):
            raise GeneratedSdkconfigError(
                "verified firmware image exceeds its application partition"
            )
        if offset + size > 0x1_0000_0000:
            raise GeneratedSdkconfigError(
                "verified PlatformIO flash image exceeds the address space"
            )
        image_ranges.append((offset, offset + size, image))
        normalized_images.append(
            {
                "offset": normalized_offset_token,
                "path": str(image),
                "size": size,
                "sha256": _file_sha256(image),
            }
        )
        normalized_command_tail.extend((normalized_offset_token, str(image)))

    if application_images != 1:
        raise GeneratedSdkconfigError(
            "verified PlatformIO flash plan does not identify exactly one "
            "application image"
        )

    for previous, current in zip(
        sorted(image_ranges), sorted(image_ranges)[1:]
    ):
        if previous[1] > current[0]:
            raise GeneratedSdkconfigError(
                "verified PlatformIO flash plan contains overlapping images: "
                f"{previous[2]} and {current[2]}"
            )

    if list(command[-len(raw_command_tail) :]) != raw_command_tail:
        raise GeneratedSdkconfigError(
            "verified PlatformIO flash command does not exactly match its image set"
        )
    image_boundary = len(command) - len(raw_command_tail)
    command = command[:image_boundary] + tuple(normalized_command_tail)
    write_flash_index = command.index("write-flash")
    if write_flash_index >= image_boundary:
        raise GeneratedSdkconfigError(
            "verified PlatformIO flash command has an invalid image boundary"
        )
    global_options = _parse_esptool_options(
        command[1:write_flash_index],
        value_options={"--chip", "--port", "--baud", "--before", "--after"},
        flag_options=set(),
        label="global options",
    )
    write_options = _parse_esptool_options(
        command[write_flash_index + 1 : image_boundary],
        value_options={"--flash-mode", "--flash-freq", "--flash-size"},
        flag_options={"-z"},
        label="write-flash options",
    )
    if global_options["--chip"] != "esp32s3":
        raise GeneratedSdkconfigError(
            "verified esptool command targets another chip"
        )
    if global_options["--port"] != FLASH_PLAN_PORT_PLACEHOLDER:
        raise GeneratedSdkconfigError(
            "verified esptool command has an invalid upload port"
        )
    baud = global_options["--baud"]
    if (
        not isinstance(baud, str)
        or not baud.isdigit()
        or not 1 <= int(baud) <= 10_000_000
    ):
        raise GeneratedSdkconfigError(
            "verified esptool command has an invalid upload baud rate"
        )
    if global_options["--before"] not in {
        "default-reset",
        "usb-reset",
        "no-reset",
        "no-reset-no-sync",
    }:
        raise GeneratedSdkconfigError(
            "verified esptool command has an invalid before-reset action"
        )
    if global_options["--after"] not in {
        "hard-reset",
        "soft-reset",
        "no-reset",
        "no-reset-stub",
    }:
        raise GeneratedSdkconfigError(
            "verified esptool command has an invalid after-reset action"
        )
    if any(
        write_options[option] != "keep"
        for option in ("--flash-mode", "--flash-freq", "--flash-size")
    ):
        raise GeneratedSdkconfigError(
            "verified esptool command may rewrite an attested flash image"
        )
    return {
        "schema": FLASH_PLAN_SCHEMA,
        "environment": environment,
        "uploadPortPlaceholder": FLASH_PLAN_PORT_PLACEHOLDER,
        "uploader": str(uploader),
        "command": list(command),
        "platformioFlashParameters": dict(raw_platformio_parameters),
        "platformioAppOffset": raw_platformio_app_offset,
        "applicationOffsetSource": "partition-table",
        "images": normalized_images,
    }


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
    try:
        source_date_epoch = git_commit_source_date_epoch(
            project_dir, source_identity
        )
        build_timestamp = build_timestamp_from_source_date_epoch(
            source_date_epoch
        )
    except ValueError:
        return False
    return (
        manifest.get("schema") == CACHE_SCHEMA
        and manifest.get("environment") == environment
        and "environmentSdkconfigSha256" in manifest
        and "managedComponentsSha256" in manifest
        and "libraryDependenciesSha256" in manifest
        and manifest.get("platformArchiveSha256")
        == WAVESHARE_PLATFORM_ARCHIVE_SHA256
        and manifest.get("platformPackagesSha256")
        == WAVESHARE_PLATFORM_PACKAGES_SHA256
        and FULL_GIT_SHA.fullmatch(source_identity) is not None
        and manifest.get("sourceIdentity") == source_identity
        and manifest.get("sourceDateEpoch") == source_date_epoch
        and manifest.get("buildTimestamp") == build_timestamp
        and manifest.get("runtimeProvenance") == _runtime_provenance()
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
    core_attestation = manifest.get("coreAttestation")
    if not isinstance(core_attestation, dict):
        raise GeneratedSdkconfigError(
            "refusing AMOLED upload without a verified core attestation"
        )
    current_flash_plan = _validated_flash_plan(
        project_dir, environment, core_attestation
    )
    if (
        manifest.get("flashPlan") != current_flash_plan
        or manifest.get("flashPlanSha256")
        != _canonical_json_sha256(current_flash_plan)
    ):
        raise GeneratedSdkconfigError(
            "refusing AMOLED upload because the PlatformIO flash plan changed "
            "after the verified build"
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
    runtime_provenance = _runtime_provenance()
    source_identity = current_source_identity(project_dir, environment)
    if (
        core_attestation is None
        or runtime_provenance is None
        or FULL_GIT_SHA.fullmatch(source_identity) is None
    ):
        manifest_path = _cache_manifest_path(project_dir)
        if manifest_path.is_file() or manifest_path.is_symlink():
            manifest_path.unlink()
        return None
    try:
        source_date_epoch = git_commit_source_date_epoch(
            project_dir, source_identity
        )
        build_timestamp = build_timestamp_from_source_date_epoch(
            source_date_epoch
        )
    except ValueError as error:
        raise GeneratedSdkconfigError(
            f"could not derive the verified firmware build clock: {error}"
        ) from error
    managed_components_sha = _managed_components_sha256(project_dir)
    library_dependencies_sha = _library_dependencies_sha256(
        project_dir, environment
    )
    firmware_artifacts = _firmware_artifact_hashes(project_dir, environment)
    manifest = {
        "schema": CACHE_SCHEMA,
        "environment": environment,
        "sourceIdentity": source_identity,
        "sourceDateEpoch": source_date_epoch,
        "buildTimestamp": build_timestamp,
        "runtimeProvenance": runtime_provenance,
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
    if environment.startswith("WAVESHARE_AMOLED_"):
        flash_plan = _validated_flash_plan(
            project_dir, environment, core_attestation
        )
        manifest["flashPlan"] = flash_plan
        manifest["flashPlanSha256"] = _canonical_json_sha256(flash_plan)
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
