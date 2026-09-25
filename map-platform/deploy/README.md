# Map Platform Deployment

`compose.yaml` is the production deployment lock for the map platform. It pins
the API/maintenance control plane and the signed-map worker to immutable GHCR
digests and passes the worker digest into the producer identity. The two pins
may match, but remain separate so an approval-only control-plane release can
advance without replacing a hardware-tested worker. Coolify secrets remain
outside Git.

`compose.development.yaml` is an independent development lock. Its automated
promotion advances API, maintenance, and worker together for development
testing without modifying the production lock. It defaults to the development
deployment/catalog channels, shadow preparation estimates, and disabled Strava.
Its API selects generation policy v2 only after the image containing that
policy has been promoted. Renderer format 4 is available to every development
installation under the policy's normal admission limits. Production stays on
policy v1 until its independent release gates and image promotion complete.
The current development lock still forwards the legacy canary allowlist to
its pinned image; the new backend ignores that variable. Remove the inert
setting in the separate development lock promotion after the active map job
finishes so this source PR does not restart the running stack.
The checked-in v3 generation policy makes format 4 global in both channels,
but the production Compose lock deliberately does not select it yet. The
catalog's `TOPOGRAPHY_PROMOTION_ENABLED` remains `0` in staging and production
until the paired-artifact and hardware qualification is recorded. This is one
global release switch, not an installation allowlist.

## One-time GitHub configuration

In repository **Settings > Actions > General > Workflow permissions**, enable
**Allow GitHub Actions to create and approve pull requests**. Keep the default
`GITHUB_TOKEN` permissions restricted to read access; the image workflow grants
write access only to its promotion job. GitHub uses this repository switch to
decide whether `GITHUB_TOKEN` may open the digest-promotion pull request.

Protect `main` with a ruleset or classic branch protection that:

- requires changes to arrive through a pull request (zero required approvals is
  acceptable for a solo-maintainer repository),
- requires the `CI Gate` status check before merge, and
- requires branches to be up to date before merging, and
- blocks force pushes and branch deletion.

This is the repository-side deployment admission control: without it, a direct
push could change the watched production Compose without passing pull-request
CI.

The top-level `CI` workflow reports the stable `CI Gate` check on every pull
request. It selects changed components and calls `Map Platform CI` only when
backend, deployment, image, or OSM inputs changed. Backend image validation also
runs for OSM changes because the production image copies the extractor. A
manual `Map Platform CI` dispatch still runs both map jobs for targeted use.

## One-time production Coolify configuration

Update the existing `open-bike-computer-map-platform` resource rather than
creating a new resource, so its domain and `map-platform-data` volume remain
attached.

- Build pack: `Docker Compose`
- Base directory: `/`
- Docker Compose location: `/map-platform/deploy/compose.yaml`
- Branch: `main`
- Auto deploy: enabled
- Watch path: `map-platform/deploy/compose.yaml`

Keep the existing secret and runtime variables in Coolify. The production
Compose no longer reads `MAP_PLATFORM_API_IMAGE`,
`MAP_PLATFORM_WORKER_IMAGE`, or `MAP_PLATFORM_MAINTENANCE_IMAGE`; remove those
three values after the first successful deployment to avoid presenting stale
configuration as active.

Set `MAP_PLATFORM_DEPLOYMENT_CHANNEL=production`. Renderer availability then
comes from the pinned `generation-profile-policy-v1.json` in the control-plane
image. `MAP_PLATFORM_BUILDING_TARGET3_ALLOWLIST` is the only runtime generation
entitlement and is restricted to the production canary profile; the retired
`MAP_PLATFORM_LABEL_TARGET2_ENABLED` and
`MAP_PLATFORM_BUILDING_TARGET3_ENABLED` variables are passed temporarily so the
currently pinned pre-policy API remains available during the rolling image
promotion. The policy-aware API ignores them. Remove them only after `/healthz`
reports both `deploymentChannel` and `generationProfilePolicySha256` from the
promoted control plane.

Keep `MAP_PLATFORM_WORKER_MEMORY_LIMIT` at the reviewed `12g` default (or a
separately reviewed lower value). The production Compose lock applies it as a
real worker cgroup limit; the chunk coordinator refuses to claim target-3 work
when that limit is absent or malformed. Keep
`MAP_PLATFORM_WORKER_MAX_CONCURRENT_TASKS=1` until retained resource evidence
supports a higher value.

