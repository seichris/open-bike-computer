# Firmware build caching

Keep using `python3 tools/build_firmware.py <environment>` from `esp32/`.
There is no cache setup command and no change to the upload workflow.

## What is reused

The pinned host runtime is shared at
`~/Library/Caches/OpenBikeComputer/firmware-runtime` on macOS. Verified compiled
core transport entries are shared at
`~/Library/Caches/OpenBikeComputer/firmware-builds`. Linux uses
`$XDG_CACHE_HOME/open-bike-computer/` or `~/.cache/open-bike-computer/`.
`OPEN_BIKE_FIRMWARE_BUILD_CACHE` selects an absolute isolated build-cache root,
primarily for CI and qualification; unsafe paths are rejected.

The same shared build-cache root keeps pinned download archives by SHA-256.
Each receiving worktree verifies the pinned size, digest, owner and permissions,
then copies the archive into its private download store without network access.
The shared payload is immutable and atomically published; APFS file clones
avoid duplicating unchanged archive bytes on this Mac.

Shared core lookup covers the exact environment, host runtime, PlatformIO
configuration, platform/package pins, declared component/partition inputs,
and the core-producing tools. Generated SDK sidecars and the complete original
archive are hashed and checked before restoration. Files, modes, owners, links,
archive inventory and manifest identities receive the same checks as private
core entries. Publication is atomic and serialized per environment. A dirty
build may consume an entry but cannot publish one. Corrupt shared entries stop
the build; they are never silently used or overwritten.

The receiving worktree restores its own mutable tools and packages. Absolute
symlinks are rebased by the existing archive extractor; UTF-8 launchers and
configuration referring to the producer are rebased to the receiving project.
Compiled binaries remain byte-exact. The derived tree is independently
attested and published as an immutable private entry before PlatformIO runs.
The producer need not remain on disk. Shared cache entries are trusted local
build outputs, not remotely signed releases or substitutes for the pinned
runtime trust contract.

Compiler objects stay private to the worktree and profile. Their namespace
uses the exact core input key rather than the entire application Git identity.
SCons still fingerprints source files, included headers, and effective compiler
commands. Git SHA and commit timestamp are included only in
`firmware_metadata.cpp`, through a generated header with an explicit dependency.
Changing a commit therefore recompiles metadata and changed sources while
allowing unchanged libraries to be restored. Raw unverified builds retain
their previous global identity flags. Version, board/profile, and configuration
changes still affect normal compiler input identities.

Final ELF linking is excluded from artifact caching, so each build produces
its own linker map. Firmware/build manifests and upload plans remain private
and bound to the exact clean source commit. No shared firmware image or upload
plan authorizes a device write.

## CI and qualification

The reusable firmware-cache action restores pinned runtime transport, verified
core transport, and application compiler objects. Keys separate OS,
architecture, environment and build tools/configuration. Each source commit
saves a fresh cache snapshot with a matching-input restore prefix. CI, release
candidates, diagnostics, and speaker builds use this action. Mutable toolchain
trees, current firmware manifests, upload plans, and final images are excluded.

The **Firmware cache qualification** workflow checks both supported native
hosts and both boards' ordinary/production profiles. Each job builds:

1. A cold source worktree with an empty isolated compiled-core cache.
2. A same-head warm rebuild, requiring matching image, ELF and flash-plan hashes.
3. A source-only commit, requiring the same core key and compiler cache hits.
4. A fresh worktree at a different path after the producer has been removed,
   requiring a core hit, no core bootstrap, and identical flashable image hashes.

The different-path ELF and flash-plan hashes may differ because debug paths and
private uploader/image paths are worktree-local; the actual flashable image
hashes must match. All phases require a fresh linker map. Timing JSON and full
logs are retained. Run this qualification before accepting changes to cache
keys or relocation rules; passing host tests alone does not qualify relocation.

After identifying the connected board, the same build-only check is available
locally from the repository root:

```sh
python3 esp32/tools/benchmark_firmware_cache.py WAVESHARE_AMOLED_175 \
  --output /absolute/path/cache-evidence/results.json
```

The benchmark creates only its own detached worktrees and a temporary transport
cache. It retains logs/JSON outside those worktrees and removes its temporary
state, including on failure. It never flashes a device. Real timing records
include setup, core bootstrap, application compilation, final linking and
attestation; use these measurements rather than assuming a cache hit saves a
fixed number of seconds. CI artifacts report the exact tested source identities.
