#!/usr/bin/env python3
"""wear_levelling_state.hpp reads WL metadata the way ESP-IDF 5.5 writes it.

States are built like ESP-IDF's components/fatfs/wl_fatfsgen.py
(_add_state_sectors): eight little-endian uint32 fields, 28 reserved zero
bytes, then binascii.crc32(header, UINT32_MAX). Each copy occupies
ceil((64 + 16 * sectors) / 4096) sectors below the final config sector.
"""

import binascii
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[2]
HARNESS = r"""
#include "lib/storage/wear_levelling_state.hpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
int main(int, char **argv) {
  FILE *file = std::fopen(argv[1], "rb");
  std::vector<uint8_t> image;
  for (int byte; (byte = std::fgetc(file)) != EOF;)
    image.push_back(static_cast<uint8_t>(byte));
  std::fclose(file);
  const uint32_t base = std::strtoul(argv[2], nullptr, 0);
  const uint32_t size = std::strtoul(argv[3], nullptr, 0);
  unsigned valid = 0;
  for (unsigned copy = 0; copy < 2; ++copy) {
    uint8_t state[wear_levelling_state::kStateBytes];
    std::memcpy(state,
                image.data() + base + wear_levelling_state::stateOffset(size, copy),
                sizeof(state));
    if (wear_levelling_state::stateValid(state))
      valid |= 1U << copy;
  }
  std::printf("%u\n", valid);
  return 0;
}
"""


def state(size: int, version: int = 2) -> bytes:
    sectors = size // 4096
    header = struct.pack("<8I", 0, sectors - 20, 0, 0, 16, 4096, version, 0x5EED) + bytes(28)
    return header + struct.pack("<I", binascii.crc32(header, 0xFFFFFFFF))


def volume(size: int, version: int = 2) -> bytearray:
    image = bytearray(b"\xff" * size)
    region = (64 + (size // 4096) * 16 + 4095) // 4096 * 4096
    for copy in range(2):
        offset = size - (2 - copy) * region - 4096
        image[offset:offset + 64] = state(size, version)
    return image


class WearLevellingStateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        root = Path(cls.directory.name)
        (root / "harness.cpp").write_text(HARNESS, encoding="utf-8")
        cls.binary = root / "harness"
        subprocess.run(["g++", "-std=c++17", "-Wall", "-Wextra", "-Werror", "-I", str(PROJECT),
                        str(root / "harness.cpp"), "-o", str(cls.binary)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def valid_copies(self, image: bytes, base: int, size: int) -> int:
        path = Path(self.directory.name) / "image.bin"
        path.write_bytes(image)
        result = subprocess.run([str(self.binary), str(path), hex(base), hex(size)],
                                check=True, capture_output=True, text=True)
        return int(result.stdout)

    def test_volumes_at_their_own_geometry_are_recognised(self):
        for size in (0x700000, 0x900000):
            with self.subTest(size=hex(size)):
                self.assertEqual(self.valid_copies(volume(size), 0, size), 0b11)

    def test_shifted_legacy_volume_is_not_recognised_at_the_new_geometry(self):
        # A dual-3-MiB FFat (0x610000, 9 MiB) seen through the dual-4-MiB
        # table (0x810000, 7 MiB): same end address, different state offsets.
        legacy = volume(0x900000)
        self.assertEqual(self.valid_copies(legacy, 0x200000, 0x700000), 0)

    def test_erased_damaged_and_old_version_states_are_not_recognised(self):
        self.assertEqual(self.valid_copies(b"\xff" * 0x700000, 0, 0x700000), 0)
        self.assertEqual(self.valid_copies(volume(0x700000, version=1), 0, 0x700000), 0)
        damaged = volume(0x700000)
        region = (64 + 0x700 * 16 + 4095) // 4096 * 4096
        first = 0x700000 - 2 * region - 4096
        damaged[first + 7] ^= 1
        # One intact copy is enough: WL_Flash::init recovers the other.
        self.assertEqual(self.valid_copies(damaged, 0, 0x700000), 0b10)


if __name__ == "__main__":
    unittest.main()
