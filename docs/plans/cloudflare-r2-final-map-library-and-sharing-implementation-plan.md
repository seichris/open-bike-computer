# Cloudflare R2 final-map library and sharing implementation plan

## Status and baseline

This is the implementation and rollout plan for moving final processed offline
maps from environment-local Coolify volumes into Cloudflare R2, making maps
created by either the development or production service available to both app
channels, persisting rider-chosen map names, and adding revocable map-sharing
links.

The plan was prepared from freshly fetched GitHub main at commit
d5f49fc2ceb17495a66c80c8230311bca6427d49 on 2026-08-25. The existing dirty
checkout was not used as the branch base.

The implementation must preserve the current final map formats and their
contents:

- zip-stored-v1 remains the existing stored ZIP compatibility artifact;
- bike-map-stream-v1 remains the existing signed BIKEMAP1 delivery artifact;
- current 2D maps remain renderer format 2 with street-label data;
- current 3D maps remain renderer format 3 with street labels and 3D buildings;
- no OSM source extracts, intermediate blocks, chunk caches, worker scratch
  directories, job queues, or build receipts move to R2 as part of this work;
  and
- a future topographic capability can add another renderer feature/version
  without changing the R2 storage or sharing model.

This document proposes Cloudflare R2 for immutable map bytes, a small
Cloudflare Worker as the shared catalog and link gateway, and Cloudflare D1 for
queryable metadata. CloudKit is not part of this design. CloudKit could later
help with Apple-account-specific preferences, but it is not a suitable neutral
control plane for two Coolify services, web share links, Android or web clients,
or operator-side map publication.

## Outcome

When complete:

1. The development map worker writes only final artifacts to a private
   development R2 bucket.
2. The production map worker writes only final artifacts to a private
   production R2 bucket.
3. Both Bicino and Bicino Dev use one shared private map-library catalog.
4. A rider sees maps associated with their library regardless of whether those
   maps originated in development or production.
5. A rider-chosen name is a mutable library alias. Renaming never changes the
   map payload, mapId, content hash, object key, manifest, or signature.
6. A shared HTTPS link opens the production app when installed, otherwise a
   safe web landing page. The recipient previews the map and explicitly adds it
   to their own library before downloading.
7. A recipient starts with the sharer's chosen name but can rename their copy
   independently.
8. Development-origin map payloads can be used by the production app without
   giving the production app a development signing key. A production-approved
   publisher strictly validates and re-signs the already-final payload; it does
   not repeat OSM extraction or map generation.
9. Final map storage and catalog compute add no long-running container and no
   reserved RAM to either Coolify deployment. The existing services make S3
   and HTTPS requests to Cloudflare.

## Existing implementation to preserve

The repository already contains most of the artifact-storage seam:

- map-platform/backend/map_platform/artifacts.py provides filesystem and S3
  artifact stores, immutable content-addressed object keys, conditional
  PutObject, HEAD verification, ranged reads, presigned GET URLs, and deletion;
- map-platform/backend/map_platform/api.py issues 15-minute artifact download
  URLs and applies the current stream rollout and producer/signing checks;
- map-platform/backend/map_platform/models.py stores a job-scoped userLabel;
- the iOS app stores final map metadata next to the local artifact, allows local
  rename, and best-effort synchronizes that name to the owning map job;
- production and development already use separate map hosts, installation
  credentials, queues, data volumes, rollout settings, and signing policy; and
- the signed artifact identity already includes the signer, signer
  fingerprint, producer build, image digest, manifest receipt, and signed
  manifest receipt.

Important limitations in the current system are:

- job metadata is environment-local, so putting identical bytes in R2 does not
  make a production API discover a development job;
- userLabel belongs to one job and one server installation, not to a durable
  shared library;
- current production and development app bundles use separate sandboxes and
  server-specific installation credentials;
- stable mapId contains an immutable requested-name slug, so it should not be
  used as the new cross-environment content identity;
- current direct download authorization expects a job owned by the requesting
  installation; and
- the iOS target has no associated-domain entitlement or production map-share
  URL handler.

R2 solves durable bytes. The catalog, library identity, alias, authorization,
and share-link layers solve the rest.

## Architecture

~~~mermaid
flowchart LR
    DEVAPP["Bicino Dev"]
    PRODAPP["Bicino"]
    DEVAPI["maps-dev.8o.vc<br/>API + worker"]
    PRODAPI["maps.8o.vc<br/>API + worker"]
    CATALOG["maps-share.8o.vc<br/>Catalog Worker"]
    D1[("D1 map catalog")]
    DEVR2[("Private R2<br/>final maps - dev")]
    PRODR2[("Private R2<br/>final maps - prod")]

    DEVAPP --> DEVAPI
    PRODAPP --> PRODAPI
    DEVAPP --> CATALOG
    PRODAPP --> CATALOG

    DEVAPI -->|"final artifacts only"| DEVR2
    PRODAPI -->|"final artifacts only"| PRODR2
    DEVAPI -->|"authenticated finalize"| CATALOG
    PRODAPI -->|"authenticated finalize / promote"| CATALOG

    CATALOG --> D1
    CATALOG -->|"read-only S3 API"| DEVR2
    CATALOG -->|"read-only S3 API"| PRODR2
    CATALOG -->|"15-minute presigned R2 GET"| DEVAPP
    CATALOG -->|"15-minute presigned R2 GET"| PRODAPP
