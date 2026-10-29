# Production map controller approval release

This registry-only image now starts from the attested contract-1 runtime
`sha256:d8b9d172d657cbfa7298e970968b64520c6b3d00f8dcb28758bab8f8cef3a9b9`
(source `8104250ca68499a50c9ec68b9102f13fe1ab5965`). This is an intentional
production backend upgrade from the previous controller, not merely an app
allowlist extension. The base is the unchanged runtime already used to generate
the development contract-1 Shanghai maps. Its recomputed producer identity is
`fabfedc35cbb2443b442d2b64753e438c40559b1eac0c98db6d3f675e9cd3d9f`.

Only the public approval registry under `/app` is overlaid. Validation compares
the entire runtime inventory to that immutable base, runs its own rollout tests,
and checks durable delivery across client upgrades, wrong signer/producer
rejection, and preservation of the legacy build-104 anchor. The entrypoint rejects
generation and inline-worker commands. The actual generation worker remains the
exact base image, independently pinned; do not use the controller as a worker.

Approval `msr-20261029-durable-contract1` retains all previous approvals. For
marked contract-1 artifacts, the backend checks the approved producer and signer
without requiring the requesting app or firmware's exact build. Legacy unmarked
maps retain the existing firmware-104 anchor. Standard format-3 maps are covered;
legacy formats 1/2 are not retroactively classified, and this rollout does not
enable production contour/POI generation.

The approval records software review under Chris's 2026-10-29 instruction to
proceed with merges and releases after recording the incomplete USB cold capture
and pending production qualification. No optional physical production runs are
claimed. Diagnostic 1.75 evidence is distinct from production on either board.

After merge, publish using the existing isolated profile:

```sh
gh workflow run map-platform-image.yml --ref main \
  -f release_profile=production-map-client-compatibility
```

Publish the updated dedicated promotion scheduler separately with
`release_profile=production-map-promotion`. Then prepare one reviewed production
Compose lock: controller from this profile, worker at the base digest above,
promotion scheduler at its new attested digest and converter identity at the same
base. Select `msr-20261029-durable-contract1` for API and worker. Preserve existing
production credentials, volumes, generation policy and enabled integrations.
Require image provenance and CI Gate before merging the lock. Verify live health,
worker identity, scheduler health and contract-aware delivery before publishing
firmware build 105. Roll back the complete previous lock; never remove approval
history or mutate already signed map bytes.
