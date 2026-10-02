"""Bounded FMB v5 contour section encoding shared with firmware/iPhone readers.

Coordinates are integer metres in the existing 4096 m block. The first pair is
absolute; subsequent pairs are signed deltas. Long paths are split by the
geometry stage, never truncated by this codec.
"""
from __future__ import annotations

import struct
import zlib
from dataclasses import dataclass
from pathlib import Path

MAX_CONTOURS = 4096
MAX_POINTS = 65536
MAX_RECORD_POINTS = 256
MAX_SEGMENT_METRES = 512
HEADER = struct.Struct("<BBHHHI")
RECORD = struct.Struct("<hBBHhhhh")
POINT = struct.Struct("<hh")
INTERVALS = {(20, 100), (50, 250)}
TOPOGRAPHY_RENDERER_FORMAT_VERSION = 4
TOPOGRAPHY_BLOCK_FORMAT_VERSION = 5
TOPOGRAPHY_PROFILE_VERSION = 1
TOPOGRAPHY_COMPANION_FORMAT = "topography-ios-v1"
TOPOGRAPHY_COMPANION_MEDIA_TYPE = "application/vnd.bicino.topography+sqlite3"


def renderer_has_labels(format_version: int) -> bool:
    return format_version in {2, 3, TOPOGRAPHY_RENDERER_FORMAT_VERSION}


def renderer_has_buildings(format_version: int) -> bool:
    return format_version in {3, TOPOGRAPHY_RENDERER_FORMAT_VERSION}


def vector_renderer_format_version(format_version: int) -> int:
    """Return the existing vector encoder target underlying a public format.

    Renderer format 4 is a strict extension of the format-3 vectors. Contours
    are attached afterwards from the single topography intermediate, so the
    OSM feature encoder must continue producing byte-compatible FMB v4 input.
    """
    return 3 if format_version == TOPOGRAPHY_RENDERER_FORMAT_VERSION else format_version


@dataclass(frozen=True)
class Contour:
    elevation_m: int
    flags: int
    points: tuple[tuple[int, int], ...]


@dataclass(frozen=True)
class ContourSection:
    minor_interval_m: int
    index_interval_m: int
    contours: tuple[Contour, ...]

    @property
    def point_count(self) -> int:
        return sum(len(record.points) for record in self.contours)


def _record(contour: Contour, minor: int, index: int) -> tuple[tuple, bytes]:
    elevation, flags, points = contour.elevation_m, contour.flags, contour.points
    if (type(elevation) is not int or not -12000 <= elevation <= 10000
            or elevation % minor or type(flags) is not int or flags & ~7
            or bool(flags & 1) != (elevation % index == 0)
            or not 2 <= len(points) <= MAX_RECORD_POINTS):
        raise ValueError("invalid contour record metadata")
    encoded = bytearray()
    previous = None
    for point in points:
        if len(point) != 2 or any(type(value) is not int or not 0 <= value <= 4096 for value in point):
            raise ValueError("contour coordinate is outside its block")
        x, y = point
        dx, dy = (x, y) if previous is None else (x - previous[0], y - previous[1])
        if previous is not None and (dx == dy == 0 or dx * dx + dy * dy > MAX_SEGMENT_METRES**2):
            raise ValueError("contour segment is degenerate or too long")
        encoded.extend(POINT.pack(dx, dy))
        previous = point
    bounds = (min(p[0] for p in points), min(p[1] for p in points),
              max(p[0] for p in points), max(p[1] for p in points))
    key = (elevation, flags, *bounds, bytes(encoded))
    return key, RECORD.pack(elevation, flags, 0, len(points), *bounds) + encoded


