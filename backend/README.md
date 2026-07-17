# Offline Map Platform Backend

This backend creates ESP32-compatible offline map packs from OpenStreetMap PBF
sources. It implements the production contract described in
`docs/offline-map-platform-implementation-plan.md`.

## What is implemented

- `POST /v1/map-jobs` for curated, custom bbox, custom polygon, and route
  corridor requests, with installation-scoped idempotency metadata.
- Installation-scoped job, list, map-pack, and download-URL reads. The client
  installation ID is required for reads; legacy jobs without an owner remain
  recoverable by ID.
- Source-region resolution from `backend/config/source-regions.json`, with a
  cached Geofabrik catalog fallback for any requested area covered by
  Geofabrik.
- File-backed job storage for local/Coolify deployment.
- Worker wrapper for `osmium extract` plus `tools/OSM_Extract`.
- Map-pack manifest generation with file hashes and OSM attribution.
- Deterministic signed `.bmap` generation behind an explicit rollout flag,
  alongside the compatible `.zip` artifact.
- Immutable content-addressed artifact storage on the persistent volume or an
  S3-compatible object store.
- Artifact metadata and identity-bound download-URL refresh APIs.
- Fail-closed exact-pack and contained bounding-box block reuse, keyed by the
  actual cached PBF snapshot and immutable worker identity.
- Installation-authenticated saved-map names and successful-download receipts,
  plus a redacted admin inventory at `GET /v1/admin/maps`.
- Coolify-oriented compose file and Dockerfile.

## Local API

```sh
cd backend
python -m venv .venv
. .venv/bin/activate
python -m pip install -e ".[api]"
export MAP_PLATFORM_INSTALLATION_SECRET='replace-with-at-least-32-random-bytes'
uvicorn --factory map_platform.api:create_app --reload --port 8080
```

Create a custom bbox job:

```sh
credential="$(curl -s -X POST http://localhost:8080/v1/installations)"
installation_id="$(printf '%s' "$credential" | python -c 'import json,sys; print(json.load(sys.stdin)["clientInstallationId"])')"
installation_token="$(printf '%s' "$credential" | python -c 'import json,sys; print(json.load(sys.stdin)["clientInstallationToken"])')"
curl -s http://localhost:8080/v1/map-jobs \
  -H 'content-type: application/json' \
  -H "x-installation-token: $installation_token" \
  -d '{
    "mode": "custom_bbox",
    "displayName": "Singapore central",
    "bbox": [103.75, 1.24, 103.93, 1.37],
    "clientInstallationId": "'"$installation_id"'",
    "clientRequestId": "request-12345678",
    "installOnDevice": false,
    "target": { "renderer": "esp32-fmb", "firmwareVersion": "0.0.0" }
  }'
```

Run a job:

```sh
python -m map_platform.cli run-job <job-id>
```

Run the production-style queue worker:

```sh
python -m map_platform.cli worker-loop
```

Run retention and artifact garbage collection independently:

```sh
python -m map_platform.cli maintenance-loop
```

The configured source PBF must exist under `backend/data/source-pbf/` before a
worker can run, or the worker will download it into the configured data root
through the source cache. Static sources are stored in the source index; other
areas are resolved from the cached Geofabrik catalog at job creation time and
persisted with the job before the worker downloads the matching PBF.

## Coolify

Use `backend/docker-compose.yml` as the first Coolify deployment shape. The
service stores mutable state in the `map-platform-data` volume. The host needs
enough CPU, RAM, and temporary disk for the largest allowed PBF cut-out.

Required Coolify secrets:

- `MAP_PLATFORM_DOWNLOAD_SECRET`: HMAC secret for signed map-pack downloads.
  Use a separate long random value so signed URLs survive API restarts without
  reusing another credential as the signing key.
- `MAP_PLATFORM_INSTALLATION_SECRET`: separate 32-byte-or-longer HMAC secret
  for stateless v2 installation credentials. Rotate it by moving the old value
  into comma-separated `MAP_PLATFORM_INSTALLATION_PREVIOUS_SECRETS`, deploy the
  new current value, then remove retired values after the app migration window.

The public iOS app contains no server-wide credential. It requests a unique
installation credential from `POST /v1/installations`, stores it in the
Keychain, and presents it only for installation-owned resources. Issuance,
map creation, download-URL creation, and the general public API are protected
by persistent limits in `/data/rate-limits.sqlite3`. Defaults are intentionally
conservative and can be tuned with:

