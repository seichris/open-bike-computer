# Backend-first durable map rollout

This change lands the backend and catalog contract regressions from #645 at
`c3c74d8eff218b26cc822bd2795cd96bf21ba160`, without its app or firmware changes.
The frozen contract-v1 corpus is copied byte for byte. It is not regenerated.
The remaining reader changes stay in #645 and the integration candidate #650.

The development worker pinned before this rollout is built from `296a5dbf`.
It does not implement the compatibility contract. Installing a newer Bicino Dev
or firmware does not change that producer: even a newly generated map remains
unmarked until the backend image is promoted.

## What changes on the backend

For covered profiles, the producer signs `"compatibility":{"contract":1}`
into the canonical manifest and stores the same classification in
`artifactMetrics.compatibilityContract`. The contract in
`map-platform/config/map-compatibility-contract-v1.json` defines the profiles
and allowed publishing channels. Renderer targets 1 and 2 stay unmarked.
Production does not gain permission to publish development-only POI profiles.

Reuse schema 5 prevents a new request from reusing an unmarked pre-baseline
artifact. Reused durable jobs retain their classification. Direct-job delivery
and catalog publication omit exact firmware build requirements for durable
maps, while preserving signer, producer approval, integrity and rollout gates.
Previously approved durable producers remain deliverable after a worker update
while their approvals and signing keys remain trusted.

The signer registry and frozen producer corpus enforce these backend contracts
and catalog delivery behavior. The new app and firmware corpus consumers remain
part of the separate reader change. Passing these checks is not physical
acceptance or evidence that either live backend has been updated.

## Development rollout and verification

1. Merge this source change through a PR after the exact candidate's CI Gate
   passes. Do not merge #650 or the firmware changes merely to publish maps.
2. Wait for Map Platform Image to publish and attest the merged source. Review
   the generated development promotion, which updates only
   `map-platform/deploy/compose.development.yaml`.
3. Verify both digest/source pairs and CI Gate, then merge that development
   lock. Verify the running deployment and `/healthz` afterward.
4. In Bicino Dev, request a new covered Standard map from the development
   server. Inspect the downloaded signed manifest, not only the UI: require
   contract 1 and the newly promoted producer identity. Verify the saved copy
   remains readable and installable by the intended bike. A previous unmarked
   map must not satisfy this test.

The baseline starts with marked signed bytes, not a calendar date. Existing
maps are not deleted, rewritten or silently reclassified.

## Production and recovery

This source change does not modify a Compose lock, rollout approval, signing
key, catalog deployment, installed app or firmware image. Production promotion
still requires its worker approval and hardware gates. In particular, do not
merge a worker-moving production lock whose digest is absent from the selected
approval; the API in `all` mode will refuse to start.

Production's full future-map guarantee also depends on shipping the reader
changes and qualifying the exact release images. Development installation
evidence does not establish that production gate.

Rollback a development deployment through a PR restoring its complete previous
lock, including both source markers and image digests. Older controllers retain
the compatibility metric but may again attach firmware requirements or hide
earlier producers. Updated readers still derive durability from the signed
manifest; a backend rollback does not rewrite signed map bytes. Keep the
production lock and the firmware release hold independent of this rollout.
