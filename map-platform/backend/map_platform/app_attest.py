from __future__ import annotations

import base64
import binascii
import hashlib
import json
import os
import re
import secrets
import sqlite3
import struct
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Protocol

from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils
from cryptography.x509.oid import ExtensionOID, ObjectIdentifier


APPLE_APP_ATTEST_NONCE_OID = ObjectIdentifier("1.2.840.113635.100.8.2")
APPLE_APP_ATTEST_FORMAT = "apple-appattest"
APPLE_APP_ATTEST_ROOT_PATH = (
    Path(__file__).resolve().parent / "data" / "Apple_App_Attestation_Root_CA.pem"
)
APP_ATTEST_CHALLENGE_BYTES = 32
APP_ATTEST_CHALLENGE_TTL_SECONDS = 300
APP_ATTEST_MAX_OBJECT_BYTES = 128 * 1024
APP_ATTEST_MAX_ASSERTION_BYTES = 16 * 1024
APP_ATTEST_MAX_RECEIPT_BYTES = 96 * 1024
APP_ATTEST_PRODUCTION_AAGUID = b"appattest" + (b"\0" * 7)
APP_ATTEST_DEVELOPMENT_AAGUID = b"appattestdevelop"
APP_ATTEST_ATTESTATION_PURPOSE = "attestation"
APP_ATTEST_MAP_CREATE_PURPOSE = "map-create"
APP_ATTEST_CLIENT_DATA_SCHEMA_VERSION = 1


class AppAttestError(RuntimeError):
    def __init__(self, code: str, message: str, *, status_code: int = 401):
        self.code = code
        self.safe_message = message
        self.status_code = status_code
        super().__init__(message)


@dataclass(frozen=True)
class VerifiedAttestation:
    public_key_x963: bytes
    receipt: bytes
    app_id: str
    environment: str
    validation_category: int | None
    bundle_version: str | None


class AppAttestationVerifying(Protocol):
    def verify_attestation(
        self,
        *,
        attestation_object: bytes,
        key_id: str,
        challenge: bytes,
        app_build: str,
    ) -> VerifiedAttestation: ...


@dataclass(frozen=True)
class AppAttestChallenge:
    challenge_id: str
    challenge: bytes
    purpose: str
    expires_at: int
    key_id: str | None = None

    def public_dict(self) -> dict[str, Any]:
        result: dict[str, Any] = {
            "challengeId": self.challenge_id,
            "challenge": base64url_encode(self.challenge),
            "purpose": self.purpose,
            "expiresAt": self.expires_at,
        }
        if self.key_id is not None:
            result["keyId"] = self.key_id
        return result


