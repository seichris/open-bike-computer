"""The scheduling wrapper must not alter the qualified converter or signer."""
import hashlib
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


class PromotionRuntimeTests(unittest.TestCase):
    def test_only_scheduler_added(self):
        def inventory(root):
            return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                    for p in root.rglob("*") if p.is_file() and "__pycache__" not in p.parts}
        before = inventory(Path("/opt/promotion-base-app"))
        after = inventory(Path("/app"))
        differences = {key for key in before.keys() | after.keys() if before.get(key) != after.get(key)}
        self.assertEqual(differences, set())

    def test_real_converter_identity_verification_passes(self):
        from map_platform.cli import _pipeline_producer_identity
        build, image = _pipeline_producer_identity(
            Path("/app"),
            "ghcr.io/seichris/open-bike-computer-map-platform@sha256:142957ae0d5f08d366b657f9bacb0ce17d85bfac9c5d98c644bc1b02188a59c8",
            required=True,
        )
        self.assertEqual(len(build), 64)
        self.assertEqual(image, "sha256:142957ae0d5f08d366b657f9bacb0ce17d85bfac9c5d98c644bc1b02188a59c8")

    def test_real_cli_reaches_promotion_with_isolated_data_root(self):
        from map_platform.cli import main
        with tempfile.TemporaryDirectory() as root, patch.dict(os.environ, {
            "MAP_PLATFORM_CATALOG_URL": "https://maps-share.8o.vc",
            "MAP_PLATFORM_CATALOG_CHANNEL": "production",
            "MAP_PLATFORM_CATALOG_SERVICE_KEY_ID": "test-production",
            "MAP_PLATFORM_CATALOG_SERVICE_SECRET": "s" * 48,
            "MAP_PLATFORM_DEPLOYMENT_CHANNEL": "production",
            "MAP_PLATFORM_WORKER_IMAGE_REFERENCE": "ghcr.io/seichris/open-bike-computer-map-platform@sha256:142957ae0d5f08d366b657f9bacb0ce17d85bfac9c5d98c644bc1b02188a59c8",
        }), patch("map_platform.map_signing.load_map_artifact_signer_from_environment", return_value=object()), patch("map_platform.cli.create_artifact_store_from_environment", return_value=object()), patch("map_platform.catalog_promotion.promote_catalog_map", return_value={}) as promote:
            with patch("sys.argv", ["map-platform", "--repo-root", "/app", "--data-root", root, "promote-catalog-map", "map_v1_" + "a" * 43]):
                self.assertEqual(main(), 0)
            promote.assert_called_once()
            self.assertEqual(promote.call_args.kwargs["work_root"], Path(root) / "promotions")
