# Social riding rollout and operations

Profile, Friends & Group Rides is available by default in Bicino and Bicino Dev.
Signing in and sharing remain optional. Existing navigation, installation
credentials, BLE ownership, and local workouts remain independent of a Bicino
account. Service deployments retain their provider, privacy, and acceptance gates.

## Identity and native configuration

Use bicino.com's **same production Firebase project** for the production iOS app.
Register `LetItRide.BikeComputer`; use a separate development project and
`LetItRide.BikeComputer.dev` for Debug. Register Apple native App IDs and associate
the website Services ID so both surfaces resolve to the same provider identity.
Enable native Sign in with Apple and Push Notifications in the developer portal.
Register the Google iOS client and reversed client-ID callback scheme. Do not
copy server credentials into Xcode or the application bundle.

The checked-in `Development.xcconfig` and `Production.xcconfig` contain each
environment's public Firebase app identifiers, API key, and Google client/callback
identifiers. These are client configuration, not server credentials. No external
xcconfig or app feature switch is required. Development uses `bicino-dev` and
production uses `bicino-prod`; keep their clients and accounts separate.
Social startup still validates the client configuration and private Keychain
group. Settings always exposes the account menu, including an initialization
error when credentials cannot be restored. Firebase explicitly selects the
app-private `BicinoSocialKeychainGroup`; the existing map-library group remains
first in the enabled entitlement array, preserving all pre-existing unscoped credential
stores. No BLE owner, transfer, diagnostics or App Attest credential migration is
introduced. This is the Keychain security review: Firebase does not use the shared
map-library group, production and Dev Firebase sessions are separate, and the
pre-existing stores retain main's read/write/delete group behavior. Firebase is
not linked into Watch or widgets. A website cookie does not
sign the native app in. Test separate web/native Apple and Google sessions for
matching UID, conflict handling, explicit linking, cancellation, expiry, logout,
and recent-auth deletion before enabling either production surface.

## Settings and profile setup

When social riding is configured, Settings opens with a centered account header.
The header opens the unified Profile, Friends & Group Rides screen with profile
editing, friends, requests, invitations, existing rides, join-by-code and account
controls. There is no duplicate social entry at the bottom of Settings. The
header shows up to five overlapping friend portraits beside the rider's portrait,
with a count for additional friends. Native provider-linking controls are removed;
account deletion still supports recent-authentication with the original provider.
Dismissing Apple or Google sign-in is treated as cancellation, not a profile error.

Sign-in is optional. After sign-in, an incomplete profile is offered a short
name/username/photo setup, including sign-ins opened from a shared link. The
offer is recorded per profile on this installation, so Not now or dismissing it
does not cause repeated prompts after relaunch or later sign-ins. The header
and account row keep a Complete your profile reminder. Photos are optional;
a name and username complete setup. Existing complete profiles are not prompted.
The same public profile is used on bicino.com; setup does not change privacy
preferences or begin live-location sharing.

Profile sharing and the QR-code action share one row. Rider lookup accepts an
exact username with or without a leading @. Native completed-ride publishing
has been removed. Shared-route publishing is no longer a separate native screen.
Private Health workout recording and group rides do not depend on publishing.

Privacy and notifications appears at the bottom of the unified profile screen.
Private-area editing is removed from the native UI; existing server settings are
preserved. Profile fields save when focus leaves a field or the editor closes;
choosing/removing a photo and preference toggles save immediately. Profile and avatar writes are serialized against the server's
profile version. Failed changes are reported; preferences roll back to the
confirmed server state. An account switch rejects queued edits from the old
account. The deployed profile-write contract requires a completed name and
username before account preferences can be changed.

The request/invitation alerts toggle includes the iPhone notification permission
step. Denied system permission keeps alerts off and offers an iPhone Settings
link. The account's notification preference still controls server delivery.

## Saved routes and group creation

Saved Routes uses Create a Route for online planning. A favorite destination's
map icon opens the selected-destination controls (From/To, transport, favorite
state and Go), preserving its saved coordinate rather than performing a new
address search. An archived route's map icon continues to preview that archive.
The passive Watch-ready checkmark is hidden; transfer failures retain retry.

