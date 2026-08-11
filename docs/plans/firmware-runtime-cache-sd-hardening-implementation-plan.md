# Firmware Runtime, Core Cache, SD, and Maintenance Hardening Plan

## Status and baseline

This is an implementation plan only. It does not change the firmware build,
flash a device, alter SD behavior, change speaker behavior, or create a local
device registry.

The plan is based on freshly fetched GitHub `origin/main` at
`e5022f83cbc475e770037b9f39e8b11fc94adca3` on 2026-08-10. The implementation
must rebase onto the then-current `origin/main` and re-check every schema,
version, path, and invariant before editing code.

Owner scope amendment (2026-08-11): the one-time playback-demo documentation
coordination originally included in point 8 is no longer required. This
implementation contains no playback-demo code, documentation, build, flash, or
physical-validation work, and none is a completion gate below.

The retained scope is deliberately limited to the earlier recommendations:

1. replace ambient/global PlatformIO with a repository-owned, content-pinned
   host runtime;
2. separate reusable custom-core identity from firmware source identity;
3. make Waveshare SD initialization recover safely from warm-reset bus state;
4. make speaker teardown idempotent and add a local device-name registry.

The following recommendations are explicitly excluded and must not be smuggled
into this work:

- no approval token, two-stage flash approval, or new flash-confirmation
  protocol;
- no generic on-device acceptance-contract framework, stack-watermark
  framework, or profile-specific runtime verifier;
- no unified firmware-test command or replacement test runner; and
- no SD-card media copy, hash-install, sync, or eject tool.

The targeted unit, integration, and physical tests below validate the retained
changes. They do not create any of those excluded productized frameworks.

## Outcome

After all retained workstreams are complete:

- `python3 tools/build_firmware.py <environment>` never imports or executes an
  ambient `pio`, `pip`, or `uv`;
- the exact Python and PlatformIO closure is selected by a tracked lock,
  verified before execution, installed offline into a private location, and
  identified in firmware provenance;
- another worktree or an ad-hoc `/tmp` environment can never become an
  implicit firmware dependency;
- a source-only firmware change reuses an attested custom Arduino core without
  weakening clean-source, artifact, flash-plan, or upload-only validation;
- a core-affecting input change or cache mutation fails closed and rebuilds the
  core;
- a warm-reset SD failure performs bounded, observable teardown/remount
  attempts before falling back to FFat;
- repeated speaker initialization and cleanup do not call I2S operations that
  are invalid for the current resource state;
- developers may refer to explicitly enrolled boards by a local nickname while
  board family and stable USB serial remain visible and validated; and
- build, SD, hardware, and device-registry documentation reflects the
  implemented behavior and the evidence actually collected.

## Current implementation and concrete failure modes

### Ambient Python and PlatformIO

`esp32/tools/build_firmware.py` currently defaults `--pio` to
`PLATFORMIO_CMD` or the first `pio` on `PATH`. The three firmware workflows
also run `python -m pip install --upgrade platformio`. The deterministic
wrapper pins and attests the installed pioarduino platform, framework,
toolchain, uploader, SCons, generated SDK configuration, and final firmware
artifacts, but its first executable is still selected by mutable workstation or
runner state.

A prior local firmware session exposed the operational consequence: an initial
private environment inherited an unhealthy global Python 3.11/PlatformIO path,
while a later ad-hoc Python 3.13 launcher worked. The global launcher happens
to execute today; that does not make it a durable build input.

The current firmware baseline is:

- pioarduino platform `55.03.34`;
- Arduino ESP32 core `3.3.4`;
- PlatformIO core family `6.1.18`;
- generated SDK/core cache schema `19`; and
- Linux CI Python `3.12`.

These are observations, not permanent choices. The runtime refresh process must
lock the exact accepted versions and bytes.

### Core cache coupled to application source

`esp32/tools/generated_sdkconfig.py::_cached_defaults_match()` currently
requires the cache manifest's:

- full clean Git source identity;
- source commit epoch and build timestamp;
- generated SDK configuration;
- full `platformio.ini`;
- managed components and library dependencies;
- installed core attestation; and
- firmware-build context

to match the current checkout. Any source commit therefore invalidates
`sdkconfig.defaults`. `build_firmware.py` then removes the entire
profile-private PlatformIO store and runs the pioarduino toolchain/custom-core
bootstrap again. It also clears the compiler build cache before every accepted
build.

This correctly prevents stale upload provenance, but it conflates two different
identities:

- the custom core, which depends on the toolchain, board, framework, effective
  configuration, and core-generation scripts; and
- the firmware image, which additionally depends on the exact application
  source commit and reproducible build timestamp.

### Warm-reset SD behavior

`Storage::initSD()` creates a static HSPI object, calls `hspi.begin()`, and
makes one `SD.begin()` attempt at the configured 4 MHz operating frequency. A
failure returns immediately. `ensureSdMounted()` calls `SD.end()` before a
later retry but never calls `hspi.end()`.

Arduino ESP32 core 3.3.4 already performs the required SD initialization
sequence inside `ff_sd_initialize()`:

