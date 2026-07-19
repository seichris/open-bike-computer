# Map Stream Trust and Rollout Runbook

This runbook is the production control plane for Bike Map Stream v1. It keeps
artifact generation, client delivery, public-key trust, hardware acceptance,
and key retirement separate so no single environment-variable change can
promote an untested path globally.

## Safety model

Four independent gates must agree before protocol v2 is used:

1. The worker generates signed artifacts only when
   `MAP_PLATFORM_MAP_STREAM_ENABLED=1` and a valid dedicated P-256 private key
   is present.
2. The API returns stream artifacts only to the configured rollout cohort.
3. iOS accepts only signatures from the generated production public-key
   registry.
4. Firmware advertises v2 only when SD/recovery initialization succeeds and
   the same compiled trust registry is non-empty.

The checked-in trust registry and promotion registry are intentionally empty
until hardware validation. Empty or invalid configuration fails closed and
keeps ZIP/protocol-v1 compatibility available.

## Commission a signing key

Generate the dedicated P-256 key inside the production secret-management
environment. Do not reuse the firmware release key, copy the private key into
the repository, send it through chat, or generate it from a deterministic test
scalar.

Example using a protected operator workstation:

```sh
umask 077
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
  -out /secure/location/map-prod-2026-01.pem
chmod 600 /secure/location/map-prod-2026-01.pem
python backend/tools/generate_map_stream_trust.py \
  --inspect-private-key /secure/location/map-prod-2026-01.pem \
  --key-id map-prod-2026-01 \
  --created-at 2026-07-13 \
  --retire-after 2027-07-13
```

The command prints public registry material only. Add that object to
`config/map-stream-trust.json`, sorted by `keyId`, then regenerate and verify:

```sh
python backend/tools/generate_map_stream_trust.py --write
python backend/tools/generate_map_stream_trust.py --check
```

Review and commit the registry plus both generated outputs. The generator
validates the P-256 point, rejects private fields and golden-vector keys, limits
the active trust set, and keeps iOS and firmware byte-identical.

Build and ship the allowlisted iOS and firmware candidates from that commit
before testing. Both clients advertise the exact trusted key fingerprint; an
older build without the key stays on ZIP/protocol v1 even if its installation
ID is allowlisted. Release candidates must come from a clean tree: firmware
advertises protocol v2 only with a full 40-character git SHA, and iOS sends its
numeric build, full 40-character git SHA, and generated component SHA-256. A
dirty or unidentified candidate therefore fails closed before v2 selection.

Build the worker image once for the candidate, publish it to the registry, and
record both its immutable registry digest and
`/app/config/map-stream-build-identity.json`. The contained
`producerBuildSha256` is derived during the image build from worker/pipeline
source bytes plus Python dependencies, architecture-qualified system packages,
and native platform/architecture inventory. The worker recomputes it at startup;
the production image executes from that same hashed source tree and rejects a
separately installed runtime package. No CI variable or runtime setting can
assert it. The image reference must be
digest-pinned as `registry/repository@sha256:<digest>`. Require promotion CI to
verify registry availability, the required platform, and GitHub provenance from
the protected `main` branch before merge, and keep the exact image available
through approval and rollout.

Put these secrets only on the worker service:

- `MAP_PLATFORM_MAP_SIGNING_KEY_ID`
- `MAP_PLATFORM_MAP_SIGNING_PRIVATE_KEY_BASE64`

Encode the unencrypted PKCS8 PEM directly into the secret manager without
printing it to logs. Keep an encrypted backup under the organization's key
recovery policy. The API service never receives the private key.

## Developer-device validation

Use `allowlist` mode for the registered installation IDs of the test iPhones:

```text
MAP_PLATFORM_MAP_STREAM_ROLLOUT_MODE=allowlist
MAP_PLATFORM_MAP_STREAM_ROLLOUT_ALLOWLIST=inst_v2_...[,inst_v2_...]
MAP_PLATFORM_MAP_STREAM_ROLLOUT_BASIS_POINTS=0
MAP_PLATFORM_MAP_STREAM_ROLLOUT_SECRET=
MAP_PLATFORM_MAP_STREAM_PROMOTION_ID=
```

