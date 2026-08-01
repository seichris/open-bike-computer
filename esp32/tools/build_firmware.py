#!/usr/bin/env python3
"""Build a real PlatformIO firmware target across pioarduino bootstrap passes."""

from __future__ import annotations

import argparse
import configparser
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Callable, Sequence


ENVIRONMENT_PATTERN = re.compile(r"^[A-Za-z0-9_-]+$")
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


class BuildError(RuntimeError):
    """Raised when a deterministic real-target build cannot be confirmed."""


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
    _remove_pioarduino_dummy(project_dir)
    _remove_environment_build(project_dir, environment)

    command: Sequence[str] = (pio_command, "run", "-e", environment)
    firmware_elf = project_dir / ".pio" / "build" / environment / "firmware.elf"

    for pass_number in range(1, max_passes + 1):
        print(
            f"=== PlatformIO real-target build: {environment} "
            f"(pass {pass_number}/{max_passes}) ===",
            flush=True,
        )
        try:
            result = runner(command, cwd=project_dir)
        except OSError as error:
            raise BuildError(f"could not run {pio_command!r}: {error}") from error

        if os.path.lexists(project_dir / ".dummy"):
            _remove_pioarduino_dummy(project_dir)
            _remove_environment_build(project_dir, environment)
            if pass_number == max_passes:
                raise BuildError(
                    "pioarduino custom-core bootstrap did not converge after "
                    f"{max_passes} passes"
                )
            print(
                "Detected pioarduino custom-core bootstrap; rebuilding the real "
                "firmware target.",
                flush=True,
            )
            continue

        if result.returncode != 0:
            raise BuildError(
                f"PlatformIO exited with status {result.returncode} while building "
                f"{environment}"
            )
        if not firmware_elf.is_file():
            raise BuildError(
                "PlatformIO returned success without the expected real-target "
                f"artifact: {firmware_elf}"
            )

        print(f"Verified real firmware artifact: {firmware_elf}", flush=True)
        return firmware_elf

    raise AssertionError("unreachable")


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
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _parse_args(argv)
    try:
        build_firmware(args.project_dir, args.environment, pio_command=args.pio)
    except BuildError as error:
        print(f"Firmware build failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