def encode_contour_section(section: ContourSection) -> bytes:
    minor, index = section.minor_interval_m, section.index_interval_m
    if type(minor) is not int or type(index) is not int or (minor, index) not in INTERVALS:
        raise ValueError("unsupported contour interval policy")
    if len(section.contours) > MAX_CONTOURS or section.point_count > MAX_POINTS:
        raise ValueError("contour section exceeds bounds")
    records = sorted(_record(record, minor, index) for record in section.contours)
    if any(left[0] == right[0] for left, right in zip(records, records[1:])):
        raise ValueError("duplicate contour record")
    return HEADER.pack(1, 0, minor, index, len(records), section.point_count) + b"".join(value for _, value in records)


def decode_contour_section(data: bytes) -> ContourSection:
    if len(data) < HEADER.size or len(data) > HEADER.size + MAX_CONTOURS * RECORD.size + MAX_POINTS * POINT.size:
        raise ValueError("invalid contour section length")
    version, flags, minor, index, count, declared_points = HEADER.unpack_from(data)
    if version != 1 or flags or (minor, index) not in INTERVALS or count > MAX_CONTOURS or declared_points > MAX_POINTS:
        raise ValueError("invalid contour section header")
    cursor, total, previous_key = HEADER.size, 0, None
    contours = []
    for _ in range(count):
        if len(data) - cursor < RECORD.size:
            raise ValueError("truncated contour record")
        elevation, flags, reserved, point_count, *bounds = RECORD.unpack_from(data, cursor)
        cursor += RECORD.size
        if (reserved or not 2 <= point_count <= MAX_RECORD_POINTS or point_count > declared_points - total
                or len(data) - cursor < point_count * POINT.size):
            raise ValueError("invalid contour point count or reserved field")
        points, x, y = [], 0, 0
        for number in range(point_count):
            dx, dy = POINT.unpack_from(data, cursor)
            cursor += POINT.size
            x, y = (dx, dy) if number == 0 else (x + dx, y + dy)
            points.append((x, y))
        record = Contour(elevation, flags, tuple(points))
        key, _ = _record(record, minor, index)
        if tuple(bounds) != key[2:6] or (previous_key is not None and key <= previous_key):
            raise ValueError("contour bounds or canonical order differ")
        contours.append(record)
        previous_key = key
        total += point_count
    if cursor != len(data) or total != declared_points:
        raise ValueError("contour section has trailing bytes or mismatched totals")
    return ContourSection(minor, index, tuple(contours))


def upgrade_fmb4(path: Path, section: ContourSection) -> bytes:
    from .map_artifact_validation import _parse_base_geometry, validate_fmb4

    validate_fmb4(path)
    raw = path.read_bytes()
    directory, _ = _parse_base_geometry(raw)
    sections = []
    for number in range(4):
        offset, length = struct.unpack_from("<II", raw, directory + 8 + number * 16 + 4)
        sections.append(raw[offset:offset + length])
    sections.append(encode_contour_section(section))
    return _encode_fmb5(raw[:directory], sections)


def empty_fmb5(profile_fingerprint: int, section: ContourSection) -> bytes:
    """Terrain-only blocks still carry the map's label profile and buildings header."""
    if type(profile_fingerprint) is not int or not 0 < profile_fingerprint <= 0xffffffff:
        raise ValueError("invalid label profile fingerprint")
    return _encode_fmb5(b"FMB\x04\0\0\0\0", [
        b"\0\0", b"\0\0", struct.pack("<IH", profile_fingerprint, 0),
        b"\0" * 8, encode_contour_section(section),
    ])


def _encode_fmb5(base: bytes, sections: list[bytes]) -> bytes:
    from .map_artifact_validation import MAX_FMB_BYTES
    output = bytearray(base)
    output[3] = 5
    output.extend(b"EXT5\x05\0\0\0")
    offset = len(output) + 5 * 16
    if offset + sum(map(len, sections)) > MAX_FMB_BYTES:
        raise ValueError("topographic FMB exceeds block byte bound")
    for number, payload in enumerate(sections, 1):
        output.extend(struct.pack("<BBHIII", number, 1, 0, offset, len(payload), zlib.crc32(payload) & 0xffffffff))
        offset += len(payload)
    for payload in sections:
        output.extend(payload)
    return bytes(output)
