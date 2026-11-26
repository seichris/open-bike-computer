# Production map controller approval release

The registry-only image uses the live production Strava controller
`sha256:e16f7fb10f480ef9605994191ee874cb16f3ed4a2c93a2412a2aef76cfbb5a35`
(source `29aa415e21eacaae83e8d801815b409a0a5178e9`). Before rebuilding the profile,
compare that base to the healthy controller running in production.

The build replaces the public approval registry and validates the `/app` file
inventory against that immutable base. It checks durable delivery, rejects wrong
signer and producer identities, and tests the build-104 compatibility anchor.
The entrypoint allows API and maintenance
commands. The production lock independently selects the approved generation
worker and promotion scheduler.

## Contract 1 history

Approval `msr-20261029-durable-contract1` retains all previous approvals. For
marked contract-1 artifacts, the backend checks the approved producer and signer
without requiring the requesting app or firmware's exact build. Legacy unmarked
maps from the selected producer retain the existing firmware-104 anchor.
Historical unmarked direct-job artifacts from a different producer are no longer
downloadable through this policy after the switch, even by previously approved
apps 24–30. Already installed maps are not deleted or rewritten. This is the
maintainer's explicit forward-only scope, not a promise of legacy redelivery.
Contract-1 artifacts from retained, trusted prior approvals stay deliverable.
Standard format-3 maps are covered;
legacy formats 1/2 are not retroactively classified, and this rollout does not
enable production contour/POI generation.

The approval records software review under Chris's 2026-10-29 instruction to
proceed with merges and releases after recording the incomplete USB cold capture
and pending production qualification. No optional physical production runs are
claimed. Diagnostic 1.75 evidence is distinct from production on either board.

## Publish and deploy

After merge, publish using the existing isolated profile:

```sh
gh workflow run map-platform-image.yml --ref main \
  -f release_profile=production-map-client-compatibility
```

Prepare a production Compose lock containing the controller from this profile,
the exact worker digest recorded in the approval registry, and its promotion ID.
Preserve the existing production credentials, volumes, generation policy and
enabled integrations. Require image provenance and CI Gate before merging the
lock. Verify the live controller, worker, scheduler and contract-aware map
delivery after deployment. Check contract-aware delivery before any associated
firmware release, as required for the original build-105 rollout. Roll back the
complete previous lock and retain all approval history and signed map bytes.
