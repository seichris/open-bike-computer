# Production map client compatibility release

This dedicated controller image enables independently approved App Store clients to coexist without replacing the qualified generation worker.

The runtime starts from production controller `sha256:1bd81869764ab37d8a8337f4814a540aab3e1deaf62504ef922740c0388e48cc` (source `503ab8945d14857452b77e3ef7d06dd7510e94c8`). Only `map_stream_rollout.py` and the recorded approval registry are replaced. It installs no runtime packages and leaves API routes, authentication, jobs, storage, converters, signing, maintenance, and producer identity unchanged. Its entrypoint rejects generation and inline-worker commands. Validation compares all runtime files against the base and exercises client binding and worker-role rejection.

Each admitted client has an independent exact approval. Compatibility requires equality of candidate source, producer digest, worker image digest, firmware version/build/source, requirements hash, and the entire approved signing-key set. The current rollout promotion remains the cohort selector and hardware anchor. An artifact is bound to the requesting approved app identity; unknown or mixed identities fail closed.

After this preparation and the exact build-25 approval have merged, publish the attested runtime candidate through the protected workflow:

```sh
gh workflow run map-platform-image.yml --ref main \
  -f release_profile=production-map-client-compatibility
```

Review a Compose-lock PR that advances only the controller digest/source. Preserve the generation worker and promotion scheduler pins. Require CI Gate and image attestation verification before merge. Verify public health advertises approved builds 24 and 25, remains in `all` mode, and still requires App Attest. Health is configuration evidence, not physical transfer qualification. Roll back using the prior complete Compose lock.
