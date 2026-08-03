import struct
import zlib


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
) -> bytes:
    data = bytearray(b"FMB\x04\0\0\0\0")
    building = bytearray(struct.pack("<HHI", 1, 0, 4))
    building.extend(
        struct.pack(
            "<BBBBHHhhhhH",
            100,
            1,
            provenance,
            0,
            123,
            20,
            0,
            0,
            100,
            100,
            1,
        )
    )
    building.extend(struct.pack("<HBBhhhhhhhhB", 4, 0, 0, 0, 0, 100, 0, 100, 100, 0, 100, 0x0F))
    sections = (
        b"\0\0",
        b"\0\0",
        struct.pack("<IH", profile_fingerprint, 0),
        bytes(building),
    )
    data.extend(b"EXT4\x04\0\0\0")
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
    data = bytearray(b"FMB\x03")
    data.extend(struct.pack("<H", 0))
    data.extend(struct.pack("<H", 1))
    data.extend(struct.pack("<HBBBhhhhHhhhh", 0x1234, 2, 5, 7, 0, 0, 100, 0, 2, 0, 0, 100, 0))
    strings = struct.pack("<HH4s", 1, 4, b"Main")
    runs = bytearray(struct.pack("<H", 3))
    for size_id in range(3):
        runs.extend(struct.pack("<HBBHhhh", 1, size_id, 1, 1, 0, 0, 640))
    labels = bytearray(struct.pack("<IH", profile_fingerprint, 1))
    labels.extend(struct.pack("<HBBBHBB", 0, 1, 0, 5, 1, 1, 1))
    labels.extend(struct.pack("<BBHHHH", 0, 0, 1, 1, 2, 3))
    labels.extend(struct.pack("<hhhhBB", 0, 0, 100, 0, 255, 0))
    sections = (strings, bytes(runs), bytes(labels))
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