The saved-route preview offers Start Offline Navigation and Start Group Ride,
followed by a Share with picker (Friends, Only Me, Anyone with the link). A local
route starts as Only Me and opening it never uploads it. Selecting a nonprivate
visibility or starting a group prepares a server snapshot automatically; no
separate Publish step is required. Account plus exact archive content hash map
to a server content ID, so later starts and visibility edits reuse the snapshot.
Changing back to Only Me uses the server's existing share-link revocation.
Link visibility offers a Share route link action. Live location remains opt-in.

The server accepts owned imported GPX archives and explicitly saved Apple Maps
archives. The 22 October 2026 maintainer request extends the saved Apple Maps
product policy to the same publishing, exact-snapshot group delivery and recipient
save flow as GPX. It does not establish Apple permission; see
`reviews/mapkit-route-storage-2026-09-15.md`. Apple archives retain
`apple.mapkit` / `Apple Maps` / `phoneOnly`, including their original geometry,
instructions, timestamps and content hash. No directions request replaces the
selected alternative. `phoneOnly` still excludes Watch transfer, including for
received copies. Active-only MapKit responses, Strava and another rider's saved
route cannot be republished. These restrictions are enforced by both app and server.

The additive `savedMapKitRoutes` capability follows the server's routes feature.
Older servers omit it, so updated clients disable Apple Maps sharing with a
server-update explanation rather than attempting an unsupported upload. Deploy
the backend through its normal immutable image-lock promotions before delivering
the app. This change adds no database migration and does not waive the existing
deployment, provider-permission or physical acceptance gates.

## Upgrade and lifecycle contracts

Schema **4** requires the explicit migration job before API/worker startup.
Stop all old social replicas first; schema-3 binaries reject schema 4, and current
binaries reject an unmigrated database. The V3-to-V4 migration creates an empty
`social_friend_shares` table. It preserves existing Group Rides and never infers
sharing consent from friendships or room membership. Deploy API and worker from
the same approved image after migration. Roll back application behavior by
turning off `BICINO_SOCIAL_FEATURE_FRIEND_SHARING`, keeping schema-4 binaries
running; do not restart schema-3 binaries against schema 4.

The earlier V2 upgrade, in one transaction under the migration advisory lock:

- adds `secret_digest` to push bindings and **retires every V2 binding**. V2 rows
  never proved possession of an installation secret, so they cannot be handed
  off safely. The app binds its installation again with a proof at its next
  launch or sign-in when alerts are authorized;
- backfills a direction-insensitive geometry fingerprint for published routes
  and room snapshots, and records route exposures conservatively for accepted
  friends of friends-visible routes and for members and invitees of rooms that
  still hold a snapshot;
- creates the deletion-receipt table and marks existing pending invitations as
  already alerted.

Do not roll back to V2 binaries after this migration. The V1 upgrade retires replay payloads and ends
legacy development rooms, clears their route snapshots/live consent, and revokes
invitations: V1 route copies cannot prove their source owner's redistribution
permission. Create a new room from an owned route afterward. New replay rows
contain references, not route bodies or capability secrets. Retried room creation
returns the existing room with `invitationCodeNeedsRotation`; the organizer can
mint a fresh invitation in the app. Retried link/code minting asks for a new
operation, rather than returning a retained or superseded secret. The native
HTTP client retries one ambiguous timeout/disconnect with the same operation key;
live state instead uses its publisher's monotonic sequence. Invite replacement
hides the old code while pending and serializes native rotation requests.

The group-ride API requires ownership of its stored route snapshot. Route
redistribution follows what Bicino actually handed to a rider: viewing a
friends-visible route, resolving a link while signed in, previewing a room code,
opening an invitation or joining a room records an exposure of that geometry.
`POST /routes` then refuses identical, ID-changed or reversed geometry from that
rider with `403 route_redistribution_not_permitted`, even after unfriending or
the owner deleting the source. The sharing-rights confirmation is not authority
over another rider's route. Riders who never received it may still publish an
independently imported identical GPX file, and owners can always republish their
own geometry. The app records owner provenance for every saved, duplicated or
room-snapshot copy, reads it back after relaunch, matches re-imported copies by
the same fingerprint and lists other riders' copies as not publishable.

