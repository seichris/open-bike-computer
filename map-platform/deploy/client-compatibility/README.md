# Production map client compatibility release

This dedicated controller image enables independently approved App Store clients to coexist without replacing the qualified generation worker.

The runtime starts from production controller `sha256:93d9b291cadeb6817733fee51a4a0810a189fe2cfc9b09014defe1d75165f9eb` (source `7ad55f177685807f45ee35846fd4384dc68df97b`). Only `map_stream_rollout.py` and the recorded approval registry are replaced. It installs no runtime packages and leaves API routes, authentication, jobs, storage, converters, signing, maintenance, and producer identity unchanged. Its entrypoint rejects generation and inline-worker commands. Validation compares all runtime files against the base and exercises client binding and worker-role rejection.

Each admitted client has an independent exact approval. Compatibility requires equality of candidate source, producer digest, worker image digest, firmware version/build/source, requirements hash, and the entire approved signing-key set. The current rollout promotion remains the cohort selector and hardware anchor. An artifact is bound to the requesting approved app identity; unknown or mixed identities fail closed.

App Store 1.10 build 29 adds its own archive identity under
`msr-20261020-build104-ios29`, retaining builds 24, 25 and 28. Its source is
`f4513993d2d3a6a9f7ed4c33bd6601e83794dc25` and its map component digest is
`1c071f99ce91d87af4640eea1856888fc1afe1c8338705aee16610089549e4af`.
The app changes from approved build 28 are limited to icon assets, property
lists and version settings; no Swift implementation changed. The report carries
forward the maintainer's recorded physical-risk acceptance and contains no
measured device runs. Keep the existing build-28 rollout promotion selected and
verify production health admits `24,25,28,29` before automatic App Store release.

After this preparation and the exact build-25 approval have merged, publish the attested runtime candidate through the protected workflow:

```sh
gh workflow run map-platform-image.yml --ref main \
  -f release_profile=production-map-client-compatibility
```

Review a Compose-lock PR that advances only the controller digest/source. Preserve the generation worker and promotion scheduler pins. Require CI Gate and image attestation verification before merge. Verify public health advertises approved builds 24 and 25, remains in `all` mode, and still requires App Attest. Health is configuration evidence, not physical transfer qualification. Roll back using the prior complete Compose lock.
