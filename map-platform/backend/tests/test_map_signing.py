from __future__ import annotations

import base64
import os
import unittest
from unittest.mock import patch

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils

from map_platform.map_signing import (
    MapArtifactSigningError,
    P256MapArtifactSigner,
    load_map_artifact_signer_from_environment,
)
from map_platform.map_stream import P256_HALF_ORDER, SIGNATURE_DOMAIN


def private_key_pem(private_key) -> bytes:
    return private_key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )


class MapSigningTests(unittest.TestCase):
    def test_signer_is_deterministic_low_s_and_verifiable(self):
        private_key = ec.derive_private_key(2, ec.SECP256R1())
        signer = P256MapArtifactSigner.from_pem("map-test-2", private_key_pem(private_key))
        manifest = b'{"files":[]}'

        first = signer.sign(manifest)
        second = signer.sign(manifest)
        self.assertEqual(first, second)
        self.assertLessEqual(int.from_bytes(first.raw_signature[32:], "big"), P256_HALF_ORDER)
        r = int.from_bytes(first.raw_signature[:32], "big")
        s = int.from_bytes(first.raw_signature[32:], "big")
        der = utils.encode_dss_signature(r, s)
        private_key.public_key().verify(
            der,
            SIGNATURE_DOMAIN + manifest,
            ec.ECDSA(hashes.SHA256()),
        )

    def test_signer_rejects_wrong_curve_and_invalid_key_id(self):
        with self.assertRaises(MapArtifactSigningError):
            P256MapArtifactSigner.from_pem(
                "map-test",
                private_key_pem(ec.generate_private_key(ec.SECP384R1())),
            )
        with self.assertRaises(MapArtifactSigningError):
            P256MapArtifactSigner.from_pem(
                "bad/key",
                private_key_pem(ec.generate_private_key(ec.SECP256R1())),
            )

    def test_environment_requires_explicit_key_when_enabled(self):
        with patch.dict(os.environ, {"MAP_PLATFORM_MAP_STREAM_ENABLED": "1"}, clear=True):
            with self.assertRaises(MapArtifactSigningError):
                load_map_artifact_signer_from_environment()

        pem = private_key_pem(ec.derive_private_key(3, ec.SECP256R1()))
        environment = {
            "MAP_PLATFORM_MAP_STREAM_ENABLED": "true",
            "MAP_PLATFORM_MAP_SIGNING_KEY_ID": "map-prod-2026-01",
            "MAP_PLATFORM_MAP_SIGNING_PRIVATE_KEY_BASE64": base64.b64encode(pem).decode("ascii"),
        }
        with patch.dict(os.environ, environment, clear=True):
            signer = load_map_artifact_signer_from_environment()
        self.assertEqual(signer.key_id, "map-prod-2026-01")

    def test_environment_never_creates_unsigned_enabled_signer(self):
        with patch.dict(os.environ, {"MAP_PLATFORM_MAP_STREAM_ENABLED": "0"}, clear=True):
            self.assertIsNone(load_map_artifact_signer_from_environment())


if __name__ == "__main__":
    unittest.main()
