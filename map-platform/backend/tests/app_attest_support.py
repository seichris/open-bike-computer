from __future__ import annotations

import base64
import hashlib
import json
import threading
from dataclasses import dataclass
from typing import Any

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

from map_platform.app_attest import (
    APP_ATTEST_ATTESTATION_PURPOSE,
    APP_ATTEST_MAP_CREATE_PURPOSE,
    BoundedCBORDecoder,
    VerifiedAttestation,
    base64url_encode,
    canonical_map_create_client_data,
    decode_base64,
    decode_key_id,
)


TEST_APP_ID = "4H5PK8686H.LetItRide.BikeComputer"
TEST_APP_BUILD = "100"


def encode_cbor(value: Any) -> bytes:
    if isinstance(value, bool):
        return b"\xf5" if value else b"\xf4"
    if value is None:
        return b"\xf6"
    if isinstance(value, int):
        if value >= 0:
            return _cbor_header(0, value)
        return _cbor_header(1, -1 - value)
    if isinstance(value, bytes):
        return _cbor_header(2, len(value)) + value
    if isinstance(value, str):
        encoded = value.encode("utf-8")
        return _cbor_header(3, len(encoded)) + encoded
    if isinstance(value, (list, tuple)):
        return _cbor_header(4, len(value)) + b"".join(
            encode_cbor(item) for item in value
        )
    if isinstance(value, dict):
        return _cbor_header(5, len(value)) + b"".join(
            encode_cbor(key) + encode_cbor(item) for key, item in value.items()
        )
    raise TypeError(f"unsupported CBOR fixture value: {type(value)!r}")


def _cbor_header(major: int, value: int) -> bytes:
    if value < 24:
        return bytes([(major << 5) | value])
    if value <= 0xFF:
        return bytes([(major << 5) | 24, value])
    if value <= 0xFFFF:
        return bytes([(major << 5) | 25]) + value.to_bytes(2, "big")
    if value <= 0xFFFFFFFF:
        return bytes([(major << 5) | 26]) + value.to_bytes(4, "big")
    return bytes([(major << 5) | 27]) + value.to_bytes(8, "big")


class TestAttestationVerifier:
    """Dependency-injected verifier; no runtime configuration selects it."""

    __test__ = False

    def verify_attestation(
        self,
        *,
        attestation_object: bytes,
        key_id: str,
        challenge: bytes,
        app_build: str,
    ) -> VerifiedAttestation:
        document = BoundedCBORDecoder(attestation_object).decode()
        if not isinstance(document, dict) or set(document) != {
            "publicKey",
            "challengeHash",
            "appBuild",
        }:
            raise ValueError("invalid test attestation")
        public_key = document["publicKey"]
        if (
            not isinstance(public_key, bytes)
            or len(public_key) != 65
            or document["challengeHash"] != hashlib.sha256(challenge).digest()
            or document["appBuild"] != app_build
            or decode_key_id(key_id) != hashlib.sha256(public_key).digest()
        ):
            raise ValueError("invalid test attestation")
        return VerifiedAttestation(
            public_key_x963=public_key,
            receipt=b"test-receipt",
            app_id=TEST_APP_ID,
            environment="production",
            validation_category=4,
            bundle_version=app_build,
        )


@dataclass
class TestInstallation:
    credential: dict[str, str]
    private_key: ec.EllipticCurvePrivateKey
    key_id: str
    counter: int = 0