- `MAP_PLATFORM_PUBLIC_REQUEST_LIMIT_PER_MINUTE` (default `240` per IP)
- `MAP_PLATFORM_INSTALLATION_ISSUE_LIMIT_PER_DAY` (default `3` per IP)
- `MAP_PLATFORM_MAP_CREATE_LIMIT_PER_HOUR` (default `4` per installation)
- `MAP_PLATFORM_MAP_CREATE_IP_LIMIT_PER_DAY` (default `20` per IP)
- `MAP_PLATFORM_DOWNLOAD_URL_LIMIT_PER_HOUR` (default `30` per installation)
- `MAP_PLATFORM_DOWNLOAD_URL_IP_LIMIT_PER_HOUR` (default `60` per IP)
- `MAP_PLATFORM_MAX_REQUEST_BODY_BYTES` (default `2097152` for every non-GET request; large enough for the maximum supported route corridor)

Production Compose requires `MAP_PLATFORM_TRUSTED_PROXY_CIDRS` to contain the
comma-separated CIDRs of the
Coolify reverse proxies that overwrite or append `X-Forwarded-For`. Forwarded
addresses are ignored unless the immediate peer is trusted, and the resolver
walks the chain from the right to prevent client-supplied spoofing. IPv6
addresses are grouped by `/64` so privacy-address rotation cannot trivially
bypass a per-client quota.

Required before enabling Bike Map Stream generation:

- `MAP_PLATFORM_MAP_SIGNING_KEY_ID`: restricted public identifier for the
  active dedicated P-256 map signing key.
- `MAP_PLATFORM_MAP_SIGNING_PRIVATE_KEY_BASE64`: base64 of an unencrypted PKCS8
  PEM P-256 private key. Do not reuse the firmware release key and never commit
  this value.

Supply map-signing secrets only to the worker service. The Internet-facing API
does not load the private key, and inline API workers are disabled in production
with `MAP_PLATFORM_INLINE_WORKER_ENABLED=0`.

Keep `MAP_PLATFORM_MAP_STREAM_ENABLED=0` until the complete firmware and iOS v2
path passes the rollout acceptance gate. When it is set to `1`, missing or
invalid signing configuration fails closed; the backend never emits an unsigned
stream artifact.

Signed artifact generation and client delivery are separate controls. The API
defaults `MAP_PLATFORM_MAP_STREAM_ROLLOUT_MODE` to `disabled`. Use `allowlist`
with `MAP_PLATFORM_MAP_STREAM_ROLLOUT_ALLOWLIST` for exact registered hardware
test installations. `percentage` additionally requires
`MAP_PLATFORM_MAP_STREAM_ROLLOUT_BASIS_POINTS`, a stable 32-byte-or-longer
`MAP_PLATFORM_MAP_STREAM_ROLLOUT_SECRET`, and an approved
`MAP_PLATFORM_MAP_STREAM_PROMOTION_ID`; `all` also requires an approved
promotion ID. The Docker build derives `producerBuildSha256` from the exact
worker source, pipeline configuration, Python dependency inventory,
architecture-qualified system packages, and native platform inventory. The
worker executes directly from that hashed source tree, verifies the runtime
package location, recomputes the content identity at startup, and signs it into
every stream manifest. It is not accepted from a build argument or runtime
label, and an approval-only control-plane commit does not change it.
Percentage and global modes refuse to start unless the promotion, current
hardware-requirements hash, and every signing key match the checked-in approval
and production trust registries. They serve only artifacts whose signed worker
content, key material, requesting iOS build, and required device firmware
identity match that approval. Pin `MAP_PLATFORM_WORKER_IMAGE` as the immutable
`registry/repository@sha256:<digest>` reference used by the hardware run when
promoting. The same Compose value supplies the worker image and the API/worker
admission identity, while registry signature/provenance policy verifies that
digest before deployment. The API image may advance to carry the approval
record without rebuilding the tested worker. See
`docs/map-stream-rollout-runbook.md` for commissioning, hardware acceptance,
promotion, rollback, retention, and rotation.

Useful production environment variables:

- `MAP_PLATFORM_ADMIN_TOKEN`: separate server-only bearer token for worker,
  source-cache, maintenance, and downloaded-map inventory API routes. If unset,
  those routes are disabled; the normal worker loop and CLI maintenance remain
  available.
- `MAP_PLATFORM_MAX_ACTIVE_JOBS`: maximum queued/running jobs accepted by the
  API, default `25`.
- `MAP_PLATFORM_JOB_RETENTION_DAYS`: days to retain ready job artifacts,
  default `30`; must be between `1` and `3650`.
- `MAP_PLATFORM_MAINTENANCE_INTERVAL_SECONDS`: maintenance-service cleanup interval,
  default `3600`.
- `MAP_PLATFORM_MAINTENANCE_MAX_GC_ITEMS`: maximum content objects attempted
  per maintenance cycle, default `100`.
- `MAP_PLATFORM_WORKER_HEALTH_MAX_AGE_SECONDS`: maximum age of the real worker
  heartbeat, default `120`. Idle polls and the active job-lease thread refresh
  it, so queue-lock stalls become unhealthy without misclassifying long builds.