~~~

### Cloudflare resources

Provision these runtime resources:

| Resource | Purpose | Public access |
| --- | --- | --- |
| Private R2 bucket: bicino-final-maps-dev | Final ZIP and signed stream artifacts produced by development | Disabled |
| Private R2 bucket: bicino-final-maps-prod | Final ZIP and signed stream artifacts produced or promoted by production | Disabled |
| D1 database: bicino-map-catalog | Map entries, artifact locations, library aliases, shares, claims, and tombstones | Worker binding only |
| Worker: bicino-map-catalog | Library API, share landing page, AASA file, authorization, and short-lived R2 download redirects | maps-share.8o.vc |
| Staging equivalents | Migration and end-to-end testing without production data | Non-production hostname |

Use two R2 buckets rather than one bucket with dev and prod prefixes.
Long-lived R2 API tokens suitable for the current Coolify services are scoped
to named buckets; do not treat a key naming prefix as the environment's
security boundary. R2 temporary credentials can be narrowed to paths, but
would require a token broker and rotation lifecycle that the current deployment
does not have. Separate buckets ensure a development write/delete credential
has no authority over production objects.

Do not enable an r2.dev URL or a public custom domain on either bucket. R2
buckets are private by default, and the r2.dev endpoint is documented as a
non-production development path. All client access must be mediated by a
short-lived catalog download grant.

### Why D1 and a Worker

R2 custom metadata is useful for integrity fields but not for aliases or
sharing:

- aliases change while final objects must remain immutable;
- a map can have one alias per library and one title snapshot per share;
- revocation, expiry, claims, pagination, ownership, and garbage collection
  require indexed queries and atomic updates; and
- rewriting shared JSON index objects in R2 would introduce avoidable
  concurrency and lost-update risks.

D1 stores only small metadata rows. R2 stores all binary data. The Worker uses
a D1 binding plus separate bucket-scoped Object Read-only S3 credentials for
the two R2 buckets. Do not use R2 Worker bindings as a read-only security
boundary: a bound R2Bucket API can also write and delete. The S3 read-only
tokens let the Worker inspect objects and create short-lived GET URLs but not
mutate either bucket. D1 and Workers scale to zero, so this adds no
continuously allocated Coolify RAM.

## Identity model

Keep the current mapId unchanged for manifests, filenames, firmware activation,
and backward compatibility. Add identities for the shared catalog:

### mapEntryId

mapEntryId identifies one exact final map content family independently of its
mutable library alias, origin environment, and signing envelope.

Derive it from a canonical descriptor containing:

- the unsigned manifestReceipt when available;
- otherwise the ZIP SHA-256;
- renderer family;
- renderer format version; and
- normalized feature/capability identifiers.

Use a versioned value such as map_v1_<base64url-sha256>. The current
manifestReceipt already commits to the canonical displayName, mapId, source
snapshot, target, files, and manifest timestamp. Do not add mutable alias,
userLabel, jobId, installationId, origin environment, or signer ID outside that
receipt.

The content identity is deliberately exact. A newly generated map from a newer
OSM source snapshot is a new map entry even if it covers the same bounds.

### artifactId

artifactId identifies one exact byte object and is derived from its full
SHA-256. ZIP and BIKEMAP1 stream artifacts have separate artifact IDs. A
production re-sign of a development payload creates another stream artifact
under the same map entry because the signed envelope differs.

### libraryId

libraryId represents one rider's map library. It is not the production or
development generation installation ID and must not grant map-generation,
admin, rollout, or firmware-signing authority.

The first implementation should synchronize Bicino and Bicino Dev on the same
iPhone using a dedicated high-entropy library credential in a shared Keychain
access group. Both bundle IDs are signed by the same team, but this capability
must be proven with real provisioning profiles before it becomes a locked
dependency.

Fallback if the shared Keychain group cannot be used by both distribution
profiles:

1. each app receives a separate library credential;
2. one app displays a short-lived, one-time link code;
3. the other app explicitly accepts the code; and
4. the catalog merges the two principals into one library after both
   credentials prove possession.

This phase provides same-device, cross-app synchronization. Cross-device
recovery and multi-device synchronization require a future account identity,
for example Sign in with Apple. Do not silently treat an installation UUID as a
person.

## Catalog data model

Add numbered D1 migrations under map-platform/catalog/migrations. Store
timestamps as UTC ISO-8601 text or integer Unix seconds consistently. Use
prepared statements and indexes for every externally filtered field.

### libraries

| Column | Notes |
| --- | --- |
| id | Random libraryId, primary key |
| credential_hash | SHA-256 of the bearer credential; never store the raw token |
| created_at, updated_at | Audit timestamps |
| revoked_at | Null while active |
| schema_version | Credential and policy evolution |

Support multiple credentials per library in a separate library_credentials
table if the link-code fallback or future multi-device access is implemented.

### map_entries

| Column | Notes |
| --- | --- |
| id | mapEntryId, primary key |
| legacy_map_id | Existing mapId retained exactly |
| content_receipt | manifestReceipt or ZIP content identity |
| origin_channel | development or production; provenance, not an access secret |
| canonical_name | Immutable generated/manifest display name |
| source_region_name | Existing source label, if safe to expose |
| bounds_json | Preview bounds; disclosed only to authorized libraries/shares |
| renderer | Current esp32-fmb |
| renderer_format_version | Current 2 or 3 |
| features_json | Sorted values such as street-labels and 3d-buildings |
| attribution_json | OSM/source attribution required by the current pack |
| generated_at | Generation time |
| delivery_state | development, promotion_pending, production, blocked, tombstoned |
| created_at, updated_at | Catalog timestamps |