- it starts at 400 kHz;
- sends 160 idle clocks with CS high;
- issues `GO_IDLE_STATE`/CMD0; and
- only uses the requested operating frequency after initialization.

The implementation must therefore fix lifecycle teardown and bounded recovery
first. It must not add a second hand-written SD command implementation or claim
that merely passing 400 kHz to `SD.begin()` fixes an initialization path that
already uses 400 kHz.

### Speaker cleanup

`releaseCodecResources()` calls `i2s_channel_disable(txChannel)` whenever a
channel handle exists. A handle can exist after allocation or standard-mode
configuration even if `i2s_channel_enable()` failed or was never reached. The
return value from disable is ignored, which produces an ESP-IDF error and makes
real audio failures harder to distinguish from cleanup noise.

The same function also needs explicit knowledge of whether the codec device was
opened before deciding which close operation is valid.

### Device identity and superseded demo context

`resolve_upload_port.py` correctly resolves an explicitly supplied stable USB
serial and refuses ambiguity. Developers still have to remember or paste raw
serials, however, which is slow and error-prone when several 1.75-inch devices
share transient `/dev/cu.usbmodem*` paths.

The former one-time playback-demo branch is not part of this implementation.
Main must not gain an orphan README or target for that retired workflow.

## Design invariants

1. **One build authority.** `build_firmware.py` remains the only supported
   build/upload entrypoint for Waveshare firmware.
2. **No ambient executable fallback.** A missing or corrupt locked runtime
   fails with a repair command. It never falls back to `PATH`, live PyPI
   resolution, another worktree, or `/tmp`.
3. **Verify before execute.** Runtime archives and every wheel are identified
   by exact size and SHA-256 and are verified before extraction, install,
   import, or execution.
4. **Separate core reuse from upload eligibility.** Reusing a core never reuses
   a firmware artifact manifest. Upload-only still requires the exact clean Git
   identity, source epoch, generated state, flash plan, and every image hash.
5. **Dirty builds are consumers, not publishers.** A dirty checkout may consume
   a fully verified immutable runtime and core cache, but cannot publish a new
   shared cache entry or become upload-eligible.
6. **Immutable shared inputs, private mutable workspaces.** Cross-worktree
   caches contain content-addressed, read-only archives. PlatformIO builds from
   a project-private hydrated copy; it never mutates a shared accepted entry.
7. **No symlink-based cache trust.** Cache validation and deletion reject
   symlinks, special files, traversal, unexpected ownership, and paths outside
   the exact content-addressed subtree.
8. **No SD protocol fork.** Use the pinned Arduino SD implementation. Recovery
   owns bus/resource lifecycle around it, not a parallel card driver.
9. **Bounded boot latency.** SD retries have a fixed maximum attempt count and
   time budget, then retain the current FFat fallback.
10. **No unsafe rail experiments.** Do not toggle an AXP2101 rail or change
    board pins to reset the SD card without schematic-backed, separately
    reviewed evidence.
11. **Explicit device selection remains required.** A nickname is shorthand
    for a stable serial and board family; it is never permission to guess a
    connected device or skip the repository's physical-board confirmation.
12. **Evidence before documentation claims.** Physical-validation wording
    names the exact target/commit/artifact and observed result. It does not turn
    a demo smoke test into a production-readiness claim.

## Workstream A: repository-owned host firmware runtime

### A1. Runtime ownership model

Introduce a firmware-owned host-runtime lock and bootstrap layer:

```text
esp32/tools/firmware-runtime/
  lock-v1.json
  refresh-inputs.json
  licenses.json
  README.md
esp32/tools/firmware_runtime.py
esp32/tools/refresh_firmware_runtime.py
esp32/tools/tests/test_firmware_runtime.py
.github/workflows/firmware-runtime-refresh.yml
```

The repository owns the lock, schema, validation, refresh process, and
selection policy. Large binary runtime/wheelhouse bundles are immutable GitHub
Release assets, not Git blobs. An Actions cache or workstation cache is only a
transport accelerator and is always rehashed.

The accepted runtime contains:

- a content-pinned CPython runtime for the host target;
- exact top-level PlatformIO and all transitive wheels;
- exact `uv` bytes if pioarduino still requires `uv`;
- the complete pioarduino root-`penv` closure;
- the complete nested ESP-IDF venv closure;
- wheels built from the exact tracked `pioarduino-core` and
  `tool-esptoolpy` sources instead of editable or live source installs; and
- a canonical inventory used for pre-execution and post-install validation.

Ordinary builds may download the one exact locked bundle. They never query a
package index or solve dependency ranges.

### A2. Target matrix

Converge the implementation on one supported CPython minor per host family
rather than inheriting whichever global launcher happens to exist:

| Runtime target | Required use | Initial ABI |
| --- | --- | --- |
| `linux-x86_64-cp313` | PR CI, tagged release, manual speaker builds | CPython 3.13 |
| `macos-arm64-cp313` | Apple Silicon local firmware work | CPython 3.13 |