class AppAttestTestClient:
    __test__ = False

    def __init__(self):
        self.verifier = TestAttestationVerifier()
        self._installations: dict[str, TestInstallation] = {}
        self._lock = threading.Lock()

    def issue_installation(self, client) -> dict[str, str]:
        challenge_response = client.post(
            "/v1/installations/app-attest/challenges",
            json={"purpose": APP_ATTEST_ATTESTATION_PURPOSE},
        )
        if challenge_response.status_code != 200:
            return challenge_response
        challenge_document = challenge_response.json()
        challenge = decode_base64(
            challenge_document["challenge"],
            field="challenge",
            maximum_bytes=32,
            exact_bytes=32,
        )
        private_key = ec.generate_private_key(ec.SECP256R1())
        public_key = private_key.public_key().public_bytes(
            serialization.Encoding.X962,
            serialization.PublicFormat.UncompressedPoint,
        )
        key_id = base64.b64encode(hashlib.sha256(public_key).digest()).decode("ascii")
        attestation_object = encode_cbor(
            {
                "publicKey": public_key,
                "challengeHash": hashlib.sha256(challenge).digest(),
                "appBuild": TEST_APP_BUILD,
            }
        )
        response = client.post(
            "/v1/installations",
            json={
                "appAttest": {
                    "challengeId": challenge_document["challengeId"],
                    "keyId": key_id,
                    "attestationObject": base64.b64encode(
                        attestation_object
                    ).decode("ascii"),
                    "appBuild": TEST_APP_BUILD,
                }
            },
        )
        if response.status_code != 200:
            return response
        credential = response.json()
        installation = TestInstallation(
            credential=credential,
            private_key=private_key,
            key_id=key_id,
        )
        with self._lock:
            self._installations[credential["clientInstallationId"]] = installation
        return credential

    def installation(self, credential: dict[str, str]) -> TestInstallation:
        with self._lock:
            return self._installations[credential["clientInstallationId"]]

    def post_map_job(
        self,
        client,
        *,
        credential: dict[str, str],
        payload: dict[str, Any],
        headers: dict[str, str] | None = None,
        challenge_document: dict[str, Any] | None = None,
        request_body: bytes | None = None,
    ):
        installation = self.installation(credential)
        if challenge_document is None:
            challenge_response = client.post(
                "/v1/installations/app-attest/challenges",
                headers={
                    "X-Installation-Token": credential[
                        "clientInstallationToken"
                    ]
                },
                json={
                    "purpose": APP_ATTEST_MAP_CREATE_PURPOSE,
                    "clientInstallationId": credential[
                        "clientInstallationId"
                    ],
                },
            )
            if challenge_response.status_code != 200:
                return challenge_response
            challenge_document = challenge_response.json()
        challenge = decode_base64(
            challenge_document["challenge"],
            field="challenge",
            maximum_bytes=32,
            exact_bytes=32,
        )
        body = request_body or json.dumps(
            payload,
            ensure_ascii=False,
            allow_nan=False,
            separators=(",", ":"),
        ).encode("utf-8")
        client_data = canonical_map_create_client_data(
            challenge_id=challenge_document["challengeId"],
            challenge=challenge,
            installation_id=credential["clientInstallationId"],
            request_body=body,
            payload=payload,
            app_build=TEST_APP_BUILD,
        )
        with self._lock:
            installation.counter += 1
            counter = installation.counter
        authenticator_data = (
            hashlib.sha256(TEST_APP_ID.encode("utf-8")).digest()
            + b"\x00"
            + counter.to_bytes(4, "big")
        )
        nonce = hashlib.sha256(
            authenticator_data + hashlib.sha256(client_data).digest()
        ).digest()
        signature = installation.private_key.sign(
            nonce,
            ec.ECDSA(hashes.SHA256()),
        )
        assertion = encode_cbor(
            {
                "signature": signature,
                "authenticatorData": authenticator_data,
            }
        )
        request_headers = {
            "Content-Type": "application/json",
            "X-Installation-Token": credential["clientInstallationToken"],
            "X-App-Attest-Challenge-Id": challenge_document["challengeId"],
            "X-App-Attest-Key-Id": installation.key_id,
            "X-App-Attest-Assertion": base64.b64encode(assertion).decode("ascii"),
            "X-App-Attest-App-Build": TEST_APP_BUILD,
            **(headers or {}),
        }
        return client.post(
            "/v1/map-jobs",
            headers=request_headers,
            content=body,
        )
