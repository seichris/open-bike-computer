# Production authentication compatibility candidate

Status: **draft, not approved for deployment**. This prepares the dedicated
compatibility release allowed by the deployment runbook. It does not waive the
worker gates or enable a new-API/old-worker override.

## Scope and evidence

The runtime starts from the exact production image digest
`sha256:142957ae0d5f08d366b657f9bacb0ce17d85bfac9c5d98c644bc1b02188a59c8`,
source `e739dfe6c0612e95db8241249dcc2edfe52d8372`. No runtime packages are
installed or upgraded. The builder checks the base API's SHA-256 before making
changes and transplants only authentication handlers and assertion checks
from the reviewed current source. All job-creation, idempotency, rate-limit,
storage, pipeline, source-cache, generator, signing, and maintenance code stays
at the base version. Existing catalog requests use the backward compatibility
deployed in PR 405.

The current App Attest verifier and Apple root certificate are copied unchanged.
The production verifier retains its production bundle, environment, validation
category, certificate, nonce, challenge, and assertion-counter checks. Tests
inject a verifier directly; no production environment variable enables it.

The compatibility image's entrypoint allows only the exact API and maintenance
commands in the production manifest and rejects inline/generation workers.
The original generation image and worker source marker must remain pinned.
The base producer-identity file is retained solely for the unchanged worker's
control-plane checks; this compatibility image is never a signing candidate.

## Local verification

Use OrbStack on macOS, from the repository root:

```sh
docker build --platform linux/amd64 --target validation \
  -f map-platform/deploy/compatibility/Dockerfile .
docker build --platform linux/amd64 --target runtime \
  -f map-platform/deploy/compatibility/Dockerfile \
  -t bicino-production-auth-compat:local .
```

Validation runs the existing App Attest cryptographic/store tests plus actual
generated-API tests for enrollment, refresh, owner isolation, signed creation,
missing assertions, idempotent replay, restart persistence, and role guards.
It compares every file under `/app` with the base: the only permitted changes
are `api.py`, `app_attest.py`, and the Apple certificate. HTTP test dependencies
exist only in the `validation` stage, never the `runtime` stage.

## Existing-download migration is a deployment blocker

The previously installed app deletes an installation credential without a usable
App Attest key before enrollment succeeds. Enrollment issues a new installation
identity. The compatibility API correctly refuses to give that new identity
access to another installation's jobs. Old credentials remain valid for reading
their own jobs, but the API cannot recover a credential already deleted from
the phone's Keychain.

Therefore a successful challenge endpoint is NOT proof that old downloaded maps
can attach. Before release:

1. Ship the credential-preserving app upgrade in this candidate together with
   the authenticated enrollment migration. It retains the old installation ID
   only when the caller proves possession of its existing token and a valid new
   Apple attestation. Existing bindings cannot be replaced. The app keeps its
   old credential on failure and persists the generated key before submission,
   allowing authenticated refresh to recover a lost enrollment response.
2. For phones that already lost that token, define and obtain approval for a
   scoped recovery flow. Do not infer ownership from a map ID, filename, or
   public hash; do not reassign jobs or insert catalog references directly.
3. Verify the affected production downloads on the actual phone, including
   catalog attachment and Share-button visibility. Test fixture success is not
   physical-app evidence.

No iOS credential mutation, data migration, production restart, or deployment
is part of this preparation. The current production maps and generator remain
unchanged.

## Publish only after review and migration gates

After merging the reviewed preparation through a PR to `main`, the existing
Map Platform Image workflow supports an explicit candidate-only dispatch:

```sh
gh workflow run map-platform-image.yml --ref main \
  -f release_profile=production-auth-compatibility
```

This validates the compatibility image, publishes only its runtime target under
the source SHA plus `-auth-compat`, and attests it using the existing trusted
workflow. It does not move `latest`, replace the pending full-worker promotion,
or create either automatic deployment promotion. Standard builds are unchanged.

Record the source SHA, immutable candidate digest, base digest, validation run,
and migration receipt. Verify registry architecture and GitHub provenance with
the existing tooling. Prepare a dedicated reviewed Compose-lock PR changing
only the control-plane source/digest and retaining the exact worker source/digest.
Never substitute the standard image built at the same source SHA.

Do not merge that deployment PR until its exact CI Gate passes and all migration
gates above have evidence. After deployment, verify API and maintenance health,
the unchanged worker image, production App Attest enrollment, existing-map
attachment, and the app UI. Roll back through a PR restoring the complete prior
Compose lock; preserve the new App Attest database and do not restore an older
authentication snapshot over newly enrolled principals.