The initial worker lock points at the image already running successfully in
production. Its control-plane lock contains the same backend revision currently
deployed from `main`, so changing the Compose location does not introduce a new
worker binary.

## Hardware-validation deployment

Create a separate Coolify Docker Compose application using
`compose.hardware-validation.yaml`. Set `MAP_PLATFORM_VALIDATION_IMAGE` to the
candidate's immutable `ghcr.io/...@sha256:...` reference, use a separate
hostname, and enable stream or target-format gates only for the exact
hardware-validation installation. The validation stack always uses its own
filesystem-backed volume; it must not share the production data volume.
Production continues to use `compose.yaml` and its independently reviewed image
pins.

## Development channel

Create a second Coolify Docker Compose application using
`compose.development.yaml` and the hostname `maps-dev.8o.vc`:

- Build pack: `Docker Compose`
- Base directory: `/`
- Docker Compose location: `/map-platform/deploy/compose.development.yaml`
- Branch: `main`
- Auto deploy: enabled
- Watch path: `map-platform/deploy/compose.development.yaml`

Give it independent installation/download/admin
secrets, an independent S3 prefix (for example `map-artifacts-dev`), independent
quotas and monitoring retention, and its own Compose-managed data volume. Do not
copy production installation credentials or the target-3 canary allowlist.
The lock defaults `MAP_PLATFORM_DEPLOYMENT_CHANNEL` and
`MAP_PLATFORM_CATALOG_CHANNEL` to `development`; an explicit Coolify value may
remain as defense in depth. For estimator calibration, the development lock
defaults `MAP_PLATFORM_PREPARATION_ESTIMATES_MODE=shadow`, while production
also defaults to `shadow` so production records calibration evidence without
publishing unvalidated estimates to clients. Hardware validation remains `off`.
Shadow mode records bounded estimate revisions without returning them in public
job responses; promote to `public` only after the documented sample and accuracy
gates pass.
For topography, merge and promote an exact image containing generation
policy v2 and the topography pipeline through the normal development image-lock
PR. Verify the pinned image contains that policy before merging the separate
development-lock change selecting
`/app/config/generation-profile-policy-v2.json`. In Bicino Dev, select the
development map server and verify that authenticated `/v1/capabilities`
responses for independent installations include renderer format 4. `/healthz`
reports the loaded source-policy summary; authenticated capabilities are the
generation gate.
Keep the production lock and secrets unchanged. Record the canary map's exact
source receipts and attribution before using it for hardware qualification.
Until `/healthz` exposes the generation-policy digest, set both legacy
compatibility flags to `1` on this new application so the pinned pre-policy API
can generate formats 2 and 3. They become inert after the control-plane image
promotion and can then be removed.

This makes Bicino Dev a deployment channel rather than a production canary.
Both channels advance through separate reviewed digest locks, while their
credentials, queue state, storage namespace, and operational limits remain
isolated. Signing-key separation remains governed by the existing map-stream
trust and hardware-promotion contract; do not introduce an untrusted development
key outside that flow.

For the one-time migration from the shared lock, first merge the change that
adds `compose.development.yaml`. Its initial image pins match `compose.yaml`, so
switching only the development Coolify Compose location and watch path does not
change the running image. Verify development health and that production still
watches `compose.yaml`; then merge the separate development image promotion.

## App Attest rollout

The API pins Apple's App Attestation root certificate in the image and selects
the allowed App ID, environment, and launch-validation categories from
`MAP_PLATFORM_DEPLOYMENT_CHANNEL`. Do not add a runtime bypass or a second root.
The Compose locks pass
`MAP_PLATFORM_APP_ATTEST_CHALLENGE_TTL_SECONDS` with a `300`-second default;
keep it between `30` and `900` seconds.
Authenticated key replacement is limited separately by
`MAP_PLATFORM_APP_ATTEST_ROTATION_IP_LIMIT_PER_DAY` (default `12`) and
`MAP_PLATFORM_APP_ATTEST_ROTATION_LIMIT_PER_DAY` (default `3` per
installation). It preserves the installation owner and is accepted only with
the existing installation token, a scoped challenge, the exact previous key,
and a fresh Apple attestation.

