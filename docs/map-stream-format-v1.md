# Bike Map Stream Format v1

This document is the normative byte-level contract for Bike Map Stream format
v1, carried by map install protocol v2. The broader installation, recovery, and
rollout design lives in
[`streaming-map-installation-implementation-plan.md`](streaming-map-installation-implementation-plan.md).

## Encoding

- Artifact extension: `.bmap`
- Media type: `application/vnd.openbikecomputer.map-stream`
- Integer encoding: unsigned little-endian
- Maximum manifest: 2 MiB
- Maximum signature key ID: 64 bytes
- Maximum map ID: 64 ASCII bytes
- Maximum variable path component: 64 ASCII bytes
- Maximum complete relative map path: 202 ASCII bytes
- Maximum file count: 100,000
- Maximum payload: 512 MiB
- No bytes may follow the declared payload.

## Fixed Header

The header is exactly 32 bytes.

| Offset | Field | Width | Requirement |
| ---: | --- | ---: | --- |
| 0 | Magic | 8 | ASCII `BIKEMAP1` |
| 8 | Format version | 2 | `1` |
| 10 | Flags | 2 | `0` |
| 12 | Manifest length | 4 | `1...2 MiB` |
| 16 | Signature envelope length | 2 | Exact encoded envelope length |
| 18 | Reserved | 2 | `0` |
| 20 | File count | 4 | `1...100,000`, equal to manifest count |
| 24 | Payload byte count | 8 | `1...512 MiB`, equal to manifest file-size sum |

Total artifact length is exactly:

```text
32 + manifest length + signature envelope length + payload byte count
```

## Canonical Manifest

The manifest immediately follows the header and is encoded as UTF-8 JSON:

- object keys sorted lexicographically;
- no insignificant whitespace;
- no trailing newline;
- finite JSON numbers only;
- files sorted lexicographically by normalized relative `path`;
- file paths unique.

The authoritative bytes are the bytes embedded in the artifact. Consumers hash
and verify those bytes directly; they do not parse and reserialize JSON to
recreate the signed input.

Every file entry includes a safe `VECTMAP/<mapId>/...fm[bp]` path, byte count,
and lowercase SHA-256. Payload order is exactly manifest file order.
`mapId`, the directory below it, and the filename (including extension) are each
1...64 ASCII bytes. With the literal `VECTMAP` prefix and separators, the exact
maximum relative path is therefore 202 bytes. Readers must enforce both the
component and complete-path limits before allocating a destination buffer.

## Signature Envelope

The binary envelope immediately follows the manifest.

| Offset | Field | Width | Requirement |
| ---: | --- | ---: | --- |
| 0 | Algorithm ID | 1 | `1` = P-256/SHA-256 |
| 1 | Key ID length | 1 | `1...64` |
| 2 | Signature length | 2 | `64` |
| 4 | Key ID | Variable | ASCII letters, digits, `.`, `_`, or `-` |
| 4 + key ID length | Signature | 64 | Fixed-width big-endian `r || s`; `r` is in `1...(n-1)` and `s` is canonical low-S in `1...floor(n/2)` |

The signed message is:

```text
"open-bike-computer-map-manifest-v1\0" || canonical manifest bytes
```

Production signing uses a dedicated P-256 key and RFC 6979 deterministic
nonces. Signers normalize `s` to low-S and readers reject non-canonical
signatures. This prevents the mathematically equivalent `(r, n-s)` signature
from creating a second `signedManifestReceipt`. Verification is ordinary
P-256/SHA-256 verification. The key ID selects a public key from the app/firmware
trust store.

## Payload

Raw file bodies follow the signature envelope with no per-file framing. The
manifest provides every boundary. For each manifest file in order, consume
exactly its declared byte count and require the calculated SHA-256 to match.

The artifact is invalid if a body is missing, short, long, reordered, has a hash
mismatch, or if trailing bytes remain after the last declared file.

## Identities

```text
manifestReceipt = SHA256(canonical manifest bytes)

signedManifestReceipt = SHA256(
  signature domain ||
  canonical manifest bytes ||
  exact signature envelope bytes
)
```

Transfer sessions and durable checkpoints bind to `signedManifestReceipt`.
`manifestReceipt` identifies equivalent manifest content across signing-key
rotation.

The backend additionally publishes SHA-256 for the complete `.bmap` artifact so
iOS can validate downloads and cached files. Firmware does not calculate a
whole-artifact hash; it verifies the signature and calculates each file hash
once while writing that file to SD.

## Required Failure Behavior

Readers fail closed on:

- wrong magic, version, flags, or reserved fields;
- arithmetic overflow or any configured limit violation;
- mismatched content length;
- malformed, unsupported, or non-canonical signature envelope;
- unknown/revoked key ID or invalid signature;
- unsafe, duplicate, missing, or reordered manifest paths;
- file-count or payload-size mismatch;
- per-file hash mismatch;
- truncation or trailing bytes.

Integrity failures never automatically fall back to protocol v1.

## Golden Vector

The shared golden vector is
[`backend/tests/fixtures/map_stream_v1_golden.txt`](../backend/tests/fixtures/map_stream_v1_golden.txt).
It contains the exact header, canonical manifest, signature envelope, payload,
complete stream, receipts, and test public key as hexadecimal fields.

The fixed test private scalar is `1` and is for tests only. It must never be
accepted by a production trust store. Regenerate the vector with:

```sh
cd backend
python tools/generate_map_stream_golden.py \
  --output tests/fixtures/map_stream_v1_golden.txt
```

Backend, Swift, and C++ tests must all consume the complete stream, agree on
section boundaries and identities, verify the signature, reject tampering, and
reject truncated or extended artifacts.
