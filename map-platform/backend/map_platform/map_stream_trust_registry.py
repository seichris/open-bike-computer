from __future__ import annotations

import re
import hashlib
from dataclasses import dataclass
from datetime import date
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric import ec

from .strict_json import load_strict_json


KEY_ID_PATTERN = re.compile(r"[A-Za-z0-9._-]{1,64}")
PUBLIC_KEY_PATTERN = re.compile(r"04[0-9a-f]{128}")
MAXIMUM_TRUSTED_KEYS = 4
FORBIDDEN_FIXTURE_KEY_IDS = frozenset(
    {"map-test-2026-01", "map-test-2026-02"}
)
FORBIDDEN_FIXTURE_PUBLIC_KEYS = frozenset(
    {
        "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2"
        "964fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5",
        "047cf27b188d034f7e8a52380304b51ac3c08969e277f21b35a60b48fc4766997"
        "807775510db8ed040293d9ac69f7430dbba7dade63ce982299e04b79d227873d1",
    }
)


@dataclass(frozen=True)
class TrustKey:
    key_id: str
    public_key_x963_hex: str
    state: str
    created_at: str
    retire_after: str | None


def parse_trust_date(value: object, field: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", value):
        raise ValueError(f"{field} must be an ISO date")
    try:
        date.fromisoformat(value)
    except ValueError as exc:
        raise ValueError(f"{field} must be an ISO date") from exc
    return value


def load_trust_registry(path: Path) -> list[TrustKey]:
    document = load_strict_json(path, description="map stream trust registry")
    if not isinstance(document, dict) or set(document) != {"schemaVersion", "keys"}:
        raise ValueError("map stream trust registry has unexpected top-level fields")
    if (
        type(document["schemaVersion"]) is not int
        or document["schemaVersion"] != 1
    ):
        raise ValueError("unsupported map stream trust registry schema")
    if not isinstance(document["keys"], list):
        raise ValueError("map stream trust registry keys must be an array")

    parsed: list[TrustKey] = []
    for index, raw in enumerate(document["keys"]):
        if not isinstance(raw, dict):
            raise ValueError(f"trust key {index} must be an object")
        allowed_fields = {
            "keyId",
            "publicKeyX963Hex",
            "state",
            "createdAt",
            "retireAfter",
        }
        required_fields = allowed_fields - {"retireAfter"}
        if not required_fields.issubset(raw) or not set(raw).issubset(allowed_fields):
            raise ValueError(f"trust key {index} has missing or unexpected fields")
        key_id = raw["keyId"]
        public_key = raw["publicKeyX963Hex"]
        state = raw["state"]
        if not isinstance(key_id, str) or not KEY_ID_PATTERN.fullmatch(key_id):
            raise ValueError(f"trust key {index} has an invalid key ID")
        if key_id in FORBIDDEN_FIXTURE_KEY_IDS:
            raise ValueError("golden-vector key IDs are forbidden in production trust")
        if not isinstance(public_key, str) or not PUBLIC_KEY_PATTERN.fullmatch(public_key):
            raise ValueError(f"trust key {index} has an invalid X9.63 public key")
        if public_key in FORBIDDEN_FIXTURE_PUBLIC_KEYS:
            raise ValueError("golden-vector public keys are forbidden in production trust")
        try:
            ec.EllipticCurvePublicKey.from_encoded_point(
                ec.SECP256R1(),
                bytes.fromhex(public_key),
            )
        except ValueError as exc:
            raise ValueError(f"trust key {index} is not a valid P-256 point") from exc
        if not isinstance(state, str) or state not in {"trusted", "retired"}:
            raise ValueError(f"trust key {index} has an invalid state")
        created_at = parse_trust_date(raw["createdAt"], f"trust key {index} createdAt")
        retire_after = raw.get("retireAfter")
        if retire_after is not None:
            retire_after = parse_trust_date(
                retire_after,
                f"trust key {index} retireAfter",
            )
            if date.fromisoformat(retire_after) <= date.fromisoformat(created_at):
                raise ValueError("trust-key retirement must be after creation")
        if state == "retired" and retire_after is not None:
            raise ValueError("retired keys must not retain a future retirement date")
        parsed.append(
            TrustKey(
                key_id=key_id,
                public_key_x963_hex=public_key,
                state=state,
                created_at=created_at,
                retire_after=retire_after,
            )
        )

    if [key.key_id for key in parsed] != sorted(key.key_id for key in parsed):
        raise ValueError("map stream trust keys must be sorted by key ID")
    if len({key.key_id for key in parsed}) != len(parsed):
        raise ValueError("map stream trust key IDs must be unique")
    if len({key.public_key_x963_hex for key in parsed}) != len(parsed):
        raise ValueError("map stream trust public keys must be unique")
    trusted = [key for key in parsed if key.state == "trusted"]
    if len(trusted) > MAXIMUM_TRUSTED_KEYS:
        raise ValueError(
            f"no more than {MAXIMUM_TRUSTED_KEYS} map stream keys may be trusted"
        )
    return parsed


def trusted_key_ids(path: Path) -> frozenset[str]:
    return frozenset(
        key.key_id for key in load_trust_registry(path) if key.state == "trusted"
    )


def trusted_key_fingerprints(path: Path) -> dict[str, str]:
    return {
        key.key_id: hashlib.sha256(bytes.fromhex(key.public_key_x963_hex)).hexdigest()
        for key in load_trust_registry(path)
        if key.state == "trusted"
    }
