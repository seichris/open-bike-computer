from __future__ import annotations

import base64
import hashlib
import json
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils
from cryptography.x509.oid import NameOID

from app_attest_support import (
    TEST_APP_BUILD,
    TEST_APP_ID,
    AppAttestTestClient,
    TestAttestationVerifier,
    encode_cbor,
)
from map_platform.app_attest import (
    APP_ATTEST_ATTESTATION_PURPOSE,
    APP_ATTEST_MAP_CREATE_PURPOSE,
    APP_ATTEST_PRODUCTION_AAGUID,
    APPLE_APP_ATTEST_NONCE_OID,
    AppAttestError,
    AppAttestStore,
    AppleAppAttestVerifier,
    BoundedCBORDecoder,
    base64url_encode,
    canonical_map_create_client_data,
    decode_base64,
)


def certificate_name(common_name: str) -> x509.Name:
    return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, common_name)])


def key_usage(*, ca: bool) -> x509.KeyUsage:
    return x509.KeyUsage(
        digital_signature=not ca,
        content_commitment=False,
        key_encipherment=False,
        data_encipherment=False,
        key_agreement=False,
        key_cert_sign=ca,
        crl_sign=ca,
        encipher_only=False,
        decipher_only=False,
    )


def issue_certificate(
    *,
    subject: x509.Name,
    issuer: x509.Name,
    public_key,
    issuer_key,
    ca: bool,
    nonce: bytes | None = None,
) -> x509.Certificate:
    now = datetime.now(timezone.utc)
    builder = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(public_key)
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(minutes=5))
        .not_valid_after(now + timedelta(days=2 if not ca else 365))
        .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True)
        .add_extension(key_usage(ca=ca), critical=True)
    )
    if nonce is not None:
        builder = builder.add_extension(
            x509.UnrecognizedExtension(
                APPLE_APP_ATTEST_NONCE_OID,
                b"\x30\x24\xa1\x22\x04\x20" + nonce,
            ),
            critical=False,
        )
    return builder.sign(issuer_key, hashes.SHA256())


def apple_attestation_fixture(
    *,
    challenge: bytes,
    app_build: str = TEST_APP_BUILD,
) -> tuple[bytes, str, x509.Certificate]:
    attested_key = ec.generate_private_key(ec.SECP256R1())
    public_key_x963 = attested_key.public_key().public_bytes(
        serialization.Encoding.X962,
        serialization.PublicFormat.UncompressedPoint,
    )
    key_id_bytes = hashlib.sha256(public_key_x963).digest()
    key_id = base64.b64encode(key_id_bytes).decode("ascii")
    cose_key = encode_cbor(
        {
            1: 2,
            3: -7,
            -1: 1,
            -2: public_key_x963[1:33],
            -3: public_key_x963[33:65],
        }
    )
    extensions = encode_cbor(
        {
            "apple_bundle_version_01": app_build,
            "apple_validation_category_01": (4).to_bytes(4, "little"),
        }
    )
    auth_data = (
        hashlib.sha256(TEST_APP_ID.encode("utf-8")).digest()
        + b"\xc0"
        + (0).to_bytes(4, "big")
        + APP_ATTEST_PRODUCTION_AAGUID
        + len(key_id_bytes).to_bytes(2, "big")
        + key_id_bytes
        + cose_key
        + extensions
    )
    nonce = hashlib.sha256(auth_data + hashlib.sha256(challenge).digest()).digest()

    root_key = ec.generate_private_key(ec.SECP384R1())
    root_name = certificate_name("Fixture App Attest Root")
    root = issue_certificate(
        subject=root_name,
        issuer=root_name,
        public_key=root_key.public_key(),
        issuer_key=root_key,
        ca=True,
    )
    intermediate_key = ec.generate_private_key(ec.SECP384R1())
    intermediate_name = certificate_name("Fixture App Attest CA")
    intermediate = issue_certificate(
        subject=intermediate_name,
        issuer=root_name,
        public_key=intermediate_key.public_key(),
        issuer_key=root_key,
        ca=True,
    )
    leaf = issue_certificate(
        subject=certificate_name("Fixture App Attest Key"),
        issuer=intermediate_name,
        public_key=attested_key.public_key(),
        issuer_key=intermediate_key,
        ca=False,
        nonce=nonce,
    )
    attestation = encode_cbor(
        {
            "fmt": "apple-appattest",
            "attStmt": {
                "x5c": [
                    leaf.public_bytes(serialization.Encoding.DER),
                    intermediate.public_bytes(serialization.Encoding.DER),
                ],
                "receipt": b"fixture-receipt",
            },
            "authData": auth_data,
        }
    )
    return attestation, key_id, root


