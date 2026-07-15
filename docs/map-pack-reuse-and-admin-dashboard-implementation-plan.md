# Map Pack Reuse and Admin Inventory Implementation Plan

## Outcome

Deliver one production feature across the offline-map backend, iOS app, and
`bicino.com`:

1. Reuse an existing ready artifact for an identical request.
2. Build a smaller bounding-box map from complete 4,096 m blocks in a larger
   compatible ready map instead of running the OSM extraction pipeline again.
3. Record maps that were actually and successfully downloaded to an iPhone.
4. Sync the name a user gives a saved map.
5. Show those records in a protected Bicino admin page, including both the
   user name and the resolved Geofabrik area name.

The backend remains the source of truth for inventory. A `ready` job is not
counted as downloaded until the iOS app has validated and durably saved an
artifact and acknowledged that result.

## Repositories and ownership

- `open-bike-computer`
  - backend data model, reuse selection and packaging, installation-authenticated
    inventory endpoints, admin API, and tests
  - iOS download acknowledgement, rename sync, and existing-cache backfill
- `bicino`
  - protected `/admin/maps` server-rendered inventory dashboard

No user installation token, raw installation ID, admin bearer token, or admin
password may be sent to browser JavaScript or included in public HTML.

## Backend data model

Add backward-compatible optional fields to each persisted `MapJob`:

- `userLabel`: the explicit name supplied by the user; separate from the map
  manifest display name and Geofabrik source name
- `buildCacheKey`: exact-output identity
- `buildCompatibilityKey`: source, target, block format, and producer identity
  shared by maps that may safely exchange blocks
- `reuseStrategy`: `exact` or `subset`
- `reuseSourceJobId`: retained internally and exposed only to admins
- `downloadReceipts`: idempotent acknowledgements with receipt ID, artifact
  format, SHA-256 when available, bytes, and timestamp

Public job responses include the user label, download summary, and reuse
strategy. Cache keys, receipt IDs, and the source job ID remain internal.
Existing job JSON without the new fields continues to decode.

## Reuse identity and safety invariants

Reuse is fail-closed. A candidate is eligible only when all of these match:

- current cache schema version
- source provider, region ID, URL, publication date, declared checksum, and the
  actual cached PBF snapshot SHA-256
- requested target and renderer format
- immutable producer build SHA-256 and worker image digest
- supported geometry mode

The exact key additionally includes normalized requested geometry and the
legacy request-level pack display name because it is embedded in the manifest.
The separate post-download user label, installation IDs, request IDs,
timestamps, and install intent are deliberately excluded because they do not
change usable map content.

Artifacts created before this release can still appear in inventory after iOS
backfill, but are not silently reused when their compatibility identity is
missing or differs from the running worker.

### Complete block rule

The renderer uses Web Mercator blocks aligned to 4,096 m boundaries. New
`custom_bbox` builds expand their processing bounds to whole block boundaries
while preserving the user-requested bounds in the job and manifest. This makes
every emitted boundary block complete and makes a block copied from a compatible
parent equivalent to the block produced by a fresh child build.

Subset reuse is allowed only when:

- both parent and child use `custom_bbox`
- their compatibility keys match
- the parent's block-aligned processing bounds contain all of the child's
  block-aligned processing bounds
- the parent is still `ready` and its immutable local ZIP is present
- the parent manifest, entry sizes, and SHA-256 values validate

Any failed check falls back to the normal build. Corrupt candidates are never
published. Polygon and route-corridor requests initially use exact reuse only.

## Worker flow

For each claimed job:

1. Calculate and persist exact and compatibility keys.
2. Look for a ready exact-key candidate.
   - Atomically reference the same legacy pack and immutable artifacts.
   - Keep the new job, ownership, label, and download history independent.
3. Otherwise find the smallest compatible containing bounding-box candidate.
   - Verify its manifest and selected block hashes.
   - Copy only required `.fmb`/`.fmp` entries under the new map ID.
   - Generate a new manifest, deterministic ZIP, and signed stream artifact.
4. If no valid candidate exists, run the full source/extract/convert/package
   pipeline.

Retention already protects shared legacy paths and object keys while any
non-expired job references them. Tests must preserve that property.

## Installation-authenticated API

### `PATCH /v1/map-jobs/{jobId}/display-name`

Query and auth are the same installation-scoped credentials used by existing
job endpoints.

Request:

```json
{ "displayName": "Shanghai to Suzhou" }
```

The backend trims the value, rejects control characters and names longer than
80 Unicode characters, verifies job ownership, and stores it as `userLabel`.

