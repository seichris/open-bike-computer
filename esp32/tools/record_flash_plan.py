"""Record PlatformIO's fully resolved esptool command for later attestation."""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path


FLASH_PLAN_SCHEMA = 2
FLASH_PLAN_FILENAME = "open-bike-flash-plan.json"
FLASH_PLAN_PORT_PLACEHOLDER = "__OPEN_BIKE_UPLOAD_PORT__"
FLASH_PLAN_APP_OFFSET_PLACEHOLDER = "__OPEN_BIKE_APP_OFFSET__"


def _direct_argument(token: object) -> str:
    """Remove shell-only outer quotes from an already-tokenized argument."""
    value = str(token)
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
        return value[1:-1]
    return value


def _resolved_path(environment, expression: str) -> str:
    value = _direct_argument(environment.subst(expression))
    return str(Path(value).resolve())


def _normalize_flash_parameters(command: list[str]) -> dict[str, str]:
    """Capture PlatformIO's values and prevent esptool from rewriting images."""
    resolved: dict[str, str] = {}
    for name, option in (
        ("mode", "--flash-mode"),
        ("frequency", "--flash-freq"),
        ("size", "--flash-size"),
    ):
        if command.count(option) != 1:
            raise RuntimeError(
                f"Waveshare upload command must contain one {option} option"
            )
        option_index = command.index(option)
        if option_index + 1 >= len(command):
            raise RuntimeError(
                f"Waveshare upload command is missing the {option} value"
            )
        resolved[name] = command[option_index + 1]
        command[option_index + 1] = "keep"
    return resolved


def require_fresh_final_link(environment) -> None:
    """Retain linker side evidence after the platform resolves PROGNAME."""
    if os.environ.get("OPEN_BIKE_DETERMINISTIC_BUILD") != "1":
        return
    if not environment.subst("$PIOENV").startswith("WAVESHARE_AMOLED_"):
        return
    # In pre: scripts PROGNAME is still "program", not "firmware". Unlike
    # PlatformIO's action hooks, NoCache resolves its target immediately.
    # Run in this post: script so the actual ELF always links and produces
    # firmware.map; object and library nodes remain cacheable.
    environment.NoCache(environment.subst("$BUILD_DIR/${PROGNAME}.elf"))


def record_flash_plan(environment) -> None:
    """Persist the exact command after PlatformIO has loaded the framework."""
    profile = environment.subst("$PIOENV")
    if not profile.startswith("WAVESHARE_AMOLED_"):
        return

    plan_environment = environment.Clone()
    plan_environment.Replace(UPLOAD_PORT=FLASH_PLAN_PORT_PLACEHOLDER)
    uploader = _resolved_path(plan_environment, "$UPLOADER")
    uploader_flags = plan_environment.get("UPLOADERFLAGS")
    if not isinstance(uploader_flags, (list, tuple)):
        raise RuntimeError(
            "Waveshare upload flags must resolve to an argument list"
        )
    firmware = _resolved_path(
        plan_environment, "$BUILD_DIR/${PROGNAME}.bin"
    )
    command = [uploader]
    command.extend(
        _direct_argument(plan_environment.subst(str(token)))
        for token in uploader_flags
    )
    platformio_app_offset = plan_environment.subst("$ESP32_APP_OFFSET")
    command.extend((FLASH_PLAN_APP_OFFSET_PLACEHOLDER, firmware))
    platformio_flash_parameters = _normalize_flash_parameters(command)

    images: list[dict[str, str]] = []
    for offset, image in environment.get("FLASH_EXTRA_IMAGES", []):
        raw_image_path = plan_environment.subst(str(image))
        resolved_image_path = _resolved_path(
            plan_environment, str(image)
        )
        command = [
            resolved_image_path if token == raw_image_path else token
            for token in command
        ]
        images.append(
            {
                "offset": plan_environment.subst(str(offset)),
                "path": resolved_image_path,
            }
        )
    images.append(
        {
            "offset": FLASH_PLAN_APP_OFFSET_PLACEHOLDER,
            "path": firmware,
        }
    )

    expected_tail = [
        value
        for image in images
        for value in (image["offset"], image["path"])
    ]
    if command[-len(expected_tail) :] != expected_tail:
        raise RuntimeError(
            "Waveshare upload command does not end with its resolved image set"
        )
    if command.count(FLASH_PLAN_PORT_PLACEHOLDER) != 1:
        raise RuntimeError(
            "Waveshare upload command must contain one upload-port placeholder"
        )

    plan = {
        "schema": FLASH_PLAN_SCHEMA,
        "environment": profile,
        "uploadPortPlaceholder": FLASH_PLAN_PORT_PLACEHOLDER,
        "uploader": uploader,
        "command": command,
        "platformioFlashParameters": platformio_flash_parameters,
        "platformioAppOffset": platformio_app_offset,
        "images": images,
    }
    output = Path(environment.subst("$BUILD_DIR")) / FLASH_PLAN_FILENAME
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary_name = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=output.parent,
            prefix=f".{output.name}.",
            delete=False,
        ) as stream:
            temporary_name = stream.name
            json.dump(plan, stream, sort_keys=True)
            stream.write("\n")
        os.replace(temporary_name, output)
        temporary_name = None
    finally:
        if temporary_name is not None:
            try:
                Path(temporary_name).unlink()
            except OSError:
                pass


try:
    Import("env")  # type: ignore[name-defined]  # noqa: F821
except NameError:
    pass
else:
    require_fresh_final_link(env)  # type: ignore[name-defined]  # noqa: F821
    record_flash_plan(env)  # type: ignore[name-defined]  # noqa: F821
