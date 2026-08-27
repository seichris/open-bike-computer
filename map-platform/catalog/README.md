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
- versioned reader-capability, delivery-tier, and exact signing-key checks
  before selecting an artifact;
- authenticated, idempotent publication from both map servers; and
- a production promotion grant for validating and re-signing a development
  final ZIP without regenerating the map.

Before either an initial publication or a production promotion becomes live,
the Worker HEAD-verifies every proposed object's exact bucket, key, byte count,
and `sha256` metadata through its read-only R2 credential. An exact
idempotency replay does not repeat those reads.

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

The checked-in `wrangler.jsonc` contains the provisioned staging and production
D1 bindings plus the repository owner's non-secret Cloudflare/Apple
identifiers. Provision or replace the production binding only after staging
passes, following
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
- Public D1 mutations are limited to 6 per library per minute and 20 aggregate
  per Cloudflare location per minute. The library counter is consumed first so
  one credential cannot spend the whole aggregate allowance. Bootstrap has
  separate 6-per-client and 12-per-location limits. Cloudflare rate-limit
  counters are location-local and eventually consistent, so the durable map,
  share, and link-code quotas below remain the authoritative cost bound.
- Signed map-service mutations use a separate 30-per-channel counter. Public
  callers cannot consume publication, retention, or promotion capacity.
- A library may retain at most 100 map references, 100 active shares, 500
  total share rows, 500 recipient share claims, 8 active credentials, 5 live
  link codes, and 50 total link-code rows. Checks are atomic in D1, including
  share claims and library-link merges. A linked group also carries an
  additive, non-resetting eight-principal merge budget across library-ID
  reparenting, and claim rate limits use the credential hash rather than the
  mutable library ID. Old inactive shares are reclaimed only
  beyond `RETENTION_GRACE_DAYS`; expired unclaimed link codes are reclaimed
  immediately, and claimed link evidence is retained through that grace
  window.
- `DELETE /v1/library/maps/{mapEntryId}` removes only the authenticated
  library's reference. It returns 204 for both the first detach and an
  idempotent retry; it never deletes another library's claimed copy, a share,
  or R2 bytes. Detach also removes that library's incoming claims for the map
  and recalculates the affected shares' claim counts, recovering claim quota.
  Active outgoing shares independently keep artifacts retained.
- Download grants and expired link codes are purged in bounded batches during
  later mutations, preventing unbounded D1 accumulation.
- Production promotion has one durable lease per map. The backend renews the
  exact source-artifact lease while downloading, validating, repacking,
  signing, and uploading. Expired leases can be recovered after a crash;
  retries short-circuit once the production artifact is already live.
- Artifact generations are bounded by an exact compatibility class containing
  bucket/channel, delivery tier, format, signer ID and fingerprint, canonical
  reader requirements, and any firmware gate. Producer/build identity is not
  part of the class. Publishing a verified replacement tombstones older rows
  in that class; an active download grant or promotion lease delays the
  transition until maintenance observes expiry. Superseded bytes become
  deletion-lease eligible after `RETENTION_GRACE_DAYS` even while the map stays
  in a library, provided a live same-class replacement still exists at
  authorization, claim, and confirmation.
- A map may have at most 16 distinct retained compatibility classes. Live,
  quarantined, and tombstoned generations all consume capacity; only confirmed
  deletion of the last retained artifact in a class frees its slot. The D1
  trigger enforces the limit atomically under concurrent publication and the
  0009 migration refuses an already-over-limit database. Quarantined artifacts
  remain unavailable to clients, retain active download/promotion protection,
  and become deletion-lease eligible after `RETENTION_GRACE_DAYS` even while the
  map remains referenced. Adding a seventeenth class fails closed; never evict
  a different signer or reader contract implicitly.

Schema changes belong in numbered files under `migrations/` and must be applied
to staging before production.