### `POST /v1/map-jobs/{jobId}/downloads`

Request:

```json
{
  "receiptId": "a stable UUID for this completed download",
  "artifactFormat": "bike-map-stream-v1",
  "sha256": "artifact SHA-256",
  "bytes": 123456
}
```

The backend verifies ownership, ready status, and artifact identity. Repeating
the same receipt is a no-op, allowing safe retries and app-launch backfill.

## iOS behavior and migration

- After artifact validation and the atomic move into the saved-map cache, save
  a stable download receipt ID in the sidecar and acknowledge the download.
- Acknowledgement failure does not discard a valid local map; the next app
  activation retries it.
- A rename updates local UI immediately, marks the sidecar name as explicitly
  user-defined, and syncs it in the background.
- On app activation, scan saved-map sidecars belonging to the current registered
  installation and server, then idempotently resend download receipts and user
  labels.
- For older sidecars that predate the explicit-name flag, compare their local
  name with the resolved Geofabrik name to infer whether the user renamed them,
  then persist that inference.
- Sidecars owned by an obsolete installation identity are left local rather
  than weakening server authorization.

This backfill is how an already-downloaded Shanghai–Suzhou map becomes visible
in the dashboard after the updated app next opens, provided its saved sidecar
still has a server job ID and matches the current installation credential.

## Admin API

Add `GET /v1/admin/maps`, protected by `MAP_PLATFORM_ADMIN_TOKEN`. By default it
returns only jobs with at least one successful download receipt.

Each row includes:

- job and map ID
- user label and effective display name
- Geofabrik provider, area ID, and area name
- requested bounds and area in km²
- artifact formats and stored bytes
- first/last successful download and count
- reuse strategy and source job ID
- created/ready timestamps
- keyed, pseudonymous installation reference (never the raw installation ID)

Summary totals include downloaded map jobs, successful download receipts,
unique installations, downloaded bytes, and reused map jobs.

## Bicino admin dashboard

Create `/admin/maps` in the Next.js App Router:

- server-rendered and `cache: "no-store"`
- excluded from search indexing
- HTTP Basic challenge at the route boundary using
  `BICINO_ADMIN_USERNAME` and `BICINO_ADMIN_PASSWORD`
- credentials revalidated in the Server Component, not only in `proxy.ts`
- backend data fetched server-side with `MAP_PLATFORM_ADMIN_BASE_URL` and
  `MAP_PLATFORM_ADMIN_TOKEN`
- responsive summary cards and a table showing user name, Geofabrik area,
  requested area, artifact size, download activity, and reuse status
- explicit empty, configuration-error, authorization-error, and upstream-error
  states without leaking secrets

Required Bicino server-only environment variables:

```text
BICINO_ADMIN_USERNAME
BICINO_ADMIN_PASSWORD
MAP_PLATFORM_ADMIN_BASE_URL
MAP_PLATFORM_ADMIN_TOKEN
```

None use the `NEXT_PUBLIC_` prefix.

## Deployment sequence

1. Deploy backend model/API changes (backward compatible).
2. Deploy a worker image containing complete-block processing and reuse logic.
3. Configure and deploy the Bicino admin route.
4. Release the iOS update with receipt/name sync and backfill.
5. Confirm the dashboard remains empty until a real acknowledgement arrives.
6. Open the updated app containing an existing saved map and confirm one
   idempotent row appears with the Geofabrik name and any inferred custom name.
7. Submit an exact request and a safely contained request; confirm `exact` and
   `subset` reuse respectively, then verify both artifacts on iOS and hardware.

Rollback is independent: disable or roll back the worker to stop new reuse,
remove the Bicino environment variables to fail the admin page closed, and keep
the additive job fields/API data intact.

## Verification and acceptance criteria

- Backend unit tests cover key stability, incompatible source/producer rejection,
  complete-block math, exact reuse, subset packaging/hash validation, corruption
  fallback, shared-artifact retention, receipt idempotency, ownership boundaries,
  label validation, and admin redaction.
- Existing backend tests remain green.
- The iOS project builds for a generic device and request construction is
  covered by deterministic helpers where the project has no unit-test target.
- Bicino unit tests, lint, and production build pass; generated output contains
  no admin secret.
- Exact reuse does not invoke source download, Osmium, conversion, or packaging.
- Subset reuse invokes only verification and packaging, not source download,
  Osmium, or feature extraction.
- A failed safety check produces a normal full build, never a partial pack.
- Only successfully saved phone downloads appear in `/admin/maps`.
- The dashboard shows user label and Geofabrik area in separate columns.
