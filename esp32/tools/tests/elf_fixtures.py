"""Minimal 32-bit little-endian ELF relocatable objects for host tests."""

import struct
from pathlib import Path


def write_elf_object(path: Path, sections: tuple[str, ...]) -> None:
    """Write an ELF32 object whose section table holds `sections` plus .shstrtab."""
    names = ["", *sections, ".shstrtab"]
    strings = b""
    offsets = []
    for name in names:
        offsets.append(len(strings))
        strings += name.encode("ascii") + b"\0"
    strings_start = 52
    table_start = strings_start + len(strings)
    table_start += (-table_start) % 4
    header = b"\x7fELF" + bytes([1, 1, 1, 0]) + b"\0" * 8
    header += struct.pack(
        "<HHIIIIIHHHHHH", 1, 94, 1, 0, 0, table_start, 0, 52, 0, 0, 40, len(names), len(names) - 1
    )
    table = b""
    for index, name in enumerate(names):
        if index == 0:
            table += struct.pack("<IIIIIIIIII", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        elif name == ".shstrtab":
            table += struct.pack("<IIIIIIIIII", offsets[index], 3, 0, 0, strings_start, len(strings), 0, 0, 1, 0)
        else:
            table += struct.pack("<IIIIIIIIII", offsets[index], 1, 6, 0, strings_start, 0, 0, 0, 4, 0)
    data = header + strings
    data += b"\0" * (table_start - len(data)) + table
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
