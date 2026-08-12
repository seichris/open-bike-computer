# Pioarduino First-Run Python Supply-Chain Hardening Reconciliation

## Status and baseline

This is the durable architecture and implementation record. The focused
runtime closure was delivered by PRs #228/#229/#231; the follow-up branch based
on PR #240 implements the maintenance, provenance, factory-binding, publication,
and performance controls described below. It does not refresh an accepted
dependency, publish a release asset, or access a physical device.

The original version of this document was written from `origin/main` at
`1392471c3f8e5e267c3f4b4bffba413b2d4fc4b1`, immediately after
[PR #178](https://github.com/seichris/open-bike-computer/pull/178). The plan
identified pioarduino's online first-run Python resolver as the remaining
pre-execution supply-chain gap.

The implementation revision was reconciled after freshly fetching GitHub
`origin/main` at `05cb1d47bb92b93087c521a421a9056b613a35b5` on 2026-08-12.
That is the merge commit for
[PR #240](https://github.com/seichris/open-bike-computer/pull/240), “Publish
attested factory firmware bundles.” Its final head was
`d0e628ca9e6dcbb23929d056b61d9e9829407ba7`; every reported PR check and the
aggregate CI gate completed successfully before merge. The focused gap is
implemented in software by:

- [PR #228](https://github.com/seichris/open-bike-computer/pull/228), merge
  commit `89d13813c3e62b82420aaf8b65a31edd9eacee4b`, added the accepted,
  repository-owned firmware runtime;
- [PR #229](https://github.com/seichris/open-bike-computer/pull/229), merge
  commit `d8cc7b408e979c141ca06022bef67784d3d9972b`, routed supported firmware
  workflows through that runtime; and
- [PR #231](https://github.com/seichris/open-bike-computer/pull/231), merge
  commit `7ec1d524d64128164cc562438bbb4e14254af019`, separated immutable
  custom-core cache identity from exact firmware and upload identity.

PR #240 did not change the accepted runtime, wheel closure, pioarduino
transforms, custom-core identity, or supported host targets. It adds a new
downstream release boundary: production builds are packaged into deterministic
factory archives, an external bundle descriptor, and a separately signed
factory-release manifest. This implementation keeps that architecture and
closes its post-build authority and publication seams instead of designing a
second wheelhouse.

Workstream A of
[`firmware-runtime-cache-sd-hardening-implementation-plan.md`](firmware-runtime-cache-sd-hardening-implementation-plan.md)
superseded the original unimplemented design. This document is retained as the
focused pioarduino/Python security record. It describes the as-built boundary,
the invariants that must remain mandatory, and the remaining long-term
maintenance work. It must not be used to reimplement a second wheelhouse or to
restore the original Python 3.11/3.12 design.

## Decision

Keep the merged repository-owned CPython 3.13 runtime as the long-term design.
It is stronger and simpler than the original wheelhouse-only proposal because
the lock selects the interpreter as well as every subsequently executed Python
distribution. Ordinary developers retain the same entrypoint:

```sh
python3 tools/build_firmware.py <environment>
```

Only maintainers perform runtime refreshes. There is no ordinary-build update
flag, resolver mode, warning-only fallback, ambient PlatformIO fallback, or
automatic dependency update path.

Ordinary local builds and device-test builds remain on that same command. A
helper-owned, opt-in factory-output mode serves CI and tagged
production releases so packaging runs after the locked-runtime handoff and
while the exact build is still protected by the project lock. Normal builds do
not package factory artifacts, and ordinary developers do not acquire a second
dependency or refresh command.

The mandatory pioarduino wheelhouse gap is closed in software at this baseline.
That claim is narrower than saying the host or GitHub is fully trusted by
cryptographic hardware. The operating system and the complete initial
`python3` startup remain trusted until the helper re-executes under the locked
runtime. Later sections distinguish maintenance required to preserve the
closed boundary from broader defense-in-depth work.

## Threat model and security gain

### In-scope attacker capabilities

The runtime design assumes the host OS and initial interpreter startup behave
honestly, but an attacker may control or mutate one or more of:

- a Python package index response, dependency metadata, or transitive version;
- the direct pioarduino-core or esptool source download;
- DNS, a mirror, CDN content, or a TLS endpoint after a lock was reviewed;
- an ambient `pio`, `pip`, `uv`, or unrelated Python installation offered as
  the post-bootstrap build runtime;
- `PYTHON*`, dynamic-loader, PlatformIO, ESP-IDF, component-manager, compiler,
  linker, or Git URL-rewrite environment state;
- a cached runtime archive, extracted runtime tree, wheel, installed virtual
  environment, transformed pioarduino platform, custom core, or firmware
  artifact; or
- an archive containing traversal paths, links, special files, duplicate
  entries, case collisions, unexpected files, or modified permissions.

The relevant attack succeeds if unreviewed Python or build-tool bytes execute
before their identity is checked, or if later upload reuses different runtime,
core, source, artifacts, or flash parameters from the verified build.

### Required invariants

The merged architecture and every future refresh must preserve these
falsifiable properties:

1. A supported firmware build selects one accepted host target from a canonical
   tracked lock before PlatformIO executes.
2. Every downloaded runtime bundle and every extracted member is identified by
   an exact size and SHA-256 before that member executes.
3. Every installed Python distribution has one exact version and one reviewed
   wheel or verified source-built wheel; live dependency solving is forbidden
   in ordinary builds.
4. Top-level PlatformIO, external `uv`, pioarduino's root `penv`, esptool, and
   the nested ESP-IDF environment all derive from the same accepted runtime
   target.
5. Pioarduino's first-run scripts are transformed only from an exact reviewed
   upstream shape and use the locked wheelhouse offline. An unknown upstream
   shape fails closed.
6. A cache is an accelerator, never an authority. Restored archives, extracted
   trees, installed environments, core entries, and firmware manifests are
   revalidated before reuse.
7. A missing, incompatible, unaccepted, or modified input stops before the
   affected Python or PlatformIO code executes. It never falls back to an
   index, `PATH`, another worktree, or `/tmp`.
8. A dependency refresh is an explicit maintainer review event. No schedule,
   push event, dependency bot, repair command, or normal build can change the
   accepted lock.
9. Upload and `--upload-only` revalidate the exact runtime, source identity,
   generated state, custom core, artifacts, uploader, and flash plan. They do
   not rebuild or resolve dependencies.
10. Ordinary contributors keep using `build_firmware.py`; refresh complexity
    remains maintainer-only.
11. A factory archive may be produced only from the exact validated,
    upload-eligible `*_PRODUCTION` build while the locked helper still owns the
    project state. Packaging reuses the canonical build/upload validator; it
    does not trust a hand-picked subset of manifest fields.
12. The external factory descriptor, archived build attestation, runtime
    identity, image set, and signed factory-release manifest form one
    versioned digest chain. Missing, mixed, stale, or independently substituted
    pieces fail before publication or factory flashing.

### Security gain

Before PR #228, an online resolver could execute after selecting live
dependencies, and the resulting trees were only attested afterward. At the
current baseline, a build verifies a reviewed runtime bundle and complete file
inventory before bundled code executes, then attests the installed and
transformed results again. A mutable registry response or ambient build-tool
executable no longer gets first execution authority over the post-handoff
firmware closure.

SHA-256 verification also separates integrity from GitHub Release
availability. Replacing an asset without changing the tracked lock causes a
fail-closed digest mismatch. It does not silently update a build.

## Current trust boundary

### Protected build path

The supported path is:

```mermaid
flowchart LR
    A["Host OS and initial Python startup"] --> B["Tracked stdlib verifier"]
    B --> C["Canonical accepted runtime lock"]
    C --> D["Exact release bundle: size and SHA-256"]
    D --> E["Safe extraction and complete inventory verification"]
    E --> F["Read-only shared cache and private CPython 3.13 runtime"]
    F --> G["Locked PlatformIO and uv"]
    G --> H["Exact pioarduino transforms"]
    H --> I["Offline root penv, esptool, and ESP-IDF environments"]
    I --> J["Custom-core and exact-source build manifests"]
    J --> K["Attested firmware and immutable esptool flash plan"]
    K --> L["Validated production factory bundle"]
    L --> M["Signed factory-release identity"]
```

`esp32/tools/firmware_runtime.py` owns lock parsing, host selection, verified
transport, safe extraction, complete-tree verification, cache publication,
repair, private hydration, and the re-exec handoff. The initial process uses
repository and standard-library modules; the selected private CPython then
executes the actual PlatformIO build.

`esp32/tools/pioarduino_custom_core.py` rewrites the pinned pioarduino scripts
so they select the locked `uv`, install exact requirements from the local
wheelhouse with offline/no-cache constraints, replace the direct
pioarduino-core URL with the exact wheel, replace editable esptool installation
with the exact wheel, and create the ESP-IDF environment from exact locked
requirements. Each transform is exact and idempotent and rejects an unknown
upstream source shape.

`esp32/tools/generated_sdkconfig.py` binds runtime identity into the custom-core
input key and exact firmware manifest. At this baseline its relevant contracts
are:

- runtime lock schema 1 and runtime inventory schema 1;
- core-cache schema 2;
- exact firmware build-manifest schema 20; and
- flash-plan schema 2.

The human-readable `FIRMWARE_BUILD_PROVENANCE` and
`FIRMWARE_UPLOAD_PROVENANCE` lines use the documented closed-field schema 2.
Factory bundle and factory-release schemas independently use version 2. The
packager invokes `require_validated_generated_sdkconfig_defaults()` and runs
only through the helper-owned factory-output path while its project lock is
held. The signed release directly binds the external/embedded descriptor,
build attestation, runtime-provenance digest, archive, and complete safe flash
layout without changing the ordinary build command.

### Residual trusted boundary

The current design does not protect against a malicious host kernel,
filesystem implementation, process tracer, root user, hardware, or initial
interpreter. More precisely, the trusted bootstrap includes the complete
startup of the caller's `python3`, not only Python source files labelled as the
standard library. Platform/site initialization or a malicious interpreter can
execute before `ensure_runtime_handoff()` can reject environment injection.

The optional recovery entrypoint, `tools/build_firmware_bootstrap.sh`, narrows
dependency on an installed Python by downloading the exact tracked standalone
CPython archive. It still trusts the host shell, `curl`, hash utility, `tar`, OS,
and kernel to verify and execute those bytes honestly.

Repository write authority and the GitHub control plane remain trusted to
approve a changed lock and publish the referenced assets. A compromise that
changes both reviewed repository state and release state is outside the
wheelhouse integrity claim. Optional broader hardening for those boundaries is
listed separately below.

## Accepted runtime and target coverage

The accepted lock set is `firmware-runtime-2026-08-10-1`. It pins CPython
3.13.15, PlatformIO 6.1.18, pioarduino-core 6.1.18, `uv` 0.12.3, esptool
5.1.0, and the full transitive closures.

| Target | Required coverage | Minimum platform tag | Accepted bundle |
| --- | --- | --- | --- |
| `linux-x86_64-cp313` | GitHub PR CI, diagnostic CI, tagged releases, and manual speaker builds | `manylinux_2_34_x86_64` | 332,805,737 bytes; SHA-256 `b6edf8cbb753164fc8ef86cc7566a157022f5dbf886bd620b8a89318e139103a` |
| `macos-arm64-cp313` | Apple Silicon local builds and native refresh validation | `macosx_11_0_arm64` | 100,696,756 bytes; SHA-256 `bf5b2738645e96a3e1c5b029543d990a16671ab1008cbad116d3fb5712bdc14b` |

Each target contract currently accounts for 71 distinct wheel files and five
exact distribution sets:

- 25 wheels for top-level PlatformIO;
- 46 wheels for pioarduino's root environment;
- 29 wheels for the ESP-IDF environment;
- one exact `uv` wheel; and
- 17 wheels for esptool and its closure.

The sets intentionally overlap; the outer inventory accounts for every unique
file once. Each wheel record contains filename, normalized name, exact version,
compatibility tags, size, SHA-256, source URL, source SHA-256, and environment
group.

Windows, Intel macOS, Linux arm64, and other ABIs are unsupported and must fail
before PlatformIO starts. Additional hosts are added only when a real developer
or release need justifies the permanent generation, review, CI, and asset
maintenance cost.

### Why this replaces the original ABI matrix

The original plan proposed consuming the host's Python ABI and therefore
needed Linux cp312 plus Apple Silicon cp311 and cp312 closures. The merged
design instead carries one content-pinned CPython minor for both host families.
This removes ambient ABI selection, reduces the number of binary closures that
must be reviewed, and makes local and CI behavior converge.

Supporting one locked cp313 runtime per host family is the preferred long-term
architecture, not an MVP reduction. We should add another ABI only for an
independent compatibility requirement, never as a fallback when the accepted
runtime is unavailable.

## Treatment of every dependency layer

### Pioarduino platform archive and PlatformIO packages

The direct pioarduino platform remains a separate, already content-pinned trust
layer. `esp32/tools/generated_sdkconfig.py` tracks pioarduino platform
`55.03.34`, its exact archive URL, byte size, and SHA-256, plus every executable
PlatformIO package bootstrap. The runtime lock records the aggregate platform
archive and package-set identities and refuses a mismatch.

The runtime bundle does not replace or weaken those pins. It supplies the host
Python execution closure; the existing archive layer supplies the firmware
platform, framework, compiler, uploader, SCons, CMake, Ninja, and related
PlatformIO packages.

### Direct pioarduino-core source

The maintainer inputs pin the direct
`pioarduino/platformio-core` tag archive by exact URL, size, and SHA-256. The
refresh tool builds and normalizes a wheel from that verified source. Ordinary
builds install `pioarduino-core==6.1.18` from the accepted local wheelhouse;
they do not fetch the direct archive.

### External uv

The runtime contains the exact `uv==0.12.3` wheel and executable. The
pioarduino transform rejects any other external executable and removes its
ambient `PATH` fallback. Offline install commands point at the locked
wheelhouse and do not contact an index.

### Pioarduino root penv and esptool

The root environment consumes a complete exact requirements file and the
`pioarduinoRoot` distribution set. Editable esptool source installation is
replaced by the exact esptool wheel built from the verified esptool source
archive. The installed distribution set and complete resulting tree are
attested after bootstrap.

### ESP-IDF venv

The ESP-IDF setup transform replaces range requirements with the reviewed
exact versions and installs the complete `espIdf` set offline from the local
wheelhouse. Its distribution set and installed tree are independently
attested; it is not treated as part of the root environment by implication.

### Top-level PlatformIO

The runtime bundle contains exact PlatformIO 6.1.18 and its complete transitive
set. `build_firmware.py` removes `--pio` and `PLATFORMIO_CMD` authority and
derives the launcher only from the verified project-private runtime. Supported
firmware workflows no longer run `pip install --upgrade platformio`.

### Firmware-release publisher

The release publisher installs an exact Python 3.13 `cryptography`/cffi/
pycparser closure by version and SHA-256 to sign OTA and factory-release
manifests. It runs after compiled artifacts exist and does not affect firmware
bytes. It remains a separately locked publisher closure outside the mandatory
pioarduino wheelhouse claim. The standard-library factory packager itself runs
inside the already accepted firmware runtime.

## Ordinary fetch, verification, and offline behavior

On the first supported-host build, the helper:

1. rejects pre-execution Python and dynamic-loader injection variables;
2. parses the canonical tracked lock with duplicate-key and strict-field
   rejection;
3. selects exactly one accepted host target and checks the host ABI/platform
   floor;
4. obtains the one locked release bundle into a content-addressed user cache;
5. verifies the bundle's exact size and SHA-256 before extraction;
6. rejects unsafe archive paths, links, special files, nested archives,
   duplicate/case-colliding names, missing files, and extra files;
7. verifies each member's size and SHA-256 while extracting;
8. verifies the complete canonical file inventory and executable identities;
9. atomically publishes a read-only shared entry and hydrates a verified,
   read-only project-private copy;
10. re-executes under the locked CPython and selects only its locked PlatformIO
    and `uv`; and
11. lets the exact pioarduino transforms create or validate their environments
    offline before compilation.

Later builds rehash the accepted runtime tree and relevant installed state.
`--repair-runtime` deletes and re-downloads only the selected lock/target
subtree after ownership, path, link, and type checks. Repair never resolves a
new version and is not a refresh command.

A prepopulated runtime cache supports a package-index-disconnected Python
bootstrap. A completely disconnected firmware build additionally needs the
already pinned pioarduino platform/package and ESP-IDF component inputs in
their verified caches. The documentation and tests must keep that distinction
explicit rather than describing Python-wheelhouse offline replay as proof that
every firmware input was already local.

## Cache, provenance, build, and upload integration

### Runtime cache

The immutable runtime transport cache is user-level and content-addressed by
lock set, target, and bundle SHA-256. It is rehashed before use and marked
read-only. Mutable host and PlatformIO state remains worktree-private under
`esp32/.pio/open-bike-build/`. One worktree cannot silently execute another
worktree's mutable environment.

Actions caches are transport accelerators only. Restoring a cache cannot skip
the runtime bundle, tree, wheel, platform archive, or installed-state checks.
No cache miss permits online Python resolution.

### Custom-core cache

PR #231 separated the source-independent custom-core key from the exact-source
firmware manifest. The core key includes the accepted runtime identity,
environment, effective tracked PlatformIO configuration, generated SDK inputs,
platform/package pins, and core-building tools. A source-only change may reuse
that verified project-private core, while dirty builds may consume but never
publish an entry or become upload eligible.

Cross-worktree core-cache reuse remains disabled because the measured archive
contained absolute source paths. That is a separate performance boundary, not
an excuse to share mutable runtime or PlatformIO stores.

### Provenance

Build and upload provenance records at least:

- runtime lock-set, manifest, target, bundle, runtime-tree, CPython executable,
  `pio`, and `uv` identities;
- exact PlatformIO version and top-level, root, ESP-IDF, `uv`, and esptool
  distribution-set digests;
- installed pioarduino root and ESP-IDF environment tree digests;
- transformed pioarduino platform-tree digest;
- core-cache status and key;
- exact Git identity, `SOURCE_DATE_EPOCH`, build timestamp, generated state,
  managed components, platform/package inputs, and firmware artifacts; and
- the exact uploader and canonical flash-plan digest.

Absolute cache URLs, credentials, and release tokens must never appear in
provenance.

### Upload-only

The pre-PR #180 `PlatformIO nobuild` model is obsolete. Current upload replays
an esptool command captured and validated during the verified build. It binds
the requested stable USB identity late, suppresses Python bytecode writes, and
executes the already-attested private uploader without asking PlatformIO to
configure or relink.

`--upload-only` must continue to validate runtime provenance, the custom-core
entry, exact clean source identity, generated state, every firmware image, the
partition-derived application offset, uploader, and flash plan before private
Python or esptool performs the upload. Runtime or wheelhouse tampering requires
a new valid build or exact-runtime repair; it never triggers online recovery.

### Factory bundle and signed release binding

`package_factory_firmware.py` is a downstream consumer of the
exact build manifest rather than an independent attestation authority. The
long-term integration is:

1. `build_firmware.py` accepts `--factory-output-dir PATH` only for the matching
   `WAVESHARE_AMOLED_175_PRODUCTION` or
   `WAVESHARE_AMOLED_206_PRODUCTION` environment, requires a clean exact Git
   identity and create-only safe output paths, and rejects combination with an
   upload selector or `--upload-only`;
2. after the normal locked build and final phase-timing manifest write, the
   helper calls the packager under the locked CPython and project-wide lock;
3. the packager calls the same strict validator used immediately before upload
   and rejects any missing or changed runtime, core, source, generated state,
   artifact, uploader, or flash-plan identity;
4. the archive and external descriptor contain byte-identical descriptor
   bytes, and the archive contains the exact canonical build-manifest bytes;
5. factory-bundle schema 2 adds one `runtimeAttestation` object derived from
   `runtimeProvenance`, containing the lock-set ID, runtime target, lock
   manifest SHA-256, runtime bundle SHA-256, and a canonical digest of the full
   runtime-provenance object;
6. the release preflight safely extracts to a private temporary directory and
   proves that the internal/external descriptors are byte-identical, the
   embedded build-attestation digest matches the descriptor, and all extracted
   checksums match before signing; and
7. factory-release schema 2 directly signs `buildAttestationSha256` and
   `runtimeProvenanceSha256` in addition to the archive and external descriptor
   digests.

The complete runtime object remains in the embedded build manifest; the small
descriptor object is an auditable index, not a second source of truth. Every
duplicated identity must be derived and equality-checked. A schema-1 factory
bundle remains a historical artifact, but a new publisher implementing this
plan must not silently emit new schema-1 artifacts.

The authoritative CI/release invocation becomes:

```sh
python3 tools/build_firmware.py WAVESHARE_AMOLED_175_PRODUCTION \
  --factory-output-dir dist
```

The 2.06-inch job selects its matching production environment. The initial
`python3` performs only the existing verifier/handoff; all packaging code runs
after re-exec under the accepted private interpreter.

## Workflow coverage

### Pull-request and push CI

`.github/workflows/ci.yml` builds the ordinary and production profiles for both
Waveshare targets through the unchanged developer helper. It does not install
PlatformIO. Workflow-policy tests must continue to reject ambient PlatformIO,
raw Waveshare `pio run`, or bypasses around `build_firmware.py`.

The original plan required every diagnostic profile in every PR matrix. Main
now uses a faster split without weakening runtime ownership:

- PR/push CI builds four representative ordinary/production targets;
- `.github/workflows/firmware-diagnostics.yml` builds the ten diagnostic
  profiles on schedule, manual dispatch, and as a tagged-release prerequisite;
- `.github/workflows/speaker-firmware.yml` builds both speaker profiles on
  manual dispatch; and
- every one of those jobs invokes the same locked helper.

PR #240 also makes each production job package, extract, and checksum the real
factory bundle. Preserve that coverage, but route production packaging through
the helper-owned factory-output mode rather than a second ambient-Python
command. Workflow-policy tests must reject direct production use of
`package_factory_firmware.py`, while its CLI remains available for focused unit
tests and explicitly non-authoritative inspection.

This is the preferred long-term balance. Because profile-specific jobs cannot
select another Python path, the wheelhouse invariant is enforced by policy
tests and the shared helper rather than by repeating all profiles on every PR.

### Tagged firmware release

`.github/workflows/firmware-release.yml` reuses ordinary CI, diagnostic CI, and
locked production builds for both boards. It preserves `env -u LD_LIBRARY_PATH`
at the build boundary and stages artifacts only after the helper reports an
upload-eligible manifest.

Each release build also emits `<target>.factory.tar.gz` and
`<target>.factory-bundle.json`, and the publisher emits
`<target>.factory-release.json`. The build job must use the helper-owned
factory-output mode. The publish job must run the archive/descriptor/
attestation consistency preflight before signing, require the exact full Git
SHA and matching production environment, and refuse cross-job or cross-target
artifact mixing.

The separate manifest-signing job's exact hashed dependency closure remains
outside compiled-byte provenance. No document may imply otherwise.

### Apple Silicon validation

The manual runtime-refresh workflow performs native macOS arm64 candidate
generation, byte-for-byte rebuild comparison, offline replay, clean and warm
1.75/2.06 builds, and tamper rejection. Ordinary PRs that do not change the
accepted lock need not repeat that expensive native bootstrap.

Any PR changing runtime inputs, lock parsing, platform transforms, target
selection, refresh logic, or accepted bundle identity must rerun both native
Linux and Apple Silicon refresh gates before acceptance.

## Manual refresh and acceptance workflow

Dependency refresh remains a deliberate maintainer operation. The accepted
workflow has only `workflow_dispatch` and `contents: read`. It cannot push,
open or merge a PR, change the accepted branch, or publish a release. Its
validation job does create one ephemeral local commit containing the assembled
candidate lock so real firmware builds receive an exact clean source identity;
that commit is neither pushed nor accepted when the runner is discarded.

### Tracked refresh inputs

`esp32/tools/firmware-runtime/refresh-inputs.json` records exact deliberate
roots and generator inputs, including:

- CPython 3.13.15 and its source archive identity;
- the python-build-standalone release and exact builder commit;
- PlatformIO 6.1.18 and `uv` 0.12.3;
- exact direct pioarduino-core and esptool source archives;
- exact distribution sets for top-level PlatformIO, pioarduino root, ESP-IDF,
  `uv`, and esptool; and
- the two supported target IDs.

No tool asks an index for “latest” during an ordinary build. A maintainer edits
explicit roots in a review branch before generating a candidate.

### Candidate generation and validation

`.github/workflows/firmware-runtime-refresh.yml` must continue to:

1. run from a clean exact generator checkout;
2. generate independent A and B candidates natively on Linux x86_64 and macOS
   arm64 from clean work areas;
3. require byte-identical bundles, contracts, license reports, and evidence;
4. replay root and ESP-IDF environment creation offline from an empty cache;
5. assemble the complete dual-host candidate lock without accepting it in the
   repository;
6. seed only the exact host candidate into an isolated cache;
7. perform clean and package-index-disconnected warm firmware builds for both
   boards;
8. compare exact firmware/runtime provenance between clean and warm runs;
9. build and package both production targets on Linux, prove that the
   factory-bundle/runtime-attestation chain matches the candidate lock, and
   extract and verify every checksum;
10. mutate an accepted runtime member and prove failure before PlatformIO and
    before factory packaging; and
11. upload short-lived candidate artifacts for human review.

Workflow artifacts and Actions caches are review inputs, not accepted runtime
URLs.

### Human review

Before publication, reviewers inspect:

- every added, removed, or changed normalized distribution and exact version;
- wheel filenames, compatibility tags, source URLs, sizes, SHA-256 values, and
  source-to-wheel relationships;
- direct pioarduino-core, esptool, CPython source, standalone-builder commit,
  and platform/package identities;
- dependency-set and license changes, including explicit overrides;
- candidate A/B byte identity and native runner identities;
- offline root/ESP-IDF replay evidence;
- clean/warm firmware manifests for both boards and both hosts;
- both production factory descriptors, embedded build-attestation hashes, and
  runtime-attestation equality evidence;
- tamper-before-PlatformIO evidence; and
- the proposed unique lock-set ID, tag, asset names, sizes, and digests.

The runtime refresh PR contains only deliberate input, lock, license,
generator, workflow, provenance, test, and documentation changes. It does not
mix unrelated firmware features.

### Publication and lock acceptance

After review, a maintainer publishes uniquely named prerelease assets. Existing
accepted tags and assets are never overwritten or deleted. The maintainer then
assembles `lock-v1.json` from the reviewed contracts and commits it in a normal
PR. Ordinary CI downloads the published URLs and independently verifies their
tracked sizes and SHA-256 values.

Merging the reviewed lock is the acceptance event. Publication alone does not
make a target accepted, and the refresh workflow never mutates the accepted
lock automatically.

The current release
[`firmware-runtime-2026-08-10-1`](https://github.com/seichris/open-bike-computer/releases/tag/firmware-runtime-2026-08-10-1)
is a public prerelease with 11 server-digested assets. At this revision, GitHub
reports `immutable: false`. Local content verification still fails closed if an
asset changes. The implemented publishers therefore refuse to create the next
runtime or product release until an administrator enables the repository's
immutable-release control.

## Implemented focused maintenance work

The follow-up implementation keeps the first-run closure intact and introduces
no live resolver or automatic lock update.

1. `AGENTS.md`, `CONTRIBUTING.md`, and `esp32/README.md` now name the protected
   private CPython/PlatformIO/uv/penv/ESP-IDF closure and the complete initial
   caller/OS/GitHub residual boundary consistently. Policy tests reject the
   obsolete resolver-boundary wording.
2. Runtime candidate generation remains read-only. A separate manual publisher
   rebinds a successful candidate run to the exact workflow commit, requires
   configured human reviewers, stages the exact 11-asset set create-only,
   verifies it after Actions-artifact transport, and receives `contents: write`
   only after environment approval.
   The publisher also rejects any pre-existing release tag and proves the new
   lightweight tag resolves to the exact reviewed generator commit.
3. Both runtime and product-release publication require repository immutable
   releases before creating anything, upload without `--clobber`, verify the
   draft inventory before publication, then require `immutable: true` and
   reverify every server-reported size/SHA-256 for the retained receipt.
4. One strict tracked `publication-v1.json` owns the prospective lock-set ID and
   release tag. Changing it is an ordinary review commit; there is no `latest`
   selector.
5. Build/upload provenance uses closed-field schema 2 with separate shared,
   hydration, and verification timings. Factory output emits its own schema-1
   timing/digest line only when explicitly requested.
6. Native Linux x86-64 and Apple Silicon performance CI records exactly five
   warm locked-runtime handoffs and enforces a lock-specific 20% median limit.
   The existing source-only custom-core 35% gate remains independent.
7. Refresh CI emits one canonical cross-target summary of root, wheel,
   distribution, source, license, runner, reproducibility, offline replay,
   build-validation, and proposed publication-asset changes. It is evidence,
   never an acceptance action.
8. `build_firmware.py --factory-output-dir` is the only CI/release factory
   authority. It runs under the private runtime and project lock, invokes the
   canonical upload validator before creating output, requires an empty safe
   destination, and records separate packaging timing.
9. Factory bundle/release schemas 2 bind the external and embedded descriptors,
   build manifest, runtime-provenance digest, safe complete checksum inventory,
   exact flash layout, required images, immutable `keep` write parameters, and
   signed archive identity. Mixed, changed, overlapping, unsafe, incomplete, or
   mutable inputs fail before signing or publication.
10. The release signer itself uses an exact Python 3.13 binary-only,
    no-dependency, SHA-256-locked closure derived from accepted runtime wheels.

Ordinary development and device testing omit the factory option and keep the
same helper command. Only CI, tagged releases, factory operators, and
maintainers perform release packaging or dependency refresh.

## Mandatory scope versus optional broader hardening

### Mandatory to preserve the closed pioarduino gap

These controls are non-negotiable for every supported firmware build and
runtime refresh:

- accepted exact-version/size/SHA-256 lock and complete inventory;
- Linux x86_64 and Apple Silicon native candidate evidence;
- locked CPython, PlatformIO, `uv`, pioarduino root, esptool, and ESP-IDF
  closures;
- verified pioarduino platform and executable-package archive layer;
- pre-execution verification, exact offline transforms, post-install
  attestation, and fail-closed unsupported-host behavior;
- ordinary CI, diagnostics, release, and speaker builds through the same
  helper;
- runtime/core/source/artifact/flash-plan binding for build, upload, and
  `--upload-only`;
- strict propagation of that same runtime/build identity into
  each production factory bundle and its signed release identity;
- manual-only refresh and human-reviewed lock acceptance; and
- immutable historical lock identities and rollback assets.

The focused documentation, release-publication, provenance-contract, review,
and performance controls above are implemented maintenance hardening around
that boundary. They must not be weakened by later refresh work.

### Optional broader host and GitHub trust hardening

These are valuable but are not required to claim that pioarduino's online
first-run Python resolver has been removed from the supported build path:

- always entering through a verified shell/native launcher to avoid trusting
  system-Python startup, site initialization, and user/global Python packages;
- reproducibly building CPython or independently rebuilding the standalone
  interpreter instead of relying on one python-build-standalone artifact;
- pinning GitHub Actions by full commit SHA and attesting runner images;
- signing runtime locks and assets with an independent Sigstore/TUF/in-toto or
  offline-maintainer trust root;
- mirroring accepted runtime assets to an independently controlled immutable
  store for availability;
- moving release signing-key custody to dedicated hardware-backed key
  management and running the factory/OTA signer in an isolated attested job;
- defending against a malicious host kernel, root user, filesystem, compiler,
  or hardware; and
- adding Windows, Intel macOS, Linux arm64, or another Python ABI.

These changes need their own threat model and acceptance gates. They must not
be folded into a routine wheel refresh or used to delay a security update to
the already accepted closure.

## Tests and validation

### Required unit and policy coverage

Keep and extend the focused suites in:

- `esp32/tools/tests/test_firmware_runtime.py`;
- `esp32/tools/tests/test_refresh_firmware_runtime.py`;
- `esp32/tools/tests/test_build_firmware.py`;
- `esp32/tools/tests/test_generated_sdkconfig.py`;
- `esp32/tools/tests/test_pioarduino_custom_core.py`;
- `esp32/tools/tests/test_firmware_profile_config.py`;
- `esp32/tools/tests/test_package_factory_firmware.py`;
- `tools/tests/test_factory_release_manifest.py`;
- `.github/scripts/tests/`.

They must cover strict/canonical lock parsing, duplicate keys, exact versions,
target/tag compatibility, bundle/member hashes and sizes, path and link safety,
ownership and permissions, ambient injection, atomic publication/repair,
offline command construction, exact transforms, installed distribution/tree
attestation, schema invalidation, cache quarantine, workflow bypass attempts,
provenance fields, and upload-only tampering.

The factory suites must additionally reject a missing, extra, or changed
`runtimeProvenance`; a package attempt after runtime/core/source/artifact
mutation; schema-1/schema-2 confusion; internal/external descriptor mismatch;
an embedded build-attestation digest mismatch; archive/descriptor mixing; a
cross-target or non-production artifact; and any factory-release signature
whose direct build/runtime digests do not equal the descriptor. Workflow tests
must require authoritative packaging through `build_firmware.py` after the
locked handoff.

Any runtime-affecting implementation PR runs at least:

```sh
cd esp32
env -u LD_LIBRARY_PATH PYTHONPATH=tools python3 -m unittest \
  tools.tests.test_build_firmware \
  tools.tests.test_firmware_runtime \
  tools.tests.test_firmware_profile_config \
  tools.tests.test_generated_sdkconfig \
  tools.tests.test_package_factory_firmware \
  tools.tests.test_pioarduino_custom_core \
  tools.tests.test_refresh_firmware_runtime

cd ..
python3 -m unittest tools.tests.test_factory_release_manifest
python3 -m unittest discover -s .github/scripts/tests
```

### Native integration coverage

For each accepted target, the refresh gate must:

1. start from clean generator and candidate work areas;
2. build two byte-identical candidate bundles;
3. replay all nested Python environments offline;
4. build ordinary 1.75 and 2.06 firmware from an empty private store;
5. repeat both builds with package-index access blocked;
6. require identical runtime and exact-build provenance across clean/warm
   repetitions;
7. mutate an accepted runtime member and prove PlatformIO is not reached; and
8. preserve upload-only rejection after runtime, installed-environment,
   transformed-platform, core, artifact, or flash-plan mutation.

On Linux, the same integration gate packages both production targets through
the helper, verifies the external descriptor and archived copy are identical,
extracts and checks the archive, and validates the build/runtime digest chain
that the schema-2 factory-release manifest will sign. A signing secret is not
needed to test canonical payload generation and public-key verification with a
test key.

No physical flash is required to prove the host Python supply-chain boundary.
Physical `BOOT_META` and ready-state evidence remains required for claims about
what runs on a board, but it is a separate firmware/hardware acceptance layer.

## Migration, repair, and rollback

### Migration to a new accepted runtime

A new lock set uses a new immutable ID and release tag. It never edits an old
asset in place. After the reviewed lock merges, the helper selects the new
content-addressed subtree and rebuilds affected private runtime/core state.
Old build/core schemas and old runtime identities become ineligible rather
than being upgraded in place.

New factory artifacts use factory-bundle and factory-release schema 2. Already
published schema-1 factory releases stay
verifiable through an explicitly versioned legacy parser; they are never
rewritten to look like schema 2. Runtime lock changes do not edit a factory
release in place: they produce a new exact source commit and release tag whose
factory artifacts bind the new runtime identity.

Ordinary users still invoke the same helper. They do not run the resolver or a
dependency migration command.

### Repair

`--repair-runtime` is recovery for corruption or an incomplete exact download.
It validates the deletion target, removes only the selected lock/target shared
and private subtrees, and obtains the same locked bytes. It cannot select a new
lock, change versions, or bypass verification.

### Rollback

A dependency rollback reverts the tracked lock and related schema/input changes
to the previous accepted lock. The helper then selects the old
content-addressed bundle and rebuilds affected private state. Keep every
accepted release asset available. Package the rollback firmware under a new
release identity; do not overwrite an already published factory archive or
signature for an older tag.

A verifier or workflow rollback reverts code, schemas, workflow policy, and
documentation together. It must not restore `pip install --upgrade
platformio`, ambient `pio`, live dependency solving, an online fallback, or
asset clobbering as an emergency path. Availability failure is safer than
executing unreviewed dependencies.

## Measurable acceptance gates

The focused hardening remains complete only while all of these gates hold:

1. The tracked lock is canonical and strict; its outer digest binds a canonical
   inventory that accounts for every bundle member, while the lock separately
   accounts for every wheel and installed distribution set by exact identity,
   size, and SHA-256.
2. Exactly the reviewed `linux-x86_64-cp313` and `macos-arm64-cp313` targets are
   accepted; unsupported hosts fail before PlatformIO.
3. Clean native Linux and Apple Silicon candidate generation is byte-identical
   across independent A/B runs.
4. Root pioarduino, esptool, and ESP-IDF environment replay succeeds with
   package-index/direct-source access disabled.
5. Top-level PlatformIO, `uv`, root `penv`, esptool, ESP-IDF, and transformed
   platform identities appear in build and upload eligibility.
6. CI, diagnostics, release, and speaker workflows contain no live PlatformIO
   installation and invoke only `build_firmware.py` for supported builds.
7. Both ordinary boards build clean and warm on both accepted host targets;
   clean/warm runtime and exact-build provenance agrees.
8. A modified bundle, member, wheel, installed environment, transformed
   platform, core entry, firmware artifact, or flash plan causes failure before
   the affected execution or upload.
9. Ambient malicious `pio`, `pip`, `uv`, Python injection, and dynamic-loader
   test doubles do not become the supported runtime.
10. Runtime repair reuses only the same lock and cannot update dependencies.
11. Runtime refresh remains manual-only, cannot persist accepted repository or
    release state, and requires human review before unique asset publication
    and lock acceptance.
12. `--upload-only` revalidates exact runtime, core, source, artifact, uploader,
    and flash-plan state and never rebuilds or resolves online.
13. Source-only local builds retain the core-cache performance gate of at most
    35% of the cold-build median with zero custom-core bootstrap time.
14. Warm runtime-handoff performance has a recorded per-target baseline and
    does not regress by more than 20% without an explained, reviewed profile.
15. Documentation accurately names the protected closure and the initial
    host/GitHub residual boundary; it contains no stale claim that the online
    pioarduino resolver remains trusted.
16. Accepted runtime assets are never replaced. Publication requires both
    repository immutable releases and the approval-gated, create-only,
    digest-verified publisher.
17. No automatic dependency update, scheduled lock refresh, warning-only mode,
    Linux-only acceptance, or fallback resolver is introduced.
18. Both production profiles package through an opt-in
    `build_firmware.py --factory-output-dir` mode under the locked runtime and
    project lock; release workflows do not invoke an ambient-Python packager as
    an authority.
19. Factory-bundle schema 2 exposes a strictly derived runtime-attestation
    digest, and factory-release schema 2 directly signs that digest and the
    embedded build-attestation digest alongside the archive and descriptor.
20. Internal/external descriptor mismatch, missing or changed runtime
    provenance, mixed build artifacts, or an invalid extracted checksum fails
    before signing or publication.
21. The ordinary helper invocation emits no factory archive, adds no packaging
    work to local coding/device-test loops, and retains the existing runtime
    and core-cache performance gates.

## Implementation evidence and remaining external decisions

The accepted runtime was generated from commit
`f354297eb831665ca37bf7ca1edfd23b6b779e35`. PR #228 records 152 focused tests,
successful Linux and native Apple Silicon candidate generation, byte-identical
A/B bundles, offline replay, clean/warm builds, and tamper rejection. PR #229
records workflow-policy validation and successful locked workflow builds. PR
#231 records a macOS arm64 source-only custom-core-cache median of 19.07% of the
cold median, with `coreCache=hit` and zero custom-core bootstrap time.

The final PR #240 head
`d0e628ca9e6dcbb23929d056b61d9e9829407ba7` was revalidated after every check
passed and merged as `05cb1d47bb92b93087c521a421a9056b613a35b5`.
The implementation is rebased from that exact `origin/main` boundary.

Local validation covers the root factory signing/release tools, the focused
184-test firmware runtime/build/factory suite, 49 workflow-policy tests, YAML
parsing, Python compilation, signing-wheel hash/availability checks, and native
Apple Silicon warm runtime measurements. GitHub Actions run `31592912639` on
implementation PR #244 established the checked five-sample warm-handoff
medians: 4,636 ms for `linux-x86_64-cp313` on `ubuntu-24.04` and 2,197 ms for
`macos-arm64-cp313` on `macos-15`.

Only these external or deliberately broader decisions remain:

1. **Repository controls:** GitHub currently reports immutable releases as
   disabled. An administrator must enable them before the next runtime or
   product release. The publisher intentionally fails before creating a
   release until this is done. The `firmware-runtime-publication` environment
   must likewise be configured with required human reviewers before use.
2. **Additional host targets:** add none until a concrete supported-developer
   or release requirement pays for native generation and continuing CI.
3. **Initial host bootstrap trust:** keep it explicit in the mandatory claim;
   a verified native/shell launcher or independent artifact mirror remains a
   separately reviewed broader-hardening project.

The factory architecture is the intended long-term version: helper-owned
locked-runtime packaging, the shared strict validator, direct schema-2
runtime/build/flash bindings, exact signer dependencies, approval-gated
create-only publication, and mandatory server-side immutability.

None of these decisions permits live Python resolution, automatic dependency
updates, asset replacement, or a second ordinary developer build command.