Allowlist mode is the only enabled mode that does not require a completed
promotion record. It still requires valid installation credentials. Check
`/healthz`; it reports the mode and allowlist count but never IDs or secrets.

Copy `docs/map-stream-hardware-validation-report.example.json` to a protected
test-results location outside the repository. Record every scenario in
`config/map-stream-hardware-gate.json` for both production targets. Shanghai
clean installs require three repetitions per target. The per-board absolute
temperature ceilings live in that reviewed requirements file; a report cannot
raise its own limit after results are known.

Each run records phase times, payload bytes, SD bytes written, durable bytes
rewritten, retry bytes skipped, maximum temperature, recovery outcome, UI
responsiveness, and a structured `observed` identity. Every non-compatibility
run must record the exact iOS build/git/component identity, firmware
version/build/git SHA, artifact SHA-256, signed manifest receipt, derived
producer build SHA-256, worker image digest, and signing-key ID/fingerprint. The
two compatibility runs must use the exact predecessor identities in
`config/map-stream-hardware-gate.json` and prove that the retained ZIP path was
selected. Record values from the app/device/artifact under test, not from notes
or a mutable deployment label. Every stream run enforces bounded integer byte
counters and a reviewed write-amplification ceiling; clean scenarios require
exactly one payload write, and interruption scenarios require nonzero
durable-prefix skipping where their interruption point guarantees one. Every
candidate signing key must appear on both hardware targets. The checker rejects
missing repetitions, unexercised or untrusted keys, duplicate runs, excess SD
writes, thermal violations, failed recovery assertions, and Shanghai
regressions:

```json
"observed": {
  "iosBuild": "100",
  "iosGitSha": "<40 lowercase hex>",
  "iosBuildSha256": "<64 lowercase hex>",
  "firmwareVersion": "0.3.0",
  "firmwareBuild": 42,
  "firmwareGitSha": "<40 lowercase hex>",
  "artifactFormat": "bike-map-stream-v1",
  "artifactSha256": "<64 lowercase hex>",
  "producerBuildSha256": "<64 lowercase hex>",
  "producerImageDigest": "sha256:<64 lowercase hex>",
  "signatureKeyId": "map-prod-2026-01",
  "signatureKeySha256": "<64 lowercase hex>",
  "signedManifestReceipt": "<64 lowercase hex>"
}
```

For `old_app_new_firmware` and `new_app_old_firmware`, set `artifactFormat` to
`zip-stored-v1` and the five stream-only identity fields from
`producerBuildSha256` through `signedManifestReceipt` to `null`. The old app has
no component SHA, so its `iosBuildSha256` is also `null`.

```sh
python backend/tools/check_map_stream_hardware_gate.py \
  --check-report /secure/test-results/map-stream-report.json \
  --promotion-id msr-20260713-first-production
```

First record all required runs with `approval.approved=false`. After review,
set the approval timestamp later than every run and identify the approver; then
run the checker. When the report passes and its approval is explicit, the
command prints a hash-bound public approval object. Add that object to
`config/map-stream-rollout-approvals.json` in a reviewed PR. Do not commit the
raw report if it contains device or operator data. The record binds the report
bytes, exact requirements bytes, candidate git SHA for audit, derived producer
build SHA-256 and immutable worker image digest for enforcement, exact firmware
version/build/git SHA, exact iOS build/git/component identity, production
targets, and trusted signing keys. An approval generated with
a custom or weakened requirements file will not match the production
requirements hash and cannot enable percentage or global delivery.

## Measured promotion

Production delivery modes are:

- `disabled`: default; no installation receives `.bmap` metadata.
- `allowlist`: exact registered test installations only; no promotion record.
- `percentage`: stable HMAC cohort from 1 to 9,999 basis points; requires a
  committed promotion ID and a stable 32-byte-or-longer cohort secret.
