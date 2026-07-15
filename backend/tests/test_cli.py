from __future__ import annotations

import unittest
from pathlib import Path
from unittest.mock import patch

from map_platform.cli import _pipeline_producer_identity
from map_platform.map_stream_build_identity import MapStreamBuildIdentity


class PipelineProducerIdentityTests(unittest.TestCase):
    @patch("map_platform.cli.verify_map_stream_build_identity")
    @patch("map_platform.cli.image_digest_from_reference")
    def test_loads_identity_when_map_stream_signing_is_disabled(
        self,
        image_digest_from_reference,
        verify_map_stream_build_identity,
    ):
        image_digest_from_reference.return_value = "sha256:" + "2" * 64
        verify_map_stream_build_identity.return_value = MapStreamBuildIdentity(
            producer_build_sha256="1" * 64
        )

        result = _pipeline_producer_identity(
            Path("/app"),
            "registry.example/map@sha256:" + "2" * 64,
            required=False,
        )

        self.assertEqual(result, ("1" * 64, "sha256:" + "2" * 64))
        verify_map_stream_build_identity.assert_called_once_with(
            Path("/app/config/map-stream-build-identity.json"),
            Path("/app"),
        )

    @patch("map_platform.cli.image_digest_from_reference")
    def test_optional_identity_fails_closed_without_blocking_builds(
        self,
        image_digest_from_reference,
    ):
        image_digest_from_reference.side_effect = ValueError("not pinned")

        self.assertEqual(
            _pipeline_producer_identity(
                Path("/app"),
                "open-bike-map-platform:local",
                required=False,
            ),
            (None, None),
        )

    @patch("map_platform.cli.image_digest_from_reference")
    def test_signed_streams_still_require_a_valid_identity(
        self,
        image_digest_from_reference,
    ):
        image_digest_from_reference.side_effect = ValueError("not pinned")

        with self.assertRaisesRegex(ValueError, "not pinned"):
            _pipeline_producer_identity(
                Path("/app"),
                "open-bike-map-platform:local",
                required=True,
            )


if __name__ == "__main__":
    unittest.main()