Do not add hard-coded is_2d, is_3d, or is_topographic columns. The renderer,
version, and feature list let a future map declare topography, elevation,
contours, or hillshade without a storage migration.

### artifacts

| Column | Notes |
| --- | --- |
| id | artifactId |
| map_entry_id | Foreign key to map_entries |
| bucket_slot | development or production; never return a physical bucket name to the app |
| object_key | Existing immutable object key |
| format, media_type, filename | Existing artifact contract |
| byte_count, sha256 | Required integrity fields |
| manifest_receipt, signed_manifest_receipt | Existing content/signing receipts |
| signature_key_id, signature_key_sha256 | Existing signing identity |
| producer_build_sha256, producer_image_digest | Existing producer identity |
| delivery_tier | development or production |
| state | live, quarantined, tombstoned, deleted |
| created_at, verified_at | Publication evidence |

Place a unique constraint on bucket_slot plus object_key and an index on
map_entry_id, format, delivery_tier, and state.

### library_maps

| Column | Notes |
| --- | --- |
| library_id, map_entry_id | Composite primary key |
| alias | Rider-chosen mutable name |
| alias_source | generated, creator, share, or user |
| added_at, updated_at | Library history |
| source_share_id | Optional provenance without exposing another library |

The current 80-character and 240-byte server limits are a suitable initial
contract. Also apply Unicode normalization, trim whitespace, reject control
characters, and escape the name in HTML. Never use the alias in an R2 key,
filename, URL path, log field, or SQL string.

### shares

| Column | Notes |
| --- | --- |
| id | Random internal share ID |
| token_hash | SHA-256 of at least 192 random token bits; unique |
| owner_library_id | Creator of the share |
| map_entry_id | Shared map |
| title_snapshot | Alias copied at share creation |
| created_at | Creation time |
| expires_at | Optional; null means valid until revoked |
| revoked_at | Immediate logical revocation |
| claim_count | Bounded analytics/abuse counter |

The raw share token appears only in the returned URL and is not recoverable from
D1. The title is a snapshot so a later rename by the sharer does not silently
change a message already sent to a friend.

Revocation prevents new previews and claims. It cannot remotely delete a map
that a recipient already claimed, downloaded, or installed; the share UI must
state that plainly.

### share_claims and publication_events

Record idempotent share claims by recipient library, and retain bounded
publication/promotion events keyed by an idempotency key. Do not store raw
installation tokens, R2 credentials, share tokens, exact IP addresses, or
download URLs in these tables.

## Naming behavior

Use three distinct names:

1. canonicalName is the immutable name present when the map was generated.
2. alias is the private name a particular library gives the map.
3. titleSnapshot is the alias included in one share at share creation.

The app display priority is:

1. the current library alias;
2. a received share's title snapshot when first claimed;
3. canonicalName;
4. the current source-region/mapId fallback policy.

Renaming a cached map performs two durable writes:

- update the local SavedMapArtifactMetadata immediately; and
- PATCH the shared library alias, retrying idempotently in the background.

Keep the existing job-scoped userLabel endpoint during migration. The app
should dual-write it for compatibility until all supported app builds use the
catalog. The catalog becomes the long-term source of truth for library names.

Names remain private by default. Do not derive a public “most popular” map name
from riders' aliases without a separate opt-in, privacy review, moderation
policy, and abuse controls.

## Cross-environment access and production trust

Origin is provenance, not the final client access rule. Artifact eligibility is
determined by the requesting app channel and the existing producer/signing
contract.

| Request | Result |
| --- | --- |
| Dev app requests a dev artifact compatible with its build | Allowed |
| Dev app requests a production artifact compatible with its build | Allowed |
| Production app requests a production-tier artifact | Allowed through the current rollout/trust checks |
| Production app requests an unpromoted dev-tier artifact | Show metadata, start/observe promotion, do not download it |
| Production app requests a promoted production-tier variant of dev content | Allowed |

Do not make the production app trust a development private key, copy a
production signing key into the development deployment, or weaken the existing
app/firmware identity checks.

### Final-payload promotion

Implement an idempotent production promotion operation:

1. The catalog issues a short-lived internal promotion grant for the exact
   development ZIP artifact.
2. The production publisher downloads the final ZIP through the catalog; it
   receives no development bucket credential.
3. It verifies expected byte count, full SHA-256, every manifest file hash,
   renderer/version/features, path limits, and the current strict pack
   validator.
4. It rejects unknown features, unsupported renderer versions, unsafe paths,
   missing attribution, inconsistent map IDs, or any artifact whose catalog
   metadata differs from its bytes.
5. The production-approved worker packages the unchanged map payload in the
   existing bike-map-stream-v1 envelope and signs it with the active approved
   production identity.
6. It writes the resulting stream to the production R2 bucket using the
   existing immutable object-key rules.
7. It registers the production-tier artifact against the same mapEntryId.
8. Only then does the catalog mark the entry production-downloadable.