Location consent
expires after **four hours** or the room expiry, whichever comes first, and
publishing cannot extend it. Consent writes require the current member `epoch`;
a stale start/stop returns `409 consent_changed` without changing the lease.
`GET /group-rides/{id}/consent` returns only the authenticated member's epoch,
even during feature rollback, so a new explicit stop can retry safely. The phone
tracks the latest consent intent and ignores superseded responses. Live snapshots
are ordered by consent generation, not by server clocks: once the server accepts
one of the phone's consent changes, any snapshot still carrying a replaced epoch
was read before it and is skipped. Snapshots with the current epoch (including a
server-side expiry, which keeps the epoch) or another device's newer epoch apply.
A coverage gap hides live state after 60 seconds;
it can resume within the existing consent deadline. The phone uses a monotonic
clock to stop its GPS demand at that deadline. Selecting/reopening a room never
silently restarts local publication. Fresh positions survive routine socket
rotation; confirmed membership/account revocation clears them immediately.

JWT signature/audience/issuer/expiry checks run on every request. Provider
revocation state is cached for at most 30 seconds per API instance, bounded to
512 UIDs; SQL account/membership/block/consent authorization is never cached.
Provider lookups run outside the cache lock, one per UID at a time (concurrent
requests for that UID wait up to eight seconds), with at most 64 lookups in
flight and a five-second Firebase HTTP timeout. A slow or failing lookup never
delays other users. Provider faults return `503 identity_unavailable`, never
`401`; live sockets keep running on SQL authorization for 90 seconds of provider
outage and then close with `1013` so the app reconnects. Only a provider answer
that the user is disabled, deleted or revoked ends authentication. Read-only
handlers retry serialization and deadlock aborts with the transaction helper and
return `503 database_busy` when retries are exhausted; mutations keep their
idempotency ledger and rate charges are taken once.
The reconciliation worker only examines its configured Firebase project. A
batch stops without changes if more than three accounts, or more than a quarter
of a batch of at least four, appear deleted, and the worker retries that same
batch every minute until it is resolved. Never interpret a provider outage as
deletion. Cleanup also verifies the stored project before contacting Firebase.
Deleted UID hashes prevent a still-valid cached token from recreating the account
during this bound.

When the circuit-breaker error is logged, recover in this order, using the
worker's own image and runtime environment:

1. Investigate first: confirm `BICINO_FIREBASE_PROJECT_ID`, the service account
   and the Firebase project are the intended ones, and find out why accounts were
   deleted outside Bicino (console clean-up, other tooling).
2. `bicino-social reconcile-review` walks batches read-only (default at most 50)
   and prints the held batch's `cursor` and the internal account IDs that Firebase
   currently reports deleted. It changes nothing and prints no provider UIDs.
3. Only when every listed deletion is confirmed legitimate, run
   `bicino-social reconcile-resolve --cursor <cursor> --account <id> ...` without
   `--confirm` to validate, then again with `--confirm`. It refuses unless every
   deletion in that exact batch is listed, each listed account belongs to it, and
   Firebase reports each one deleted again at that moment. An unavailable provider
   status anywhere in the batch refuses resolution without changes. The command
   applies that validated snapshot directly, so a second provider read cannot add
   unreviewed deletions. The per-account project checks still apply, and later
   batches keep the normal breaker.
4. The running worker resumes on its next pass, because the resolved accounts
   leave the active set. If configuration was wrong, fix it and restart instead;
   never resolve a batch to work around a misconfiguration.

Share and invitation links use `/social/shared#<secret>` and
`/social/ride#<code>`; the website never receives the fragment. The page can open
Bicino or Bicino Dev. API resolution uses `POST /shared/resolve` or
`POST /group-rides/preview` with `{"code":"..."}` in the body; never log request
bodies. Public profile IDs can remain in paths. Regenerate older development
links, whose capability paths are no longer supported. Recent-auth deletion
allows the same -60 to 300 second clock window on both surfaces.

