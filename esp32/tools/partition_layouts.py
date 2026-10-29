"""Versioned 16 MiB partition layouts shared by builds and signed USB recipes.

``esp32/partition_layouts.json`` is the single numeric source. This module
validates it, renders the exact binary table that ESP-IDF's gen_esp32part.py
emits for each layout, parses built/device tables strictly, and checks the
PlatformIO CSVs. Release tooling, the firmware build guard and the tests all
use these helpers instead of repeating offsets.
"""

from __future__ import annotations

import hashlib
import json
import re
import struct
from dataclasses import dataclass
from pathlib import Path

REGISTRY_PATH = Path(__file__).resolve().parents[1] / "partition_layouts.json"

FLASH_BYTES = 0x1000000
TABLE_OFFSET = 0x8000
TABLE_BYTES = 0xC00
SECTOR = 0x1000
APP_ALIGNMENT = 0x10000
APPLICATION_RESERVE_BYTES = 0x10000

_ENTRY = struct.Struct("<HBBII16sI")
_ENTRY_MAGIC = 0x50AA
_MD5_MAGIC = b"\xeb\xeb"
_HEX = re.compile(r"0x[0-9a-f]+")
_SHA256 = re.compile(r"[0-9a-f]{64}")
_LABEL = re.compile(r"[a-z][a-z0-9_]{0,14}")

TYPES = {"app": 0x00, "data": 0x01}
SUBTYPES = {
    ("app", "ota_0"): 0x10,
    ("app", "ota_1"): 0x11,
    ("data", "ota"): 0x00,
    ("data", "nvs"): 0x02,
    ("data", "coredump"): 0x03,
    ("data", "fat"): 0x81,
}
ROLES = ("production", "development")
STATUSES = ("current", "legacy")
# Bytes that every layout must place identically. A migration rewrites the
# table, OTA selection, application slots and FFat; these are never moved.
SHARED_PARTITIONS = ("nvs", "otadata", "coredump")


class LayoutError(ValueError):
    """Raised when a registry, CSV or partition table is not a known layout."""


@dataclass(frozen=True)
class Partition:
    name: str
    type: int
    subtype: int
    offset: int
    size: int

    @property
    def end(self) -> int:
        return self.offset + self.size

    def record(self) -> tuple[str, int, int, int, int]:
        return (self.name, self.type, self.subtype, self.offset, self.size)


@dataclass(frozen=True)
class Layout:
    id: str
    generation: int
    role: str
    status: str
    csv: str | None
    partitions: tuple[Partition, ...]
    table_sha256: str

    def partition(self, name: str) -> Partition:
        for partition in self.partitions:
            if partition.name == name:
                return partition
        raise LayoutError(f"{self.id} has no {name} partition")

    @property
    def application_slots(self) -> tuple[Partition, ...]:
        return tuple(p for p in self.partitions if p.type == TYPES["app"])

    @property
    def ffat(self) -> Partition:
        return self.partition("ffat")

    @property
    def max_application_bytes(self) -> int:
        """Largest image a slot accepts while keeping the 64 KiB reserve."""
        return min(slot.size for slot in self.application_slots) - (
            APPLICATION_RESERVE_BYTES
        )

    def table_bytes(self) -> bytes:
        return encode_table(self.partitions)


@dataclass(frozen=True)
class Migration:
    id: str
    source: Layout
    destination: Layout


@dataclass(frozen=True)
class Registry:
    layouts: tuple[Layout, ...]
    migrations: tuple[Migration, ...]

    def layout(self, layout_id: str) -> Layout:
        for layout in self.layouts:
            if layout.id == layout_id:
                return layout
        raise LayoutError(f"unknown partition layout: {layout_id}")

    def current(self, role: str) -> Layout:
        return self._one(role, "current")

    def legacy(self, role: str) -> Layout:
        return self._one(role, "legacy")

    def _one(self, role: str, status: str) -> Layout:
        matches = [
            layout
            for layout in self.layouts
            if layout.role == role and layout.status == status
        ]
        if len(matches) != 1:
            raise LayoutError(f"expected exactly one {status} {role} layout")
        return matches[0]

    def for_csv(self, name: str) -> Layout:
        matches = [layout for layout in self.layouts if layout.csv == name]
        if len(matches) != 1:
            raise LayoutError(f"no current layout is built from {name}")
        return matches[0]

    def identify(self, table: bytes) -> Layout | None:
        """Return the layout whose exact table bytes match, if any."""
        digest = hashlib.sha256(table).hexdigest()
        for layout in self.layouts:
            if layout.table_sha256 == digest:
                return layout
        return None

    def migration(self, source: Layout, destination: Layout) -> Migration:
        for migration in self.migrations:
            if (
                migration.source.id == source.id
                and migration.destination.id == destination.id
            ):
                return migration
        raise LayoutError(
            f"no reviewed migration from {source.id} to {destination.id}"
        )