- `MAP_PLATFORM_ARTIFACT_STORE`: `filesystem` (default) or `s3`. Filesystem
  objects live on the persistent data volume and are written immutably by
  content key. Use `s3` for multi-host production durability.
- `MAP_PLATFORM_ARTIFACT_ROOT`: filesystem object root, default
  `$MAP_PLATFORM_DATA_ROOT/artifacts`.
- `MAP_PLATFORM_S3_BUCKET`, `MAP_PLATFORM_S3_PREFIX`, and optional
  `MAP_PLATFORM_S3_ENDPOINT_URL`: S3-compatible storage destination. Standard
  `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `AWS_REGION` configure the
  client. Grant only object read/write/delete within the configured prefix.
- `MAP_PLATFORM_S3_API_ACCESS_KEY_ID`,
  `MAP_PLATFORM_S3_API_SECRET_ACCESS_KEY`, and optional
  `MAP_PLATFORM_S3_API_SESSION_TOKEN`: separate short-lived API credentials
  restricted to presigning/reading objects. Worker credentials use the normal
  AWS variables, including `AWS_SESSION_TOKEN` when present. Workload-identity
  deployments may instead set
  `MAP_PLATFORM_S3_API_USE_DEFAULT_CREDENTIAL_CHAIN=1`; API S3 startup otherwise
  fails closed rather than silently inheriting worker credentials.
- `MAP_PLATFORM_DYNAMIC_SOURCE_DISCOVERY`: enable Geofabrik catalog fallback,
  default `1`.
- `MAP_PLATFORM_GEOFABRIK_INDEX_URL`: provider catalog URL, default
  `https://download.geofabrik.de/index-v1.json`.
- `MAP_PLATFORM_GEOFABRIK_INDEX_CACHE`: catalog cache path, default
  `$MAP_PLATFORM_DATA_ROOT/source-catalogs/geofabrik-index-v1.json`.
- `MAP_PLATFORM_GEOFABRIK_INDEX_TTL_SECONDS`: catalog cache TTL, default
  `86400`.
- `MAP_PLATFORM_GEOFABRIK_FAILURE_COOLDOWN_SECONDS`: fail-fast interval shared
  by concurrent catalog callers after an upstream failure, default `30`.

Completed jobs expose an `artifacts` array. A client refreshes the immutable
stream URL with:

```text
POST /v1/map-packs/{mapId}/artifacts/bike-map-stream-v1/download-url
  ?jobId={jobId}
  &clientInstallationId={installationId}
  &signedManifestReceipt={receipt}
```

Before creating v2 jobs, the app calls `POST /v1/installations` and stores
the returned installation ID and high-entropy token in the Keychain. Requests
for that registered installation send the token as `X-Installation-Token`.
Existing credentials periodically call the same endpoint with their installation
ID and token so the server can refresh them onto the current installation secret
before a previous secret is retired.
An app build with production stream keys also sends `X-Map-Stream-Trust` as a
comma-separated set of exact `keyId=SHA256(X9.63 public key)` capabilities.
It sends its `CFBundleVersion` as `X-Map-Stream-App-Build`. Without both
capabilities, or when a promoted build differs from the approval, the API keeps
returning only the ZIP artifact even if the installation is in the rollout
cohort.
Artifact URL refresh always requires this installation-bound credential; the
bundled app API token and a caller-supplied installation ID are not sufficient.
Issuance is stateless: the server writes no per-installation file, so repeated
bootstrap calls cannot consume the map data volume. New issuance is protected
by the persistent IP quota; authenticated refreshes remain subject to the
general public API quota.

The receipt is required for stream URL refresh, so an expired URL can be
replaced without changing artifact identity. Filesystem storage returns a
short-lived application-signed download route; S3 storage returns a short-lived
presigned GET URL.

For signing-key rotation, first ship the new public key in both trust stores,
then change the backend key ID/private key, retain the previous verification key
through the artifact-retention window, and remove it only after old artifacts no
longer need transfer. Object keys include the key ID, exact public-key
fingerprint, producer build SHA-256, and signed manifest receipt, so rotations
and candidate builds never overwrite one another.

Publication leases, superseded retry objects, terminal failures, and expired
artifacts feed a durable garbage-collection queue in job metadata. Maintenance
deletes each object outside the global job lock under a bounded striped fenced lock;
transient deletion failures remain queued and cannot stop normal worker jobs.
The production Compose shape runs this bounded work in a separate maintenance
service with its own heartbeat; the map-build worker never waits for S3 GC.
The durable round-robin cursor prevents one undeletable object from starving
later cleanup work.
The maintenance heartbeat allowance is derived from its configured interval, so
long but intentional sleep intervals do not trigger restart loops.

Tailscale SSH can still be used for bootstrap and incident response when browser
authorization has been completed, but normal deploys should go through Coolify.
