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

The Cloudflare account must have an active R2 subscription before Wrangler can
create or inspect buckets. R2 includes a free monthly allowance, but activation
is a billed usage subscription and must be completed by the account owner.

Create staging resources in the Cloudflare account:

1. R2 buckets `bicino-final-maps-dev-staging` and
   `bicino-final-maps-prod-staging`, with public access and `r2.dev` disabled.
2. D1 database `bicino-map-catalog-staging`.
3. Worker custom hostname `maps-share-staging.8o.vc`, created from the
   checked-in Wrangler Custom Domain route during deployment.
4. One Object Read & Write token per staging bucket for its matching Coolify
   publisher.
5. One Object Read-only token per staging bucket for the catalog Worker.

Never give the development publisher authority over the production bucket.
Never reuse publisher credentials in the Worker.

Verify the checked-in staging account ID, D1 ID, Apple team ID, and App Store
URL still match the target accounts. The production D1 placeholder must remain
invalid until the complete staging flow passes.

Create independent random values of at least 32 bytes for the service HMAC
secrets. Store them only as Worker/Coolify secrets. These commands target the
top-level staging Worker explicitly by omitting a named environment:

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

The checked-in configuration disables both `workers.dev` and version preview
URLs for staging and production. Do not temporarily re-enable either public
route: the Custom Domain must be the only public ingress so zone security rules
cannot be bypassed. After each deploy, open **Workers & Pages > the catalog
Worker > Settings > Domains & Routes** and retain a screenshot showing only the
expected Custom Domain. Also confirm that the account's `workers.dev` route and
an old version-preview URL cannot reach `/healthz`.

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

Development streams use a dedicated development-only P-256 signing identity.
The Bicino Dev build may trust its public key in addition to production public
keys. Device installation of those streams requires an opt-in
`*_REMOTE_DEBUG` firmware profile, which compiles the same public key in
addition to production trust. Ordinary, production, factory, and release
firmware remain production-only. Configure the development worker with
`MAP_PLATFORM_MAP_SIGNING_KEY_ID=map-dev-2026-08` and the matching private key
through `MAP_PLATFORM_MAP_SIGNING_PRIVATE_KEY_BASE64`. Never copy the production
private key to development or either private key into the app, catalog Worker,
repository, logs, or API service. Rotate the development identity by first
shipping its new public key in Bicino Dev and remote-debug firmware, then
changing the development worker signer; retain old public keys while their maps
remain downloadable.

Every stream publication persists a versioned reader contract covering the
stream format, manifest schema, renderer format version, and required features.
Dev, production, and future app builds receive a grant only when their discrete
capability set contains every requirement and their exact signer key ID and
fingerprint is trusted. App build identity remains signed audit context; it is
not immutable map compatibility and does not make old maps expire after an app
release. Unknown reader-contract schemas and missing capabilities fail closed.
If firmware compatibility is fixed for the map, configure all three
`MAP_PLATFORM_CATALOG_REQUIRED_FIRMWARE_*` fields together.

Start with `mirror`: the filesystem remains primary while R2 receives the same
immutable final bytes. Compare sampled SHA-256 values and catalog publication
state, then switch to `s3`. Keep the old filesystem volume read-only through
the rollback window.

Existing filesystem-era READY jobs are not published automatically. After the
R2 compatibility check, backfill each retained job explicitly from the owning
environment's maintenance/worker container:

```sh
map-platform backfill-catalog-job <jobId>
```

The command verifies the recorded local size and SHA-256, performs an
immutable mirror upload, verifies both copies, and only then finalizes the
catalog publication. A missing or conflicting object fails closed; do not mark
the job published by editing its JSON or D1 rows.

Published objects use catalog-authoritative retention. The checked-in Worker
configuration sets `RETENTION_GRACE_DAYS=30`. Zero-reference artifacts are
tombstoned for a full grace period, then the owning environment receives a
short deletion lease. Coolify maintenance rechecks the exact channel, object
key, size, SHA-256, local job state, and active lease before deleting, confirms
R2 absence, and only then records deletion in D1. Keep physical deletion
enabled only after reviewing the zero-reference report in staging; increasing
the grace is safe, while shortening it requires a separate retention review.

