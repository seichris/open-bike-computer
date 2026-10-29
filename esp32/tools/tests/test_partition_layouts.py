#!/usr/bin/env python3

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

import partition_layouts as pl

# Exact bytes observed outside this repository: the dual-3-MiB table hash is
# signed in v0.3.4-release.13's web recovery manifests and the 6 MiB developer
# table hash is the partitions.bin of a CI-built WAVESHARE_AMOLED_175 profile.
PUBLISHED_LEGACY_PRODUCTION_TABLE = (
    "6d6e105907099b7344b9c167d2615a9a7f43d8c6926229cf5837720e6674cbbf"
)
BUILT_LEGACY_DEVELOPMENT_TABLE = (
    "7dd5955a3be2f162301cd46e83ba8d6ce83a106e47f49308937b71e3fb9fc7ce"
)


class PartitionLayoutRegistryTests(unittest.TestCase):
    def setUp(self):
        self.registry = pl.load()
        self.raw = json.loads(pl.REGISTRY_PATH.read_text(encoding="utf-8"))

    def load_modified(self, change):
        raw = json.loads(json.dumps(self.raw))
        change(raw)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "layouts.json"
            path.write_text(json.dumps(raw), encoding="utf-8")
            return pl.load(path)

    def test_legacy_tables_match_real_toolchain_output(self):
        self.assertEqual(
            self.registry.legacy("production").table_sha256,
            PUBLISHED_LEGACY_PRODUCTION_TABLE,
        )
        self.assertEqual(
            self.registry.legacy("development").table_sha256,
            BUILT_LEGACY_DEVELOPMENT_TABLE,
        )

    def test_current_generation_geometry(self):
        production = self.registry.current("production")
        development = self.registry.current("development")
        self.assertEqual(production.id, "esp32s3-16m-dual4m-ffat7m-v1")
        self.assertEqual(
            [(s.name, s.offset, s.size) for s in production.application_slots],
            [("app0", 0x10000, 0x400000), ("app1", 0x410000, 0x400000)],
        )
        self.assertEqual(production.max_application_bytes, 0x400000 - 0x10000)
        self.assertEqual(development.application_slots[0].size, 0x800000)
        self.assertEqual(production.ffat, development.ffat)
        self.assertEqual((production.ffat.offset, production.ffat.size), (0x810000, 0x700000))
        legacy = self.registry.legacy("production")
        self.assertEqual(legacy.max_application_bytes, 3_080_192)
        # The two FFat generations end at the same address: a table swap
        # without an explicit FFat recreate would leave shifted old data.
        self.assertEqual(legacy.ffat.end, production.ffat.end)
        for name in pl.SHARED_PARTITIONS:
            self.assertEqual(
                legacy.partition(name), production.partition(name), name
            )

    def test_identify_requires_exact_table_bytes(self):
        for layout in self.registry.layouts:
            self.assertIs(self.registry.identify(layout.table_bytes()), layout)
            self.assertEqual(pl.parse_table(layout.table_bytes()), layout.partitions)
        table = bytearray(self.registry.current("production").table_bytes())
        table[-1] = 0
        self.assertIsNone(self.registry.identify(bytes(table)))

    def test_strict_table_parser_rejects_torn_or_flagged_tables(self):
        table = self.registry.current("production").table_bytes()
        checksum = len(self.registry.current("production").partitions) * 32
        cases = {
            "truncated": table[:-1],
            "flag": table[:28] + b"\x01" + table[29:],
            "checksum": table[: checksum + 20] + b"\0" + table[checksum + 21 :],
            "trailing": table[:-1] + b"\0",
            "missing checksum": table[:checksum] + b"\xff" * (len(table) - checksum),
            "erased": b"\xff" * pl.TABLE_BYTES,
        }
        for label, data in cases.items():
            with self.subTest(label), self.assertRaises(pl.LayoutError):
                pl.parse_table(data)

    def test_registry_rejects_unsafe_changes(self):
        def layout(raw, layout_id):
            return next(item for item in raw["layouts"] if item["id"] == layout_id)

        changes = {
            "hash drift": lambda raw: layout(raw, "esp32s3-16m-dual4m-ffat7m-v1")
            .__setitem__("partitionTableSha256", "0" * 64),
            "moved nvs": lambda raw: layout(raw, "esp32s3-16m-dual4m-ffat7m-v1")[
                "partitions"
            ][0].__setitem__("offset", "0xa000"),
            "split ffat": lambda raw: layout(raw, "esp32s3-16m-single8m-ffat7m-v1")[
                "partitions"
            ][3].__setitem__("size", "0x6ff000"),
            "overlap": lambda raw: layout(raw, "esp32s3-16m-dual4m-ffat7m-v1")[
                "partitions"
            ][2].__setitem__("size", "0x410000"),
            "uppercase hex": lambda raw: raw.__setitem__("flashBytes", "0x1000000".upper()),
            "reserve": lambda raw: raw.__setitem__("applicationReserveBytes", "0x8000"),
            "two current": lambda raw: layout(raw, "esp32s3-16m-dual3m-ffat9m-v1")
            .__setitem__("status", "current"),
            "unknown key": lambda raw: layout(raw, "esp32s3-16m-dual3m-ffat9m-v1")
            .__setitem__("extra", True),
            "reverse migration": lambda raw: raw["migrations"][0].update(
                source="esp32s3-16m-dual4m-ffat7m-v1",
                destination="esp32s3-16m-dual3m-ffat9m-v1",
            ),
        }
        for label, change in changes.items():
            with self.subTest(label), self.assertRaises(pl.LayoutError):
                self.load_modified(change)

    def test_migration_is_explicit_and_one_way(self):
        legacy = self.registry.legacy("production")
        current = self.registry.current("production")
        migration = self.registry.migration(legacy, current)
        self.assertEqual(migration.id, "dual3m-to-dual4m-v1")
        with self.assertRaises(pl.LayoutError):
            self.registry.migration(current, legacy)
        with self.assertRaises(pl.LayoutError):
            self.registry.migration(self.registry.legacy("development"), current)

    def test_csv_parser_matches_current_tables(self):
        project = pl.REGISTRY_PATH.parent
        for role in pl.ROLES:
            layout = self.registry.current(role)
            rows = pl.parse_csv(project / layout.csv)
            self.assertEqual(
                hashlib.sha256(pl.encode_table(rows)).hexdigest(),
                layout.table_sha256,
            )


if __name__ == "__main__":
    unittest.main()
