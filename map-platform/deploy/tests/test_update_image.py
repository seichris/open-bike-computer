from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "update_image.py"
SPEC = importlib.util.spec_from_file_location("update_image", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
update_image = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = update_image
SPEC.loader.exec_module(update_image)


class UpdateImageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.compose = MODULE_PATH.with_name("compose.yaml")

    def copy_compose(self, directory: str) -> Path:
        target = Path(directory) / "compose.yaml"
        target.write_text(self.compose.read_text(encoding="utf-8"), encoding="utf-8")
        return target

    def test_committed_production_compose_is_digest_pinned(self) -> None:
        deployment = update_image.validate_manifest(self.compose)

        self.assertRegex(deployment.control_plane_source_commit, r"^[0-9a-f]{40}$")
        self.assertRegex(deployment.worker_source_commit, r"^[0-9a-f]{40}$")
        self.assertRegex(
            deployment.control_plane_reference,
            r"^ghcr\.io/seichris/open-bike-computer-map-platform@sha256:[0-9a-f]{64}$",
        )
        self.assertRegex(
            deployment.worker_reference,
            r"^ghcr\.io/seichris/open-bike-computer-map-platform@sha256:[0-9a-f]{64}$",
        )

    def test_control_plane_can_advance_without_worker(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = self.copy_compose(directory)
            before = update_image.validate_manifest(target)
            deployment = update_image.update_manifest(
                target,
                control_plane_digest="sha256:" + "b" * 64,
                source_commit="a" * 40,
            )

            self.assertEqual(deployment.control_plane_source_commit, "a" * 40)
            self.assertEqual(deployment.control_plane_digest, "sha256:" + "b" * 64)
            self.assertEqual(deployment.worker_source_commit, before.worker_source_commit)
            self.assertEqual(deployment.worker_reference, before.worker_reference)

    def test_worker_and_control_plane_can_advance_together(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = self.copy_compose(directory)
            digest = "sha256:" + "c" * 64
            deployment = update_image.update_manifest(
                target,
                control_plane_digest=digest,
                worker_digest=digest,
                source_commit="d" * 40,
            )

            self.assertEqual(deployment.control_plane_source_commit, "d" * 40)
            self.assertEqual(deployment.worker_source_commit, "d" * 40)
            self.assertEqual(deployment.control_plane_digest, digest)
            self.assertEqual(deployment.worker_digest, digest)
            self.assertNotIn(":latest", target.read_text(encoding="utf-8"))

    def test_pending_worker_can_be_preserved_while_control_plane_advances(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            current = self.copy_compose(directory)
            pending = Path(directory) / "pending-compose.yaml"
            pending.write_text(current.read_text(encoding="utf-8"), encoding="utf-8")
            pending_worker_digest = "sha256:" + "e" * 64
            pending_worker_commit = "f" * 40
            update_image.update_manifest(
                pending,
                control_plane_digest="sha256:" + "1" * 64,
                worker_digest=pending_worker_digest,
                source_commit=pending_worker_commit,
            )

            preserved = update_image.validate_manifest(pending)
            deployment = update_image.update_manifest(
                current,
                control_plane_digest="sha256:" + "2" * 64,
                source_commit="3" * 40,
                worker_digest=preserved.worker_digest,
                worker_source_commit=preserved.worker_source_commit,
            )

            self.assertEqual(deployment.control_plane_source_commit, "3" * 40)
            self.assertEqual(deployment.control_plane_digest, "sha256:" + "2" * 64)
            self.assertEqual(deployment.worker_source_commit, pending_worker_commit)
            self.assertEqual(deployment.worker_digest, pending_worker_digest)

    def test_update_rejects_mutable_or_malformed_digest(self) -> None:
        for digest in ("latest", "sha256:1234", "sha256:" + "A" * 64):
            with self.subTest(digest=digest), self.assertRaisesRegex(
                ValueError,
                "control-plane digest must be sha256",
            ):
                update_image.update_manifest(
                    self.compose,
                    control_plane_digest=digest,
                    source_commit="a" * 40,
                )

    def test_validation_rejects_service_or_identity_drift(self) -> None:
        original = self.compose.read_text(encoding="utf-8")
        mutations = (
            original.replace(
                "    image: *map-platform-control-plane-image",
                "    image: image:latest",
                1,
            ),
            original.replace(
                "MAP_PLATFORM_WORKER_IMAGE_REFERENCE: *map-platform-worker-image",
                "MAP_PLATFORM_WORKER_IMAGE_REFERENCE: image:latest",
                1,
            ),
        )
        for mutated in mutations:
            with self.subTest(), self.assertRaises(ValueError):
                update_image.validate_manifest_text(mutated)

    def test_validation_rejects_swapped_api_and_worker_aliases(self) -> None:
        original = self.compose.read_text(encoding="utf-8")
        api_marker = "  map-platform-api:\n    image: *map-platform-control-plane-image"
        worker_marker = "  map-platform-worker:\n    image: *map-platform-worker-image"
        swapped = original.replace(
            api_marker,
            "  map-platform-api:\n    image: *map-platform-worker-image",
        ).replace(
            worker_marker,
            "  map-platform-worker:\n    image: *map-platform-control-plane-image",
        )

        with self.assertRaisesRegex(ValueError, "API service"):
            update_image.validate_manifest_text(swapped)

    def test_validation_requires_worker_identity_in_environment(self) -> None:
        original = self.compose.read_text(encoding="utf-8")
        identity = (
            "      MAP_PLATFORM_WORKER_IMAGE_REFERENCE: "
            "*map-platform-worker-image\n"
        )
        moved_to_labels = original.replace(identity, "", 1).replace(
            "    volumes:\n",
            "    labels:\n"
            "      MAP_PLATFORM_WORKER_IMAGE_REFERENCE: "
            "*map-platform-worker-image\n"
            "    volumes:\n",
            1,
        )

        with self.assertRaisesRegex(ValueError, "API service must receive"):
            update_image.validate_manifest_text(moved_to_labels)


if __name__ == "__main__":
    unittest.main()
