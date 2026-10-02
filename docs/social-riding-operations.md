# Social riding rollout and operations

This implementation is opt-in. Existing navigation, installation credentials, BLE
ownership, and local workouts remain independent of a Bicino account. Do not turn
on social uploads until both repository PRs, provider configuration, privacy
review, and the acceptance matrix below are complete.

## Identity and native configuration

Use bicino.com's **same production Firebase project** for the production iOS app.
Register `LetItRide.BikeComputer`; use a separate development project and
`LetItRide.BikeComputer.dev` for Debug. Register Apple native App IDs and associate
the website Services ID so both surfaces resolve to the same provider identity.
Enable native Sign in with Apple and Push Notifications in the developer portal.
Register the Google iOS client and reversed client-ID callback scheme. Do not
copy server credentials into Xcode or the application bundle.

Set build settings `BICINO_FIREBASE_APP_ID`, `BICINO_FIREBASE_SENDER_ID`,
`BICINO_FIREBASE_API_KEY`, `BICINO_FIREBASE_PROJECT_ID`, `BICINO_GOOGLE_CLIENT_ID`,
and `BICINO_GOOGLE_REVERSED_CLIENT_ID`, then `BICINO_SOCIAL_ENABLED = YES`.
Their committed defaults are empty / NO. Firebase uses the app's own default
Keychain access group, preceding the existing explicitly selected map-library
group; Firebase is not linked into Watch or widgets. A website cookie does not
sign the native app in. Test separate web/native Apple and Google sessions for
matching UID, conflict handling, explicit linking, cancellation, expiry, logout,
and recent-auth deletion before enabling either production surface.

## Runtime

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

The Firebase service account is a read-only container secret. Use only Auth
verification/deletion permissions needed by this service. Use a separate private
media bucket per environment, block public access, and disable public CDN caching.
Grant only avatar-prefix get/put/delete/list access. Never use a public avatar URL.

Start PostgreSQL, run `docker compose -f map-platform/deploy/compose.social.yaml
--profile migration run --rm social-migrate`, then start API and worker. Migration
v1 is additive and runs under a PostgreSQL advisory lock. API startup verifies the
schema and fails closed rather than migrating during a request. Use a DML-only
runtime role after the schema is installed, and a separate migration credential.
The application uses serializable transactions and bounded conflict retries.

Route `/v1/social/*` from the configured iPhone map-service origin to the social
API, including WebSocket upgrades. Alternatively opt in to the mounted router in
the existing API using `BICINO_SOCIAL_ENABLED=true` and the same settings. Do not
put bearer tokens in URLs. Disable access-log query/path capture for `/social/shared/*`
and `/group-rides/preview/*` and redact Authorization, Apple grants, coordinates,
push tokens, and request bodies in all proxy/APM/error collection. Set a 5 MiB
request cap and bounded connection/time limits. API responses are `no-store`.

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
