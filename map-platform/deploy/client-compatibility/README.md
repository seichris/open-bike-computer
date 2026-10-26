# Production map client compatibility release

This controller-only image admits exact approved App Store app identities while retaining the qualified generation worker.

The runtime starts from production controller `sha256:a007eb1beeeba69e51a287394aa2741879598d55a7586fff1d13f3e0004e29f0` (source `2e4d28554061f3b7243fd7f8d21fe628a407f67b`). Only the public approval registry under `/app` is replaced. The API, rollout implementation, authentication, jobs, storage, converters, signing, maintenance and producer identity stay byte-identical to that base. The entrypoint rejects generation and inline-worker commands. Runtime validation checks the complete file inventory and uses the frozen base image's rollout tests, plus exact-client and artifact rejection cases. Current main's newer rollout implementation is not overlaid onto the older production API.

Each admitted client has an independent exact approval. Compatibility requires equality of candidate source, producer digest, worker image digest, firmware version/build/source, requirements hash, and the complete approved signing-key set. The current rollout promotion remains the cohort selector and hardware anchor. Unknown or mixed client identities remain rejected.

## Bicino 1.11 (30)

The exact signed Release archive comes from GitHub main `25107bf69edab1a62b092ee16bd5500ebe9bbdeb`, with map component `95f7eb0f2df99197c4683e883231d00c216d018dbdeb5c92845b31be1f5bcb05`. Approval `msr-20261026-worker-social-ios30` adds that identity alongside builds 24, 25, 28 and 29 for the existing production worker and firmware.

The approval records software qualification under the maintainer's app-publication request. The checked-in hardware matrix is optional and unchanged; no physical map-transfer, Watch ride, power-loss, battery or thermal acceptance is claimed. Raw qualification notes remain in operator release artifacts. Keep `msr-20261022-worker-social-ios28` selected as the rollout promotion and require production health to advertise `24,25,28,29,30` before App Store submission.

After this preparation merges and no image workflow is active, publish the candidate:

```sh
gh workflow run map-platform-image.yml --ref main \
  -f release_profile=production-map-client-compatibility
```

Review a Compose-lock PR that advances only the controller digest/source. Preserve the generation worker and promotion scheduler pins. Require CI Gate and image attestation verification before merging the lock. Verify the public API remains in `all` mode, requires App Attest, and admits builds 24, 25, 28, 29 and 30. Health is configuration evidence, not physical transfer qualification. Roll back using the previous complete Compose lock.