Before releasing the iOS client, enable App Attest for both Apple App IDs and
regenerate the corresponding provisioning profiles. Promote the compatible API
first and verify `/healthz` reports App Attest as required with the expected
TTL. Then validate Development on a physical iPhone before submitting the
production build. Existing installation credentials remain usable for reads,
but only an attested installation can request a map-creation challenge.

Back up `/data/app-attest.sqlite3` with the rest of the channel's persistent
control-plane state. If a restore removes a device's key binding while its
stateless installation credential remains valid, the app uses an authenticated,
installation-scoped challenge to attest a fresh key while preserving the same
owner and maps. Never copy this database between Development, hardware
validation, and Production.

## Strava route import configuration

Leave `MAP_PLATFORM_STRAVA_ENABLED=0` until the matching Strava developer app,
privacy/branding review, and intended athlete capacity are ready. Enabling it
requires all of the following in that Coolify application's secrets/runtime
variables:

```text
MAP_PLATFORM_STRAVA_CLIENT_ID
MAP_PLATFORM_STRAVA_CLIENT_SECRET
MAP_PLATFORM_STRAVA_REDIRECT_URI
MAP_PLATFORM_STRAVA_TOKEN_KEY_ID
MAP_PLATFORM_STRAVA_TOKEN_KEY_BASE64
MAP_PLATFORM_STRAVA_PREVIOUS_TOKEN_KEYS
MAP_PLATFORM_STRAVA_CONNECTION_IDLE_TTL_DAYS
```

Use `https://maps-dev.8o.vc/v1/integrations/strava/oauth/callback` only with
the Development channel and `https://maps.8o.vc/v1/integrations/strava/oauth/callback`
only with Production. Startup fails closed if an enabled or partially supplied
configuration is invalid, including a callback/channel mismatch or an
encryption key that does not decode to exactly 32 bytes.

API and maintenance must share the same Strava client and encryption settings
because both can revoke athlete tokens. The worker must never receive them.
The persistent `map-platform-data` volume contains the encrypted
`strava-integrations.sqlite3`; it contains no plaintext token columns. Rotate
token-encryption keys by placing retained `key-id=base64-key` entries (or a
JSON object mapping IDs to keys) in
`MAP_PLATFORM_STRAVA_PREVIOUS_TOKEN_KEYS`, deploying the new current key to API
and maintenance together, and keeping old keys available until their rows have
been lazily re-encrypted or retired.

The optional quota variables are
`MAP_PLATFORM_STRAVA_OAUTH_START_LIMIT_PER_HOUR`,
`MAP_PLATFORM_STRAVA_ROUTE_IMPORT_LIMIT_PER_HOUR`,
`MAP_PLATFORM_STRAVA_ROUTE_LIST_LIMIT_PER_HOUR`,
`MAP_PLATFORM_STRAVA_ROUTE_VALIDATION_LIMIT_PER_HOUR`, and
`MAP_PLATFORM_STRAVA_DISCONNECT_LIMIT_PER_HOUR`. The route archive lifetime is
always 604,800 seconds and is intentionally not configurable.

Promote the backend image through the normal immutable digest workflow below;
do not edit the live Coolify Compose or image digest as an untracked enablement
step. Verify `/healthz` reports `stravaIntegration: enabled`, then verify the
authenticated capabilities response before allowing the iOS feature to start
OAuth.

## Promotion flow

The `Map Platform Image` workflow builds and attests candidate images. After a
successful build from `main`, it proposes the candidate through two independent
automation-owned branches:

- `deploy/map-platform-development` updates only
  `compose.development.yaml` and advances the API, maintenance, and worker pins
  together. It cannot modify `compose.yaml`.
- `deploy/map-platform-production` updates only `compose.yaml`. It advances the
  control-plane digest and source commit, and advances the signed worker only
  when the production worker policy permits it. It cannot modify the
  development lock.

A dispatch from another branch publishes a candidate image but cannot open
either deployment promotion. `latest` tracks the most recent successful
image-building commit on `main`; neither deployment reads that mutable tag.