Repeated publication of the same map is also bounded. The catalog retains one
live head for each exact bucket/tier, format, signer fingerprint, reader
requirements, and firmware compatibility class. A newly verified same-class
head makes older generations eligible for the same grace-and-lease deletion
flow, even when the map remains in a library. Active download grants and
promotion leases delay supersession, and every deletion phase rechecks that a
live same-class replacement remains. Each map is limited to 16 live classes;
publication 17 fails atomically instead of silently dropping compatibility.
Before staging migration 0008, query for any map over that bound and explicitly
review which obsolete class can be quarantined or retired. The migration fails
closed if the database is already over the limit.

## 4. Validate the complete staging flow

Both shipped app configurations use the shared production catalog. For a
staging validation build, override both hosts at build time without editing the
tracked xcconfig files:

```text
BICINO_MAP_CATALOG_HOST=maps-share-staging.8o.vc
BICINO_MAP_R2_DOWNLOAD_HOST=5834cd65d5f197557149dbc10074d37f.r2.cloudflarestorage.com
```

The staging override uses an isolated Keychain account, so it cannot send or
replace the production library credential.

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

Both iOS xcconfig files pin the account's exact
`5834cd65d5f197557149dbc10074d37f.r2.cloudflarestorage.com` hostname. Keep that
value aligned with the R2 account used by the catalog. The app still validates
the grant, signer, artifact metadata, and redirect host before downloading; an
inactive account or missing bucket fails at the network boundary.

## 5. Complete the abuse and billing gate