def encode_table(partitions: tuple[Partition, ...] | list[Partition]) -> bytes:
    """Render gen_esp32part.py's binary table: entries, MD5 record, 0xFF pad."""
    entries = b"".join(
        _ENTRY.pack(
            _ENTRY_MAGIC,
            partition.type,
            partition.subtype,
            partition.offset,
            partition.size,
            partition.name.encode("ascii"),
            0,
        )
        for partition in partitions
    )
    table = entries + _MD5_MAGIC + b"\xff" * 14 + hashlib.md5(entries).digest()
    if len(table) > TABLE_BYTES:
        raise LayoutError("partition table exceeds its sector budget")
    return table.ljust(TABLE_BYTES, b"\xff")


def parse_table(data: bytes) -> tuple[Partition, ...]:
    """Strictly decode a 3072-byte table; reject flags and torn checksums."""
    if len(data) != TABLE_BYTES:
        raise LayoutError("partition table must contain exactly 3072 bytes")
    partitions: list[Partition] = []
    checksum_seen = False
    for offset in range(0, len(data), _ENTRY.size):
        entry = data[offset : offset + _ENTRY.size]
        if entry == b"\xff" * _ENTRY.size:
            if any(byte != 0xFF for byte in data[offset:]):
                raise LayoutError("partition table has data after its terminator")
            break
        if entry[:2] == _MD5_MAGIC:
            if (
                checksum_seen
                or entry[2:16] != b"\xff" * 14
                or entry[16:] != hashlib.md5(data[:offset]).digest()
            ):
                raise LayoutError("partition table checksum is invalid")
            checksum_seen = True
            continue
        if checksum_seen:
            raise LayoutError("partition entry follows the checksum")
        magic, kind, subtype, start, size, label, flags = _ENTRY.unpack(entry)
        if magic != _ENTRY_MAGIC or flags != 0:
            raise LayoutError("unsupported partition entry or security flags")
        try:
            name = label.rstrip(b"\0").decode("ascii")
        except UnicodeDecodeError as error:
            raise LayoutError("partition label is not ASCII") from error
        partitions.append(Partition(name, kind, subtype, start, size))
    if not checksum_seen:
        raise LayoutError("partition table has no checksum record")
    return tuple(partitions)


def parse_csv(path: Path) -> tuple[Partition, ...]:
    """Parse a PlatformIO partition CSV whose rows carry explicit offsets."""
    partitions: list[Partition] = []
    for line in path.read_text(encoding="ascii").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = [field.strip() for field in line.split(",")]
        if len(fields) != 6 or fields[5]:
            raise LayoutError(f"{path.name}: rows need six fields and no flags")
        name, kind, subtype, offset, size, _ = fields
        if kind not in TYPES or (kind, subtype) not in SUBTYPES:
            raise LayoutError(f"{path.name}: unsupported {kind}/{subtype}")
        partitions.append(
            Partition(
                name,
                TYPES[kind],
                SUBTYPES[(kind, subtype)],
                _hex(offset.lower(), f"{path.name} {name} offset"),
                _hex(size.lower(), f"{path.name} {name} size"),
            )
        )
    return tuple(partitions)


def _hex(value: object, label: str) -> int:
    if not isinstance(value, str) or _HEX.fullmatch(value) is None:
        raise LayoutError(f"{label} must be a lowercase 0x-prefixed integer")
    return int(value, 16)


def _partition(raw: object, layout_id: str) -> Partition:
    if not isinstance(raw, dict) or set(raw) != {
        "name",
        "type",
        "subtype",
        "offset",
        "size",
    }:
        raise LayoutError(f"{layout_id}: invalid partition record")
    name, kind, subtype = raw["name"], raw["type"], raw["subtype"]
    if not isinstance(name, str) or _LABEL.fullmatch(name) is None:
        raise LayoutError(f"{layout_id}: invalid partition label")
    if kind not in TYPES or (kind, subtype) not in SUBTYPES:
        raise LayoutError(f"{layout_id}: unsupported {kind}/{subtype}")
    return Partition(
        name,
        TYPES[kind],
        SUBTYPES[(kind, subtype)],
        _hex(raw["offset"], f"{layout_id} {name} offset"),
        _hex(raw["size"], f"{layout_id} {name} size"),
    )