The protected map-only CI dispatch recognizes only those exact automation
branches and fails if a promotion changes anything beyond its own lock. Both
promotion jobs also use repository-owned pull-request checks and exact branch
leases so a concurrent or foreign branch update cannot be overwritten.

The production workflow refuses to guess when a control-only push arrives while
the open production promotion moves the worker pin. Re-run **Map Platform
Image** manually on `main`
and choose one of the explicit `pending_worker` policies:

- `preserve-pending` carries the open PR's worker into the new control-plane
  candidate, for example after intentionally committing its bound approval. It
  is rejected if later commits changed any worker input.
- `promote-candidate` replaces the pending worker with the newly built
  candidate; run the required worker and hardware gates before merging it.
- `auto` is safe only when no open promotion moves the worker; it fails closed
  rather than inferring intent. For a manual rebuild with no moving pending
  worker, it conservatively proposes both the control and worker pins so a
  dependency-only rebuild can be tested and promoted.

The control plane and worker share backend code and persistent job state, so the
workflow never offers an unsafe "new API with old worker" override after worker
inputs have changed. Resolve the pending candidate or build a dedicated,
reviewed compatibility release instead.

The shared `map-platform-data` volume is also the restart-safe source for
`jobs/*.json`, `map-monitoring.sqlite3`, `app-attest.sqlite3`, source-cache
state, and filesystem artifacts. Coolify/container stdout remains a live
structured-log surface, not the durable monitoring store; use the admin
monitoring endpoint or the CLI summary when inspecting history after a restart.

The production PR body reports worker movement from the final manifest diff,
not merely the latest commit's path classification. Neither promotion job
changes a deployment directly.

Review and merge the relevant promotion pull request when its candidate is
ready. A development promotion changes only `compose.development.yaml`; a
production promotion changes only `compose.yaml`. Each matches only its own
Coolify watch path and deploys the exact pinned image. Promotion-only merges do
not start another image build, so the workflow cannot loop.

GitHub suppresses workflow events caused by `GITHUB_TOKEN`, so the promotion
job explicitly dispatches `ci.yml` with `scope=map` for the promotion commit
after opening or refreshing the pull request. That produces the required
aggregate gate while running only the map backend and OSM checks, keeping
unrelated firmware and iOS CI changes out of the image-promotion path while
retaining the least-privileged repository token.

Validate the lock locally with:

```sh
python3 map-platform/deploy/update_image.py \
  map-platform/deploy/compose.yaml \
  --check

python3 map-platform/deploy/verify_registry_images.py \
  map-platform/deploy/compose.yaml

python3 map-platform/deploy/update_image.py \
  map-platform/deploy/compose.development.yaml \
  --check

python3 map-platform/deploy/verify_registry_images.py \
  map-platform/deploy/compose.development.yaml

MAP_PLATFORM_DOWNLOAD_SECRET=ci-download-secret \
MAP_PLATFORM_INSTALLATION_SECRET=ci-installation-secret-32-bytes-minimum \
MAP_PLATFORM_TRUSTED_PROXY_CIDRS=172.16.0.0/12 \
docker compose -f map-platform/deploy/compose.yaml config

MAP_PLATFORM_DOWNLOAD_SECRET=ci-download-secret \
MAP_PLATFORM_INSTALLATION_SECRET=ci-installation-secret-32-bytes-minimum \
MAP_PLATFORM_TRUSTED_PROXY_CIDRS=172.16.0.0/12 \
docker compose -f map-platform/deploy/compose.development.yaml config
```

The registry check requires Docker Buildx and an authenticated GitHub CLI. It
confirms that both immutable references resolve to Linux/AMD64 images and that
GitHub recorded provenance from this repository's image workflow for each
adjacent source commit.

## Rollback

Revert the relevant promotion commit or restore that channel's complete
previously known-good lock in a new pull request: both image anchors and both
adjacent source commit markers. Restoring a digest without its matching marker
fails provenance verification. Restore `compose.yaml` or
`compose.development.yaml` as a unit; never copy one channel's lock over the
other. Git history records the exact source commit and image used by every
deployment. Coolify's rollback remains available for incident response, but
follow it with a Git revert so declared state matches the running state.