Python 3.13 is the initial target because the reviewed pioarduino 55.03.34
dependency closure supports it. Before
locking assets, the refresh job must prove both host targets with clean 1.75 and
2.06 builds. If an exact dependency has no compatible CPython 3.13 wheel, the
implementation must resolve that in the reviewed refresh inputs or amend this
plan; it must not add an online fallback.

Windows, Intel macOS, Linux arm64, and Python 3.14 are initially unsupported.
An unsupported host receives the supported-target list and a deterministic
failure before PlatformIO starts.

### A3. Lock and bundle contract

`lock-v1.json` must be canonical UTF-8 JSON with duplicate-key rejection,
strict schemas, normalized package names, exact versions, positive sizes, and
full SHA-256 values. It records:

- schema and lock-set ID;
- target OS, architecture, Python implementation, ABI, and minimum platform
  tag;
- CPython runtime archive URL, size, SHA-256, license, and source provenance;
- outer bundle URL, size, and SHA-256;
- every wheel filename, normalized name, exact version, compatibility tags,
  size, SHA-256, source URL/digest, and environment group;
- exact top-level PlatformIO, pioarduino root, ESP-IDF, `uv`, and
  esptool distribution sets;
- pioarduino platform/archive identity and the existing executable-package pin
  set;
- generator version/commit and refresh inputs; and
- license inventory identity.

The safe downloader/extractor must:

1. stream to a temporary file with an exact maximum size;
2. verify outer size and SHA-256;
3. reject duplicate entries, absolute paths, `..`, symlinks, devices,
   case-colliding names, nested archives, missing files, and extra files;
4. verify every member's size and SHA-256 before any member executes;
5. extract into a new lock/target-specific staging directory;
6. verify the canonical inventory and expected executable paths;
7. atomically publish the verified entry; and
8. mark the accepted entry read-only.

### A4. Bootstrap and ordinary build flow

`build_firmware.py` remains the user-facing command but performs an early
stdlib-only handoff:

1. parse only enough arguments to identify the project and target;
2. load and validate the tracked runtime lock;
3. select the current OS/architecture runtime target;
4. verify or obtain the exact runtime bundle;
5. create or validate a lock-specific private host environment;
6. re-exec itself through that environment's CPython with an internal,
   validated handoff marker;
7. install/validate PlatformIO, pioarduino, ESP-IDF, `uv`, and esptool
   distributions using only verified local wheels and
   `--no-index --no-deps --only-binary=:all:`-equivalent enforcement;
8. invoke the exact private `pio` executable; and
9. continue through the current deterministic platform/package, custom-core,
   artifact, flash-plan, and upload gates.

The caller's Python only runs the tracked stdlib bootstrap. It does not import
PlatformIO or resolve packages. Add a small recovery bootstrap for the case
where a workstation has no usable `python3`: it may download the exact runtime
archive with OS tools, must verify the tracked digest, and then delegates safe
extraction and all build behavior to the private runtime. It must not install
or repair a global Python.