class AppleAppAttestVerifierTests(unittest.TestCase):
    def test_validates_chain_nonce_identity_key_environment_and_extensions(self):
        challenge = b"c" * 32
        attestation, key_id, root = apple_attestation_fixture(challenge=challenge)
        verifier = AppleAppAttestVerifier(
            allowed_app_ids={TEST_APP_ID},
            environment="production",
            root_certificate=root,
            allowed_validation_categories={4},
        )

        verified = verifier.verify_attestation(
            attestation_object=attestation,
            key_id=key_id,
            challenge=challenge,
            app_build=TEST_APP_BUILD,
        )

        self.assertEqual(verified.app_id, TEST_APP_ID)
        self.assertEqual(verified.environment, "production")
        self.assertEqual(verified.validation_category, 4)
        self.assertEqual(verified.bundle_version, TEST_APP_BUILD)
        self.assertEqual(
            hashlib.sha256(verified.public_key_x963).digest(),
            base64.b64decode(key_id),
        )

    def test_rejects_wrong_challenge_and_bundle_version(self):
        challenge = b"c" * 32
        attestation, key_id, root = apple_attestation_fixture(challenge=challenge)
        verifier = AppleAppAttestVerifier(
            allowed_app_ids={TEST_APP_ID},
            environment="production",
            root_certificate=root,
            allowed_validation_categories={4},
        )
        with self.assertRaisesRegex(AppAttestError, "challenge"):
            verifier.verify_attestation(
                attestation_object=attestation,
                key_id=key_id,
                challenge=b"d" * 32,
                app_build=TEST_APP_BUILD,
            )
        with self.assertRaisesRegex(AppAttestError, "bundle version"):
            verifier.verify_attestation(
                attestation_object=attestation,
                key_id=key_id,
                challenge=challenge,
                app_build="101",
            )

    def test_strict_cbor_rejects_duplicate_indefinite_and_trailing_values(self):
        for value in (
            bytes.fromhex("a2616101616102"),
            bytes.fromhex("9f01ff"),
            bytes.fromhex("0102"),
        ):
            with self.subTest(value=value.hex()), self.assertRaises(AppAttestError):
                BoundedCBORDecoder(value).decode()

    def test_map_create_client_data_matches_cross_platform_golden_vector(self):
        fixture = json.loads(
            (
                Path(__file__).parent
                / "fixtures"
                / "app_attest_map_create_v1.json"
            ).read_text()
        )
        request_body = fixture["requestBody"].encode("utf-8")
        client_data = canonical_map_create_client_data(
            challenge_id=fixture["challengeId"],
            challenge=decode_base64(
                fixture["challenge"],
                field="challenge",
                maximum_bytes=32,
                exact_bytes=32,
            ),
            installation_id=fixture["clientInstallationId"],
            request_body=request_body,
            payload=json.loads(request_body),
            app_build=fixture["appBuild"],
        )

        self.assertEqual(client_data.decode("utf-8"), fixture["expectedClientData"])
        self.assertEqual(
            hashlib.sha256(client_data).hexdigest(),
            fixture["expectedClientDataSha256"],
        )


class AppAttestStoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.now = 1_800_000_000
        self.store = AppAttestStore(
            Path(self.tmp.name) / "app-attest.sqlite3",
            TestAttestationVerifier(),
            clock=lambda: self.now,
        )
        self.helper = AppAttestTestClient()

    def tearDown(self):
        self.tmp.cleanup()

    def enroll(self, installation_id: str):
        challenge = self.store.issue_challenge(
            purpose=APP_ATTEST_ATTESTATION_PURPOSE
        )
        private_key = ec.generate_private_key(ec.SECP256R1())
        public_key = private_key.public_key().public_bytes(
            serialization.Encoding.X962,
            serialization.PublicFormat.UncompressedPoint,
        )
        key_id = base64.b64encode(hashlib.sha256(public_key).digest()).decode("ascii")
        attestation = encode_cbor(
            {
                "publicKey": public_key,
                "challengeHash": hashlib.sha256(challenge.challenge).digest(),
                "appBuild": TEST_APP_BUILD,
            }
        )
        self.store.enroll(
            installation_id=installation_id,
            challenge_id=challenge.challenge_id,
            key_id=key_id,
            attestation_object=attestation,
            app_build=TEST_APP_BUILD,
        )
        return private_key, key_id

    def assertion(
        self,
        *,
        private_key,
        challenge,
        installation_id,
        payload,
        body,
        counter,
        app_build=TEST_APP_BUILD,
        extensions=None,
    ) -> bytes:
        client_data = canonical_map_create_client_data(
            challenge_id=challenge.challenge_id,
            challenge=challenge.challenge,
            installation_id=installation_id,
            request_body=body,
            payload=payload,
            app_build=app_build,
        )
        auth_data = (
            hashlib.sha256(TEST_APP_ID.encode()).digest()
            + (b"\x80" if extensions is not None else b"\x00")
            + counter.to_bytes(4, "big")
        )
        if extensions is not None:
            auth_data += encode_cbor(extensions)
        nonce = hashlib.sha256(
            auth_data + hashlib.sha256(client_data).digest()
        ).digest()
        signature = private_key.sign(
            nonce,
            ec.ECDSA(utils.Prehashed(hashes.SHA256())),
        )
        return encode_cbor(
            {"signature": signature, "authenticatorData": auth_data}
        )

    def test_assertion_allows_signed_app_upgrade_and_rejects_wrong_category(self):
        installation_id = "inst_v2_" + "e" * 32
        private_key, key_id = self.enroll(installation_id)
        payload = {
            "mode": "custom_bbox",
            "bbox": [103.75, 1.24, 103.93, 1.37],
            "clientInstallationId": installation_id,
            "clientRequestId": "request-app-upgrade-1",
        }
        body = json.dumps(payload, separators=(",", ":")).encode()
        challenge = self.store.issue_challenge(
            purpose=APP_ATTEST_MAP_CREATE_PURPOSE,
            installation_id=installation_id,
        )
        assertion = self.assertion(
            private_key=private_key,
            challenge=challenge,
            installation_id=installation_id,
            payload=payload,
            body=body,
            counter=1,
            app_build="101",
            extensions={
                "validationCategory": (4).to_bytes(4, "little"),
                "bundleVersion": "101",
            },
        )
        self.assertEqual(
            self.store.verify_map_create_assertion(
                installation_id=installation_id,
                challenge_id=challenge.challenge_id,
                key_id=key_id,
                assertion_object=assertion,
                request_body=body,
                payload=payload,
                app_build="101",
            ),
            1,
        )

        next_challenge = self.store.issue_challenge(
            purpose=APP_ATTEST_MAP_CREATE_PURPOSE,
            installation_id=installation_id,
        )
        invalid = self.assertion(
            private_key=private_key,
            challenge=next_challenge,
            installation_id=installation_id,
            payload=payload,
            body=body,
            counter=2,
            app_build="101",
            extensions={
                "validationCategory": (3).to_bytes(4, "little"),
                "bundleVersion": "101",
            },
        )
        with self.assertRaisesRegex(AppAttestError, "identity"):
            self.store.verify_map_create_assertion(
                installation_id=installation_id,
                challenge_id=next_challenge.challenge_id,
                key_id=key_id,
                assertion_object=invalid,
                request_body=body,
                payload=payload,
                app_build="101",
            )

    def test_assertion_is_bound_to_body_challenge_and_monotonic_counter(self):
        installation_id = "inst_v2_" + "a" * 32
        private_key, key_id = self.enroll(installation_id)
        payload = {
            "mode": "custom_bbox",
            "bbox": [103.75, 1.24, 103.93, 1.37],
            "clientInstallationId": installation_id,
            "clientRequestId": "request-attested-1",
        }
        body = __import__("json").dumps(payload, separators=(",", ":")).encode()
        challenge = self.store.issue_challenge(
            purpose=APP_ATTEST_MAP_CREATE_PURPOSE,
            installation_id=installation_id,
        )
        assertion = self.assertion(
            private_key=private_key,
            challenge=challenge,
            installation_id=installation_id,
            payload=payload,
            body=body,
            counter=1,
        )

        counter = self.store.verify_map_create_assertion(
            installation_id=installation_id,
            challenge_id=challenge.challenge_id,
            key_id=key_id,
            assertion_object=assertion,
            request_body=body,
            payload=payload,
            app_build=TEST_APP_BUILD,
        )

        self.assertEqual(counter, 1)
        with self.assertRaisesRegex(AppAttestError, "challenge"):
            self.store.verify_map_create_assertion(
                installation_id=installation_id,
                challenge_id=challenge.challenge_id,
                key_id=key_id,
                assertion_object=assertion,
                request_body=body,
                payload=payload,
                app_build=TEST_APP_BUILD,
            )

        second_challenge = self.store.issue_challenge(
            purpose=APP_ATTEST_MAP_CREATE_PURPOSE,
            installation_id=installation_id,
        )
        replay_counter = self.assertion(
            private_key=private_key,
            challenge=second_challenge,
            installation_id=installation_id,
            payload=payload,
            body=body,
            counter=1,
        )
        with self.assertRaisesRegex(AppAttestError, "replayed"):
            self.store.verify_map_create_assertion(
                installation_id=installation_id,
                challenge_id=second_challenge.challenge_id,
                key_id=key_id,
                assertion_object=replay_counter,
                request_body=body,
                payload=payload,
                app_build=TEST_APP_BUILD,
            )

        third_challenge = self.store.issue_challenge(
            purpose=APP_ATTEST_MAP_CREATE_PURPOSE,
            installation_id=installation_id,
        )
        bound_assertion = self.assertion(
            private_key=private_key,
            challenge=third_challenge,
            installation_id=installation_id,
            payload=payload,
            body=body,
            counter=2,
        )
        with self.assertRaisesRegex(AppAttestError, "signature"):
            self.store.verify_map_create_assertion(
                installation_id=installation_id,
                challenge_id=third_challenge.challenge_id,
                key_id=key_id,
                assertion_object=bound_assertion,
                request_body=body + b" ",
                payload=payload,
                app_build=TEST_APP_BUILD,
            )

    def test_challenges_expire_and_attested_key_cannot_be_rebound(self):
        challenge = self.store.issue_challenge(
            purpose=APP_ATTEST_ATTESTATION_PURPOSE
        )
        self.now = challenge.expires_at + 1
        with self.assertRaisesRegex(AppAttestError, "expired"):
            self.store.enroll(
                installation_id="inst_v2_" + "b" * 32,
                challenge_id=challenge.challenge_id,
                key_id=base64.b64encode(b"k" * 32).decode(),
                attestation_object=b"invalid",
                app_build=TEST_APP_BUILD,
            )

        self.now += 1
        private_key, key_id = self.enroll("inst_v2_" + "c" * 32)
        public_key = private_key.public_key().public_bytes(
            serialization.Encoding.X962,
            serialization.PublicFormat.UncompressedPoint,
        )
        next_challenge = self.store.issue_challenge(
            purpose=APP_ATTEST_ATTESTATION_PURPOSE
        )
        with self.assertRaisesRegex(AppAttestError, "already associated"):
            self.store.enroll(
                installation_id="inst_v2_" + "d" * 32,
                challenge_id=next_challenge.challenge_id,
                key_id=key_id,
                attestation_object=encode_cbor(
                    {
                        "publicKey": public_key,
                        "challengeHash": hashlib.sha256(
                            next_challenge.challenge
                        ).digest(),
                        "appBuild": TEST_APP_BUILD,
                    }
                ),
                app_build=TEST_APP_BUILD,
            )


if __name__ == "__main__":
    unittest.main()
