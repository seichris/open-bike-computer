from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from map_platform.map_stream_build_identity import (
    load_map_stream_build_identity,
    producer_build_sha256,
    require_hashed_worker_runtime,
    worker_source_inputs,
)


class MapStreamBuildIdentityTests(unittest.TestCase):
    def write(self, contents: str) -> Path:
        path = Path(self.tmp.name) / "map-stream-build-identity.json"
        path.write_text(contents, encoding="utf-8")
        return path

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.tmp.cleanup()

    def test_loads_exact_immutable_producer_identity(self):
        identity = load_map_stream_build_identity(
            self.write(
                '{"schemaVersion":1,"producerBuildSha256":"'
                + "1" * 64
                + '"}'
            )
        )
        self.assertEqual(identity.producer_build_sha256, "1" * 64)

    def test_identity_is_derived_from_source_and_dependency_bytes(self):
        source = Path(self.tmp.name) / "worker.py"
        source.write_text("print('a')\n", encoding="utf-8")
        first = producer_build_sha256(
            [("worker.py", source)],
            dependency_inventory=b"fastapi==1\n",
            system_package_inventory=b"osmium=1\n",
            platform_inventory=b"architecture=arm64\n",
        )
        source.write_text("print('b')\n", encoding="utf-8")
        changed_source = producer_build_sha256(
            [("worker.py", source)],
            dependency_inventory=b"fastapi==1\n",
            system_package_inventory=b"osmium=1\n",
            platform_inventory=b"architecture=arm64\n",
        )
        changed_dependency = producer_build_sha256(
            [("worker.py", source)],
            dependency_inventory=b"fastapi==2\n",
            system_package_inventory=b"osmium=1\n",
            platform_inventory=b"architecture=arm64\n",
        )
        changed_architecture = producer_build_sha256(
            [("worker.py", source)],
            dependency_inventory=b"fastapi==2\n",
            system_package_inventory=b"osmium=1\n",
            platform_inventory=b"architecture=amd64\n",
        )
        self.assertRegex(first, r"^[0-9a-f]{64}$")
        self.assertNotEqual(first, changed_source)
        self.assertNotEqual(changed_source, changed_dependency)
        self.assertNotEqual(changed_dependency, changed_architecture)

    def test_rejects_missing_malformed_and_ambiguous_identity(self):
        invalid_documents = [
            '{"schemaVersion":1,"producerBuildSha256":""}',
            '{"schemaVersion":true,"producerBuildSha256":"' + "1" * 64 + '"}',
            '{"schemaVersion":1,"producerBuildSha256":"' + "A" * 64 + '"}',
            '{"schemaVersion":1,"producerBuildSha256":"' + "1" * 64 + '","extra":1}',
            '{"schemaVersion":1,"schemaVersion":1,"producerBuildSha256":"'
            + "1" * 64
            + '"}',
        ]
        for document in invalid_documents:
            with self.subTest(document=document):
                with self.assertRaises(ValueError):
                    load_map_stream_build_identity(self.write(document))

    def test_runtime_must_execute_from_the_hashed_source_tree(self):
        repo_root = Path(self.tmp.name) / "repo"
        hashed_package = repo_root / "map-platform" / "backend" / "map_platform"
        installed_package = repo_root / "site-packages" / "map_platform"
        hashed_package.mkdir(parents=True)
        installed_package.mkdir(parents=True)

        require_hashed_worker_runtime(repo_root, hashed_package)
        with self.assertRaisesRegex(ValueError, "hashed source tree"):
            require_hashed_worker_runtime(repo_root, installed_package)

    def test_worker_identity_hashes_relocated_osm_extract_sources(self):
        repo_root = Path(__file__).resolve().parents[3]
        logical_names = {name for name, _ in worker_source_inputs(repo_root)}

        self.assertTrue(
            any(name.startswith("tools/OSM_Extract/conf/") for name in logical_names)
        )
        self.assertTrue(
            any(name.startswith("tools/OSM_Extract/scripts/") for name in logical_names)
        )
        self.assertFalse(any(name.startswith("OSM_Extract/") for name in logical_names))


if __name__ == "__main__":
    unittest.main()