This can run automatically on first production-library import or explicitly
from an authenticated operator action. Start with explicit or allowlisted
on-demand promotion, measure it, then make it automatic after the validation
and abuse gates pass.

Promotion reuses final map data and does not download OSM source data or repeat
extraction, clipping, label shaping, building preprocessing, chunking, or final
map assembly. The BIKEMAP1 signing envelope and artifact hash change; the map
payload does not.

## R2 object contract

Continue using the current immutable logical object keys:

- maps/{mapId}/zip-stored-v1/{sha256}.zip
- maps/{mapId}/bike-map-stream-v1/{signer}/{fingerprint}/{producer}/{image}/{signedReceipt}.bmap

The environment's MAP_PLATFORM_S3_PREFIX may add one fixed implementation
prefix, but no alias, library ID, installation ID, or share token may enter the
key.

Configure the S3 client with:

- endpoint https://<account-id>.r2.cloudflarestorage.com;
- region auto;
- a bucket-scoped credential;
- a known Content-Length for every single-part upload; and
- bounded retries that preserve current conditional immutability.

The existing R2 compatibility spike must exercise the exact boto3 calls used by
S3ArtifactStore. Cloudflare currently documents conditional PutObject,
HeadObject, ranged GetObject, CopyObject, multipart operations, and region
auto. Its current S3 compatibility table does not advertise a full-object
SHA-256 checksum for ordinary PutObject in the same way AWS S3 does. Therefore:

1. test the current ChecksumSHA256 request against a disposable R2 bucket;
2. if R2 rejects it, keep the application SHA-256 in custom metadata and use
   supported Content-MD5 for transport corruption detection on single-part
   uploads;
3. retain local full-SHA verification before upload and metadata/length
   verification after upload;
4. perform a sampled or migration-time streamed GET and full SHA-256 check;
5. use multipart upload only when required by measured reliability or object
   size; and
6. never silently remove end-to-end SHA-256 from the catalog or iOS verifier.

Use R2 Standard storage initially. Published maps are user-downloadable and may
be read unpredictably. Infrequent Access has retrieval charges and a minimum
storage duration, so it should be considered only after real access data
demonstrates a saving.

## R2 credentials and Coolify configuration

Create distinct credentials:

| Principal | R2 authority |
| --- | --- |
| Development map worker/maintenance | Object read/write only on the development bucket |
| Development API fallback downloader | Object read only on the development bucket |
| Production map worker/maintenance | Object read/write only on the production bucket |
| Production API fallback downloader | Object read only on the production bucket |
| Catalog Worker | Separate Object Read-only S3 credentials for both buckets |
| Human/CI infrastructure provisioning | Separate narrowly scoped admin token, never a runtime secret |

Do not share R2 write tokens between environments. Rotate one credential without
rotating the others. Keep all values in Coolify or Cloudflare secrets; commit
only variable names and validation.

Set the existing map-platform variables per Coolify application:

- MAP_PLATFORM_ARTIFACT_STORE=s3 after the shadow phase;
- MAP_PLATFORM_S3_ENDPOINT_URL to the account R2 endpoint;
- AWS_REGION=auto;
- MAP_PLATFORM_S3_BUCKET to that environment's bucket;
- MAP_PLATFORM_S3_PREFIX to a stable final-artifact prefix;
- worker/maintenance AWS credentials for that environment; and
- API read-only S3 credentials for same-environment compatibility endpoints.

Add environment-independent catalog settings:

- MAP_PLATFORM_CATALOG_URL;
- MAP_PLATFORM_CATALOG_CHANNEL;
- MAP_PLATFORM_CATALOG_SERVICE_KEY_ID; and
- MAP_PLATFORM_CATALOG_SERVICE_SECRET.

Authenticate Coolify-to-catalog finalize requests with separate
environment-specific HMAC secrets. Sign the method, canonical path, timestamp,
idempotency key, and body SHA-256. Reject stale timestamps, unknown key IDs, and
body mismatches. Support overlap during secret rotation.

## Catalog API contract

Version all endpoints and return bounded JSON. Use cursor pagination rather than
unbounded lists.

### App-facing endpoints

| Endpoint | Purpose |
| --- | --- |
| POST /v1/libraries/bootstrap | Create or refresh the shared library credential |
| POST /v1/libraries/link-codes | Optional fallback for linking dev and prod principals |
| POST /v1/libraries/link-codes/{code}/claim | Explicitly link a second app principal |
| GET /v1/library/maps | List maps attached to the authenticated library |
| GET /v1/library/maps/{mapEntryId} | Fetch one map and compatible artifact metadata |
| PATCH /v1/library/maps/{mapEntryId} | Update the private alias |
| POST /v1/library/maps/{mapEntryId}/shares | Create a stable share |
| GET /v1/library/shares | List active/revoked shares for management |
| DELETE /v1/library/shares/{shareId} | Revoke a share |
| GET /v1/shares/{token} | Return a privacy-bounded share preview |
| POST /v1/shares/{token}/claim | Add the shared map to the recipient library |
| POST /v1/library/maps/{mapEntryId}/download-grants | Select an eligible artifact and issue a short grant |
| GET /v1/downloads/{grant} | Validate the grant and redirect to a 15-minute presigned R2 GET |

The download-grant request must include the same exact app build identity and
map-stream trust capabilities used by the current map API. The catalog selects
only an artifact whose delivery tier and required identities are compatible.
The iOS app still validates every returned artifact field and the signed map
before local activation.

