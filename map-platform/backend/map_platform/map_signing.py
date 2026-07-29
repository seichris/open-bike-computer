from __future__ import annotations

import base64
import binascii
import hashlib
import os
import re
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils

from .map_stream import (
    MAX_KEY_ID_BYTES,
    P256_HALF_ORDER,
    P256_ORDER,
    MapStreamSignatureEnvelope,
    signed_manifest_payload,
)


class MapArtifactSigningError(RuntimeError):
    code = "map_stream_signing_failed"


class P256MapArtifactSigner:
    def __init__(self, key_id: str, private_key: ec.EllipticCurvePrivateKey):
        if (
            not key_id
            or len(key_id.encode("ascii", errors="ignore")) != len(key_id)
            or len(key_id) > MAX_KEY_ID_BYTES
            or not re.fullmatch(r"[A-Za-z0-9._-]+", key_id)
        ):
            raise ValueError("map signing key ID is invalid")
        if not isinstance(private_key, ec.EllipticCurvePrivateKey):
            raise ValueError("map signing private key is not an EC key")
        if not isinstance(private_key.curve, ec.SECP256R1):
            raise ValueError("map signing key must use P-256")
        self.key_id = key_id
        self._private_key = private_key

    @classmethod
    def from_pem(cls, key_id: str, pem: bytes) -> P256MapArtifactSigner:
        try:
            private_key = serialization.load_pem_private_key(pem, password=None)
        except (TypeError, ValueError) as exc:
            raise MapArtifactSigningError("map signing private key is invalid") from exc
        if not isinstance(private_key, ec.EllipticCurvePrivateKey):
            raise MapArtifactSigningError("map signing private key is not an EC key")
        try:
            return cls(key_id, private_key)
        except ValueError as exc:
            raise MapArtifactSigningError(str(exc)) from exc

    def sign(self, manifest: bytes) -> MapStreamSignatureEnvelope:
        try:
            der_signature = self._private_key.sign(
                signed_manifest_payload(manifest),
                ec.ECDSA(hashes.SHA256(), deterministic_signing=True),
            )
        except Exception as exc:
            raise MapArtifactSigningError("deterministic map manifest signing failed") from exc
        r, s = utils.decode_dss_signature(der_signature)
        if s > P256_HALF_ORDER:
            s = P256_ORDER - s
        raw_signature = r.to_bytes(32, "big") + s.to_bytes(32, "big")
        return MapStreamSignatureEnvelope(self.key_id, raw_signature).validated()

    def public_key_x963(self) -> bytes:
        numbers = self._private_key.public_key().public_numbers()
        return b"\x04" + numbers.x.to_bytes(32, "big") + numbers.y.to_bytes(32, "big")

    @property
    def public_key_sha256(self) -> str:
        return hashlib.sha256(self.public_key_x963()).hexdigest()


def map_stream_generation_enabled() -> bool:
    value = os.environ.get("MAP_PLATFORM_MAP_STREAM_ENABLED", "0").strip().lower()
    if value in {"1", "true", "yes"}:
        return True
    if value in {"0", "false", "no"}:
        return False
    raise ValueError("MAP_PLATFORM_MAP_STREAM_ENABLED must be a boolean")


def load_map_artifact_signer_from_environment() -> P256MapArtifactSigner | None:
    if not map_stream_generation_enabled():
        return None
    key_id = os.environ.get("MAP_PLATFORM_MAP_SIGNING_KEY_ID", "")
    sources = [
        bool(os.environ.get("MAP_PLATFORM_MAP_SIGNING_PRIVATE_KEY_PEM")),
        bool(os.environ.get("MAP_PLATFORM_MAP_SIGNING_PRIVATE_KEY_BASE64")),
        bool(os.environ.get("MAP_PLATFORM_MAP_SIGNING_PRIVATE_KEY_FILE")),
    ]
    if sum(sources) != 1:
        raise MapArtifactSigningError(
            "exactly one map signing private-key source is required when stream generation is enabled"
        )
    if sources[0]:
        pem = os.environ["MAP_PLATFORM_MAP_SIGNING_PRIVATE_KEY_PEM"].encode("utf-8")
    elif sources[1]:
        try:
            pem = base64.b64decode(
                os.environ["MAP_PLATFORM_MAP_SIGNING_PRIVATE_KEY_BASE64"],
                validate=True,
            )
        except (binascii.Error, ValueError) as exc:
            raise MapArtifactSigningError("base64 map signing private key is invalid") from exc
    else:
        try:
            pem = Path(os.environ["MAP_PLATFORM_MAP_SIGNING_PRIVATE_KEY_FILE"]).read_bytes()
        except OSError as exc:
            raise MapArtifactSigningError("map signing private-key file is unavailable") from exc
    return P256MapArtifactSigner.from_pem(key_id, pem)