def _validate_geometry(layout: Layout) -> None:
    previous_end = TABLE_OFFSET + SECTOR
    names = set()
    for partition in layout.partitions:
        if partition.name in names:
            raise LayoutError(f"{layout.id}: duplicate {partition.name}")
        names.add(partition.name)
        alignment = (
            APP_ALIGNMENT if partition.type == TYPES["app"] else SECTOR
        )
        if (
            partition.offset % alignment
            or partition.size % SECTOR
            or partition.size == 0
            or partition.offset < previous_end
            or partition.end > FLASH_BYTES
        ):
            raise LayoutError(f"{layout.id}: {partition.name} is misplaced")
        previous_end = partition.end
    slots = layout.application_slots
    subtypes = [slot.subtype for slot in slots]
    expected = [0x10, 0x11] if layout.role == "production" else [0x10]
    if subtypes != expected or len({slot.size for slot in slots}) != 1:
        raise LayoutError(f"{layout.id}: unsupported application slots")
    if [p.name for p in layout.partitions if p.subtype == 0x81] != ["ffat"]:
        raise LayoutError(f"{layout.id}: exactly one ffat partition is required")
    if layout.max_application_bytes <= 0:
        raise LayoutError(f"{layout.id}: slots cannot keep the reserve")


def load(path: Path = REGISTRY_PATH) -> Registry:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise LayoutError(f"partition layout registry is unreadable: {error}") from error
    if not isinstance(raw, dict) or raw.get("schemaVersion") != 1:
        raise LayoutError("unsupported partition layout registry")
    for key, expected in (
        ("flashBytes", FLASH_BYTES),
        ("partitionTableOffset", TABLE_OFFSET),
        ("partitionTableBytes", TABLE_BYTES),
        ("applicationReserveBytes", APPLICATION_RESERVE_BYTES),
    ):
        if _hex(raw.get(key), key) != expected:
            raise LayoutError(f"registry {key} differs from the firmware contract")
    layouts: list[Layout] = []
    for item in raw.get("layouts", []):
        if not isinstance(item, dict) or not set(item) <= {
            "id",
            "generation",
            "role",
            "status",
            "csv",
            "partitionTableSha256",
            "partitions",
        }:
            raise LayoutError("invalid layout record")
        layout_id = item.get("id")
        if not isinstance(layout_id, str) or not layout_id:
            raise LayoutError("layout id is required")
        generation = item.get("generation")
        if type(generation) is not int or generation <= 0:
            raise LayoutError(f"{layout_id}: invalid generation")
        if item.get("role") not in ROLES or item.get("status") not in STATUSES:
            raise LayoutError(f"{layout_id}: invalid role or status")
        csv = item.get("csv")
        if (item["status"] == "current") != isinstance(csv, str):
            raise LayoutError(f"{layout_id}: exactly current layouts name a CSV")
        partitions = tuple(_partition(p, layout_id) for p in item.get("partitions", []))
        table_sha256 = item.get("partitionTableSha256")
        if not isinstance(table_sha256, str) or _SHA256.fullmatch(table_sha256) is None:
            raise LayoutError(f"{layout_id}: invalid partitionTableSha256")
        layout = Layout(
            layout_id,
            generation,
            item["role"],
            item["status"],
            csv,
            partitions,
            table_sha256,
        )
        _validate_geometry(layout)
        if hashlib.sha256(layout.table_bytes()).hexdigest() != table_sha256:
            raise LayoutError(f"{layout_id}: recorded table hash does not match")
        layouts.append(layout)
    if len({layout.id for layout in layouts}) != len(layouts):
        raise LayoutError("duplicate layout ids")
    if len({layout.table_sha256 for layout in layouts}) != len(layouts):
        raise LayoutError("distinct layouts must have distinct tables")
    shared = {
        name: {layout.partition(name).record() for layout in layouts}
        for name in SHARED_PARTITIONS
    }
    if any(len(records) != 1 for records in shared.values()):
        raise LayoutError("NVS, OTA selection and coredump must never move")
    registry = Registry(tuple(layouts), ())
    for status in STATUSES:
        roles = [registry._one(role, status) for role in ROLES]
        # Switching profiles within a generation must not relocate FFat.
        if len({layout.ffat.record() for layout in roles}) != 1:
            raise LayoutError(f"{status} production/development FFat differ")
        if len({layout.generation for layout in roles}) != 1:
            raise LayoutError(f"{status} layouts must share one generation")
    if registry.current("production").generation <= registry.legacy(
        "production"
    ).generation:
        raise LayoutError("current layouts must supersede legacy layouts")
    migrations: list[Migration] = []
    for item in raw.get("migrations", []):
        if not isinstance(item, dict) or set(item) != {"id", "source", "destination"}:
            raise LayoutError("invalid migration record")
        source = registry.layout(item["source"])
        destination = registry.layout(item["destination"])
        if (
            not isinstance(item["id"], str)
            or source.role != "production"
            or destination.role != "production"
            or source.status != "legacy"
            or destination.status != "current"
        ):
            raise LayoutError(f"unsupported migration {item['id']!r}")
        migrations.append(Migration(item["id"], source, destination))
    if len({migration.id for migration in migrations}) != len(migrations):
        raise LayoutError("duplicate migration ids")
    return Registry(tuple(layouts), tuple(migrations))