Download grants and the resulting R2 presigned GET expire after 15 minutes.
They are bearer credentials and must be scoped to one artifact, one operation,
one library, and one expiry. Do not put a permanent R2 URL or object key in a
share URL. The app must accept the redirect only to the exact configured R2 S3
account/jurisdiction endpoint over HTTPS.

### Internal endpoints

| Endpoint | Purpose |
| --- | --- |
| POST /v1/internal/publications/finalize | Atomically register a verified READY artifact set |
| POST /v1/internal/publications/{id}/attach-library | Prove job ownership and attach the creator's library |
| POST /v1/internal/promotions/{mapEntryId}/grant | Let the production publisher read one dev ZIP |
| POST /v1/internal/promotions/{mapEntryId}/finalize | Register the production-signed variant |
| POST /v1/internal/publications/{id}/quarantine | Block a conflicting or corrupt entry |

Finalize is idempotent. Repeating the same receipt returns the same mapEntryId.
The same object key with different bytes, receipts, or producer fields is a
hard conflict and quarantines the publication rather than applying
last-write-wins behavior.

## Share links and iOS deep linking

Use a stable URL such as:

    https://maps-share.8o.vc/s/<opaque-token>

The link is a catalog capability, not an R2 URL. By default it remains valid
until the sharer revokes it. A product setting may optionally add an expiry.
R2/download grants remain short-lived regardless of share lifetime.

### Universal-link routing

Serve an apple-app-site-association file without redirects from:

    https://maps-share.8o.vc/.well-known/apple-app-site-association

Add associated-domain entitlements and explicit path routing:

