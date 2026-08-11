#!/usr/bin/env python3
"""Manage the local, explicit Waveshare device-name registry."""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Sequence


SCHEMA = 1
BOARD_FAMILIES = frozenset(
    {"WAVESHARE_AMOLED_175", "WAVESHARE_AMOLED_206"}
)
NICKNAME_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
SERIAL_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,254}$")
MAX_REGISTRY_BYTES = 1024 * 1024
TIMESTAMP_PATTERN = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z$"
)


class DeviceRegistryError(RuntimeError):
    """Raised when a registry or requested mutation is unsafe or invalid."""


@dataclass(frozen=True)
class DeviceEntry:
    nickname: str
    board_family: str
    serial: str
    note: str | None
    updated_at: str

    def as_json(self) -> dict[str, object]:
        value: dict[str, object] = {
            "nickname": self.nickname,
            "boardFamily": self.board_family,
            "serialNumber": self.serial,
            "updatedAt": self.updated_at,
        }
        if self.note is not None:
            value["note"] = self.note
        return value


def default_registry_path() -> Path:
    if sys.platform == "darwin":
        return Path.home() / "Library/Application Support/OpenBikeComputer/devices.json"
    config_home = os.environ.get("XDG_CONFIG_HOME")
    # XDG_CONFIG_HOME is valid only as an absolute path. Ignoring a relative
    # value prevents a registry containing real serials from landing in the
    # current checkout by accident.
    root = (
        Path(config_home)
        if config_home and Path(config_home).is_absolute()
        else Path.home() / ".config"
    )
    return root / "open-bike-computer/devices.json"


def _absolute_without_resolving(path: Path) -> Path:
    return Path(os.path.abspath(path.expanduser()))


def _validate_registry_parent(path: Path) -> None:
    parent = path.parent
    current = parent
    while True:
        if os.path.lexists(current) and current.is_symlink():
            raise DeviceRegistryError(
                f"device registry path contains a symlinked directory: {current}"
            )
        if current == current.parent:
            break
        current = current.parent
    if not parent.is_dir():
        raise DeviceRegistryError(
            f"device registry parent is not a directory: {parent}"
        )
    info = parent.stat()
    if hasattr(os, "getuid") and info.st_uid != os.getuid():
        raise DeviceRegistryError(
            f"device registry directory has the wrong owner: {parent}"
        )
    if stat.S_IMODE(info.st_mode) & 0o022:
        raise DeviceRegistryError(
            f"device registry directory is writable by another user: {parent}"
        )


def _prepare_registry_parent(path: Path) -> None:
    parent = path.parent
    missing: list[Path] = []
    current = parent
    while not os.path.lexists(current):
        missing.append(current)
        if current == current.parent:
            break
        current = current.parent
    while True:
        if os.path.lexists(current):
            info = current.lstat()
            if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
                raise DeviceRegistryError(
                    f"device registry path contains an unsafe directory: {current}"
                )
        if current == current.parent:
            break
        current = current.parent
    for directory in reversed(missing):
        try:
            directory.mkdir(mode=0o700)
        except FileExistsError:
            pass
        info = directory.lstat()
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            raise DeviceRegistryError(
                f"device registry path contains an unsafe directory: {directory}"
            )
        if hasattr(os, "getuid") and info.st_uid != os.getuid():
            raise DeviceRegistryError(
                f"device registry directory has the wrong owner: {directory}"
            )
        if stat.S_IMODE(info.st_mode) & 0o022:
            raise DeviceRegistryError(
                f"device registry directory is writable by another user: {directory}"
            )
    _validate_registry_parent(path)


def _reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise DeviceRegistryError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _normalize_nickname(value: str) -> str:
    nickname = value.strip()
    if not NICKNAME_PATTERN.fullmatch(nickname):
        raise DeviceRegistryError(
            "nickname must be 1-64 ASCII letters, digits, dots, underscores, or hyphens"
        )
    return nickname


def normalize_serial(value: str) -> str:
    serial = value.strip().upper()
    if not SERIAL_PATTERN.fullmatch(serial):
        raise DeviceRegistryError("stable USB serial is empty or malformed")
    return serial


