# Cloudflare R2 final-map library rollout

This runbook deploys the shared final-map library implemented by
`map-platform/catalog`. Follow it staging-first. The repository implementation
does not provision Cloudflare resources or change either Coolify deployment.

## Runtime shape

- Coolify development writes final artifacts to private R2 bucket
  `bicino-final-maps-dev`.
- Coolify production writes final artifacts to private R2 bucket
  `bicino-final-maps-prod`.
- The Cloudflare Worker at `maps-share.8o.vc` stores library, alias, publication,
  share, and grant metadata in D1.
- The Worker reads both buckets using separate Object Read-only credentials.
- No new container, database, or reserved RAM is added to Coolify.

Only `zip-stored-v1` and `bike-map-stream-v1` final artifacts are uploaded.
OSM extracts, intermediate blocks, caches, job state, and scratch files remain
environment-local.

## 1. Provision staging

Create staging resources in the Cloudflare account:

1. R2 buckets `bicino-final-maps-dev-staging` and
   `bicino-final-maps-prod-staging`, with public access and `r2.dev` disabled.
2. D1 database `bicino-map-catalog-staging`.
3. Worker custom hostname `maps-share-staging.8o.vc`.
4. One Object Read & Write token per staging bucket for its matching Coolify
   publisher.
5. One Object Read-only token per staging bucket for the catalog Worker.

Never give the development publisher authority over the production bucket.
Never reuse publisher credentials in the Worker.

Replace the staging placeholders in `map-platform/catalog/wrangler.jsonc` with
the actual Cloudflare account ID, D1 ID, Apple team ID, and App Store URL. The
production section must remain pointed at production resources.

Create independent random values of at least 32 bytes for the service HMAC
secrets. Store them only as Worker/Coolify secrets:

```sh
cd map-platform/catalog
pnpm exec wrangler secret put SERVICE_KEYS_JSON
pnpm exec wrangler secret put R2_DEVELOPMENT_ACCESS_KEY_ID
pnpm exec wrangler secret put R2_DEVELOPMENT_SECRET_ACCESS_KEY
pnpm exec wrangler secret put R2_PRODUCTION_ACCESS_KEY_ID
pnpm exec wrangler secret put R2_PRODUCTION_SECRET_ACCESS_KEY
```

`SERVICE_KEYS_JSON` maps each configured service key ID to an object containing
its independent HMAC secret and exact `development` or `production` channel,
for example `{"dev-publisher":{"channel":"development","secret":"..."}}`.
Use different principals for development and production. Only a production
principal can request or finalize promotion.

Apply the D1 migration and deploy staging only after `pnpm check` passes:

```sh
pnpm exec wrangler d1 migrations apply bicino-map-catalog-staging --remote
pnpm exec wrangler deploy --env=""
```

Verify `/healthz`, both AASA paths, D1 migration state, and that a share landing
page cannot disclose an object key or trigger a download.

## 2. Prove R2 compatibility

Run the opt-in spike against each disposable staging bucket before switching a
real worker. It writes and then deletes one object under a unique
`compatibility-spike/` prefix:

```sh
cd map-platform/backend
MAP_PLATFORM_R2_SPIKE_CONFIRM=delete-disposable-object \
MAP_PLATFORM_ARTIFACT_STORE=s3 \
MAP_PLATFORM_S3_BUCKET=bicino-final-maps-dev-staging \
MAP_PLATFORM_S3_ENDPOINT_URL=https://ACCOUNT_ID.r2.cloudflarestorage.com \
MAP_PLATFORM_S3_PREFIX=map-artifacts \
MAP_PLATFORM_S3_CHECKSUM_MODE=sha256 \
AWS_ACCESS_KEY_ID=REDACTED \
AWS_SECRET_ACCESS_KEY=REDACTED \
AWS_REGION=auto \
python tools/check_r2_compatibility.py
```

The spike must prove immutable conflict rejection, HEAD verification, ranged
GET, full streamed SHA-256 verification, and deletion. If R2 rejects the SDK's
SHA-256 checksum headers, repeat with `MAP_PLATFORM_S3_CHECKSUM_MODE=md5`; do
not use `metadata-only` without a separate integrity review.

## 3. Configure staging Coolify services

Add these values to every API, worker, and maintenance service as represented
in `map-platform/deploy/compose.yaml`:

```text
MAP_PLATFORM_ARTIFACT_STORE=mirror
MAP_PLATFORM_S3_BUCKET=<matching staging bucket>
MAP_PLATFORM_S3_PREFIX=map-artifacts
MAP_PLATFORM_S3_ENDPOINT_URL=https://<account-id>.r2.cloudflarestorage.com
MAP_PLATFORM_S3_CHECKSUM_MODE=sha256
AWS_REGION=auto
MAP_PLATFORM_CATALOG_URL=https://maps-share-staging.8o.vc
MAP_PLATFORM_CATALOG_CHANNEL=development|production
MAP_PLATFORM_CATALOG_SERVICE_KEY_ID=<environment principal>
MAP_PLATFORM_CATALOG_SERVICE_SECRET=<matching HMAC secret>
```

Give the worker its bucket-scoped write credentials through `AWS_ACCESS_KEY_ID`
and `AWS_SECRET_ACCESS_KEY`. Give the API separate read-only credentials through
`MAP_PLATFORM_S3_API_ACCESS_KEY_ID` and
`MAP_PLATFORM_S3_API_SECRET_ACCESS_KEY`. Do not expose any R2 secret to an app.

For production-tier streams, also configure one reviewed, exact app identity:

```text
MAP_PLATFORM_CATALOG_REQUIRED_IOS_BUILD=<CFBundleVersion>
MAP_PLATFORM_CATALOG_REQUIRED_IOS_GIT_SHA=<40-hex-source-SHA>
MAP_PLATFORM_CATALOG_REQUIRED_IOS_BUILD_SHA256=<64-hex-build-identity>
```

If firmware compatibility is fixed for the map, configure all three firmware
fields together. Partial iOS or firmware identity tuples fail closed.

Start with `mirror`: the filesystem remains primary while R2 receives the same
immutable final bytes. Compare sampled SHA-256 values and catalog publication
state, then switch to `s3`. Keep the old filesystem volume read-only through
the rollback window.

## 4. Validate the complete staging flow

Use non-production app builds and disposable maps to prove:

1. a dev-generated 2D and 3D map publishes and appears in both apps;
2. a prod-generated map appears in both apps;
3. aliases synchronize without changing map or artifact identity;
4. a share preview requires an explicit Add action and the recipient can
   download, validate, and rename independently;
5. revocation blocks new previews/claims without deleting a recipient's
   already claimed map;
6. production requests never receive a development-signed stream;
7. redirects terminate only on the configured R2 S3 hostname; and
8. the existing firmware/app artifact verifier accepts downloaded maps.

Confirm the actual distribution provisioning profiles contain both the
associated domain and shared Keychain access group. If the shared group is not
available to both bundle IDs, use the implemented one-time link-code fallback
before release.

Set `BICINO_MAP_R2_DOWNLOAD_HOST` in both iOS xcconfig files to the account's
exact `<32-hex-account-id>.r2.cloudflarestorage.com` hostname for the release
build. The checked-in `invalid.invalid` value intentionally keeps downloads
disabled until this rollout gate is complete.

## 5. Production promotion

A production operator can turn the exact final development ZIP into a
production-signed stream without rerunning OSM extraction:

```sh
map-platform promote-catalog-map <mapEntryId>
```

Run this only in a production worker image with production catalog credentials,
the production bucket, production map-signing key, exact producer identity, and
exact iOS delivery identity configured. The command streams and verifies the
ZIP, validates every payload file and renderer capability, signs a new
`bike-map-stream-v1`, uploads it immutably, and finalizes it under the same map
entry. A production app never receives the original development stream.

## 6. Production and rollback

Repeat provisioning with `bicino-final-maps-dev`,
`bicino-final-maps-prod`, `bicino-map-catalog`, and `maps-share.8o.vc`. Apply D1
migrations before deploying the production Worker. Move one environment at a
time through `filesystem` to `mirror` to `s3` and inspect health/catalog state
at every step.

Rollback order:

1. set the affected Coolify service back to `filesystem` or `mirror` using the
   retained volume;
2. leave R2 objects immutable and disable new catalog publication by clearing
   `MAP_PLATFORM_CATALOG_URL` if the catalog is at fault;
3. roll back the Worker deployment and D1 migration according to its reviewed
   migration procedure; and
4. revoke only the affected service or bucket credential.

Do not delete R2 objects or D1 rows during incident response. Quarantine the
publication first and preserve its receipts for investigation.