- `all`: every valid registered installation; requires a committed promotion
  ID.

For `percentage` and `all`, set `MAP_PLATFORM_MAP_STREAM_PROMOTION_ID` to an ID
present in the checked-in approval registry. The approval PR is expected to be
later than the tested source commit; that control-plane-only change does not
alter the derived worker component identity. Keep the worker image anchor in
`deploy/map-platform/compose.yaml` on the exact
`registry/repository@sha256:<digest>` reference exercised by the hardware report
and deploy it without rebuilding it. The production lock passes that value as
both the worker service image and the API/worker admission identity; the
promotion CI policy must verify the image platform and `main`-branch provenance
before merge. Its separate control-plane image anchor may advance to include the
approval registry. The worker signs its derived content identity into every
stream manifest and records the exact public-key fingerprint in the
key-specific artifact identity. The API
refuses to start if the worker reference is mutable or differs from the approved
digest, the approval or requirements hash differs, approved key
material is no longer trusted, the cohort secret is short, or rollout variables
conflict. In percentage/global mode it hides any artifact whose signed producer
identity, image digest, signing key, or requesting app build/git/component
differs from the approval. The
artifact tells iOS the exact approved firmware identity, and iOS negotiates ZIP
when the connected device differs. A rotation or later untested binary therefore
cannot silently reuse an older hardware result.

Recommended sequence:

1. Keep generation on and delivery on the hardware-test allowlist.
2. Commit the passing, hash-bound promotion record while retaining the tested
   worker image digest.
3. Move to `percentage` at 100 basis points (1%).
4. Observe artifact refresh errors, background upload completion, activation
   failures, rollback/recovery, duration, SD writes, and thermal reports.
5. Increase monotonically with the same cohort secret: 5%, 10%, 25%, 50%,
   100%. Hold or return to the prior percentage on any regression.
6. Use `all` only after the 100% cohort remains healthy for the defined
   observation window.

Changing the cohort secret reshuffles users and is not a rollback mechanism.
Rollback by reducing basis points, switching to the tested allowlist, or setting
the mode to `disabled`. Keep ZIP artifacts and protocol v1 during the full
migration window.

Rollout changes stop new stream metadata and URL refreshes immediately. A
previously issued immutable download URL can remain usable for its bounded
15-minute lifetime, so emergency response must also disable device transfer or
quarantine the referenced object when immediate byte-level revocation is
required.

## Key rotation

Rotation is additive and must preserve resumable artifact identity:

1. Generate a new dedicated key and add its public key to the trust registry as
   `trusted` while the old key remains trusted.
2. Ship and measure app and firmware adoption before changing the worker's
   active signing key. Confirm their reported exact trust capabilities, not
   only a version label.
3. Switch the worker to the new key. Do not rewrite existing immutable
   artifacts; their key ID remains part of their object key and receipt.
4. Keep the old public key trusted for at least the larger of the artifact
   retention window, signed-URL lifetime, supported app/firmware update window,
   and paused-transfer recovery window.
5. Stop serving artifacts signed by the old key, confirm no retained job or
   resumable transfer references it, then mark it `retired` and regenerate both
   clients.

Never remove a public key merely because the worker has begun signing with its
replacement. A client that loses the old verifier cannot transfer or resume a
still-valid old artifact.

## Emergency response

For a suspected signing-key compromise:

1. Set rollout mode to `disabled` immediately. This hides stream metadata while
   preserving ZIP delivery.
2. Disable stream generation on workers and revoke the private secret.
3. Preserve logs containing job ID, key ID, manifest receipt, and artifact
   receipt; never log or retrieve the private key through application logs.
4. Add and ship a replacement public key before resuming generation.
5. Remove the compromised public key only after affected immutable artifacts
   are quarantined and paused device sessions are explicitly invalidated.
6. Run the complete hardware gate again and create a new promotion record.

Key rotation, emergency revocation, and rollout changes are separate reviewed
changes. V1 retirement is also a separate decision after the compatibility and
rollback windows close.
