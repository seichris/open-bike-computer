import importlib.util
from pathlib import Path
import random
import unittest


TOOL = Path(__file__).resolve().parents[1] / "generate_world_radio_map.py"
SPEC = importlib.util.spec_from_file_location("world_radio_map_generator", TOOL)
generator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(generator)


def unpack(packets):
    output = bytearray()
    position = 0
    while position < len(packets):
        control = packets[position]
        position += 1
        count = (control & 127) + 1
        if control & 128:
            output.extend(bytes([packets[position]]) * count)
            position += 1
        else:
            output.extend(packets[position:position + count])
            position += count
    return bytes(output)


class WorldRadioMapAssetsTests(unittest.TestCase):
    def test_packet_boundaries(self):
        for length in (0, 1, 2, 3, 127, 128, 129, 255, 256, 257, 1024):
            for data in (b"a" * length, bytes(i % 256 for i in range(length)),
                         b"ab" * length + b"c" * 129 + b"de"):
                self.assertEqual(unpack(generator.pack(data)), data)

    def test_random_packets_round_trip(self):
        rng = random.Random(190)
        for _ in range(100):
            data = bytes(rng.randrange(256) for _ in range(rng.randrange(1500)))
            self.assertEqual(unpack(generator.pack(data)), data)

    def test_generated_files_are_current(self):
        code, manifest, preview = generator.generate()
        self.assertEqual(generator.OUTPUT.read_bytes(), code)
        self.assertEqual(generator.MANIFEST.read_bytes(), manifest)
        self.assertEqual(preview.size, (1024, 512))


if __name__ == "__main__":
    unittest.main()
