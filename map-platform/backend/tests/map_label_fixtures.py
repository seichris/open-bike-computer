import struct
import zlib
from pathlib import Path


GOLDEN_FMB_FIXTURE = (
    Path(__file__).resolve().parents[3]
    / "tools"
    / "tests"
    / "fixtures"
    / "fmb"
    / "golden_blocks.txt"
)


def golden_fmb(name: str) -> bytes:
    for raw_line in GOLDEN_FMB_FIXTURE.read_text(encoding="ascii").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        fixture_name, encoded = line.split("=", 1)
        if fixture_name == name:
            return bytes.fromhex(encoded)
    raise KeyError(f"unknown golden FMB fixture: {name}")


def _base_geometry_end(data: bytes) -> int:
    version = data[3]
    offset = 4
    polygon_count = struct.unpack_from("<H", data, offset)[0]
    offset += 2
    for _ in range(polygon_count):
        offset += 12 if version >= 2 else 11
        point_count = struct.unpack_from("<H", data, offset)[0]
        offset += 2 + point_count * 4
    polyline_count = struct.unpack_from("<H", data, offset)[0]
    offset += 2
    for _ in range(polyline_count):
        offset += 13 if version >= 2 else 12
        point_count = struct.unpack_from("<H", data, offset)[0]
        offset += 2 + point_count * 4
    return offset


def _section_span(data: bytes, section_type: int) -> tuple[int, int, int]:
    directory = _base_geometry_end(data)
    entry = directory + 8 + (section_type - 1) * 16
    if data[entry] != section_type:
        raise ValueError("golden FMB section order changed")
    offset, length = struct.unpack_from("<II", data, entry + 4)
    return entry, offset, length


def _refresh_section_crc(
    data: bytearray, entry: int, offset: int, length: int
) -> None:
    checksum = zlib.crc32(data[offset : offset + length]) & 0xFFFFFFFF
    struct.pack_into("<I", data, entry + 12, checksum)


def _set_profile_fingerprint(data: bytearray, profile_fingerprint: int) -> None:
    entry, offset, length = _section_span(data, 3)
    struct.pack_into("<I", data, offset, profile_fingerprint)
    _refresh_section_crc(data, entry, offset, length)


def empty_fmb3(profile_fingerprint: int = 0x12345678) -> bytes:
    data = bytearray(b"FMB\x03\0\0\0\0")
    sections = (
        b"\0\0",
        b"\0\0",
        struct.pack("<IH", profile_fingerprint, 0),
    )
    data.extend(b"EXT3\x03\0\0\0")
    offset = len(data) + len(sections) * 16
    for section_type, section in enumerate(sections, 1):
        data.extend(
            struct.pack(
                "<BBHIII",
                section_type,
                1,
                0,
                offset,
                len(section),
                zlib.crc32(section) & 0xFFFFFFFF,
            )
        )
        offset += len(section)
    for section in sections:
        data.extend(section)
    return bytes(data)


def empty_fma1(
    profile_fingerprint: int = 0x12345678,
    languages: tuple[str, ...] = ("zh-Hant", "en"),
) -> bytes:
    language_table = b"".join(
        bytes((len(language.encode("ascii")),)) + language.encode("ascii")
        for language in languages
    )
    face_name = b"test"
    face_table = struct.pack("<BBH32s", 0, 0, len(face_name), b"\x55" * 32) + face_name
    return struct.pack(
        "<4sBBBBIIIIII",
        b"FMA1",
        1,
        3,
        len(languages),
        1,
        profile_fingerprint,
        0,
        len(language_table),
        len(face_table),
        0,
        0,
    ) + language_table + face_table


def one_building_fmb4(
    profile_fingerprint: int = 0x12345678,
    provenance: int = 0,
    flags: int = 1,
) -> bytes:
    data = bytearray(golden_fmb("fmb_v4"))
    _set_profile_fingerprint(data, profile_fingerprint)
    entry, offset, length = _section_span(data, 4)
    data[offset + 8 + 1] = flags
    data[offset + 8 + 2] = provenance
    _refresh_section_crc(data, entry, offset, length)
    return bytes(data)


def one_label_fma1(profile_fingerprint: int = 0x12345678) -> bytes:
    language_table = b"\x02en"
    face_name = b"test"
    face_table = struct.pack("<BBH32s", 0, 0, len(face_name), b"\x55" * 32) + face_name
    index = bytearray()
    payload = bytearray()
    for size_id in range(3):
        fill_offset = len(payload)
        payload.extend(b"\x00\x0f")
        distance_offset = len(payload)
        payload.extend(b"\x00\x0f")
        index.extend(
            struct.pack(
                "<HBBhhhHHHIIII",
                1,
                0,
                size_id,
                0,
                0,
                640,
                1,
                1,
                0,
                fill_offset,
                2,
                distance_offset,
                2,
            )
        )
    return struct.pack(
        "<4sBBBBIIIIII",
        b"FMA1",
        1,
        3,
        1,
        1,
        profile_fingerprint,
        3,
        len(language_table),
        len(face_table),
        len(index),
        len(payload),
    ) + language_table + face_table + index + payload


def one_label_fmb3(profile_fingerprint: int = 0x12345678) -> bytes:
    data = bytearray(golden_fmb("fmb_v3"))
    _set_profile_fingerprint(data, profile_fingerprint)
    return bytes(data)