The website deletion bridge validates in a fixed order and returns typed codes:
`503 deletion_bridge_unconfigured` (social secret missing or short),
`401 deletion_proof_invalid` (signature; checked before any other field and before
any database work), `403 deletion_project_mismatch`, `401 deletion_proof_expired`
(`issuedAt` outside ±60 seconds), then `401 reauthentication_required` (the
person's sign-in is outside the window). Only the last asks the person to sign in
again. The website logs the others by status and code only (never the proof,
signature, account or body), shows a retryable "temporarily unavailable" error,
and never deletes the Firebase user after any refusal.

Requests without an account token are limited per client network in hourly
windows held in the shared limits table, so every replica enforces one bound and
one network cannot spend another's allowance: anonymous share-link resolution
60, deletion-receipt resolution 30 and push-binding release 30 per network.
Signed-in link resolution is charged to the account (120 per hour) on top of the
general quotas. Each limit is charged before the endpoint's own lookup. The
signed website bridge does no database work before its proof verifies; verified
proofs are limited to 10 per hour per account subject, not per network, because
serverless egress addresses are shared. IPv6 clients share one bucket per /64.
Limiter keys hold a digest of the network, never the address, and expire with
their window.

Push bindings belong to an app installation, identified by a UUID and proven by
a 256-bit secret kept only in the app's existing explicit private, device-only
Keychain group. The server stores the secret's SHA-256. Knowing an installation
ID or a push token is never enough to move a binding: a different secret, or a
token bound by another installation of a different account, returns
`409 notification_binding_in_use`. A proven installation moves to the account
now signed in, so switching accounts hands it over even if the previous sign-out
never reached the server. Sign-out, forced sign-out, account switch and deletion
persist a release obligation and complete it with
`POST /notification-devices/{installation}/release` and the secret plus the
expected owner, which needs no account token and cannot remove a binding already
handed to the next account. Alert registration failures are reported separately
and never make a successful refresh or social action look failed.

A declined friend request cannot be reopened by its original sender; the
recipient may initiate a new request. A declined ride invitation likewise stands
for the room (`409 invitation_declined`), while the recipient can still join by
code. Repeating a pending invitation returns it unchanged, members cannot be
invited (`409 already_member`), and re-issuing a revoked invitation alerts the
recipient at most once per day per room.

Native deletion sends the digest of a fresh client-held receipt secret, which the
server commits atomically with an accepted deletion. The app persists the receipt
before sending and, after lost responses, an app restart, identity cleanup or an
automatic sign-out, confirms it with `POST /deletion-receipts/resolve` before any
provider re-authentication. That endpoint takes no bearer token, so recovery never
signs in or recreates an identity. Unknown receipts and a missing provider
identity are never treated as completion, and completion signs out only the
deleted account, never one the rider switched to. Receipts survive identity
cleanup and expire after 30 days. APNs keeps its HTTP/2 connection and caches
provider tokens for 50 minutes, below Apple's one-hour limit.

Both iPhone configurations use `BikeComputerSocial.entitlements`, including
Apple sign-in, the environment-specific Push entitlement, and the private
Firebase Keychain group. Release readiness remains separate from source tests: validate production App ID
Sign in with Apple/Push capabilities, provisioning, callback configuration and
APNs topic before the next signed TestFlight archive. The shared image includes
social dependencies; its promotion still moves the signed map worker and must
pass the existing worker/hardware promotion gates.

## Runtime

### Map-independent friend indicators

Friend markers and their shared marker-size setting are enabled in production
and development firmware by default, independently of `FIRMWARE_DIAGNOSTICS`.
The iPhone still requires the device's negotiated rider capability and the
service's hardware-relay capability before sending authenticated rider packets.
Production releases before this rollout (including the original build 106)
need a firmware update; using Bicino Dev alone does not change their support.

On 31 October 2026 the maintainer explicitly requested that group/friend rider
markers remain enabled in both development and production firmware on both
Waveshare boards. This records acceptance of the rollout before full per-board
physical qualification, including the remaining display, memory and power
risks. The owner observed working markers on a spare 1.75-inch device; that
observation does not qualify the 2.06-inch board or replace either board's
exact-production-image transfer, reconnect, readability and long-run checks.
Keep those hardware gates separate from CI build/image-reserve results and
from factory/golden-image qualification. Disabling the backend `HARDWARE` flag
stops relay only; firmware recovery requires restoring a compatible image
under the partition-migration runbook.

Social locations are global. Offline map packs supply the background, not a
geographic limit on friends. With a usable published map, portraits use its
projection as before. Without a map or microSD card, fresh friend positions use
great-circle GPS bearing and distance and remain on the screen rim; a coincident
friend appears in the center. The existing missing-map message remains visible.
Distances are straight-line distances, not road or route distances.

The fallback follows course-up when a resolved heading is available, otherwise
north-up, with an explicit orientation label. It requires a valid own coordinate
and source measurement younger than 15 seconds. BLE source revocation takes effect
immediately. Existing friend staleness (15 seconds), expiry (60 seconds), clustering,
portraits, privacy revocation and BLE capability negotiation remain in force.
An exactly antipodal friend has no unique bearing and is omitted.

### Staged feature activation

The global `BICINO_SOCIAL_ENABLED` switch mounts social in the existing map API;
the isolated social server is controlled by its deployment. Once the service is
reachable, accounts, profiles, friends, blocking and account deletion are always
available. All seven additional features default to **false**. Set these exact
environment variables to `true` in the shared API/worker runtime environment:

| Variable | Enables |
| --- | --- |
| `BICINO_SOCIAL_FEATURE_MEDIA` | Picture upload and authenticated picture reads |
| `BICINO_SOCIAL_FEATURE_ROUTES` | Route publication, lists, detail and share links |
| `BICINO_SOCIAL_FEATURE_ACTIVITIES` | Completed-ride publication, lists, detail and links |
| `BICINO_SOCIAL_FEATURE_GROUPS` | Invitations, sessions, consent and live positions; also requires routes |
| `BICINO_SOCIAL_FEATURE_HARDWARE` | Phone-to-device rider relay; also requires groups and routes |
| `BICINO_SOCIAL_FEATURE_FRIEND_SHARING` | One-way, per-friend live location and GPS ride stats; independent of routes/groups |
| `BICINO_SOCIAL_FEATURE_INVITE_PREVIEWS` | Public view-only invite cards; requires media, groups and routes, plus the website preview release |

Use lowercase `true`/`false`; invalid values fail startup. The authenticated
`GET /v1/social/capabilities` response drives native feature availability. Live
snapshots carry the same capabilities so a connected phone clears portrait caches
or its BLE rider slots when those features are disabled. Firmware must still
advertise the Group Riders capability, which is now enabled in production and
development builds. Keep `HARDWARE=true` in both deployed environments for the
standard friend-marker feature; it remains an operational rollback switch.

Enable media with profiles, then routes, activities, groups and finally hardware.
For a fully enabled **development test environment**, enable the applicable
flags, including `FRIEND_SHARING` for direct sharing;
retain native sign-in and device BLE capability negotiation. Provider, S3 and
database configuration must still be supplied; disabling media does not remove
its cleanup configuration. Restart every API replica and worker together when
changing flags. Do not run mixed rollout settings across replicas.

Disabling a feature returns `503 feature_unavailable` for affected reads/writes,
including share links, alternate content paths and idempotent retries. Disabling
groups also closes live sockets and denies new state. Stop sharing, leave/end,
invitation decline/cancel, blocks, content/link deletion, photo removal and account
deletion remain available. The worker continues cleanup and holds invitation
notifications until groups are enabled again. Turning a flag back on does not
renew expired live consent. Keep API/worker revocation services running during a
rollback instead of taking the whole social service offline.

`map-platform/deploy/compose.social.yaml` provides PostgreSQL 17, an API, an
explicit migration job, and an outbox worker. It does not change the deployed map
worker or promote an image. Set `BICINO_SOCIAL_IMAGE` to the CI-produced immutable
application image digest containing this change; validate the value has the form
`ghcr.io/seichris/open-bike-computer-map-platform@sha256:<64 lowercase hex>`.
Use the normal image verification/promotion workflow. No mutable production tags.

Supply the required Compose secret file paths and a mode-0600 runtime env file:

- `BICINO_SOCIAL_DATABASE_URL=postgresql+psycopg://.../bicino_social` (URL-encode credentials).
- `BICINO_FIREBASE_PROJECT_ID`, matching the site's environment.
- `BICINO_SOCIAL_MEDIA_BUCKET`, optional `BICINO_SOCIAL_MEDIA_ENDPOINT`, scoped
  `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `AWS_DEFAULT_REGION`.
- `BICINO_SOCIAL_ENVIRONMENT=development` or `production`.
- `BICINO_SOCIAL_DELETION_SECRET`: independently generated shared secret of at
  least 32 characters, also configured in the website. Never a Firebase token.
- `BICINO_APPLE_NATIVE_CLIENT_ID`, `BICINO_APPLE_TEAM_ID`,
  `BICINO_APPLE_KEY_ID`, `BICINO_APPLE_PRIVATE_KEY` for Apple code revocation.
- `BICINO_APNS_TEAM_ID`, `BICINO_APNS_KEY_ID`, `BICINO_APNS_PRIVATE_KEY` for APNs.
- `BICINO_SOCIAL_TRUSTED_PROXIES`: comma-separated CIDRs of the reverse proxies
  that connect to the API (for example the proxy's Docker network). Empty by
  default, which trusts only the TCP peer. Invalid values fail startup.

The Firebase service account is a read-only container secret. Use only Auth
verification/deletion permissions needed by this service. Use a separate private
media bucket per environment, block public access, and disable public CDN caching.
Grant only avatar-prefix get/put/delete/list access. Never use a public avatar URL.

Start PostgreSQL, run `docker compose -f map-platform/deploy/compose.social.yaml
--profile migration run --rm social-migrate`, then start API and worker. Migration
runs under a PostgreSQL advisory lock. The V4 upgrade creates the empty direct
friend consent table; earlier upgrades also retire unsafe V1 replay/room state
and unproven V2 push bindings, and backfill route fingerprints and exposures as
described above. API startup verifies the
schema and fails closed rather than migrating during a request. Use a DML-only
runtime role after the schema is installed, and a separate migration credential.
The application uses serializable transactions and bounded conflict retries.
For an existing development database, stop the old social API and worker writers
before migration, then start the schema-4 API and worker together. Do not run older
writers against schema 4 or roll back to older binaries after the migration.

Route `/v1/social/*` from the configured iPhone map-service origin to the social
API, including WebSocket upgrades. Alternatively opt in to the mounted router in
the existing API using `BICINO_SOCIAL_ENABLED=true` and the same settings. Do not
put bearer tokens or capability secrets in URL paths/queries. Redact Authorization, Apple grants, coordinates,
push tokens, and request bodies in all proxy/APM/error collection. Set a 5 MiB
request cap and bounded connection/time limits. API responses are `no-store`.

Client networks for anonymous limits come from the TCP peer. `X-Forwarded-For` is
read only when that peer is in `BICINO_SOCIAL_TRUSTED_PROXIES`, and then from the
right: the nearest address that is not a trusted proxy is the client, so entries
a client writes itself are never used. Every trusted proxy must append the address
it received the connection from (for example nginx
`proxy_add_x_forwarded_for`); otherwise all its clients share the proxy's bucket.
The Compose API runs uvicorn with `--no-proxy-headers` so only this policy reads
the header. For the mounted router, keep the map API's uvicorn
`--forwarded-allow-ips` at its loopback default or consistent with this list. A
proxy-level per-client rate limit is still recommended as defense in depth.

Set website `BICINO_SOCIAL_ENABLED=true`, `BICINO_SOCIAL_ORIGIN` to the API's HTTPS
origin, and the same deletion secret. Deploy the companion website change before
native signup is enabled. Website deletion first disables social access using a
signed, short-lived, server-verified account proof; service unavailability stops
deletion instead of orphaning social data. Apple revocation runs on the initiating
surface before deletion. The worker retries Firebase/media cleanup. Both sides
accept an already-deleted Firebase user as successful cleanup.

## Retention, monitoring, rollback

Monitor database health, API 401/409/429/5xx rates, oldest outbox event age, retries,
media errors, active socket counts, and migration version without recording rider
identifiers. Alert on cleanup older than one hour and sustained 409 serialization
conflicts. Run at least one worker; horizontally replicated APIs share authority
in PostgreSQL and poll accepted room state every two seconds. Auth revocation is
rechecked every 30 seconds on sockets; membership and blocks on every snapshot.
A bounded worker reconciliation also detects identities deleted or disabled
outside Bicino (100 accounts per minute, advancing across the account set).

Route exposures keep only viewer and owner account IDs with a geometry digest,
never coordinates. Deleting an account removes the routes it received; records of
copies other riders received from it keep restricting their republication.
Only latest live state is retained; samples disappear at 60 seconds and live
leases require fresh consent after expiry. Group sessions expire 24 hours after
their scheduled start. Worker cleanup runs every 10 seconds, messages and replay
receipts expire at 24 hours, expired invitations at 30 days. Replay receipts never
retain live positions. Original activity tracks are processed in memory and not
stored; only trimmed segments survive. Privacy edits hide all previous activity
publications until the owner's phone resubmits. Hourly private-bucket reconciliation
removes unreferenced failed-upload objects older than 24 hours.

Back up PostgreSQL daily with encrypted backups and a documented expiry policy.
Test `pg_dump`/restore into a separate database, schema check, and authorization
fixtures before production. Object versions and backups must obey the operator's
deletion retention policy; deleting live rows does not erase old backups instantly.
Never restore an old database over live consent state: start restored memberships
with sharing disabled, clear live samples, invalidate links and device bindings,
and replay the deletion ledger before accepting traffic. Roll back application
images with social disabled; preserve the database and continue cleanup workers.

## Device and account acceptance

Host fixtures verify packet bounds, retry semantics, session reset, image commit,
staleness, and complete portrait/label footprints at all 360 bearings. Native
builds and these fixtures do **not** qualify physical rendering. Group-rider BLE
capability is diagnostic-firmware-only pending measured 1.75-inch acceptance.

On the identified round 1.75-inch board, separately authorize/install the exact
validated image and record device ID, image hash, portrait screenshots and logs:

- Friends inside/outside the map in eight directions, north/course-up, pan/zoom,
  bird's-eye, screen changes, map tiles missing, and stale/absent own GPS.
- No-map and no-card GPS fallback, covered-to-uncovered map transitions,
  antimeridian/polar positions and explicit fallback orientation.
- Real 40×40 RGB565 photos, initials fallback, overlap count, 15-second stale fade,
  60-second expiry, image truncation/hash failure, interruption and reconnect.
- Stop sharing, leave, removal, block, end, logout, owner change, and account deletion.
- Navigation responsiveness and full-frame rendering with eight riders and an
  avatar transfer; PSRAM budget and BLE backpressure alongside navigation/maps.
- Two real accounts on separate phones; web/native identity equivalence; push
  permission denied/granted; background ride operation; offline recovery and
  renewed consent after lease expiry; private/friends/link content and revoked links.

Record a 2.06-inch rectangular-screen qualification independently. Promote the
firmware feature gate only with physical evidence for the enabled target families.


### Group ride invitation cards

Deploy the bicino.com website preview release before enabling
`BICINO_SOCIAL_FEATURE_INVITE_PREVIEWS=true`. The website uses its existing
`BICINO_SOCIAL_ENABLED=true` and HTTPS-origin-only `BICINO_SOCIAL_ORIGIN`
configuration; no new credential is required. Ship the backend through the normal
main/digest-pinned promotion workflow. Enable the preview flag consistently on API
replicas and workers only after both releases are ready.

The native app checks the advertised `invitePreviews` capability before uploading
a real 1200×630 MapKit snapshot with the route drawn, title, distance and
“Join the group ride.” Older backends and failed snapshots keep a working standard
invitation link. Existing links remain supported and do not acquire a map preview
retroactively. The snapshot retains MapKit attribution.

Owner-only `PUT /v1/social/group-rides/{rideID}/invite-preview` sanitizes the image
and attaches a new random preview asset ID to the immutable ride route snapshot.
`GET /v1/social/ride-previews/{previewID}` returns only title, distance, image hash
and expiration; `/image` returns the bounded sanitized PNG. Neither endpoint
returns the join code, route archive/coordinates, roster, account IDs or live
positions. The image itself intentionally reveals the route map to recipients.
The website validates/proxies the image and renders Open Graph/Twitter metadata
on the server. Both services use `no-store` responses.

Invitation URLs are `/social/ride/{previewID}#join-code`. The preview ID permits
viewing the card only. Joining still requires the separate secret in the URL
fragment and an explicit Join action in the app. Native join/create actions
start sharing location, speed, distance and moving/elapsed times by default,
after any OS location prompt. Merely opening a link or reopening the profile
screen does not start sharing. Stop sharing, Leave and End remain available;
the existing four-hour sharing bound still applies. Permission denial preserves
successful membership and starts sharing automatically when the rider grants location access and returns.

The original invite is retained in the account-scoped, app-private device-only
Keychain. A legacy ride or another device without the original secret offers
Create invite link; a known invitation is never replaced automatically. Owner
ending, account deletion, card replacement and ride expiration revoke preview
reads. Worker jobs delete their private media objects, and the existing orphan
reconciler also covers `ride-previews/`. External messaging clients can retain
previously downloaded image previews in their own caches.


## Direct friend live sharing

Each Friends row offers a separate outgoing sharing toggle. The footer names
location, GPS speed, session distance, moving time and elapsed time, explains
that sharing is one-way and expires after four hours, and that removing or
blocking the friend stops direct sharing. This does not grant access to HealthKit
workouts, heart rate, routes, or private account data. Friend details show the
username when set, plus currently received live ride stats. Incoming positions
also use the existing map marker and authenticated BLE relay projection.

`GET /friend-sharing/{profileID}/consent` returns the current directional epoch;
`POST` to that path conditionally changes consent using the existing location /
stats / epoch body. Every change rotates the epoch, clears the prior fix and
sequence, and starts at most a four-hour server lease. At most 100 recipients
can be active. `POST /friend-sharing/state` sends one bounded fix with an
explicit profile-to-epoch audience map. It cannot enable consent or extend a
lease. Sequence, freshness, accuracy, per-recipient stats permission, friendship,
account state and blocks are checked in the same transaction. Stale epochs are
ignored; the reply names accepted recipients. No route or group membership is
created or shared. Idempotent consent replays read current state rather than
replaying an obsolete permission payload.

`GET /friend-sharing` returns current outgoing consents and incoming riders for
accepted friends only. Received positions disappear at 60 seconds; the worker
clears stale fixes and expired leases. Unfriend/block deletes both directions;
account deletion/disable also clears them. Re-adding/unblocking never restores
consent. This installation remembers explicitly enabled outgoing consents in its
app-private, device-only Keychain, scoped to the authenticated account and bound
to an installation marker in the app container (excluded from backup). Keychain
items can survive deleting the app, but the marker does not, so a reinstall never
resumes earlier consents; records without a matching marker are deleted. On a
foreground relaunch it resumes only after a snapshot confirms the same epoch,
friendship and original server deadline. It never creates or extends a lease to
resume. Offline launches retry validation every three seconds while foregrounded,
independently of capability discovery.
Saved selections stay on with a waiting status until validated, and can be
switched off while offline. Stop all (available before friend names have loaded)
saves the cleared selection, then sends one `DELETE /friend-sharing`; the account
stays signed in and keeps receiving friends. Sign-out/account switches,
revocation and expiry clear remembered recipients. An unreadable or invalid
record is deleted and reported, never resumed later. If the Keychain refuses to
record a stop, a new installation marker disowns every saved record; if that also
fails, the error is shown and this process reads no record again until one
succeeds. A
selection that cannot be saved is not started and its new server lease is
withdrawn. Another device's server
consents alone cannot start publication. Reserved sequence blocks survive a
force-close without retaining location fixes. Local Stop durably removes the recipient before any
network await. `DELETE /friend-sharing` revokes all outgoing friend consents in
one request for sign-out and Stop all, while preserving incoming consents. Group and friend
sharing share one GPS lifecycle so stopping either does not stop the other.
Turning off the rollout flag rejects snapshots/publications/start requests while
retaining consent reads and explicit stops.

The app polls `GET /friend-sharing` every three seconds only while this phone
shares with a friend or shows a friend position younger than 60 seconds. With
neither, it checks once a minute while the app is in the foreground, and not at
all in the background. Returning to the foreground or changing a consent checks
immediately. It publishes only new, accurate fixes, uses monotonic local
deadlines, and leaves at least 2.2 seconds after its previous publication attempt
so an immediate check never trips the server's two-second per-recipient rate.
A request superseded by such a check is neither a sharing failure nor a
revocation, and the server's own rate rejection is not reported as one either.

This is a deliberate battery and server-load trade-off. While the phone is in
the background and neither condition applies, a friend who starts sharing is not
discovered until Bicino returns to the foreground or the rider starts sharing.
That includes the map and the authenticated bike-computer relay. Positions
already being received, and this phone's own outgoing sharing, continue in the
background within the existing location permission. Bicino does not request
additional background location access for discovery.
