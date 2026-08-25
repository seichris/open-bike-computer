# Bicino map catalog

This Cloudflare Worker is the shared control plane for final offline maps. It
stores only metadata in D1 and grants short-lived reads from two private R2
buckets. Development and production map generators remain on Coolify and keep
all source data, intermediate files, queues, and scratch space on their own
volumes.

The catalog provides:

- an app library credential shared by Bicino and Bicino Dev through a Keychain
  access group;
- immutable map and artifact identities with mutable per-library aliases;
- revocable share links with explicit recipient claim;
- exact app-build and signing-key checks before selecting an artifact;
- authenticated, idempotent publication from both map servers; and
- a production promotion grant for validating and re-signing a development
  final ZIP without regenerating the map.

R2 buckets are private. The Worker has Object Read-only credentials for each
bucket and creates 15-minute presigned GET URLs. Coolify publishers use
different bucket-scoped write credentials.

## Development

Install the pinned package manager and run every local check:

```sh
corepack enable
pnpm install --frozen-lockfile
pnpm check
```

`pnpm check` typechecks the Worker, runs the D1 integration tests, and performs
staging and production Wrangler dry-runs. It does not deploy anything.

The checked-in `wrangler.jsonc` contains the provisioned staging D1 binding and
the repository owner's non-secret Cloudflare/Apple identifiers. The production
D1 binding remains invalid until staging passes; replace it only during the
production step in
[`../../docs/runbooks/cloudflare-r2-final-map-library.md`](../../docs/runbooks/cloudflare-r2-final-map-library.md).

## Security boundaries

- `SERVICE_KEYS_JSON` contains independent, channel-scoped development and
  production HMAC service principals; request signatures bind the method,
  path, timestamp, idempotency key, and body SHA-256. A principal has the shape
  `{"channel":"development|production","secret":"..."}`.
- `R2_DEVELOPMENT_*` and `R2_PRODUCTION_*` are read-only credentials and must
  never be reused by a map publisher.
- Share previews contain bounded metadata and never reveal an R2 key or a
  download URL.
- Opening a share landing page never claims or downloads a map.
- Unauthenticated library bootstrap is protected by per-client and
  per-location Cloudflare rate-limit bindings. The counters are intentionally
  separate between staging and production; keep their namespace IDs unique
  within the Cloudflare account.

Schema changes belong in numbered files under `migrations/` and must be applied
to staging before production.