This still trusts the operating system and the initial Python standard library
(or the recovery script's OS download/hash tools) to execute the verifier
honestly. The change removes mutable global Python packages and launchers from
the firmware dependency closure; it does not claim to defend against a
malicious host interpreter, kernel, or filesystem. State that residual boundary
in provenance and documentation.

Remove the ordinary CLI/environment authority of:

- `--pio`;
- `PLATFORMIO_CMD`;
- ambient `pio`, `pip`, and `uv`; and
- cross-worktree or ad-hoc interpreter paths.

Keep dependency injection at the Python function/test seam so unit tests can
use fake runners without exposing a production bypass.

### A5. Pioarduino pre-execution enforcement

Extend `pioarduino_custom_core.py` and the verified platform staging logic so
the pinned pioarduino scripts:

- use only the preseeded verified root `penv`;
- use the preseeded verified ESP-IDF venv;
- never call a package index or direct unpinned URL;
- never select `uv` from `PATH`;
- never perform an editable esptool install;
- validate repo-owned markers containing lock ID, runtime target, interpreter
  identity, exact distribution-set digest, and installed tree digest; and
- fail if the upstream script shape differs from the reviewed transform.

Transforms must remain exact, idempotent, and covered by source fixtures.
Post-install attestation remains required even though inputs are now verified
before execution.

### A6. Cache layout

Use two locations with different trust semantics:

- a user-level, content-addressed download cache for immutable runtime bundles
  and wheels, shared across worktrees only after re-verification; and
- project-private mutable host and PlatformIO stores under
  `esp32/.pio/open-bike-build/`.

Never point one worktree at another worktree's `.pio` directory. Never execute
from `/tmp`. A shared verified archive may hydrate a private store by
copy/reflink after path-safety and digest validation; symlinking a mutable
PlatformIO store is prohibited.

Provide a narrow `--repair-runtime` operation that removes and recreates only
the exact validated lock/target subtree after confirming it is a non-symlink
directory inside the firmware cache root. It does not update dependencies.

### A7. Provenance and workflow integration

Extend structured build/upload provenance and cache identity with:

- runtime lock-set ID and manifest SHA-256;
- runtime target and bundle SHA-256;
- CPython version and executable/tree identity;
- top-level PlatformIO version and installed-distribution digest;
- `uv` identity;
- pioarduino root-`penv` distribution/tree digest;
- ESP-IDF venv distribution/tree digest; and
- transformed pioarduino platform-tree digest.

Bump schemas from their then-current values; do not assume schema 19 will still
be current when implementation begins. Old manifests become ineligible rather
than being silently upgraded.

Update:

- `.github/workflows/ci.yml`;
- `.github/workflows/firmware-release.yml`; and
- `.github/workflows/speaker-firmware.yml`

to remove `pip install --upgrade platformio` and exercise the same locked
runtime. CI consumes accepted locks only. A separate manual
`workflow_dispatch` refresh workflow produces candidate manifests, bundles,
dependency graphs, license inventories, offline-replay evidence, and build
attestations; it does not commit, push, open, or merge a PR.

The firmware-release publisher's separate `cryptography` install signs
release manifests and does not compile firmware. Keep it explicitly outside
this work rather than falsely claiming the firmware runtime lock covers it.

### A8. Runtime tests

Extend `test_build_firmware.py`, `test_generated_sdkconfig.py`,
`test_pioarduino_custom_core.py`, and add `test_firmware_runtime.py` for:

- strict lock parsing and canonicalization;
- duplicate keys, name collisions, ranges, wrong ABI/tag, invalid sizes, and
  invalid hashes;
- target selection on Linux x86_64 and macOS arm64;
- unsupported-host failure before PlatformIO execution;
- truncated/oversized/wrong-hash bundles;
- ZIP/tar traversal, symlink, device, duplicate, Unicode, and case collisions;
- proof that unverified Python/wheel code is not imported;
- exact offline install command construction;
- malicious ambient `pio`, `pip`, and `uv` executables never executing;
- atomic runtime creation and repair;
- mutation of the runtime, installed distributions, or transformed platform
  invalidating build/upload eligibility; and
- provenance fields containing no credentials or machine-specific cache URLs.

Native integration gates for both runtime targets must start from empty private
stores, block package-index/direct dependency access, build both ordinary
Waveshare targets, repeat from a warm cache, corrupt one input, and prove
fail-closed behavior.

## Workstream B: custom-core cache independent of source identity

### B1. Split the current manifest

Replace the overloaded SDK-config cache record with two explicit contracts:

1. **Core cache manifest** — identifies only inputs and outputs required to
   reuse the generated custom Arduino core.
2. **Firmware build manifest** — identifies the exact source, clock, generated
   state, core reference, final artifacts, and flash plan for upload
   eligibility.

Suggested project-private layout:

```text
.pio/open-bike-build/
  core-cache/<environment>/<core-key>/
    manifest.json
    sdkconfig.defaults
    sdkconfig.<environment>
    core-artifacts.tar
  builds/<environment>/
    current.json
  platformio/<environment>/
    ... hydrated mutable profile store ...
```

A content-addressed shared cache may store the immutable core bundle only after
the relocatability gate in B5 passes. The active PlatformIO profile remains a
private copy.

### B2. Core input key

Compute a canonical `coreInputKey` from all inputs that can affect custom-core
bytes:

- cache schema and environment;
- runtime lock/target and exact top-level PlatformIO identity;
- pioarduino platform archive and executable-package pins;
- board MCU, board definition, memory type, framework, and partition-related
  core configuration;
- canonical effective PlatformIO environment configuration, including inherited
  sections and all build flags;
- `custom_sdkconfig` and generated `sdkconfig.defaults` contents;
- managed-component lock/input identity;
- compiler/toolchain/framework/core builder identities;
- `prebuild.py`, `pioarduino_custom_core.py`,
  `generated_sdkconfig.py`, and the relevant staging/patch schema;
- any library or component input proven to participate in core generation.

The key contains inputs only. The manifest stored at that key separately
records the resulting core archive digest and complete core attestation. Cache
lookup first selects by `coreInputKey`, then verifies those recorded outputs;
putting a result digest into the input key would create a circular identity
that cannot be computed before a miss is built.

Deliberately exclude:

- application Git SHA and dirty-source digest;
- commit timestamp/build metadata;
- application `src/` and ordinary library implementation bytes that are
  compiled after the core;
- final ELF/BIN/bootloader/partition image hashes;
- flash plan and upload port/device state; and
- map/media content.

Using the full canonical effective PlatformIO environment is intentionally
conservative: a configuration edit may rebuild unnecessarily, but a source-only
application edit must not.

### B3. Reuse flow

Before starting pioarduino bootstrap:

1. compute the pre-core input fingerprint;
2. locate the exact project or shared immutable entry;
3. validate its manifest, archive inventory, generated SDK configs, complete
   core attestation, ownership, and tree hashes;
4. hydrate a fresh/matching profile-private PlatformIO store;
5. run the real firmware target without the custom-core bootstrap passes; and
6. create a new firmware build manifest that references the exact
   `coreInputKey` and `coreAttestationSha256`.

On a miss:

1. bootstrap in a temporary project-private profile store;
2. converge the pioarduino dummy/toolchain/core passes as today;
3. attest the generated core and SDK inputs;
4. package only the allowlisted reusable outputs;
5. atomically publish the immutable entry; and
6. continue with a clean real-target application build.

Never let PlatformIO build directly inside an accepted shared entry. Reflink or
copy it into the mutable profile store. If PlatformIO changes any hydrated
core-owned byte, the post-build comparison fails and the entry is quarantined.

### B4. Firmware build and upload identity remains exact

The firmware build manifest continues to include:

- exact clean Git source identity or dirty diagnostic identity;
- `SOURCE_DATE_EPOCH` and reproducible build timestamp;
- selected environment/profile;
- effective generated SDK state;
- runtime and core identities;
- managed components and library dependencies;
- ELF, firmware, bootloader, partition-table, and OTA bootstrap hashes;
- exact normalized flash plan; and
- `uploadEligible`.

`require_validated_generated_sdkconfig_defaults()` should become a clearly
named build-manifest validator rather than treating core cache validity as
sufficient. Upload-only must fail after any source, build-clock, core, generated
state, runtime, artifact, or flash-plan change.

A dirty checkout may read a verified core entry for fast diagnostics but:

- cannot publish or replace a core entry;
- cannot write an upload-eligible build manifest;
- cannot use upload-only; and
- must preserve its current `dirty-...` firmware identity.

### B5. Shared-cache relocatability gate

Before enabling cross-worktree core reuse:

1. build one core in a clean source worktree;
2. inspect every reusable file/archive for absolute source, build, Python,
   PlatformIO, and cache paths;
3. hydrate it into a second clean worktree at a different absolute path;
4. build both 1.75 and 2.06 targets as applicable;
5. compare the resulting core attestation and expected core archives;
6. verify debug/source maps do not point at another mutable worktree; and
7. mutate/delete the first worktree and prove the second remains valid.

If the artifacts are not relocatable, retain content-addressed reuse inside
each worktree and share only verified runtime/download inputs. Do not solve
relocatability with symlinks to another worktree.

### B6. Compiler-cache namespace

Keep application compilation and core/bootstrap compilation in separate cache
namespaces. The historical reason for clearing the whole build cache was that
dummy/bootstrap and real-target objects could collide. Encode the phase and
core key into bootstrap/core cache paths, and both source identity and core key
into application cache paths, so:

- bootstrap objects cannot satisfy a real-target compile;
- application objects cannot be mistaken for framework/core objects; and
- the accepted core archive survives a clean application rebuild.

This plan does not introduce an unverified “fast/dev build” mode. Every clean
build remains deterministic and attested; it simply avoids recomputing an
unchanged core.

### B7. Cache tests and performance gate

Add tests proving:

- a clean source-only commit change hits the same core key;
- changes to runtime lock, platform/package pins, effective PlatformIO
  configuration, custom SDK configuration, toolchain, core patches, managed
  core components, or generated core bytes miss;
- a firmware source change still changes the firmware manifest and invalidates
  upload-only;
- tampered, truncated, extra-file, symlinked, or wrong-owner cache entries are
  rejected;
- dirty builds consume but never publish;
- concurrent builders serialize publication and never observe partial entries;
- interrupted publication leaves the previous accepted entry intact;
- project-private hydration cannot mutate the shared entry; and
- old combined manifests fail closed.

Record structured phase timings for runtime bootstrap, custom-core bootstrap,
application compile, link, and attestation. On the same host and target:

- the second unchanged build must perform zero custom-core bootstrap passes;
- a source-only commit must perform zero custom-core bootstrap passes;
- the source-only build's median wall time over three runs must be no more than
  35% of the cold-cache build median; and
- output provenance must explicitly report `coreCache=hit|miss`,
  `coreInputKey`, and the measured phase durations.

The observed roughly five-minute cold rebuild versus roughly 50-second
application rebuild is motivation, not a hardcoded universal timing claim.

## Workstream C: bounded Waveshare SD warm-reset recovery

### C1. Own the HSPI lifecycle

Move the Waveshare HSPI object and its begun/mounted state into a file-local
controller owned by `storage.cpp` or an explicit private `Storage` member.
Do not hide it as a function-local static with no teardown state.

Implement one idempotent teardown operation:

1. close/unmount the Arduino SD filesystem with `SD.end()`;
2. end HSPI with `hspi.end()` only when begun;
3. set CS to output/high;
4. clear internal mounted/begun state; and
5. wait the policy-selected settle interval before another attempt.

Calling teardown before initialization, after partial initialization, after a
successful mount, or twice must be safe.

### C2. Mount retry state machine

For Waveshare 1.75 and 2.06 profiles, implement a fixed three-attempt policy:

| Attempt | Preparation | Operating frequency | Failure delay |
| --- | --- | ---: | ---: |
| 1 | clean stale Arduino/HSPI state, CS high | configured 4 MHz default | 50 ms |
| 2 | full `SD.end()` + `hspi.end()`, recreate bus | configured 4 MHz default | 150 ms |
| 3 | full teardown and final recreate | configured 4 MHz default | none |

Arduino's pinned SD driver already initializes every attempt at 400 kHz and
sends the required idle clocks/CMD0. Do not add a frequency ladder until logs
show a post-initialization high-speed failure. If later evidence supports a
lower operating-frequency fallback, make it a separate measured change and
record the map and sequential-read throughput impact.

Each attempt must:

- acquire the existing storage power-management lock;
- run under one mount single-flight/mutex;
- call `hspi.begin(SD_CLK, SD_MISO, SD_MOSI, SD_CS)`;
- call `SD.begin(..., WAVESHARE_SD_SPI_FREQ_HZ, "/sdcard")`;
- reject `CARD_NONE`;
- open and close the filesystem root as a basic mount-health check; and
- publish `isSdLoaded=true` only after all checks pass.

After all attempts fail, retain the current FFat fallback. Do not loop forever
or reboot automatically.

### C3. Re-mount behavior

`ensureSdMounted()` already serializes a health check and reinitialization.
Refactor it to call one private `mountSdLocked()` operation so locks are not
recursively acquired and boot-time and runtime recovery share the exact retry
policy.

Add a bounded retry cooldown after a complete failed sequence so a missing card
cannot stall every map/storage call. A successful card insertion or explicit
operator retry may clear the cooldown; there is no automatic hot-swap guarantee
until physically validated.

Open files must never survive teardown. Callers that observe an I/O failure
continue to close their file, mark SD unavailable, and retry from a higher-level
operation rather than having the storage layer silently replay a partial write.

### C4. Structured diagnostics

Replace ambiguous single-result logging with:

```text
SDIO: attempt=1/3 phase=begin bus=HSPI freq=4000000
SDIO: attempt=1/3 phase=mount ok=0 elapsedMs=...
SDIO: recovery action=full-bus-teardown delayMs=50
SDIO: attempt=2/3 phase=mount ok=1 elapsedMs=... type=SDHC sizeMB=...
SDIO: summary ok=1 attempts=2 totalElapsedMs=... fallback=none
```

When all attempts fail, emit exactly one summary naming `fallback=ffat`.
Retain the low-volume always-on `SDIO:` policy and keep verbose map I/O logs
opt-in.

Do not parse unstable ESP-IDF log text as application state. Record stable
application phases around the boolean Arduino API while preserving underlying
driver warnings for diagnosis.

### C5. SD policy tests

Extract only the attempt/delay/result transition policy into a small
hardware-independent header or source module and add a host test covering:

- first-attempt success;
- second/third-attempt recovery;
- complete failure and one FFat fallback;
- teardown before/after every partial state;
- idempotent repeated teardown;
- root-health-check failure;
- cooldown and retry after cooldown;
- concurrent callers seeing one attempt sequence; and
- no-card behavior staying bounded.

Do not create a new repository-wide test runner. Add the test to the existing
CI command list in `.github/workflows/ci.yml`.

### C6. Physical validation matrix

Record exact Git SHA, firmware profile, board serial, artifact SHA, card model,
capacity/filesystem, reset method, and logs.

For both Waveshare board families, when hardware is available:

| Scenario | Repetitions per card/board | Required result |
| --- | ---: | --- |
| Full power removal and cold boot | 10 | mount and root-health check succeed |
| ESP software restart | 50 | mount succeeds without unplugging |
| USB upload/reset transition | 20 | mount succeeds without unplugging |
| Intentional USB serial reset | 20 | mount succeeds without unplugging |
| Runtime mark-unavailable/remount | 20 | one bounded sequence restores access |
| No card inserted | 10 | bounded failure, one FFat fallback, no reboot loop |
| Card restored after failure | 10 | later explicit/cooldown retry succeeds |

Use at least three representative FAT32 cards, including the known-good 32 GB
SDHC card and another vendor/capacity. For each successful mount, read a fixed
checksummed file; for one writable test card, perform a temporary write,
`fflush`/close, reread, and verify without touching user map data.

Acceptance requires:

- 100% success for inserted known-good cards in the matrix;
- zero required cable or battery power cycles after warm resets;
- no Guru Meditation, watchdog, or repeated boot;
- no filesystem corruption or leaked file handles;
- final-failure latency no greater than six seconds before FFat fallback; and
- map-block and sequential-read performance at 4 MHz remaining within 5% of
  baseline medians.

If the 2.06 board is unavailable, software may be reviewed but the workstream
is not reported physically complete for that board.

## Workstream D: focused maintenance fixes

### D1. Idempotent speaker/I2S cleanup

Replace implicit handle-based assumptions with explicit resource states:

- channel allocated;
- standard mode initialized;
- channel enabled;
- codec/data/GPIO interfaces created;
- codec device created;
- codec device opened; and
- PA enabled.

Set each state only after the corresponding API succeeds. Cleanup runs in
reverse order and:

- lowers PA immediately;
- closes the codec only when opened;
- deletes the codec device/interfaces only when created;
- disables I2S only when enabled;
- deletes the channel only when allocated;
- clears each state after successful release; and
- is safe to call again after success or after any partial initialization
  failure.

Check and classify every cleanup return value. `ESP_ERR_INVALID_STATE` must not
be normalized as harmless by ignoring it; the state machine should avoid making
the invalid call. If a deletion genuinely fails, retain the relevant state for
one controlled retry and log one stable application-level error.

Add fault-injection or policy tests for failure after every initialization step,
successful playback cleanup, queued back-to-back playback, and repeated
cleanup. Physical validation on both audio-capable boards must play at least
100 short sounds/replay cycles while checking:

- no `i2s_channel_disable: channel has not been enabled` message;
- no cleanup retry during the success path;
- no growing heap/resource loss;
- PA is low between playback sessions; and
- subsequent playback remains audible.

### D2. Local device-name registry

Add a small, versioned local registry tool, for example:

```text
esp32/tools/device_registry.py
esp32/tools/device-registry.schema.json
esp32/tools/device-registry.example.json
esp32/tools/tests/test_device_registry.py
```

Store actual enrollment outside Git at the platform user-config location
(`~/Library/Application Support/OpenBikeComputer/devices.json` on macOS and
the XDG config location on Linux). Never commit real serials.

Schema 1 records:

- unique nickname;
- board family: `WAVESHARE_AMOLED_175` or `WAVESHARE_AMOLED_206`;
- normalized stable USB serial;
- optional human note; and
- enrollment/update timestamp for operator context.

Provide explicit `list`, `show`, `add`, `rename`, and `remove`
operations with strict validation, atomic writes, safe file permissions, and
symlink refusal. Mutating operations print the exact entry and path changed.

Extend `resolve_upload_port.py` and `build_firmware.py` with a mutually
exclusive `--device-name` selector:

1. resolve nickname to board family and stable serial;
2. reject unknown, duplicate, malformed, or ambiguous entries;
3. validate that the requested firmware environment belongs to the enrolled
   board family before spending time building or uploading;
4. resolve the serial to the live transient port immediately before upload;
5. print nickname, board family, serial, VID:PID, description, and resolved
   port; and
6. keep the stable serial in existing upload provenance.

Do not auto-select the only attached board, auto-enroll a device, infer a board
family from a port name, or treat nickname selection as flash approval. The
existing instruction to ask which physical board is connected remains.

Tests cover schema/version errors, duplicate nicknames/serials, case
normalization, atomic updates, symlinks, unsafe permissions, environment-family
mismatch, a device disappearing/reappearing, and multiple live matches.

### D3. Documentation updates

After behavior exists and tests pass:

- update `AGENTS.md` with the locked-runtime bootstrap/repair path, cache
  layers, device-name usage, and retained physical-board confirmation;
- update `CONTRIBUTING.md` with ordinary developer versus maintainer refresh
  responsibilities;
- update `esp32/README.md` so it no longer asks users to install ambient
  PlatformIO and accurately states the new Python/runtime trust boundary;
- update `hardware/README.md` with the SD retry lifecycle, physical matrix,
  and any board/card limitations;
- add this plan to `docs/README.md`; and
- update workflow comments where floating PlatformIO installation is removed.

Do not add playback-demo files or media-copy automation; both are outside the
amended implementation scope.

## Dependency and merge order

Use reviewable stacked changes rather than one unreviewable firmware/tools
rewrite:

1. **Runtime lock and verifier:** schemas, safe transport/extraction, private
   runtime, pioarduino transforms, unit/adversarial tests.
2. **Runtime workflow migration:** CI/release/speaker workflows, provenance,
   clean offline build evidence, docs trust-boundary update.
3. **Core/build manifest split:** core input key, local immutable cache,
   hydration, upload manifest separation, regression tests.
4. **Cross-worktree core cache:** only after the relocatability gate passes.
5. **SD lifecycle/retry:** storage refactor, host policy tests, structured logs,
   both-board/card physical evidence.
6. **Speaker lifecycle:** resource-state cleanup, failure tests, repeated
   physical playback.
7. **Device registry:** schema/tool/build integration and documentation.
Workstreams C and D may proceed in parallel with A/B in separate branches, but
the final documentation must describe only merged behavior. Workstream B's core
key must include the final runtime identity from Workstream A, so do not merge a
cache design that plans to retrofit runtime identity later.

## File-by-file implementation map

| File/path | Planned responsibility |
| --- | --- |
| `esp32/tools/build_firmware.py` | Locked runtime handoff, private `pio`, split core/build manifests, cache hydration, device-name selector, provenance |
| `esp32/tools/generated_sdkconfig.py` | Core input/attestation contract separated from exact firmware/upload manifest |
| `esp32/tools/pioarduino_custom_core.py` | Pre-execution offline root/ESP-IDF environment enforcement |
| `esp32/prebuild.py` | Preserve exact custom-core corrections; expose only core-affecting inputs to the key |
| `esp32/tools/firmware_runtime.py` | Strict lock parsing, target selection, verified bundle handling, offline environment validation |
| `esp32/tools/refresh_firmware_runtime.py` | Maintainer-only candidate generation and offline replay |
| `esp32/tools/firmware-runtime/*` | Tracked locks, refresh inputs, licenses, maintainer documentation |
| `esp32/tools/device_registry.py` | Local nickname/board-family/serial registry |
| `esp32/tools/resolve_upload_port.py` | Resolve registry result through existing stable-serial logic |
| `esp32/lib/storage/storage.cpp/.hpp` | Owned HSPI lifecycle, bounded retries, cooldown, structured diagnostics |
| `esp32/lib/speaker/speaker.cpp/.hpp` | Explicit resource states and idempotent reverse-order cleanup |
| `esp32/tools/tests/test_build_firmware.py` | Runtime/core/build/device integration and upload-ineligibility regressions |
| `esp32/tools/tests/test_generated_sdkconfig.py` | Core/build manifest split and tamper cases |
| `esp32/tools/tests/test_pioarduino_custom_core.py` | Exact offline transform fixtures |
| `esp32/tools/tests/test_firmware_runtime.py` | Runtime lock, download, extraction, install, and ambient-executable attacks |
| `esp32/tools/tests/test_device_registry.py` | Registry schema, atomic persistence, family validation |
| new focused SD policy host test | Retry, teardown, cooldown, and fallback transitions |
| new focused speaker lifecycle host test | Partial init, repeated cleanup, retry, and success transitions |
| `.github/workflows/ci.yml` | Locked runtime build matrix and existing-list additions for focused tests |
| `.github/workflows/firmware-release.yml` | Same locked runtime for production firmware builds |
| `.github/workflows/speaker-firmware.yml` | Same locked runtime for manual speaker profiles |
| `.github/workflows/firmware-runtime-refresh.yml` | Manual-only candidate bundle/lock generation |
| `AGENTS.md`, `CONTRIBUTING.md`, `esp32/README.md` | Runtime/cache/device workflow and trust boundary |
| `hardware/README.md` | SD recovery design and physical evidence |
| `docs/README.md` | Link this implementation plan |

## Rollout and rollback

### Runtime

Land the first accepted runtime bundles before enabling mandatory consumption.
Test fresh and warm stores on both host targets. Enabling commits invalidate old
ambient-built manifests and rebuild project-private environments.

A dependency rollback reverts the tracked lock to the previous accepted bundle;
it never restores live resolution. Keep accepted release assets immutable and
available. A bootstrap-code rollback reverts code, schemas, workflows, and
documentation together.

### Core cache

Initially publish project-private immutable entries while collecting
relocatability evidence. Enable shared archive lookup only after B5. A rollback
disables shared lookup and rebuilds from pinned inputs; firmware correctness
must not depend on cache availability.

Cache corruption removes/quarantines only the exact content-addressed entry
after path validation. It never triggers broad deletion of `~`, a repository
root, or another worktree.

### SD

Keep FFat fallback throughout rollout. If retry behavior increases boot time or
regresses a card, revert the retry policy/controller while retaining the
diagnostic evidence. Do not “fix” a regression by raising SPI frequency,
toggling PMIC rails, or formatting a card automatically.

### Speaker and registry

Speaker rollback restores the prior initialization path but must not leave a
partially mixed lifecycle state. Registry support is additive; users can always
continue supplying `--device-serial`. Removing a local nickname never affects
firmware bytes or device ownership.

## Completion gates

The retained plan is complete only when all of these are true:

1. No supported firmware workflow installs or selects PlatformIO from a live
   package index or ambient `PATH`.
2. Clean Linux x86_64 and macOS arm64 builds use the exact accepted CPython
   3.13 runtime and emit complete runtime provenance.
3. A prepopulated verified cache supports a package-index-disconnected build;
   missing/corrupt inputs fail before execution.
4. Ambient malicious `pio`, `pip`, and `uv` test doubles never execute.
5. Runtime, wheel, installed-environment, transformed-platform, core, or
   artifact mutation invalidates build/upload eligibility.
6. A source-only commit reuses the same core key with zero custom-core
   bootstrap passes while producing a source-specific firmware manifest.
7. Every core-affecting input mutation tested above causes a miss.
8. Dirty builds may consume but cannot publish cache entries or upload.
9. Cross-worktree core reuse is enabled only with recorded relocatability and
   immutable-hydration evidence.
10. Warm reset, software restart, and upload reset meet the SD matrix without a
    manual power cycle on every available supported board/card.
11. Missing-card failure is bounded and falls back once to FFat.
12. SD map-block and sequential-read throughput remains within the stated
    baseline tolerance.
13. Speaker partial failures and 100-cycle physical playback produce no invalid
    I2S disable warning or resource leak.
14. Device nicknames resolve only explicit, unique stable serials and reject
    board-family mismatch before build/upload work.
15. The ordinary developer docs contain no raw Waveshare `pio run` path and
    make runtime repair deterministic.
16. The implementation contains no approval-token flash workflow, generic
    runtime acceptance framework, unified test runner, or SD media installer.

## Superseded planning context

The earlier local planning branch `plan/pioarduino-wheelhouse-hardening` at
`c77a716a42ecdfc2cf3da49dc1cecbb63953b0f9` remains useful historical design
input, but it was based on an older main commit, cache schema, and
Python-3.11/3.12 host matrix. Do not merge it unchanged. Workstream A supersedes
that plan with the current baseline, a repository-owned CPython 3.13 runtime,
and an explicit interaction with the new core-cache split.