def _validate_note(value: object) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not value.strip() or len(value) > 256:
        raise DeviceRegistryError("note must be a nonempty string of at most 256 characters")
    note = value.strip()
    if not note.isprintable() or "\0" in note:
        raise DeviceRegistryError("note contains unsupported characters")
    return note


def _validate_timestamp(value: object) -> str:
    if not isinstance(value, str) or TIMESTAMP_PATTERN.fullmatch(value) is None:
        raise DeviceRegistryError("updatedAt must be an ISO-8601 UTC timestamp")
    try:
        datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise DeviceRegistryError("updatedAt must be an ISO-8601 UTC timestamp") from error
    return value


def _entry_from_json(value: object) -> DeviceEntry:
    if not isinstance(value, dict):
        raise DeviceRegistryError("each device entry must be an object")
    allowed = {"nickname", "boardFamily", "serialNumber", "note", "updatedAt"}
    required = {"nickname", "boardFamily", "serialNumber", "updatedAt"}
    if set(value) - allowed or not required <= set(value):
        raise DeviceRegistryError("device entry has missing or unexpected fields")
    nickname_value = value["nickname"]
    family = value["boardFamily"]
    serial_value = value["serialNumber"]
    if not isinstance(nickname_value, str) or not isinstance(serial_value, str):
        raise DeviceRegistryError("nickname and serialNumber must be strings")
    if not isinstance(family, str) or family not in BOARD_FAMILIES:
        raise DeviceRegistryError("device boardFamily is unsupported")
    nickname = _normalize_nickname(nickname_value)
    serial = normalize_serial(serial_value)
    note = _validate_note(value.get("note"))
    if nickname_value != nickname or serial_value != serial:
        raise DeviceRegistryError(
            "device nickname or stable USB serial is not canonical"
        )
    if "note" in value and value["note"] != note:
        raise DeviceRegistryError("device note is not canonical")
    return DeviceEntry(
        nickname=nickname,
        board_family=family,
        serial=serial,
        note=note,
        updated_at=_validate_timestamp(value["updatedAt"]),
    )


def _validate_entries(values: object) -> tuple[DeviceEntry, ...]:
    if not isinstance(values, list):
        raise DeviceRegistryError("devices must be an array")
    entries = tuple(_entry_from_json(value) for value in values)
    names: set[str] = set()
    serials: set[str] = set()
    for entry in entries:
        name_key = entry.nickname.casefold()
        serial_key = entry.serial.casefold()
        if name_key in names:
            raise DeviceRegistryError(f"duplicate device nickname: {entry.nickname}")
        if serial_key in serials:
            raise DeviceRegistryError(f"duplicate stable USB serial: {entry.serial}")
        names.add(name_key)
        serials.add(serial_key)
    return entries


def load_registry(path: Path | None = None, *, missing_ok: bool = True) -> tuple[DeviceEntry, ...]:
    path = _absolute_without_resolving(path or default_registry_path())
    if not os.path.lexists(path):
        if missing_ok:
            return ()
        raise DeviceRegistryError(f"device registry does not exist: {path}")
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise DeviceRegistryError(f"device registry is not a regular non-symlink file: {path}")
    if info.st_nlink != 1:
        raise DeviceRegistryError(f"device registry must not be hard-linked: {path}")
    if stat.S_IMODE(info.st_mode) != 0o600:
        raise DeviceRegistryError(f"device registry permissions must be 0600: {path}")
    if hasattr(os, "getuid") and info.st_uid != os.getuid():
        raise DeviceRegistryError(f"device registry has the wrong owner: {path}")
    if info.st_size > MAX_REGISTRY_BYTES:
        raise DeviceRegistryError(f"device registry exceeds {MAX_REGISTRY_BYTES} bytes")
    _validate_registry_parent(path)
    try:
        raw = path.read_text(encoding="utf-8")
        value = json.loads(raw, object_pairs_hook=_reject_duplicate_keys)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise DeviceRegistryError(f"could not read device registry: {error}") from error
    if not isinstance(value, dict) or set(value) != {"schema", "devices"}:
        raise DeviceRegistryError("device registry has missing or unexpected fields")
    if value["schema"] != SCHEMA or isinstance(value["schema"], bool):
        raise DeviceRegistryError("unsupported device registry schema")
    return _validate_entries(value["devices"])


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _write_registry(path: Path, entries: Sequence[DeviceEntry]) -> None:
    path = _absolute_without_resolving(path)
    if os.path.lexists(path) and (path.is_symlink() or not path.is_file()):
        raise DeviceRegistryError(f"refusing unsafe device registry path: {path}")
    _prepare_registry_parent(path)
    value = {"schema": SCHEMA, "devices": [entry.as_json() for entry in entries]}
    temporary_name: str | None = None
    try:
        descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        if os.path.lexists(path) and path.is_symlink():
            raise DeviceRegistryError(f"refusing symlink device registry: {path}")
        _validate_registry_parent(path)
        os.replace(temporary_name, path)
        temporary_name = None
        os.chmod(path, 0o600, follow_symlinks=False)
        if hasattr(os, "O_DIRECTORY"):
            directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
    except OSError as error:
        raise DeviceRegistryError(f"could not update device registry: {error}") from error
    finally:
        if temporary_name is not None:
            try:
                Path(temporary_name).unlink()
            except OSError:
                pass


