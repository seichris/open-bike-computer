# ADR 0006: Cloudflare R2 final-map library

- Status: Accepted for staged rollout
- Date: 2026-08-25

## Decision

Store immutable final map ZIP and signed stream artifacts in separate private
Cloudflare R2 development and production buckets. Use a Cloudflare Worker and
D1 as the shared library, alias, publication, authorization, and share-link
control plane.

Coolify keeps generation jobs, source extracts, intermediates, queues, caches,
and scratch data. It publishes verified final artifacts through the existing
S3-compatible seam. The catalog supplies short-lived reads and never gives an
app or development publisher production write authority.

Mutable user names are per-library aliases, not map metadata. Development
payloads enter production only through strict validation and production
re-signing of the final ZIP. Renderer family/version/features make the shared
identity extensible to a future topographic format.

## Consequences

Both app channels can discover the same exact map entries and share revocable
links without adding a continuously running Coolify service. The design adds a
D1 schema, Worker operations, R2 credentials, associated domains, and a shared
Keychain capability that must be validated in distribution profiles. CloudKit
is not used because the server publishers and public link gateway require a
platform-neutral control plane.

The rollout and rollback gates are documented in
`docs/runbooks/cloudflare-r2-final-map-library.md`.
