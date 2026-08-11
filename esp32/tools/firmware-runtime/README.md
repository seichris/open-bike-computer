# Firmware host runtime

Ordinary firmware builds consume only an accepted, content-pinned bundle from
`lock-v1.json`. A bundle contains an extracted CPython 3.13 runtime, exact
PlatformIO/uv executables, their complete installed distributions, the
pioarduino root and ESP-IDF Python closures, and a canonical per-file inventory.

The accepted lock set is `firmware-runtime-2026-08-10-1`. It supports exactly
`linux-x86_64-cp313` and `macos-arm64-cp313`; other operating-system,
architecture, and Python ABI combinations fail before PlatformIO starts. The
immutable bundles and their contracts, license evidence, and offline-replay
records are published in the
[`firmware-runtime-2026-08-10-1` prerelease](https://github.com/seichris/open-bike-computer/releases/tag/firmware-runtime-2026-08-10-1).
The dual-host candidate and clean/warm/tamper evidence came from
[workflow run 31459192166](https://github.com/seichris/open-bike-computer/actions/runs/31459192166).
The Linux bundle requires `manylinux_2_34_x86_64`; the macOS bundle requires
`macosx_11_0_arm64`.

## Ordinary builds and repair

Keep using the repository helper:

```sh
python3 tools/build_firmware.py WAVESHARE_AMOLED_175
python3 tools/build_firmware.py WAVESHARE_AMOLED_206
```

The caller's Python executes only the tracked standard-library bootstrap. The
helper validates the canonical lock, selects the exact host target, rehashes or
downloads its immutable bundle, safely publishes a read-only user cache entry,
hydrates this worktree's private runtime below `.pio/open-bike-build/`, and
re-executes under the locked CPython. It never falls back to ambient
PlatformIO, pip, uv, another worktree, or a temporary environment.

If validation reports a corrupt runtime, rebuild only that lock/target subtree
with the same build command plus `--repair-runtime`. Repair re-downloads the
already locked bytes; it does not update dependencies or weaken validation.
The optional `OPEN_BIKE_FIRMWARE_RUNTIME_CACHE` override is intended for an
absolute, isolated CI cache root and receives the same path and symlink checks.

The shared transport cache is content-addressed and rehashed before use. All
mutable PlatformIO, package, build, manifest, and upload state remains private
to the current worktree. Accepted runtime trees are read-only, and a changed
member fails before PlatformIO executes.

## Refreshing the lock

Dependency refresh is a manual maintainer operation through
`.github/workflows/firmware-runtime-refresh.yml`:

1. build independent candidates for both supported hosts;
2. require byte-identical A/B bundles, contracts, and evidence;
3. replay pioarduino and ESP-IDF environment creation offline from empty
   caches;
4. inspect every pinned dependency and license record;
5. prove clean and warm builds for both Waveshare targets and prove a mutated
   accepted runtime fails before PlatformIO;
6. publish new immutable prerelease assets without replacing an existing tag
   or asset; and
7. assemble and review a new lock with exact URLs, sizes, SHA-256 values, and
   `accepted: true`.

Workflow artifacts and Actions caches are review inputs, never accepted runtime
URLs. `--repair-runtime` cannot perform a refresh.

The trust boundary still includes the host operating system and the initial
Python standard library (or the recovery script's operating-system download and
hash tools). The lock removes mutable global Python packages and launchers from
the firmware dependency closure; it does not claim to defend against a
malicious kernel, interpreter, or filesystem.
