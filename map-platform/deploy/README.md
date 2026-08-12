# Map Platform Production Deployment

`compose.yaml` is the production deployment lock for the map platform. It pins
the API/maintenance control plane and the signed-map worker to immutable GHCR
digests and passes the worker digest into the producer identity. The two pins
may match, but remain separate so an approval-only control-plane release can
advance without replacing a hardware-tested worker. Coolify secrets remain
outside Git.

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

## One-time Coolify configuration

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

Create a second Coolify Docker Compose application from the same immutable
`compose.yaml` lock, with `MAP_PLATFORM_DEPLOYMENT_CHANNEL=development` and the
hostname `maps-dev.8o.vc`. Give it independent installation/download/admin
secrets, an independent S3 prefix (for example `map-artifacts-dev`), independent
quotas and monitoring retention, and its own Compose-managed data volume. Do not
copy production installation credentials or the target-3 canary allowlist.
Until `/healthz` exposes the generation-policy digest, set both legacy
compatibility flags to `1` on this new application so the pinned pre-policy API
can generate formats 2 and 3. They become inert after the control-plane image
promotion and can then be removed.

This makes Bicino Dev a deployment channel rather than a production canary.
Both channels still advance through the reviewed digest lock, while their
credentials, queue state, storage namespace, and operational limits remain
isolated. Signing-key separation remains governed by the existing map-stream
trust and hardware-promotion contract; do not introduce an untrusted development
key outside that flow.

## Promotion flow

The `Map Platform Image` workflow builds and attests candidate images. After a
successful build from `main`, it opens or refreshes the automation-owned
`deploy/map-platform-production` pull request with the new control-plane digest
and source commit. When the Git range changes an input used by the signed worker
identity, the same PR also advances the worker pin. Manual workflow dispatches
from `main` conservatively propose both pins for explicit review; select the
`main` branch in the dispatch form. A dispatch from another branch publishes a
candidate image but cannot open a production promotion. `latest` tracks the
most recent successful image-building commit on `main`; production never reads
that mutable tag.

The workflow refuses to guess when a control-only push arrives while the open
promotion moves the worker pin. Re-run **Map Platform Image** manually on `main`
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
`jobs/*.json`, `map-monitoring.sqlite3`, source-cache state, and filesystem
artifacts. Coolify/container stdout remains a live structured-log surface, not
the durable monitoring store; use the admin monitoring endpoint or the CLI
summary when inspecting history after a restart.

The PR body reports worker movement from the final manifest diff, not merely
the latest commit's path classification. The workflow never changes production
directly.

Review and merge that promotion pull request when the candidate is ready. The
merge changes `compose.yaml`, which matches the Coolify watch path and deploys
the exact pinned image. A promotion-only merge does not start another image
build, so the workflow cannot loop.

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

MAP_PLATFORM_DOWNLOAD_SECRET=ci-download-secret \
MAP_PLATFORM_INSTALLATION_SECRET=ci-installation-secret-32-bytes-minimum \
MAP_PLATFORM_TRUSTED_PROXY_CIDRS=172.16.0.0/12 \
docker compose -f map-platform/deploy/compose.yaml config
```

The registry check requires Docker Buildx and an authenticated GitHub CLI. It
confirms that both immutable references resolve to Linux/AMD64 images and that
GitHub recorded provenance from this repository's image workflow for each
adjacent source commit.

## Rollback

Revert the promotion commit or restore the complete previously known-good lock
in a new promotion pull request: both image anchors and both adjacent source
commit markers. Restoring a digest without its matching marker fails provenance
verification. The safest manual rollback is to restore the historical
`compose.yaml` as a unit. Git history records the exact source commit and image
used by every deployment. Coolify's rollback remains available for incident
response, but follow it with a Git revert so declared production state matches
the running state.
