from __future__ import annotations

import argparse
import hashlib
from pathlib import Path

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, utils

from map_platform.map_stream import (
    P256_HALF_ORDER,
    P256_ORDER,
    MapStreamSignatureEnvelope,
    build_stream_prefix,
    canonical_manifest_bytes,
    manifest_receipt,
    signed_manifest_payload,
    signed_manifest_receipt,
)


TEST_KEY_ID = "map-test-2026-01"
TEST_PAYLOAD = b"map-block"
TEST_PRIVATE_VALUE = 1


def build_vector() -> dict[str, str]:
    manifest = {
        "bounds": [103.75, 1.24, 103.93, 1.37],
        "displayName": "Golden Map",
        "files": [
            {
                "bytes": len(TEST_PAYLOAD),
                "path": "VECTMAP/golden-map/+0000+0000/0_0.fmb",
                "sha256": hashlib.sha256(TEST_PAYLOAD).hexdigest(),
            }
        ],
        "mapId": "golden-map",
        "schemaVersion": 1,
        "target": {
            "formatVersion": 1,
            "minFirmwareVersion": "0.0.0",
            "renderer": "esp32-fmb",
        },
    }
    manifest_bytes = canonical_manifest_bytes(manifest)
    private_key = ec.derive_private_key(TEST_PRIVATE_VALUE, ec.SECP256R1())
    der_signature = private_key.sign(
        signed_manifest_payload(manifest_bytes),
        ec.ECDSA(hashes.SHA256(), deterministic_signing=True),
    )
    r, s = utils.decode_dss_signature(der_signature)
    if s > P256_HALF_ORDER:
        s = P256_ORDER - s
    raw_signature = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    envelope = MapStreamSignatureEnvelope(TEST_KEY_ID, raw_signature).encode()
    prefix = build_stream_prefix(
        manifest_bytes,
        MapStreamSignatureEnvelope(TEST_KEY_ID, raw_signature),
        file_count=1,
        payload_bytes=len(TEST_PAYLOAD),
    )
    public_key = private_key.public_key().public_numbers()
    x963_public_key = (
        b"\x04"
        + public_key.x.to_bytes(32, "big")
        + public_key.y.to_bytes(32, "big")
    )
    stream = prefix + TEST_PAYLOAD
    return {
        "manifest_hex": manifest_bytes.hex(),
        "signature_envelope_hex": envelope.hex(),
        "header_hex": prefix[:32].hex(),
        "payload_hex": TEST_PAYLOAD.hex(),
        "stream_hex": stream.hex(),
        "manifest_receipt": manifest_receipt(manifest_bytes),
        "signed_manifest_receipt": signed_manifest_receipt(manifest_bytes, envelope),
        "public_key_x963_hex": x963_public_key.hex(),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    vector = build_vector()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("".join(f"{key}={value}\n" for key, value in vector.items()))


if __name__ == "__main__":
    main()