def base64url_encode(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def decode_base64(
    value: str,
    *,
    field: str,
    maximum_bytes: int,
    exact_bytes: int | None = None,
) -> bytes:
    if not isinstance(value, str) or not value or len(value) > maximum_bytes * 2 + 8:
        raise AppAttestError("app_attest_invalid_encoding", f"{field} is invalid")
    try:
        encoded = value.encode("ascii")
    except UnicodeEncodeError as exc:
        raise AppAttestError(
            "app_attest_invalid_encoding", f"{field} is invalid"
        ) from exc
    padding = b"=" * ((4 - len(encoded) % 4) % 4)
    try:
        # Key IDs use standard Base64, while JSON challenges use URL-safe
        # Base64 without padding. Accept both alphabets but require a canonical
        # round trip in one of those two forms.
        decoded = base64.b64decode(
            encoded.translate(bytes.maketrans(b"-_", b"+/")) + padding,
            validate=True,
        )
    except (binascii.Error, ValueError) as exc:
        raise AppAttestError(
            "app_attest_invalid_encoding", f"{field} is invalid"
        ) from exc
    standard = base64.b64encode(decoded).decode("ascii")
    urlsafe = base64url_encode(decoded)
    if value not in {standard, standard.rstrip("="), urlsafe}:
        raise AppAttestError("app_attest_invalid_encoding", f"{field} is invalid")
    if len(decoded) > maximum_bytes or (
        exact_bytes is not None and len(decoded) != exact_bytes
    ):
        raise AppAttestError("app_attest_invalid_encoding", f"{field} is invalid")
    return decoded


def decode_key_id(key_id: str) -> bytes:
    return decode_base64(
        key_id,
        field="App Attest key identifier",
        maximum_bytes=32,
        exact_bytes=32,
    )


def canonical_map_create_client_data(
    *,
    challenge_id: str,
    challenge: bytes,
    installation_id: str,
    request_body: bytes,
    payload: dict[str, Any],
    app_build: str,
) -> bytes:
    if not re.fullmatch(r"[0-9a-f]{32}", challenge_id):
        raise AppAttestError(
            "app_attest_invalid_challenge", "App Attest challenge is invalid"
        )
    if len(challenge) != APP_ATTEST_CHALLENGE_BYTES:
        raise AppAttestError(
            "app_attest_invalid_challenge", "App Attest challenge is invalid"
        )
    if not re.fullmatch(r"inst_v2_[0-9a-f]{32}", installation_id):
        raise AppAttestError(
            "app_attest_invalid_principal", "installation credential is invalid"
        )
    if not isinstance(app_build, str) or not re.fullmatch(
        r"[A-Za-z0-9._-]{1,64}", app_build
    ):
        raise AppAttestError(
            "app_attest_invalid_build", "App Attest app build is invalid"
        )
    client_request_id = payload.get("clientRequestId")
    if not isinstance(client_request_id, str) or not re.fullmatch(
        r"[A-Za-z0-9._-]{8,128}", client_request_id
    ):
        raise AppAttestError(
            "app_attest_invalid_request", "map request identity is invalid"
        )
    target = payload.get("target")
    if target is None:
        target = {}
    if not isinstance(target, dict):
        raise AppAttestError(
            "app_attest_invalid_request", "map renderer identity is invalid"
        )
    renderer = target.get("renderer", "esp32-fmb")
    renderer_format_version = target.get("rendererFormatVersion", 1)
    if not isinstance(renderer, str) or not re.fullmatch(
        r"[A-Za-z0-9._-]{1,64}", renderer
    ):
        raise AppAttestError(
            "app_attest_invalid_request", "map renderer identity is invalid"
        )
    if isinstance(renderer_format_version, bool) or not isinstance(
        renderer_format_version, int
    ):
        raise AppAttestError(
            "app_attest_invalid_request", "map renderer identity is invalid"
        )
    labels = payload.get("labels")
    if labels is None:
        labels = {}
    if not isinstance(labels, dict):
        raise AppAttestError(
            "app_attest_invalid_request", "map label profile is invalid"
        )
    profile_version = labels.get("profileVersion", 0)
    if isinstance(profile_version, bool) or not isinstance(profile_version, int):
        raise AppAttestError(
            "app_attest_invalid_request", "map label profile is invalid"
        )
    document = {
        "appBuild": app_build,
        "bodySha256": hashlib.sha256(request_body).hexdigest(),
        "challenge": base64url_encode(challenge),
        "challengeId": challenge_id,
        "clientInstallationId": installation_id,
        "idempotencyKey": client_request_id,
        "labelProfileVersion": profile_version,
        "method": "POST",
        "path": "/v1/map-jobs",
        "renderer": renderer,
        "rendererFormatVersion": renderer_format_version,
        "schemaVersion": APP_ATTEST_CLIENT_DATA_SCHEMA_VERSION,
    }
    return json.dumps(
        document,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


class BoundedCBORDecoder:
    """Small strict decoder for the fixed WebAuthn/App Attest structures."""

    def __init__(
        self,
        data: bytes,
        *,
        maximum_bytes: int = APP_ATTEST_MAX_OBJECT_BYTES,
        maximum_depth: int = 10,
        maximum_items: int = 256,
    ):
        if not isinstance(data, bytes) or len(data) > maximum_bytes:
            raise AppAttestError(
                "app_attest_invalid_cbor", "App Attest object is invalid"
            )
        self.data = data
        self.offset = 0
        self.maximum_depth = maximum_depth
        self.remaining_items = maximum_items

    def decode(self) -> Any:
        value = self.decode_one()
        if self.offset != len(self.data):
            raise AppAttestError(
                "app_attest_invalid_cbor", "App Attest object has trailing data"
            )
        return value

    def decode_one(self, depth: int = 0) -> Any:
        if depth > self.maximum_depth or self.remaining_items <= 0:
            raise AppAttestError(
                "app_attest_invalid_cbor", "App Attest object exceeds its limits"
            )
        self.remaining_items -= 1
        initial = self._read_byte()
        major = initial >> 5
        additional = initial & 0x1F
        if major in {0, 1}:
            unsigned = self._length(additional)
            return unsigned if major == 0 else -1 - unsigned
        if major in {2, 3}:
            length = self._length(additional)
            raw = self._read(length)
            if major == 2:
                return raw
            try:
                return raw.decode("utf-8")
            except UnicodeDecodeError as exc:
                raise AppAttestError(
                    "app_attest_invalid_cbor", "App Attest text is invalid"
                ) from exc
        if major == 4:
            length = self._length(additional)
            self._consume_items(length)
            return [self.decode_one(depth + 1) for _ in range(length)]
        if major == 5:
            length = self._length(additional)
            self._consume_items(length * 2)
            result: dict[Any, Any] = {}
            for _ in range(length):
                key = self.decode_one(depth + 1)
                if not isinstance(key, (str, int, bytes)) or key in result:
                    raise AppAttestError(
                        "app_attest_invalid_cbor",
                        "App Attest map keys are invalid",
                    )
                result[key] = self.decode_one(depth + 1)
            return result
        if major == 7 and additional in {20, 21, 22}:
            return {20: False, 21: True, 22: None}[additional]
        raise AppAttestError(
            "app_attest_invalid_cbor", "App Attest CBOR type is unsupported"
        )

    def _consume_items(self, count: int) -> None:
        if count < 0 or count > self.remaining_items:
            raise AppAttestError(
                "app_attest_invalid_cbor", "App Attest object exceeds its limits"
            )

    def _length(self, additional: int) -> int:
        if additional < 24:
            return additional
        sizes = {24: 1, 25: 2, 26: 4, 27: 8}
        size = sizes.get(additional)
        if size is None:
            raise AppAttestError(
                "app_attest_invalid_cbor",
                "indefinite App Attest CBOR values are not allowed",
            )
        raw = self._read(size)
        value = int.from_bytes(raw, "big")
        minimum = {1: 24, 2: 256, 4: 65_536, 8: 4_294_967_296}[size]
        if value < minimum:
            raise AppAttestError(
                "app_attest_invalid_cbor", "App Attest CBOR is not canonical"
            )
        if value > len(self.data):
            raise AppAttestError(
                "app_attest_invalid_cbor", "App Attest CBOR length is invalid"
            )
        return value

    def _read_byte(self) -> int:
        return self._read(1)[0]

    def _read(self, count: int) -> bytes:
        end = self.offset + count
        if count < 0 or end < self.offset or end > len(self.data):
            raise AppAttestError(
                "app_attest_invalid_cbor", "App Attest CBOR is truncated"
            )
        value = self.data[self.offset:end]
        self.offset = end
        return value


@dataclass(frozen=True)
class ParsedAuthenticatorData:
    rp_id_hash: bytes
    flags: int
    counter: int
    credential_id: bytes | None
    public_key_x963: bytes | None
    extensions: dict[Any, Any] | None


def parse_authenticator_data(
    auth_data: bytes,
    *,
    attestation: bool,
) -> ParsedAuthenticatorData:
    if len(auth_data) < 37:
        raise AppAttestError(
            "app_attest_invalid_authenticator", "authenticator data is invalid"
        )
    rp_id_hash = auth_data[:32]
    flags = auth_data[32]
    counter = int.from_bytes(auth_data[33:37], "big")
    offset = 37
    credential_id: bytes | None = None
    public_key_x963: bytes | None = None
    extensions: dict[Any, Any] | None = None

    has_attested_data = bool(flags & 0x40)
    has_extensions = bool(flags & 0x80)
    if attestation != has_attested_data:
        raise AppAttestError(
            "app_attest_invalid_authenticator", "authenticator flags are invalid"
        )
    if attestation:
        if len(auth_data) < offset + 18:
            raise AppAttestError(
                "app_attest_invalid_authenticator", "attested credential is truncated"
            )
        aaguid = auth_data[offset : offset + 16]
        offset += 16
        credential_length = int.from_bytes(auth_data[offset : offset + 2], "big")
        offset += 2
        if credential_length != 32 or len(auth_data) < offset + credential_length:
            raise AppAttestError(
                "app_attest_invalid_authenticator", "credential identifier is invalid"
            )
        credential_id = auth_data[offset : offset + credential_length]
        offset += credential_length
        decoder = BoundedCBORDecoder(auth_data[offset:])
        cose_key = decoder.decode_one()
        if not isinstance(cose_key, dict) or set(cose_key) != {1, 3, -1, -2, -3}:
            raise AppAttestError(
                "app_attest_invalid_key", "App Attest public key is invalid"
            )
        if cose_key[1] != 2 or cose_key[3] != -7 or cose_key[-1] != 1:
            raise AppAttestError(
                "app_attest_invalid_key", "App Attest public key is invalid"
            )
        x_coordinate = cose_key[-2]
        y_coordinate = cose_key[-3]
        if not isinstance(x_coordinate, bytes) or len(x_coordinate) != 32:
            raise AppAttestError(
                "app_attest_invalid_key", "App Attest public key is invalid"
            )
        if not isinstance(y_coordinate, bytes) or len(y_coordinate) != 32:
            raise AppAttestError(
                "app_attest_invalid_key", "App Attest public key is invalid"
            )
        public_key_x963 = b"\x04" + x_coordinate + y_coordinate
        offset += decoder.offset
        if aaguid not in {
            APP_ATTEST_PRODUCTION_AAGUID,
            APP_ATTEST_DEVELOPMENT_AAGUID,
        }:
            raise AppAttestError(
                "app_attest_wrong_environment", "App Attest environment is invalid"
            )

    # Apple's App Attest attestation objects append launch-validation
    # extensions even though their authenticator flags do not set ED. Keep
    # that compatibility limited to attestation objects; assertions still
    # require ED before any trailing extension data is accepted.
    if has_extensions or (attestation and offset < len(auth_data)):
        decoder = BoundedCBORDecoder(auth_data[offset:])
        decoded_extensions = decoder.decode_one()
        if not isinstance(decoded_extensions, dict):
            raise AppAttestError(
                "app_attest_invalid_extensions", "App Attest extensions are invalid"
            )
        extensions = decoded_extensions
        offset += decoder.offset
    if offset != len(auth_data):
        raise AppAttestError(
            "app_attest_invalid_authenticator",
            "authenticator data has trailing bytes",
        )
    return ParsedAuthenticatorData(
        rp_id_hash=rp_id_hash,
        flags=flags,
        counter=counter,
        credential_id=credential_id,
        public_key_x963=public_key_x963,
        extensions=extensions,
    )


def _attestation_extension_values(
    extensions: dict[Any, Any] | None,
) -> tuple[int | None, str | None]:
    if extensions is None:
        return None, None
    allowed = {
        "apple_validation_category_01",
        "apple_bundle_version_01",
    }
    if not set(extensions).issubset(allowed):
        raise AppAttestError(
            "app_attest_invalid_extensions", "App Attest extensions are invalid"
        )
    validation_category_value = extensions.get("apple_validation_category_01")
    bundle_version = extensions.get("apple_bundle_version_01")
    if validation_category_value is None and bundle_version is None:
        return None, None
    validation_category = _validation_category(validation_category_value)
    if (
        validation_category is None
        or not isinstance(bundle_version, str)
        or not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", bundle_version)
    ):
        raise AppAttestError(
            "app_attest_invalid_extensions", "App Attest extensions are invalid"
        )
    return validation_category, bundle_version


def _assertion_extension_values(
    extensions: dict[Any, Any] | None,
) -> tuple[int | None, str | None]:
    if extensions is None:
        return None, None
    allowed = {"validationCategory", "bundleVersion"}
    if not set(extensions).issubset(allowed):
        raise AppAttestError(
            "app_attest_invalid_extensions", "App Attest extensions are invalid"
        )
    validation_category_value = extensions.get("validationCategory")
    bundle_version = extensions.get("bundleVersion")
    if validation_category_value is None and bundle_version is None:
        return None, None
    validation_category = _validation_category(validation_category_value)
    if (
        validation_category is None
        or not isinstance(bundle_version, str)
        or not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", bundle_version)
    ):
        raise AppAttestError(
            "app_attest_invalid_extensions", "App Attest extensions are invalid"
        )
    return validation_category, bundle_version


def _validation_category(value: Any) -> int | None:
    # Apple encodes the UInt32 extension value as four little-endian bytes.
    # Accept an integer as well so the parser remains compatible with a future
    # direct-CBOR representation of the documented UInt32 value.
    if isinstance(value, bytes) and len(value) == 4:
        return int.from_bytes(value, "little")
    if isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= 0xFFFFFFFF:
        return value
    return None


class AppleAppAttestVerifier:
    def __init__(
        self,
        *,
        allowed_app_ids: set[str],
        environment: str,
        root_certificate: x509.Certificate | None = None,
        allowed_validation_categories: set[int] | None = None,
        clock=time.time,
    ):
        if not allowed_app_ids or any(
            not re.fullmatch(r"[A-Z0-9]{10}\.[A-Za-z0-9.-]{1,200}", app_id)
            for app_id in allowed_app_ids
        ):
            raise ValueError("App Attest app identifiers are invalid")
        if environment not in {"development", "production"}:
            raise ValueError("App Attest environment is invalid")
        self.allowed_app_ids = frozenset(allowed_app_ids)
        self.environment = environment
        self.allowed_validation_categories = frozenset(
            allowed_validation_categories
            if allowed_validation_categories is not None
            else ({2, 4} if environment == "production" else {3})
        )
        if not self.allowed_validation_categories:
            raise ValueError("App Attest validation categories are invalid")
        if root_certificate is None:
            root_certificate = x509.load_pem_x509_certificate(
                APPLE_APP_ATTEST_ROOT_PATH.read_bytes()
            )
        self.root_certificate = root_certificate
        self.clock = clock

    def verify_attestation(
        self,
        *,
        attestation_object: bytes,
        key_id: str,
        challenge: bytes,
        app_build: str,
    ) -> VerifiedAttestation:
        if len(attestation_object) > APP_ATTEST_MAX_OBJECT_BYTES:
            raise AppAttestError(
                "app_attest_object_too_large", "App Attest object is too large",
                status_code=413,
            )
        key_id_bytes = decode_key_id(key_id)
        document = BoundedCBORDecoder(attestation_object).decode()
        if not isinstance(document, dict) or set(document) != {
            "fmt",
            "attStmt",
            "authData",
        }:
            raise AppAttestError(
                "app_attest_invalid_attestation", "App Attest object is invalid"
            )
        if document["fmt"] != APPLE_APP_ATTEST_FORMAT:
            raise AppAttestError(
                "app_attest_invalid_attestation", "App Attest format is invalid"
            )
        statement = document["attStmt"]
        auth_data = document["authData"]
        if (
            not isinstance(statement, dict)
            or set(statement) != {"x5c", "receipt"}
            or not isinstance(auth_data, bytes)
        ):
            raise AppAttestError(
                "app_attest_invalid_attestation", "App Attest object is invalid"
            )
        certificate_bytes = statement["x5c"]
        receipt = statement["receipt"]
        if (
            not isinstance(certificate_bytes, list)
            or not 2 <= len(certificate_bytes) <= 4
            or any(
                not isinstance(value, bytes) or not 1 <= len(value) <= 16 * 1024
                for value in certificate_bytes
            )
            or not isinstance(receipt, bytes)
            or not 1 <= len(receipt) <= APP_ATTEST_MAX_RECEIPT_BYTES
        ):
            raise AppAttestError(
                "app_attest_invalid_attestation", "App Attest statement is invalid"
            )
        try:
            certificates = [
                x509.load_der_x509_certificate(value) for value in certificate_bytes
            ]
        except ValueError as exc:
            raise AppAttestError(
                "app_attest_invalid_certificate", "App Attest certificate is invalid"
            ) from exc
        self._verify_certificate_chain(certificates)

        parsed = parse_authenticator_data(auth_data, attestation=True)
        if parsed.counter != 0:
            raise AppAttestError(
                "app_attest_invalid_counter", "App Attest counter is invalid"
            )
        expected_aaguid = (
            APP_ATTEST_PRODUCTION_AAGUID
            if self.environment == "production"
            else APP_ATTEST_DEVELOPMENT_AAGUID
        )
        # The AAGUID begins at offset 37 for attestation authData.
        if auth_data[37:53] != expected_aaguid:
            raise AppAttestError(
                "app_attest_wrong_environment", "App Attest environment is invalid"
            )
        app_id = next(
            (
                value
                for value in self.allowed_app_ids
                if secrets.compare_digest(
                    hashlib.sha256(value.encode("utf-8")).digest(),
                    parsed.rp_id_hash,
                )
            ),
            None,
        )
        if app_id is None:
            raise AppAttestError(
                "app_attest_wrong_app", "App Attest app identity is invalid"
            )
        if not secrets.compare_digest(parsed.credential_id or b"", key_id_bytes):
            raise AppAttestError(
                "app_attest_invalid_key", "App Attest key identifier is invalid"
            )

        leaf_public_key = certificates[0].public_key()
        if not isinstance(leaf_public_key, ec.EllipticCurvePublicKey) or not isinstance(
            leaf_public_key.curve, ec.SECP256R1
        ):
            raise AppAttestError(
                "app_attest_invalid_key", "App Attest public key is invalid"
            )
        public_key_x963 = leaf_public_key.public_bytes(
            serialization.Encoding.X962,
            serialization.PublicFormat.UncompressedPoint,
        )
        if not secrets.compare_digest(
            hashlib.sha256(public_key_x963).digest(), key_id_bytes
        ) or not secrets.compare_digest(
            parsed.public_key_x963 or b"", public_key_x963
        ):
            raise AppAttestError(
                "app_attest_invalid_key", "App Attest public key is invalid"
            )

        client_data_hash = hashlib.sha256(challenge).digest()
        expected_nonce = hashlib.sha256(auth_data + client_data_hash).digest()
        try:
            extension = certificates[0].extensions.get_extension_for_oid(
                APPLE_APP_ATTEST_NONCE_OID
            )
        except x509.ExtensionNotFound as exc:
            raise AppAttestError(
                "app_attest_invalid_nonce", "App Attest nonce is missing"
            ) from exc
        if not isinstance(extension.value, x509.UnrecognizedExtension):
            raise AppAttestError(
                "app_attest_invalid_nonce", "App Attest nonce is invalid"
            )
        actual_nonce = _decode_apple_nonce_extension(extension.value.value)
        if not secrets.compare_digest(expected_nonce, actual_nonce):
            raise AppAttestError(
                "app_attest_invalid_nonce", "App Attest challenge is invalid"
            )

        validation_category, bundle_version = _attestation_extension_values(
            parsed.extensions
        )
        if validation_category is not None:
            if validation_category not in self.allowed_validation_categories:
                raise AppAttestError(
                    "app_attest_invalid_validation_category",
                    "App Attest launch validation category is invalid",
                )
            if bundle_version != app_build:
                raise AppAttestError(
                    "app_attest_invalid_bundle_version",
                    "App Attest bundle version is invalid",
                )
        return VerifiedAttestation(
            public_key_x963=public_key_x963,
            receipt=receipt,
            app_id=app_id,
            environment=self.environment,
            validation_category=validation_category,
            bundle_version=bundle_version,
        )

    def _verify_certificate_chain(
        self,
        certificates: list[x509.Certificate],
    ) -> None:
        now = datetime.fromtimestamp(self.clock(), tz=timezone.utc)
        chain = [*certificates, self.root_certificate]
        for index, certificate in enumerate(chain):
            if not (
                certificate.not_valid_before_utc <= now <= certificate.not_valid_after_utc
            ):
                raise AppAttestError(
                    "app_attest_invalid_certificate",
                    "App Attest certificate is outside its validity period",
                )
            try:
                basic_constraints = certificate.extensions.get_extension_for_oid(
                    ExtensionOID.BASIC_CONSTRAINTS
                ).value
            except x509.ExtensionNotFound as exc:
                raise AppAttestError(
                    "app_attest_invalid_certificate",
                    "App Attest certificate constraints are missing",
                ) from exc
            if basic_constraints.ca != (index != 0):
                raise AppAttestError(
                    "app_attest_invalid_certificate",
                    "App Attest certificate constraints are invalid",
                )
            if index == 0:
                try:
                    key_usage = certificate.extensions.get_extension_for_oid(
                        ExtensionOID.KEY_USAGE
                    ).value
                except x509.ExtensionNotFound as exc:
                    raise AppAttestError(
                        "app_attest_invalid_certificate",
                        "App Attest certificate key usage is missing",
                    ) from exc
                if not key_usage.digital_signature:
                    raise AppAttestError(
                        "app_attest_invalid_certificate",
                        "App Attest certificate key usage is invalid",
                    )
            elif index < len(chain) - 1:
                try:
                    key_usage = certificate.extensions.get_extension_for_oid(
                        ExtensionOID.KEY_USAGE
                    ).value
                except x509.ExtensionNotFound as exc:
                    raise AppAttestError(
                        "app_attest_invalid_certificate",
                        "App Attest CA key usage is missing",
                    ) from exc
                if not key_usage.key_cert_sign:
                    raise AppAttestError(
                        "app_attest_invalid_certificate",
                        "App Attest CA key usage is invalid",
                    )

        for child, issuer in zip(chain, chain[1:]):
            if child.issuer != issuer.subject:
                raise AppAttestError(
                    "app_attest_invalid_certificate",
                    "App Attest certificate chain is invalid",
                )
            issuer_key = issuer.public_key()
            if not isinstance(issuer_key, ec.EllipticCurvePublicKey):
                raise AppAttestError(
                    "app_attest_invalid_certificate",
                    "App Attest certificate chain is invalid",
                )
            try:
                issuer_key.verify(
                    child.signature,
                    child.tbs_certificate_bytes,
                    ec.ECDSA(child.signature_hash_algorithm),
                )
            except InvalidSignature as exc:
                raise AppAttestError(
                    "app_attest_invalid_certificate",
                    "App Attest certificate signature is invalid",
                ) from exc


def _decode_apple_nonce_extension(value: bytes) -> bytes:
    # DER SEQUENCE { [1] { OCTET STRING (32 bytes) } }
    offset = 0

    def read_tlv(expected_tag: int, parent_end: int) -> tuple[int, int]:
        nonlocal offset
        if offset >= parent_end or value[offset] != expected_tag:
            raise AppAttestError(
                "app_attest_invalid_nonce", "App Attest nonce is invalid"
            )
        offset += 1
        if offset >= parent_end:
            raise AppAttestError(
                "app_attest_invalid_nonce", "App Attest nonce is invalid"
            )
        first = value[offset]
        offset += 1
        if first & 0x80:
            length_bytes = first & 0x7F
            if length_bytes == 0 or length_bytes > 2 or offset + length_bytes > parent_end:
                raise AppAttestError(
                    "app_attest_invalid_nonce", "App Attest nonce is invalid"
                )
            length = int.from_bytes(value[offset : offset + length_bytes], "big")
            offset += length_bytes
            if length < 128:
                raise AppAttestError(
                    "app_attest_invalid_nonce", "App Attest nonce is invalid"
                )
        else:
            length = first
        end = offset + length
        if end > parent_end:
            raise AppAttestError(
                "app_attest_invalid_nonce", "App Attest nonce is invalid"
            )
        return offset, end

    _, sequence_end = read_tlv(0x30, len(value))
    _, context_end = read_tlv(0xA1, sequence_end)
    octet_start, octet_end = read_tlv(0x04, context_end)
    nonce = value[octet_start:octet_end]
    offset = octet_end
    if len(nonce) != 32 or offset != context_end or offset != sequence_end or offset != len(value):
        raise AppAttestError(
            "app_attest_invalid_nonce", "App Attest nonce is invalid"
        )
    return nonce


class AppAttestStore:
    def __init__(
        self,
        path: Path,
        verifier: AppAttestationVerifying,
        *,
        challenge_ttl_seconds: int = APP_ATTEST_CHALLENGE_TTL_SECONDS,
        clock=time.time,
    ):
        if challenge_ttl_seconds < 30 or challenge_ttl_seconds > 900:
            raise ValueError("App Attest challenge TTL must be between 30 and 900 seconds")
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.verifier = verifier
        self.challenge_ttl_seconds = challenge_ttl_seconds
        self.clock = clock
        self._initialize()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=10.0)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA busy_timeout = 10000")
        return connection

    def _initialize(self) -> None:
        with self._connect() as connection:
            connection.execute("PRAGMA journal_mode = WAL")
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS app_attest_challenges(
                    challenge_id TEXT PRIMARY KEY,
                    challenge BLOB NOT NULL,
                    purpose TEXT NOT NULL,
                    installation_id TEXT,
                    created_at INTEGER NOT NULL,
                    expires_at INTEGER NOT NULL,
                    consumed_at INTEGER,
                    CHECK(length(challenge_id) = 32),
                    CHECK(length(challenge) = 32),
                    CHECK(purpose IN ('attestation', 'map-create'))
                );
                CREATE INDEX IF NOT EXISTS app_attest_challenges_expiry
                    ON app_attest_challenges(expires_at);
                CREATE TABLE IF NOT EXISTS app_attest_keys(
                    key_id TEXT PRIMARY KEY,
                    installation_id TEXT NOT NULL UNIQUE,
                    public_key_x963 BLOB NOT NULL UNIQUE,
                    receipt BLOB NOT NULL,
                    app_id TEXT NOT NULL,
                    environment TEXT NOT NULL,
                    validation_category INTEGER,
                    bundle_version TEXT,
                    assertion_counter INTEGER NOT NULL DEFAULT 0,
                    created_at INTEGER NOT NULL,
                    CHECK(length(public_key_x963) = 65),
                    CHECK(environment IN ('development', 'production')),
                    CHECK(assertion_counter >= 0)
                );
                """
            )
        try:
            os.chmod(self.path, 0o600)
        except OSError:
            pass

    def issue_challenge(
        self,
        *,
        purpose: str,
        installation_id: str | None = None,
    ) -> AppAttestChallenge:
        if purpose not in {
            APP_ATTEST_ATTESTATION_PURPOSE,
            APP_ATTEST_MAP_CREATE_PURPOSE,
        }:
            raise AppAttestError(
                "app_attest_invalid_purpose", "App Attest purpose is invalid",
                status_code=400,
            )
        if purpose == APP_ATTEST_ATTESTATION_PURPOSE and installation_id is not None:
            raise AppAttestError(
                "app_attest_invalid_purpose", "App Attest principal is not allowed",
                status_code=400,
            )
        if purpose == APP_ATTEST_MAP_CREATE_PURPOSE and installation_id is None:
            raise AppAttestError(
                "app_attest_invalid_principal", "installation credential is required"
            )
        now = int(self.clock())
        challenge_id = secrets.token_hex(16)
        challenge = secrets.token_bytes(APP_ATTEST_CHALLENGE_BYTES)
        expires_at = now + self.challenge_ttl_seconds
        key_id: str | None = None
        try:
            with self._connect() as connection:
                connection.execute("BEGIN IMMEDIATE")
                self._prune_challenges(connection, now)
                if installation_id is not None:
                    row = connection.execute(
                        "SELECT key_id FROM app_attest_keys WHERE installation_id = ?",
                        (installation_id,),
                    ).fetchone()
                    if row is None:
                        raise AppAttestError(
                            "installation_attestation_required",
                            "installation App Attest enrollment is required",
                        )
                    key_id = str(row["key_id"])
                connection.execute(
                    """
                    INSERT INTO app_attest_challenges(
                        challenge_id, challenge, purpose, installation_id,
                        created_at, expires_at, consumed_at
                    ) VALUES (?, ?, ?, ?, ?, ?, NULL)
                    """,
                    (
                        challenge_id,
                        challenge,
                        purpose,
                        installation_id,
                        now,
                        expires_at,
                    ),
                )
        except sqlite3.Error as exc:
            raise AppAttestError(
                "app_attest_storage_unavailable",
                "App Attest verification is temporarily unavailable",
                status_code=503,
            ) from exc
        return AppAttestChallenge(
            challenge_id=challenge_id,
            challenge=challenge,
            purpose=purpose,
            expires_at=expires_at,
            key_id=key_id,
        )

    def enroll(
        self,
        *,
        installation_id: str,
        challenge_id: str,
        key_id: str,
        attestation_object: bytes,
        app_build: str,
    ) -> VerifiedAttestation:
        now = int(self.clock())
        try:
            with self._connect() as connection:
                connection.execute("BEGIN IMMEDIATE")
                row = self._active_challenge(
                    connection,
                    challenge_id=challenge_id,
                    purpose=APP_ATTEST_ATTESTATION_PURPOSE,
                    installation_id=None,
                    now=now,
                )
                verified = self.verifier.verify_attestation(
                    attestation_object=attestation_object,
                    key_id=key_id,
                    challenge=bytes(row["challenge"]),
                    app_build=app_build,
                )
                try:
                    connection.execute(
                        """
                        INSERT INTO app_attest_keys(
                            key_id, installation_id, public_key_x963, receipt,
                            app_id, environment, validation_category,
                            bundle_version, assertion_counter, created_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
                        """,
                        (
                            key_id,
                            installation_id,
                            verified.public_key_x963,
                            verified.receipt,
                            verified.app_id,
                            verified.environment,
                            verified.validation_category,
                            verified.bundle_version,
                            now,
                        ),
                    )
                except sqlite3.IntegrityError as exc:
                    raise AppAttestError(
                        "app_attest_key_already_bound",
                        "App Attest key is already associated with an installation",
                    ) from exc
                self._consume_challenge(connection, challenge_id, now)
                return verified
        except AppAttestError:
            raise
        except sqlite3.Error as exc:
            raise AppAttestError(
                "app_attest_storage_unavailable",
                "App Attest verification is temporarily unavailable",
                status_code=503,
            ) from exc

    def key_id_for_installation(self, installation_id: str) -> str | None:
        try:
            with self._connect() as connection:
                row = connection.execute(
                    "SELECT key_id FROM app_attest_keys WHERE installation_id = ?",
                    (installation_id,),
                ).fetchone()
        except sqlite3.Error as exc:
            raise AppAttestError(
                "app_attest_storage_unavailable",
                "App Attest verification is temporarily unavailable",
                status_code=503,
            ) from exc
        return None if row is None else str(row["key_id"])

    def verify_map_create_assertion(
        self,
        *,
        installation_id: str,
        challenge_id: str,
        key_id: str,
        assertion_object: bytes,
        request_body: bytes,
        payload: dict[str, Any],
        app_build: str,
    ) -> int:
        if len(assertion_object) > APP_ATTEST_MAX_ASSERTION_BYTES:
            raise AppAttestError(
                "app_attest_assertion_too_large", "App Attest assertion is too large",
                status_code=413,
            )
        now = int(self.clock())
        try:
            with self._connect() as connection:
                connection.execute("BEGIN IMMEDIATE")
                challenge_row = self._active_challenge(
                    connection,
                    challenge_id=challenge_id,
                    purpose=APP_ATTEST_MAP_CREATE_PURPOSE,
                    installation_id=installation_id,
                    now=now,
                )
                key_row = connection.execute(
                    """
                    SELECT key_id, public_key_x963, app_id, environment,
                           assertion_counter
                    FROM app_attest_keys WHERE installation_id = ?
                    """,
                    (installation_id,),
                ).fetchone()
                if key_row is None:
                    raise AppAttestError(
                        "installation_attestation_required",
                        "installation App Attest enrollment is required",
                    )
                if not secrets.compare_digest(str(key_row["key_id"]), key_id):
                    raise AppAttestError(
                        "app_attest_key_mismatch", "App Attest key is invalid"
                    )
                client_data = canonical_map_create_client_data(
                    challenge_id=challenge_id,
                    challenge=bytes(challenge_row["challenge"]),
                    installation_id=installation_id,
                    request_body=request_body,
                    payload=payload,
                    app_build=app_build,
                )
                new_counter = self._verify_assertion(
                    assertion_object=assertion_object,
                    public_key_x963=bytes(key_row["public_key_x963"]),
                    app_id=str(key_row["app_id"]),
                    previous_counter=int(key_row["assertion_counter"]),
                    client_data=client_data,
                    environment=str(key_row["environment"]),
                    app_build=app_build,
                )
                updated = connection.execute(
                    """
                    UPDATE app_attest_keys SET assertion_counter = ?
                    WHERE installation_id = ? AND key_id = ?
                      AND assertion_counter = ?
                    """,
                    (
                        new_counter,
                        installation_id,
                        key_id,
                        int(key_row["assertion_counter"]),
                    ),
                )
                if updated.rowcount != 1:
                    raise AppAttestError(
                        "app_attest_counter_replay", "App Attest assertion was replayed"
                    )
                self._consume_challenge(connection, challenge_id, now)
                return new_counter
        except AppAttestError:
            raise
        except sqlite3.Error as exc:
            raise AppAttestError(
                "app_attest_storage_unavailable",
                "App Attest verification is temporarily unavailable",
                status_code=503,
            ) from exc

    def _verify_assertion(
        self,
        *,
        assertion_object: bytes,
        public_key_x963: bytes,
        app_id: str,
        previous_counter: int,
        client_data: bytes,
        environment: str,
        app_build: str,
    ) -> int:
        document = BoundedCBORDecoder(
            assertion_object,
            maximum_bytes=APP_ATTEST_MAX_ASSERTION_BYTES,
            maximum_items=32,
        ).decode()
        if not isinstance(document, dict) or set(document) != {
            "signature",
            "authenticatorData",
        }:
            raise AppAttestError(
                "app_attest_invalid_assertion", "App Attest assertion is invalid"
            )
        signature = document["signature"]
        auth_data = document["authenticatorData"]
        if (
            not isinstance(signature, bytes)
            or not 8 <= len(signature) <= 144
            or not isinstance(auth_data, bytes)
        ):
            raise AppAttestError(
                "app_attest_invalid_assertion", "App Attest assertion is invalid"
            )
        parsed = parse_authenticator_data(auth_data, attestation=False)
        expected_rp_id = hashlib.sha256(app_id.encode("utf-8")).digest()
        if not secrets.compare_digest(parsed.rp_id_hash, expected_rp_id):
            raise AppAttestError(
                "app_attest_wrong_app", "App Attest app identity is invalid"
            )
        if parsed.counter <= 0 or parsed.counter <= previous_counter:
            raise AppAttestError(
                "app_attest_counter_replay", "App Attest assertion was replayed"
            )
        validation_category, bundle_version = _assertion_extension_values(
            parsed.extensions
        )
        if validation_category is not None:
            allowed_validation_categories = (
                {2, 4} if environment == "production" else {3}
            )
            if (
                validation_category not in allowed_validation_categories
                or bundle_version != app_build
            ):
                raise AppAttestError(
                    "app_attest_invalid_extensions",
                    "App Attest assertion identity is invalid",
                )
        client_data_hash = hashlib.sha256(client_data).digest()
        nonce = hashlib.sha256(auth_data + client_data_hash).digest()
        try:
            public_key = ec.EllipticCurvePublicKey.from_encoded_point(
                ec.SECP256R1(), public_key_x963
            )
            public_key.verify(
                signature,
                nonce,
                ec.ECDSA(utils.Prehashed(hashes.SHA256())),
            )
        except (ValueError, InvalidSignature) as exc:
            raise AppAttestError(
                "app_attest_invalid_signature", "App Attest signature is invalid"
            ) from exc
        return parsed.counter

    @staticmethod
    def _active_challenge(
        connection: sqlite3.Connection,
        *,
        challenge_id: str,
        purpose: str,
        installation_id: str | None,
        now: int,
    ) -> sqlite3.Row:
        if not isinstance(challenge_id, str) or not re.fullmatch(
            r"[0-9a-f]{32}", challenge_id
        ):
            raise AppAttestError(
                "app_attest_invalid_challenge", "App Attest challenge is invalid"
            )
        row = connection.execute(
            """
            SELECT challenge, purpose, installation_id, expires_at, consumed_at
            FROM app_attest_challenges WHERE challenge_id = ?
            """,
            (challenge_id,),
        ).fetchone()
        expected_installation = installation_id or ""
        actual_installation = "" if row is None else (row["installation_id"] or "")
        if (
            row is None
            or row["purpose"] != purpose
            or not secrets.compare_digest(actual_installation, expected_installation)
            or row["consumed_at"] is not None
            or int(row["expires_at"]) < now
        ):
            raise AppAttestError(
                "app_attest_invalid_challenge",
                "App Attest challenge is expired, consumed, or invalid",
            )
        return row

    @staticmethod
    def _consume_challenge(
        connection: sqlite3.Connection,
        challenge_id: str,
        now: int,
    ) -> None:
        updated = connection.execute(
            """
            UPDATE app_attest_challenges SET consumed_at = ?
            WHERE challenge_id = ? AND consumed_at IS NULL
            """,
            (now, challenge_id),
        )
        if updated.rowcount != 1:
            raise AppAttestError(
                "app_attest_invalid_challenge", "App Attest challenge was replayed"
            )

    @staticmethod
    def _prune_challenges(connection: sqlite3.Connection, now: int) -> None:
        connection.execute(
            """
            DELETE FROM app_attest_challenges
            WHERE expires_at < ? OR (consumed_at IS NOT NULL AND consumed_at < ?)
            """,
            (now - 3_600, now - 3_600),
        )


def production_app_attest_verifier(deployment_channel: str) -> AppleAppAttestVerifier:
    if deployment_channel == "production":
        return AppleAppAttestVerifier(
            allowed_app_ids={"4H5PK8686H.LetItRide.BikeComputer"},
            environment="production",
            allowed_validation_categories={2, 4},
        )
    if deployment_channel == "development":
        return AppleAppAttestVerifier(
            allowed_app_ids={"4H5PK8686H.LetItRide.BikeComputer.dev"},
            environment="development",
            allowed_validation_categories={3},
        )
    raise ValueError("App Attest requires a production or development deployment channel")