Do not deploy production until the controls below have a private rollout
receipt. A Worker runtime rate limiter executes only after a request has
invoked the Worker. The zone custom rule rejects unknown routes first, and the
zone rate-limiting rule is the request-volume brake for every allowed route.
Cloudflare documents that a terminating custom-rule Block stops later phases,
and that
[custom rules run before rate limiting](https://developers.cloudflare.com/waf/feature-interoperability/#execution-order).

### Block every route outside the catalog allowlist

Free zones have
[five WAF custom rules and support Block](https://developers.cloudflare.com/waf/custom-rules/#availability).
In the Cloudflare dashboard, select the `8o.vc` zone, then open **Security >
Security rules > Create rule > Custom rules**. Use the Expression Editor, set
the rule name to `bicino-map-catalog-route-allowlist`, choose the default
**Block** action, and place it first in the zone custom-rule list. Do not
configure a paid custom response; the expected Free-plan response is the
default `403`.

The durable boundary follows the stable route families rather than enumerating
every current endpoint. Query strings do not affect the path match:

| Methods                          | Allowed path family                             |
| -------------------------------- | ----------------------------------------------- |
| `GET`                            | exact `/healthz`                                |
| `GET`                            | exact AASA path, with or without `/.well-known` |
| `GET`                            | `/s/*` and `/dev/s/*` share landings            |
| `GET`, `POST`, `PATCH`, `DELETE` | `/v1/*` app and authenticated internal APIs     |

The Worker does not implement `HEAD`, `PUT`, `OPTIONS`, or any other method, so
the rule does not admit them. Unknown paths inside `/v1/`, `/s/`, or `/dev/s/`
can reach the Worker and receive its bounded `404`, but the rate-limiting rule
below counts those requests before invocation. This is intentional: it keeps
the custom expression stable for new `/v1/` endpoints, including a future
topographic map API, without reopening the cost boundary.

Paste this compact expression in the Expression Editor. It uses the documented
[`http.host`](https://developers.cloudflare.com/ruleset-engine/rules-language/fields/reference/http.host/),
[`http.request.method`](https://developers.cloudflare.com/ruleset-engine/rules-language/fields/reference/http.request.method/),
and
[Rules language functions](https://developers.cloudflare.com/ruleset-engine/rules-language/functions/),
and remains well below Cloudflare's
[4,096-character expression limit](https://developers.cloudflare.com/ruleset-engine/rules-language/expressions/#maximum-rule-expression-length).

```text
(http.host in {"maps-share-staging.8o.vc" "maps-share.8o.vc"} and not ((http.request.method eq "GET" and (http.request.uri.path in {"/healthz" "/.well-known/apple-app-site-association" "/apple-app-site-association"} or starts_with(http.request.uri.path, "/s/") or starts_with(http.request.uri.path, "/dev/s/"))) or (http.request.method in {"GET" "POST" "PATCH" "DELETE"} and starts_with(http.request.uri.path, "/v1/"))))
```

Before deploying it, audit the `8o.vc` zone for URL Rewrite Rules and IP Access
Allow rules that match either catalog hostname. Rewrites run before custom
rules, and an IP Access Allow can bypass custom rules; remove or narrow any
conflict. Cloudflare documents these
[phase interactions](https://developers.cloudflare.com/waf/troubleshooting/phase-interactions/).

Prove the custom rule in staging before creating the rate-limiting rule:

1. In **Cloudflare dashboard > Trace**, simulate the three exact `GET` paths,
   `GET /s/probe`, `GET /dev/s/probe`, and `GET`, `POST`, `PATCH`, and `DELETE`
   requests to `/v1/probe`. Retain the exported trace results showing the
   custom rule does not match and the catalog Worker route is reached. Trace is
   [available on all plans and reports Workers routing](https://developers.cloudflare.com/rules/trace-request/how-to/#steps-in-trace-results).
2. Trace `GET /_waf_probe/<nonce>`, `PUT /healthz`, `POST /s/probe`, and
   `HEAD /healthz`. Retain results showing the custom rule takes the terminating
   Block action and no Worker step executes. Separately trace
   `GET /v1/_waf_probe/<nonce>` and retain evidence that it reaches the Worker
   and the path-only rate-limiting rule applies.
3. Send the four blocked requests to the staging hostname. Each must return
   Cloudflare's default `403` with a `cf-ray`. In **Security > Analytics >
   Events**, retain the sampled custom-rule event for at least one probe.
4. Compare the staging Worker's request metric before and after a bounded batch
   of unknown-path probes. After metrics settle, the batch must appear in WAF
   events but not as an equivalent increase in Worker requests. Record the UTC
   interval, probe count, rule ID, and metric screenshots.
5. Confirm the live `/v1/_waf_probe/<nonce>` receives the Worker's `404`, not a
   WAF `403`. Then complete Section 4 again. Health and AASA must return `200`;
   all app, share-landing, publication, retention, and promotion flows must
   reach their expected Worker response without a WAF `403`.

### Install the one Free-plan WAF rate-limiting rule

In the Cloudflare dashboard, select the `8o.vc` zone, then open **Security >
Security rules > Create rule > Rate limiting rules**. The
[Free-plan matrix](https://developers.cloudflare.com/waf/rate-limiting-rules/#availability)
allows one zone rule, only `Path` (and Verified Bot) in its match expression,
only IP as its counting characteristic, and fixed 10-second counting and
mitigation periods. Therefore, first inventory every proxied hostname and
Worker Custom Domain in the `8o.vc` zone and verify that no non-catalog service
uses exact path `/healthz`, either AASA path, or prefixes `/v1/`, `/s/`, or
`/dev/s/`. Stop if any path collides: the Free rate-limiting rule cannot also
match `Host`, so it cannot safely distinguish that service. The hostname-scoped
custom rule above does not remove this zone-wide counter collision.

Create and deploy exactly this rule:

```text
Rule name: bicino-map-catalog-free-plan-guard
When incoming requests match:
  http.request.uri.path eq "/healthz" or
  http.request.uri.path eq "/.well-known/apple-app-site-association" or
  http.request.uri.path eq "/apple-app-site-association" or
  starts_with(http.request.uri.path, "/v1/") or
  starts_with(http.request.uri.path, "/s/") or
  starts_with(http.request.uri.path, "/dev/s/")
Counting characteristic: IP
When rate exceeds: 60 requests in 10 seconds
Action: Block (default response)
Duration: 10 seconds
```

Leave **Also apply rate limiting to cached assets** enabled, do not add a
custom counting expression, and do not configure a custom response. The
checked-in maintenance defaults retry at most four catalog publications and
process at most five retention objects per channel. That is a maximum of 15
internal calls per pass: four finalizations, one authorization, five claims,
and five confirmations. Development and production maintenance can overlap
behind the same Coolify source IP, making 30 requests in 10 seconds. The
60-request threshold leaves 30 requests of headroom for immediate publication,
promotion, app traffic, and network retries. Do not raise either catalog batch:
the backend rejects values above 4 or 5, and the shared service limiter remains
30 calls per channel per minute.
Because Free counts by IP and Cloudflare data center, shared carrier/NAT users
can share a counter, distributed attackers can use separate counters, and
counter propagation is not instantaneous. This is not a hard request or spend
cap; retain the application's persistent quotas and endpoint-specific limits.

Verify the rule against staging from one controlled, non-shared source:

1. Complete the normal Section 4 app and publisher flow and confirm it never
   triggers the rule.
2. Confirm `/healthz` and both AASA paths return `200`, then send at least 70
   requests inside 10 seconds to an allowed but nonexistent staging share path
   such as
   `https://maps-share-staging.8o.vc/v1/shares/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA`.
   Record the status sequence and one `cf-ray`; initial responses should be the
   Worker response and later responses should be Cloudflare's default `429`.
3. During the mitigation window, request `/healthz` and both AASA paths from
   the same source. Each must also return `429`, proving there is no allowed
   cheap-route bypass. After the 10-second mitigation expires, all three must
   return `200` again.
4. In the `8o.vc` zone open **Security > Analytics > Events**, constrain the
   window to the test, and retain the sampled event showing the rule name,
   Block action, matched path, and Ray ID. Free-plan events are sampled, so the
   HTTP `429` capture remains required even if no event is displayed.
5. Save a screenshot of the deployed rule showing its expression, IP counter,
   `60 / 10 seconds` threshold, 10-second duration, and rule identifier. Record
   the UTC test time and operator in the rollout receipt.

If normal staging traffic is blocked, do not guess a higher threshold. Measure
the largest legitimate 10-second burst, document the shared-IP impact, and
review the new value before production.

### Enable billable-usage visibility and a low-dollar alert

These controls require the account owner to complete the R2 subscription
checkout at **Storage & databases > R2 > Overview**. That activates R2's
pay-as-you-go subscription even though the service has a free monthly
allowance. If **Manage Account > Billing > Billable Usage** is unavailable, the
activation and billing gate is incomplete.

1. Open **Manage Account > Billing > Subscriptions** and retain a redacted
   screenshot showing the active R2 subscription and billing-cycle start.
2. Open **Manage Account > Billing > Billable Usage**, select the current
   billing period, filter Product family to `R2`, and record the displayed
   total usage, billable usage, and usage cost. Retain a screenshot even when
   each value is zero or inside the free allowance.
3. On **Billable Usage**, select **Create budget alert**. Create
   `bicino-map-library-account-spend-usd-1` with a **USD 1** threshold and the
   account owner plus the map-platform operator as email recipients. Budget
   alerts are account-wide, so the description must say that unrelated
   usage-based Cloudflare products also contribute to this threshold.
4. Reload **Billable Usage > Budget alerts** and retain a redacted screenshot
   showing the saved name, USD 1 threshold, and expected recipients. Record the
   UTC verification time and operator beside the WAF receipt. If Cloudflare
   enforces a higher minimum, stop and record the UI error rather than silently
   choosing a less protective threshold.

The [Billable Usage dashboard](https://developers.cloudflare.com/billing/manage/billable-usage/)
shows daily usage-based costs, and
[budget alerts](https://developers.cloudflare.com/billing/manage/budget-alerts/)
send one email after account-wide spend crosses the threshold. Both are
informational and can lag usage; they do not pause requests, cap R2 or Workers,
or limit the invoice. The monthly invoice remains authoritative. Review the R2
rows and receipt at least weekly during rollout and immediately after an abuse
event.

## 6. Production promotion

A production operator can turn the exact final development ZIP into a
production-signed stream without rerunning OSM extraction:

```sh
map-platform promote-catalog-map <mapEntryId>
```

Run this only in a production worker image with production catalog credentials,
the production bucket, production map-signing key, and exact producer identity.
The command streams and verifies the ZIP, validates every payload file and
renderer capability, records the discrete reader contract, signs a new
`bike-map-stream-v1`, uploads it immutably, and finalizes it under the same map
entry. A production app never receives the original development stream.

## 7. Production and rollback

Repeat provisioning with `bicino-final-maps-dev`,
`bicino-final-maps-prod`, `bicino-map-catalog`, and `maps-share.8o.vc`. Apply D1
migrations before deploying the production Worker. Wrangler secrets are scoped
to the selected environment, so provision the production Worker independently:

```sh
cd map-platform/catalog
pnpm exec wrangler secret put SERVICE_KEYS_JSON --env production
pnpm exec wrangler secret put R2_DEVELOPMENT_ACCESS_KEY_ID --env production
pnpm exec wrangler secret put R2_DEVELOPMENT_SECRET_ACCESS_KEY --env production
pnpm exec wrangler secret put R2_PRODUCTION_ACCESS_KEY_ID --env production
pnpm exec wrangler secret put R2_PRODUCTION_SECRET_ACCESS_KEY --env production
pnpm exec wrangler d1 migrations apply bicino-map-catalog --env production --remote
pnpm exec wrangler deploy --env production
```

Do not assume staging secrets carry into `--env production`, and do not copy a
staging secret value into production. Move one environment at a time through
`filesystem` to `mirror` to `s3` and inspect health/catalog state at every step.

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