- production Bicino handles /s/*;
- Bicino Dev handles /dev/s/*; and
- both paths resolve the same underlying share token.

The public link uses /s/* so friends get the production app by default. The web
landing page includes an explicit “Open in Bicino Dev” link to /dev/s/* for
testers. This avoids asking iOS to choose unpredictably between two installed
apps claiming the same path.

When no app is installed, the page shows:

- the title snapshot;
- a bounded preview and area description;
- map type/features and approximate download size;
- required attribution;
- an App Store link;
- an Open in Bicino Dev option where appropriate; and
- no raw object key, installation ID, owner identity, or exact private
  metadata beyond what the sharer intentionally shared.

The app must validate HTTPS scheme, exact host, path shape, token length, and
allowed characters. Opening a link shows a preview and an Add Map confirmation;
it must never immediately download, install, rename, delete, or replace a map.

After claim:

1. the catalog inserts an idempotent library_maps row;
2. the recipient alias starts as titleSnapshot;
3. the recipient may rename it independently;
4. the app requests a fresh compatible download grant; and
5. the existing download, SHA/signature verification, local metadata, and
   optional device-transfer flow runs unchanged.

## App integration

### Configuration

Keep OfflineMapServiceConfig's hard build-channel boundary for generation:

- Bicino Dev creates jobs at maps-dev.8o.vc;
- Bicino creates jobs at maps.8o.vc.

Add a separate fixed catalog host shared by both builds. Do not allow a remote
response or user default to substitute an arbitrary catalog/download host.
Allow only maps-share.8o.vc and the exact Cloudflare staging host in
development/test configurations.

### Models and local metadata

Extend SavedMapArtifactMetadata with optional, backwards-compatible fields:

- catalogMapEntryID;
- catalogLibraryID or a non-secret local credential reference;
- originChannel;
- catalogAliasRevision;
- sourceShareID; and
- catalogSyncState.

Do not replace the existing mapID, serverURLString, jobID, installationID,
primaryArtifact, legacyArtifact, or transfer receipts. Old local map metadata
must continue to decode.

### Library UI

Evolve the saved maps list to merge:

- locally cached artifacts;
- current environment-local build jobs; and
- shared catalog library entries.

One logical map row may be:

- available locally;
- available in R2 but not downloaded;
- being generated;
- awaiting production promotion;
- incompatible with this app/firmware;
- shared with the rider; or
- unavailable because a share was revoked before claim.

Show origin as small diagnostic metadata where useful, especially in Bicino
Dev. Do not make origin the primary title. The user-facing distinction is
availability and compatibility.

### Ownership bridge for existing jobs

An app must not attach an arbitrary job ID to its library. Add an
installation-authenticated origin-server operation that proves the caller owns
the job and then posts a signed internal attach request to the catalog.

On first catalog adoption:

1. bootstrap or load the shared library credential;
2. fetch the current installation's READY jobs from the build-channel server;
3. ask that server to attach each owned job to the library;
4. import existing userLabel values as aliases;
5. reconcile matching local cached artifacts; and
6. retain the old server job records for rollback.

New jobs carry a short-lived catalog-issued library binding proof or use the
same post-create ownership bridge. Raw library IDs alone are not proof.

## Future topographic maps

R2 is format-agnostic, so no storage redesign is required for topography.

When topographic maps are implemented:

- add a reviewed renderer format version only if the device byte contract
  changes;
- add feature values such as elevation, contours, or hillshade;
- include any new assets in the existing manifest, hashes, size ceilings, and
  signature;
- teach catalog compatibility selection and the iOS preview to describe the
  new capability;
- keep current 2D and 3D artifacts valid and downloadable; and
- do not infer topography from a filename or bucket path.

This plan does not define the topographic data source, licensing, resolution,
device rendering, preprocessing, or firmware memory budget.

## Retention and garbage collection

Do not apply an age-only R2 lifecycle deletion rule to final published map
prefixes. R2 cannot know whether a D1 library or share still references an
object.

Make the catalog the authority for published final-object retention:

1. a live library_maps row retains its map entry;
2. an unrevoked share retains its entry until expiry plus a grace period;
3. active promotion and publication operations retain their input artifacts;
4. zero-reference entries become tombstoned, not immediately deleted;
5. a scheduled Worker rechecks references after a configurable 30-day grace
   period and issues an environment-scoped, short-lived deletion authorization;
6. the owning Coolify maintenance service rechecks the authorization and
   catalog state, deletes only from its own bucket, and reports the result;
7. deletion is idempotent and updates artifacts.state only after R2 confirms
   absence; and
8. a recreated reference before physical deletion cancels the tombstone.

The current Coolify job maintenance must not delete a catalog-published object
solely because its generation job aged out. Add a catalog publication receipt
or retention lease to the job record and delegate final-object deletion to the
catalog. Job JSON, source caches, build chunks, and scratch data remain under
the existing Coolify retention policies.

R2 lifecycle rules may still:

- abort incomplete multipart uploads after the platform default/grace window;
- remove explicitly temporary migration objects under a dedicated prefix; and
- transition data only after measured cost evidence and a separate review.

## Cost model and guardrails

Cloudflare's pricing pages must be rechecked at implementation time. As of this
plan:

- R2 Standard includes 10 GB-month, one million Class A operations, and ten
  million Class B operations monthly, then lists Standard storage at
  $0.015/GB-month; direct R2 egress is free;
- Workers Free lists 100,000 requests per day, while the paid Workers plan has
  a base subscription and included monthly requests/CPU;
- D1 Free lists five million rows read per day, 100,000 rows written per day,
  and 5 GB total storage; and
- D1 bills for rows and storage rather than a continuously running database
  instance.

Authoritative references:

- [R2 pricing](https://developers.cloudflare.com/r2/pricing/)
- [R2 S3 compatibility](https://developers.cloudflare.com/r2/api/s3/api/)
- [R2 authentication and bucket-scoped tokens](https://developers.cloudflare.com/r2/api/tokens/)
- [R2 consistency](https://developers.cloudflare.com/r2/reference/consistency/)
- [R2 lifecycle rules](https://developers.cloudflare.com/r2/buckets/object-lifecycles/)
- [Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/)
- [D1 pricing](https://developers.cloudflare.com/d1/platform/pricing/)
- [Apple associated domains](https://developer.apple.com/documentation/xcode/supporting-associated-domains)

Estimate storage with:

    retained unique final GB × current R2 Standard GB-month price

ZIP and BIKEMAP1 artifacts are alternate delivery forms that may contain much
of the same payload, so measure retained bytes rather than assuming one map
equals one object. Deduplicate exact byte-identical artifacts by SHA-256 and
avoid copying objects merely to change a display name.

Add these guardrails before production:

- Cloudflare usage alerts and a monthly budget alarm;
- dashboards for stored bytes by bucket, Class A/B operations, Worker
  requests/CPU, and D1 rows read/written;
- indexed cursor queries to prevent D1 table scans;
- per-library and per-IP share creation/resolve/claim limits;
- per-library retained-map limits with a clear product error;
- bounded share preview responses and no unauthenticated catalog enumeration;
- rate limits and concurrency caps on production promotion;
- a zero-reference retention report before enabling physical deletion; and
- sampled download and R2-integrity checks.

Start with Standard storage and direct 15-minute R2 S3 presigned GET downloads.
A presigned URL remains a bearer credential, works only on the R2 S3 domain,
and must never replace the stable revocable share URL. This path reuses the
repository's existing presigned-download model and keeps map bytes out of
Worker memory.

## Implementation phases

### Phase 0: ADR and live compatibility spike

Deliver:

- a short architecture decision record confirming Worker + D1 versus shared
  Postgres;
- disposable development R2 and D1 resources;
- a script or integration test exercising the exact boto3 adapter calls;
- a shared-Keychain provisioning spike for both app bundle IDs; and
- a measured large-object presigned R2 range/resume spike.

The R2 spike must prove:

- PutObject with known length and If-None-Match;
- supported transport checksum behavior;
- custom SHA-256 metadata round-trip;
- HEAD length/metadata verification;
- conflict handling;
- range GET, cancelled download, and resume;
- delete and missing-object behavior;
- a representative 2D and 3D artifact;
- an object near the current 512 MiB stream payload ceiling; and
- no whole-object buffering in Python, the Worker, or iOS.

Exit gate: document the exact supported request shape and update the plan if R2
behavior differs. No production bucket or credentials are introduced in this
phase.

### Phase 1: Cloudflare project and schema

Create map-platform/catalog with:

- TypeScript Worker source;
- wrangler configuration with explicit staging and production bindings;
- generated binding types;
- numbered D1 migrations;
- request/response schemas;
- local Miniflare/Wrangler tests;
- deployment and rollback runbooks; and
- CI for type checking, formatting, unit tests, migration checks, and a
  deployment dry run.

Implement health, AASA, service-HMAC verification, library bootstrap, and
read-only catalog primitives first. Bind staging to disposable buckets.

Exit gate: clean-database and migrated-database tests pass locally and against
staging; secrets do not appear in Git or logs.

### Phase 2: R2 artifact adapter and shadow writes

In map-platform/backend:

- make the R2-specific checksum behavior explicit and tested;
- add a mirrored artifact-store mode for controlled migration;
- retain immutable keys and existing artifact records;
- separate final artifact publication from local source/cache/work paths;
- add R2 endpoint/region startup validation;
- expose non-secret artifact backend/channel status in health/admin
  diagnostics;
- keep API read credentials separate from worker/maintenance credentials; and
- add failure metrics without logging object URLs or credentials.

Roll out to development with filesystem authoritative and R2 shadow writes.
Compare bytes, SHA-256, metadata, manifest receipts, and object counts. Repair
or retry missing shadow objects idempotently.

Exit gate: a retained observation window has zero unexplained mismatches and
development can read an exact shadow artifact through the staging catalog.

### Phase 3: Publication and shared catalog

Add backend publication receipts and an internal catalog client:

- register only READY jobs after all existing artifact verification succeeds;
- derive mapEntryId and artifactId deterministically;
- attach the creator's library through an ownership proof;
- persist publication status/idempotency in job metadata;
- retry finalize after transient Cloudflare errors;
- quarantine conflicts;
- prevent current job cleanup from deleting catalog-retained objects; and
- backfill existing READY development jobs.

Implement catalog list/detail/alias APIs and library credential rotation.

Exit gate: one library sees production-origin and development-origin metadata
through the same API, aliases remain independent of object bytes, and no
unauthenticated caller can enumerate another library.

### Phase 4: Production-safe promotion

Implement the final-payload promotion operation in the production backend:

- short-lived internal input grant;
- strict ZIP/manifest/renderer validation;
- approved producer identity and signing;
- immutable production-bucket publication;
- idempotent catalog finalize;
- explicit failure/quarantine codes;
- bounded queue/concurrency; and
- operator status/metrics.

Test the complete compatibility matrix. Do not widen any existing map-stream
rollout or trust gate merely because the artifact is in R2.

Exit gate: the exact payload of a development 2D map and a development 3D map
is production-repackaged without OSM regeneration, accepted by the production
app trust contract, and rejected after any byte or metadata substitution.

### Phase 5: iOS shared library and aliases

Add:

- shared catalog configuration;
- shared library Keychain credential or the reviewed link-code fallback;
- backwards-compatible catalog models;
- catalog/local/job reconciliation;
- alias sync with offline retry;
- origin, availability, compatibility, and promotion state in saved-map UI;
- ownership bridge/backfill for existing jobs; and
- unit tests for merge, conflict, rename, retry, migration, and old metadata.

Keep current generation hosts fixed by build channel.

Exit gate: with Bicino and Bicino Dev installed on one test iPhone, a rename in
either app appears in the other after sync, while local download and device
activation still use the existing verified artifact flow.

### Phase 6: sharing and universal links

Implement:

- share creation/list/revocation;
- privacy-bounded HTML previews;
- token hashing and expiry/revocation policy;
- claim and recipient alias creation;
- AASA hosting;
- production and development associated-domain paths;
- strict URL parsing;
- Add Map confirmation;
- system share sheet integration; and
- web/App Store fallback.

Exit gate: Messages/Mail/Safari tests cover production installed, only dev
installed, neither installed, both installed, revoked, expired, malformed,
already claimed, incompatible, and promotion-pending cases.

### Phase 7: production migration

Use a reversible sequence:

1. inventory both environment-local final artifacts and catalogable READY
   jobs without mutating them;
2. upload and full-hash verify existing development artifacts;
3. enable development R2 reads with filesystem fallback;
4. enable the shared catalog in Bicino Dev;
5. retain filesystem copies through the observation window;
6. repeat shadow upload and verification for production;
7. enable production R2 reads for an allowlisted app cohort;
8. enable production catalog reads without cross-origin downloads;
9. enable production promotion for an allowlisted cohort;
10. validate cross-environment imports and shares;
11. make R2 authoritative for new final artifacts; and
12. remove obsolete final artifact files only after a separate inventory,
    backup, retention, and deletion approval.

The Coolify volume remains required for job state, queues, caches, source data,
worker coordination, and logs. This migration reduces final-artifact disk use;
it does not eliminate the volume or the map worker's RAM requirement.

### Phase 8: operations and cost hardening

Add:

- catalog, R2, publication, promotion, share, and download dashboards;
- alerts for finalize backlog, quarantine, R2/D1/Worker errors, cost, and
  integrity mismatch;
- D1 export and time-travel recovery drills;
- an R2 inventory/hash audit;
- secret rotation drills;
- tombstone/GC dry runs followed by allowlisted deletion;
- abuse reporting and emergency share revocation;
- a no-catalog fallback for existing same-environment downloads; and
- runbooks for Cloudflare outage, Coolify outage, partial publication, and
  compromised credentials.

Exit gate: staging recovery and rollback drills complete without losing an
alias, share record, or referenced artifact.

## Verification plan

### Static and unit verification

- Python artifact identity and R2 adapter tests;
- catalog ID canonicalization and schema tests;
- D1 migration-upgrade tests from every released schema;
- prepared-statement and authorization tests;
- Swift decoding of old and new metadata;
- alias normalization and Unicode/control-character tests;
- share token, expiry, revocation, claim, and replay tests;
- strict URL allowlist/parser tests;
- app list reconciliation and retry tests; and
- no-secret/no-raw-token log tests.

### Integration verification

- real R2 conditional upload, HEAD, range GET, resume, conflict, and delete;
- real D1 read-after-write paths needed by claim and rename;
- catalog redirect plus presigned R2 Content-Length, Content-Type,
  Content-Disposition, ETag, Accept-Ranges, 206, and 416 behavior;
- finalize retry after R2 success but before D1 success;
- D1 success followed by client retry;
- simultaneous alias updates with deterministic last accepted revision;
- duplicate publication and duplicate share claim;
- dev/prod bucket credential isolation;
- production publisher tamper rejection;
- 2D, 3D, ZIP fallback, and signed-stream artifacts;
- future unknown feature rejected safely rather than downgraded; and
- full current artifact size ceiling without memory buffering.

### Security verification

- buckets remain private and r2.dev disabled;
- dev credentials cannot read/write/delete the production bucket;
- API read credentials cannot write/delete;
- catalog app endpoints reject service credentials and internal endpoints
  reject library credentials;
- a leaked stable share URL cannot become an R2 write credential;
- revoked shares cannot be claimed again;
- an already issued 15-minute download expires normally after revocation;
- no endpoint permits cross-library enumeration;
- title/alias HTML and log injection tests;
- rate-limit and denial-of-wallet tests;
- invalid AASA/deep-link input cannot perform a destructive action; and
- production refuses unpromoted dev-tier artifacts.

### Deployed verification

Label evidence separately:

- staging Cloudflare resources and Worker revision;
- development Coolify R2 shadow/read state;
- production Coolify R2 shadow/read state;
- D1 migration version;
- bucket public-access state and token scope;
- real upload/download receipts and hashes;
- Worker/D1/R2 cost metrics; and
- rollback results.

A healthy endpoint or successful deployment does not prove app or hardware
acceptance.

### Physical-device verification

On supported iPhones:

- test production-only, dev-only, both-app, and no-app share-link routing;
- test rename synchronization between installed app variants;
- interrupt and resume a large R2 download;
- verify local artifact SHA/signature and metadata after download; and
- transfer/install representative 2D and 3D maps through the existing device
  flow.

On each supported Waveshare target, separately prove that migrated/downloaded
artifacts activate and render exactly as their pre-R2 equivalents. Topographic
maps require a later hardware plan.

## Rollback

Rollback is layered:

1. Disable catalog discovery/share UI by a server-controlled capability while
   retaining current per-server jobs and local cached maps.
2. Route same-environment artifact reads through the existing API and R2
   adapter.
3. During the mirrored window, switch MAP_PLATFORM_ARTIFACT_STORE back to
   filesystem for generation and download.
4. Roll the catalog Worker back to its previous immutable version and, if
   required, restore D1 using Time Travel/export.
5. Stop production promotion without disabling ordinary production map
   generation.

Never roll back by making a bucket public, copying production signing material
into development, accepting an unsigned stream, or deleting D1/R2 data.

Maps created after filesystem dual-write ends may exist only in R2, so the
long-term rollback path keeps the same-environment R2 adapter available even if
the shared catalog is disabled.

## Acceptance criteria

The implementation is complete only when:

1. current 2D and 3D payload bytes are unchanged by the storage migration;
2. final ZIP and BIKEMAP1 artifacts are stored in private R2 buckets;
3. intermediate/source/queue/cache data remains outside R2;
4. dev write credentials have no production-bucket authority;
5. both apps list library maps originating from both services;
6. the production app downloads dev-origin content only through a
   production-approved artifact variant;
7. current rollout, signer, producer, app, firmware, SHA, and manifest checks
   remain fail-closed;
8. a rider alias survives app restart and server job cleanup;
9. the same linked library sees aliases in Bicino and Bicino Dev on one iPhone;
10. renaming does not alter mapId, object key, manifest, artifact hash, or
    another rider's alias;
11. a stable HTTPS share can be revoked without changing or deleting the map;
12. claiming a share creates an independent recipient alias and requires
    explicit confirmation;
13. a share never exposes permanent R2 access or credentials;
14. large downloads support cancellation/resume without whole-object memory
    buffering;
15. existing locally cached maps and old app metadata remain usable;
16. catalog or Cloudflare failure does not corrupt an existing map/job;
17. cost and usage dashboards/alerts are active before broad production
    rollout;
18. recovery and rollback are exercised in staging;
19. no new continuously running Coolify service is required; and
20. adding a future topographic feature does not require a new storage,
    library, alias, or sharing schema.

## Decisions to confirm before implementation

Recommended defaults are shown first:

1. Share lifetime: valid until explicitly revoked, with optional user-selected
   expiry.
2. Production handling of dev maps: allowlisted on-demand strict repackage and
   re-sign first, then automatic after evidence.
3. Cross-app identity: shared Keychain library credential on the same iPhone,
   with link-code fallback.
4. Cross-device identity: out of scope until an account/authentication design
   is approved.
5. Catalog visibility: private library only; no public global map browser.
6. Storage class: R2 Standard until measured access data justifies a change.
7. Download delivery: short-lived presigned R2 GET after catalog authorization.