def resolve_device_name(name: str, path: Path | None = None) -> DeviceEntry:
    requested = _normalize_nickname(name).casefold()
    matches = [
        entry
        for entry in load_registry(path, missing_ok=False)
        if entry.nickname.casefold() == requested
    ]
    if len(matches) != 1:
        raise DeviceRegistryError(f"unknown or ambiguous device nickname: {name}")
    return matches[0]


def environment_matches_family(environment: str, family: str) -> bool:
    return environment == family or environment.startswith(family + "_")


def _print_entry(entry: DeviceEntry, path: Path) -> None:
    print(
        json.dumps(
            {"schema": SCHEMA, "path": str(path), "device": entry.as_json()},
            sort_keys=True,
        )
    )


def _parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path, default=default_registry_path())
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("list")
    show = commands.add_parser("show")
    show.add_argument("nickname")
    add = commands.add_parser("add")
    add.add_argument("nickname")
    add.add_argument("board_family", choices=sorted(BOARD_FAMILIES))
    add.add_argument("serial")
    add.add_argument("--note")
    rename = commands.add_parser("rename")
    rename.add_argument("nickname")
    rename.add_argument("new_nickname")
    remove = commands.add_parser("remove")
    remove.add_argument("nickname")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _parse_args(argv)
    path = _absolute_without_resolving(args.registry)
    try:
        entries = list(load_registry(path))
        if args.command == "list":
            print(
                json.dumps(
                    {
                        "schema": SCHEMA,
                        "path": str(path),
                        "devices": [entry.as_json() for entry in entries],
                    },
                    sort_keys=True,
                )
            )
            return 0
        if args.command == "show":
            _print_entry(resolve_device_name(args.nickname, path), path)
            return 0
        if args.command == "add":
            nickname = _normalize_nickname(args.nickname)
            serial = normalize_serial(args.serial)
            if any(entry.nickname.casefold() == nickname.casefold() for entry in entries):
                raise DeviceRegistryError(f"device nickname already exists: {nickname}")
            if any(entry.serial.casefold() == serial.casefold() for entry in entries):
                raise DeviceRegistryError(f"stable USB serial already exists: {serial}")
            changed = DeviceEntry(
                nickname,
                args.board_family,
                serial,
                _validate_note(args.note),
                _utc_now(),
            )
            entries.append(changed)
        elif args.command == "rename":
            current = resolve_device_name(args.nickname, path)
            nickname = _normalize_nickname(args.new_nickname)
            if any(
                entry.nickname.casefold() == nickname.casefold()
                and entry != current
                for entry in entries
            ):
                raise DeviceRegistryError(f"device nickname already exists: {nickname}")
            changed = DeviceEntry(
                nickname,
                current.board_family,
                current.serial,
                current.note,
                _utc_now(),
            )
            entries = [changed if entry == current else entry for entry in entries]
        elif args.command == "remove":
            changed = resolve_device_name(args.nickname, path)
            entries = [entry for entry in entries if entry != changed]
        else:
            raise AssertionError("unhandled registry command")
        entries.sort(key=lambda entry: entry.nickname.casefold())
        _write_registry(path, entries)
        _print_entry(changed, path)
        return 0
    except DeviceRegistryError as error:
        print(f"Device registry failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
