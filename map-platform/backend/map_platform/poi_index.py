"""FPI1: signed, bounded block summaries for offline nearest-POI queries.

Coordinates and category truth remain in FMB6 section 6. The index may only
reference canonical blocks belonging to the same manifest, and is validated
against those blocks before an artifact is published or activated.
"""
from __future__ import annotations

import struct
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from .map_artifact_validation import MAX_FMB_BYTES, MAX_POIS, _parse_base_geometry, validate_fmb6
from .reuse import MapBlock, block_from_pack_path

HEADER = struct.Struct("<4sHHII")
ENTRY = struct.Struct("<iiI5HIIH")
MAX_ENTRIES = 16384
MAX_BYTES = HEADER.size + ENTRY.size * MAX_ENTRIES


@dataclass(frozen=True, order=True)
class PoiIndexEntry:
    x: int
    y: int
    category_mask: int
    category_counts: tuple[int, int, int, int, int]
    section_offset: int
    section_bytes: int

    @property
    def record_count(self) -> int:
        return sum(self.category_counts)

    def relative_path(self, map_id: str) -> str:
        block = MapBlock(self.x, self.y)
        return f"VECTMAP/{map_id}/{block.folder_name}/{block.local_x}_{block.local_y}.fmb"


def index_path(map_id: str) -> str:
    # Match manifest map-ID rules before constructing any filesystem path.
    import re
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", map_id) or map_id in {".", ".."}:
        raise ValueError("invalid POI index map ID")
    return f"VECTMAP/{map_id}/assets/nearby-pois.fpi"


def decode_index(data: bytes) -> tuple[PoiIndexEntry, ...]:
    if not HEADER.size <= len(data) <= MAX_BYTES:
        raise ValueError("POI index byte limit or truncated header")
    magic, size, reserved, count, crc = HEADER.unpack_from(data)
    if (magic != b"FPI1" or size != ENTRY.size or reserved or count > MAX_ENTRIES
            or len(data) != HEADER.size + count * ENTRY.size
            or zlib.crc32(data[HEADER.size:]) & 0xffffffff != crc):
        raise ValueError("POI index header, count, or CRC is invalid")
    result = []
    previous = None
    for values in ENTRY.iter_unpack(data[HEADER.size:]):
        x, y, mask, *tail = values
        counts = tuple(tail[:5])
        offset, length, flags = tail[5:]
        actual_mask = sum(1 << category for category, value in enumerate(counts) if value)
        total = sum(counts)
        if (flags or mask != actual_mask or not 1 <= total <= MAX_POIS
                or offset < 8 + 8 + 6 * 16 or length != 8 + total * 8
                or offset > MAX_FMB_BYTES - length
                or (previous is not None and (x, y) <= previous)):
            raise ValueError("POI index entry is invalid or noncanonical")
        result.append(PoiIndexEntry(x, y, mask, counts, offset, length))
        previous = (x, y)
    return tuple(result)


def _block_entries(map_root: Path, map_id: str, files: list[dict],
                   cancel: Callable[[], None]) -> tuple[PoiIndexEntry, ...]:
    index_path(map_id)
    result = []
    seen = set()
    for file in files:
        relative = file["path"]
        if not relative.endswith(".fmb"):
            continue
        cancel()
        block = block_from_pack_path(relative)
        if (block is None or block in seen
                or not all(-(1 << 31) <= coordinate < (1 << 31) for coordinate in (block.x, block.y))
                or relative != f"VECTMAP/{map_id}/{block.folder_name}/{block.local_x}_{block.local_y}.fmb"):
            raise ValueError("POI index block path is invalid or duplicated")
        seen.add(block)
        path = map_root / relative
        parts = path.relative_to(map_root).parts
        if any(map_root.joinpath(*parts[:end]).is_symlink() for end in range(len(parts) + 1)):
            raise ValueError("POI index block cannot be a symlink")
        metadata = validate_fmb6(path)
        if not metadata.poi_records:
            continue
        if len(result) >= MAX_ENTRIES:
            raise ValueError("POI index exceeds entry limit")
        with path.open("rb") as source:
            raw = source.read(MAX_FMB_BYTES + 1)
        if len(raw) > MAX_FMB_BYTES:
            raise ValueError("POI index block exceeds byte limit")
        directory, _ = _parse_base_geometry(raw)
        offset, length = struct.unpack_from("<II", raw, directory + 8 + 5 * 16 + 4)
        counts = metadata.poi_categories
        mask = sum(1 << category for category, value in enumerate(counts) if value)
        result.append(PoiIndexEntry(block.x, block.y, mask, counts, offset, length))
    return tuple(sorted(result))


def build_index(map_root: Path, map_id: str, files: list[dict], *,
                cancel: Callable[[], None] = lambda: None) -> bytes:
    entries = _block_entries(map_root, map_id, files, cancel)
    body = b"".join(ENTRY.pack(value.x, value.y, value.category_mask,
                               *value.category_counts, value.section_offset,
                               value.section_bytes, 0) for value in entries)
    raw = HEADER.pack(b"FPI1", ENTRY.size, 0, len(entries), zlib.crc32(body) & 0xffffffff) + body
    decode_index(raw)
    return raw


def validate_index(map_root: Path, map_id: str, files: list[dict], *,
                   cancel: Callable[[], None] = lambda: None) -> tuple[PoiIndexEntry, ...]:
    relative = index_path(map_id)
    if sum(file["path"] == relative for file in files) != 1:
        raise ValueError("target 5 requires exactly one POI index")
    path = map_root / relative
    parts = path.relative_to(map_root).parts
    if any(map_root.joinpath(*parts[:end]).is_symlink() for end in range(len(parts) + 1)):
        raise ValueError("POI index cannot be a symlink")
    with path.open("rb") as source:
        entries = decode_index(source.read(MAX_BYTES + 1))
    expected = _block_entries(map_root, map_id, files, cancel)
    if entries != expected:
        raise ValueError("POI index does not match every nonempty POI block")
    return entries
