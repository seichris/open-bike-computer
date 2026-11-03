"""Minimal 32-bit little-endian ELF relocatable objects for host tests."""

import struct
from pathlib import Path


def write_elf_object(
    path: Path, sections: tuple[str, ...], undefined_symbols: tuple[str, ...] = ()
) -> None:
    """Write an ELF32 object with `sections`, optional undefined symbols and .shstrtab."""
    names = ["", *sections]
    if undefined_symbols:
        names += [".symtab", ".strtab"]
    names += [".shstrtab"]
    section_names = b""
    name_offsets = []
    for name in names:
        name_offsets.append(len(section_names))
        section_names += name.encode("ascii") + b"\0"
    strings = b"\0"
    symbols = b"\0" * 16
    for symbol in undefined_symbols:
        # GLOBAL NOTYPE symbol in section 0 (SHN_UNDEF): an import.
        symbols += struct.pack("<IIIBBH", len(strings), 0, 0, 0x10, 0, 0)
        strings += symbol.encode("ascii") + b"\0"
    names_start = 52
    strings_start = names_start + len(section_names)
    symbols_start = strings_start + len(strings)
    symbols_start += (-symbols_start) % 4
    table_start = symbols_start + len(symbols)
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
            table += struct.pack("<IIIIIIIIII", name_offsets[index], 3, 0, 0, names_start, len(section_names), 0, 0, 1, 0)
        elif name == ".strtab":
            table += struct.pack("<IIIIIIIIII", name_offsets[index], 3, 0, 0, strings_start, len(strings), 0, 0, 1, 0)
        elif name == ".symtab":
            table += struct.pack("<IIIIIIIIII", name_offsets[index], 2, 0, 0, symbols_start, len(symbols), names.index(".strtab"), 1, 4, 16)
        else:
            table += struct.pack("<IIIIIIIIII", name_offsets[index], 1, 6, 0, names_start, 0, 0, 0, 4, 0)
    data = header + section_names
    data += b"\0" * (strings_start - len(data)) + strings
    data += b"\0" * (symbols_start - len(data)) + symbols
    data += b"\0" * (table_start - len(data)) + table
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
