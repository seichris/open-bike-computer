# PR #378 review fixes

## October 25 verified-fix publication and remaining gates

Mode: publish; standard profile; sequential-local; zero subagents; P0/P1/P2
gate. The user authorized committing/pushing the already verified fixes,
refreshing plan/PR text, checking CI, then flashing the selected isolated POI
profile to the identified 175. This does not authorize a PR merge, production
rollout, unrelated fixes, manual 2.06 CI or an automatic review-budget reset.

Source: main `cd7ad00bb6c4f9566195cd44ab4d6a675518b94d`, published PR head
before this batch `69008639a56264e16dc8d41b39015848655904a1`, reviewed local
source through `645681ea` and separate cleanup `4f9c7b1d`. The publication
reconstruction's full source tree matched verified tree
`165f34d6a34e042b7b87e32d088666ad909b6735` before these documentation edits.
Main's current policy and verification-runner changes were kept unchanged.
An inherited blank EOF line in main's REVIEW.md is not a runtime change and
is not repaired here; the PR delta against current main passes diff checking.

The latest whole-PR review used all three passes. Its final pass exposed R71;
the user explicitly authorized its narrow repair plus one independent
confirming verification. That confirmation passed. No additional broad audit
or unlimited repair cycle is implied by this publication. Older iteration
records below are historical, not new budget grants.

| ID / class | Current disposition and evidence |
| --- | --- |
| R71 / COD-JOURNAL-VARIANT-AUTHORITY, P1 | Fixed+verified locally: malformed primary plus foreign signed backup preserves both journals and yields owner-required recovery, with POI runtime off/on. Three canonical recovery/stream/durable checks passed at clean local 645681ea; 2,420 modeled schedules and 2,364 recovery cuts had no previous-map loss/invalid/unavailable outcomes. |
| INT-1, integration test | Fixed+verified: the source-wiring assertion now checks guarded device capture, helper invocation and all fresh identity/epoch/readiness/revision/mode/token/generation fields. Complete canonical manifest check: 228 tests passed. Runtime code was not weakened. |
| First-pass and radio/cleanup repairs | Included from the independently checked local batches: accepted-install confirmation, HTTP layer state, target negotiation/admission, metadata allocation/readback/recovery, startup rejection, bounded finalizer error reports and cross-manager/device cleanup fencing. Prior clean local reports passed 15 iOS/41 firmware checks, 58 radio checks, and 15 cleanup checks; those retained reports are not new published-head CI. |
| R53/R56, P2 | Active: iOS/backend/catalog target-5 contour companion contract needs coordinated work. No deployment is included. |
| R54, P2 | Active: POI regeneration action is missing from the configurable-screen editor. |
| R55, P2 | Active: target-5 reuse misses regenerate the map; cost/efficiency rather than incorrect data. |
| R65/R66 and R67-R70 | Pre-existing main concerns/separate follow-ups: ATT fairness, status/buffer pressure, retry/reconnect and UI staleness. No claim that this batch solves them or proves the observed field root cause. |
| H-R71b | Hypothesis only: foreign backup beside a valid own v2 primary in other writer/cleanup paths requires a multi-fault reproduction; not invalidated or described as fixed. |
| Map+Navigation / physical acceptance | Active unverified behavior: black/entry failure remains undiagnosed. New-head transfer/cleanup, GPS/reconnect, Nearby and cold/both-board acceptance are separate physical gates. |

The narrow R71/integration scope has two fixed+verified items and zero active
items; the full feature still has the active items above. No finding is
silently user-deferred. State: **not merge-ready / physical and feature gates
open**. Publishing the verified repair batch is not whole-PR approval.

Uncommitted integrated local validation: 58 broad checks passed, the wiring
failure was repaired and its full check passed, OSM passed all 183 tests in
an isolated container despite broken host GDAL/Python dependencies, backend
ran 1,053 tests with three skips, and stable-source iOS/Watch simulator plus
Debug/Release container checks passed. These are executed local checks with
the documented environment limitations, not CI reuse claims.

Dirty 175 build measurements: production 3,006,704 bytes, isolated POI
qualification 3,068,736 bytes. Slots remain 3,145,728 bytes each and reserve
65,536 bytes, leaving 73,488 / 11,456 bytes beyond the reserve respectively.
Clean published-head size/provenance/CI and exact device delivery remain new
gates; earlier dirty artifacts have uploadEligible=0 and must never be flashed.

Risk: **high**, because activation recovery and authenticated transfer
ownership affect installed map state. Preserve retained incident bytes and
working maps. Before a reset/flash, establish that no transfer or unpreserved
recovery evidence is active. Any rollback needs an operator-approved compatible
firmware/app/map snapshot after reconciling pending operations; do not erase
journals, overwrite unknown authority or restore an older image blindly.
Production remains unchanged and POIs disabled there. The PR description owns
the exact published head, CI links and subsequent delivery results.

## October 23 physical Nearby test: phone GPS gating

R34 (P1): the connected 175 remained at `Waiting for GPS` even while Bicino
Dev recorded fresh CoreLocation samples and successful GPS ATT writes. The
Nearby predicate additionally required `isGpsFixed`, which is owned only by
the onboard NMEA receiver; authenticated phone packets never set that flag.
The source-owned presentation timestamp already validates freshness for both
sources and invalidates a disconnected BLE source. Nearby now uses that clock
and valid coordinates, matching the map renderer, without changing global
receiver status, ride-detection quality, or the strict 2.5-second age bound.

A native regression executes the actual `nearbyFreshPosition` and
`nearbyStartSearch` bodies. It fails on `8d4f62b0` and passes with the fix:
fresh stationary phone positions search without an onboard fix; stale,
unknown-age, disconnected and invalid-coordinate inputs cannot search;
millisecond wrap and independent hardware-source timing remain valid.
All three lifecycle tests and the four affected Nearby/render-ahead host
checks pass locally. Exact-commit firmware size and physical acceptance are
separate pending gates, not implied by those host results.

The current phone recorder's 26 chunks and manifest validate with the
repository diagnostics parser (no truncated tails or sequence gaps). Its
13:20-13:46 UTC window shows fresh fixes and successful BLE writes, not
durable firmware application evidence: no imported firmware chunks were in
that acquisition. The running iOS app requires no code change. This GPS fix
does not waive target-5 POI-map service, transfer or physical Nearby-result
qualification, change trust/partitions, or enable POIs in shipping profiles.

## October 23 main integration (route elevation and device map library)

Mode: publish. Scoped update requested by the user: merge current `main` into
the existing PR branch, resolve conflicts, verify, push; no PR merge, flash,
install, deployment, hardware/serial access, 206 build or shipping POI
enablement. The four generated ESP32 SDK/bootstrap files remain never-stage.

- Published PR head before the update: `b64ca6c79b5d0b9a7ecd6e752afd9da3917e4e40`.
- Integrated main: `b84e68543ac5aa402ae55ecfe3d34439d14786ff` (34 commits:
  shared route elevation #620, SD map library and coverage selection #618,
  iPhone online nearby places #615, friend-sharing resume/hardening #619/#621).
- Merge commit: `f5a8387a89659bb8f51f5df8710f8690ea50db63`; follow-up
  `2edf8896f6320e6bd9bbd18347299f279b1cf1c7` (legacy Elevation enum); main's
  later development promotion `b576d2f04d6969fba241c120a917719e87232529`
  merged as `bf56baedb379f40e217a12cd8114e2a201065f79`. Normal merges and
  fast-forward pushes only; no history rewrite or force push.
- The owner then merged main `d2b10c00d09a722f95baf9042f22e0b4e6a78714`
  (#624 map tracking controls, #625 Apple Maps route elevation: iOS, docs and
  backend only, no firmware) through GitHub as
  `404e6ae6c398a11c083beb708f97eaee63439c7d`. Main's development image pin
  `483c8c5ab11715e08a4d84e29dbd1aef666d4810` merged as `1d58708b`; the owner
  merged main `58b3b297eed423496c25baa5aab0c8c239fa78bb` (#628,
  diagnostics-only Elevation text) as
  `b8d22c1c539dc5823a1d1c539a20bf7608345ab5`.

| ID | Priority | Trigger, fix and verification | State |
| --- | --- | --- | --- |
| R32 | P1 | Main's released route elevation owns CAP2 extended bit 2/client 32 and screen type 6, the same values as the unpublished POI/Nearby allocation; a merged build would have read route-elevation firmware as POI-capable and mapped Nearby onto Elevation. POIs move to extended bit 3/client 33 and Nearby to screen type 7 (tile 9); the client version is 33; both bindings and the pinned-LVGL preview metadata are regenerated. Firmware and iOS tests cover bit/client separation, combined words, route-elevation-only firmware receiving no POI bits, and the 175 diagnostics+POI matrix where Elevation and Nearby coexist | fixed; firmware host, iOS fast and exact-head CI verified at `99c8032d` |
| R33 | P1 | After integration the enabled-POI `WAVESHARE_AMOLED_175_POI_LIFECYCLE_QUALIFICATION` image no longer fit the dual 3 MiB slot with the 65,536-byte reserve: total image 3,094,427 bytes, about 14.4 KB over the 3,080,192-byte `firmware.bin` maximum, because main's production-behavior image grew about 49.5 KB. `20294f17` recovers the space without changing any output: large mostly-zero state moves from `.data` to `.bss` and three serializers use in-place appends. No budget, partition or profile change | fixed; CI-verified at `b8d22c1c`: 3,072,864-byte binary, 7,328 bytes beyond the reserve |

Conflict resolutions (23 files):

- Contract, generated C++/Swift bindings, `docs/ble-protocol.md`: keep main's
  route elevation; add `map_pois` bit 3/client 33 and `nearby: 7`.
- Firmware screens (`ble_navigation.*`, `screen_configuration*`,
  `mainScreenTypes.hpp`, `mainScreenRegistry.hpp`, `mainScr.cpp`): enumerate
  both Elevation and Nearby; masks stay one byte (Nearby is bit 7). Both screens
  are opt-in: the registry default mask now also excludes Elevation, matching
  main's `DEVICE_SCREEN_DEFAULT_MASK`. R21 stored-document normalization still
  applies to Nearby only; Elevation keeps main's own downgrade behavior.
- `map_transfer_http.hpp`/`main.cpp`: keep both the renderer health probes and
  main's stream free-space probe. `test_map_transfer.cpp`: run both POI and
  map-library tests.
- iOS model/view/tests: add `.nearby` beside `.elevation`; update pinned screen
  types, client version and CAP2 fixtures (POIs are extended byte `0x08`).
  The first local Swift helper run exposed that the regenerated legacy
  screen enum dropped main's Elevation (used by BLEManager's legacy screen
  settings); `2edf8896` keeps the six original screens plus Elevation and
  leaves Nearby wire-only, and fixes the native-zone capability fixture.
- `tools/development/checks.json`: keep the PR's `python3` fix and main's
  map-library control test; add the diagnostics+POI registry and
  screen-configuration variants to the Nearby feature-gate check.

Reviewed auto-merged interactions: main's map library activates a selected
installed map through the same renderer activation as transfers. R30's
transient POI metadata failure reports a failed activation; the previous map
stays active, a transfer rolls back and a library candidate is excluded only
until the next library command clears `libraryRejectedSessions_`. POI-disabled
firmware omits installed target-5 maps from the library (manifest rejected)
rather than deleting them. R29 routing still selects the native OSM gate for
backend shard changes. R31's generation/shutdown-aware retry is unchanged.

Verification: local, on the exact merge `f5a8387a` unless noted.

- `tools/dev-check` (auto, fast): 55 checks passed with `sourceUnchanged=true`,
  including every firmware host check (Nearby query/lifecycle/layout/feature
  gate, screen configuration, registry, device capabilities, map transfer,
  route elevation). Failed: Swift helper tests (the legacy-enum compile error
  fixed in `2edf8896`) and OSM extraction (host venv lacks `shapely`, `osmium`,
  `freetype`). Blocked: map backend tests (no `map-platform/backend/.venv`;
  not created, to avoid installing packages).
- OSM suite with the dependency-capable Python 3.11: 181 tests, 179 pass; the
  two native OGR tests abort because this Mac's Homebrew `ogr2ogr` lacks
  `libx265`. CI runs them in the product tools image.
- Backend unit tests with Python 3.11: 978 run, 54 skipped, 7 import errors
  (`rasterio` x5 terrain, `sqlalchemy` x2 social) - missing optional extras,
  not merge regressions. Deployment: 61 pass. CI installs the full extras.
- Registry flag matrix (default, diagnostics, POI, Elevation, POI+Elevation,
  175 diagnostics+POI) and capability/contract-reuse tests pass; the pinned
  LVGL preview `--check` and fast preview test pass.
- iOS fast after `2edf8896`, on stable head `99c8032d`: 12/12 passed with
  `sourceUnchanged=true`. Earlier `b64ca6c7` artifacts (3,045,056 bytes) are
  not relabeled for this head.

### Exact-head CI and application budget (R33)

PR CI [39933153447](https://github.com/seichris/open-bike-computer/actions/runs/39933153447)
built `99c8032d` (merge ref `11735fbf`). Passed: ESP32 host tests; 175
ordinary, production, lifecycle-qualification and remote-debug firmware; map
backend, OSM pipeline (including native POI equivalence), Social PostgreSQL,
topography readers, Cloudflare catalog; iOS fast, simulator and app builds;
CI selection; Workout Zone contracts. Failed: the enabled-POI 175
qualification image at the verified reserve gate ("leaves less than the
required 65536-byte application reserve"), and therefore CI Gate. The
branch-bound firmware run
[39933173298](https://github.com/seichris/open-bike-computer/actions/runs/39933173298)
passed the same four 175 profiles and host tests; its POI job stopped on a
transient `tool-mklittlefs` download reset before any size result. PR CI
[39939860119](https://github.com/seichris/open-bike-computer/actions/runs/39939860119)
at `13afed20` (after main `d2b10c00`; merge ref `8251396`) reproduced every
size byte-for-byte and the same single failure.

| Image (175) | Source | Total image | `firmware.bin` | Beyond 65,536-byte reserve |
| --- | --- | ---: | ---: | ---: |
| Lifecycle, POIs off | this PR, merge ref `11735fbf` | 3,054,183 | 3,054,336 | +25,856 |
| Lifecycle, POIs on | this PR, merge ref `11735fbf` | 3,094,427 | about 3,094,580 (not recorded; gate failed) | about -14,390 |
| Lifecycle, POIs off | main after #618/#620, merge ref `2430001e` | 3,077,795 | 3,077,952 | +2,240 |
| Lifecycle, POIs on | previous baseline `c6181a70` | - | 3,044,960 | +35,232 |

The binary estimate adds the 153-157 bytes of image overhead observed for
the passing profiles. Linker-map and symbol comparison of the two POI-off
lifecycle ELFs explains the gap without any lost main code: main still links
libstdc++ file-stream and locale instantiations (about 42 KB of
`.flash.rodata`, mostly unwind tables, plus their code) that this PR's
`MapReadFile`/`MapWriteFile` path removes, while the PR's always-on target-5
manifest, block and index code adds about 18 KB of `.flash.text`. The POI
runtime itself (Nearby screen, query cursor and layout, map icon layer,
manifest checks) costs about 40.2 KB at the same head. Main's own lifecycle
image is therefore within 2.3 KB of the gate.

A per-translation-unit size study with the pinned Xtensa toolchain
estimates about 7-8 KB of PR-local, behavior-preserving savings (Nearby view
state moved from `.data` to `.bss`, compact JSON and manifest field
builders, a table-driven icon painter, one sort instead of two
instantiations). Only the 1,584-byte `.data` move is exact; none of it is
implemented or CI-measured. That is roughly half the shortfall; closing it also needs main-owned code changes,
deeper Nearby algorithm rewrites, the separate partition migration (#461) or
a narrower POI scope. Those are owner decisions and none was taken. A local
exact-head firmware build was abandoned when this Mac ran out of disk space;
no local firmware artifact exists for this head.

### R33 resolution: behavior-preserving size recovery

The owner chose to trim to fit, including main-owned code with byte-identical
behavior. `20294f17` keeps the 3 MiB slots, the 65,536-byte reserve and every
profile unchanged:

- **`.data` to `.bss`.** File-local state whose defaults hold a few non-zero
  sentinels stored its whole, mostly zero, initializer image in the flash
  slot. `StartupConstructed<T>` (`lib/utils/src/startup_constructed.hpp`)
  value-initializes the same object during C++ static initialization, before
  `setup()`, in zero-filled `.bss`; the old name binds to it by reference, so
  no caller changes. Moved: the screen-configuration control (4,136 bytes),
  deferred BLE notifications (2,112), the workout reducer (1,688), the Nearby
  view (1,584), rider badges (1,280), the active screen snapshot (972), the
  destination catalog (556), ride-stats slots (420) and the ride delivery
  tracker (272). The pinned Xtensa compiler places each in `.bss` with one
  small startup initializer per file and identical accessor code.
- **In-place appends.** `targetMetadataJson`, `manifestReceipt` and
  `appendRendererLayerStatus` built their output from `operator+` chains, one
  string temporary and exception cleanup per operand. They now append in
  place. The old and new bodies, extracted verbatim, matched on 800,000
  randomized comparisons (empty targets, every format version, contour
  states, three key prefixes, escape-heavy text, `UINT32_MAX`, `UINT64_MAX`
  and `INT32_MIN` coordinates); a one-key mutation was caught immediately.
  The status helper matched an exhaustive 1,600-case sweep.
  `test_map_transfer.cpp` now pins golden bytes recorded from the old
  implementation: the v1 library receipt, the target-5 installed receipt and
  the target-5 `active-map.json`.

Measured per-object with the pinned toolchain, the moves saved 12,212 bytes
and the serializers about 11.9 KB before link deduplication. Local
`tools/dev-check --suite firmware` at `b8d22c1c`: 41/41 passed with
`sourceUnchanged=true`.

PR CI [39946703308](https://github.com/seichris/open-bike-computer/actions/runs/39946703308)
at `b8d22c1c` (after the owner merged main `58b3b297`; merge ref `420be6d4`):
**all 16 jobs passed, CI Gate green**. Exact binaries from the build
evidence:

| Image (175) | Total image | `firmware.bin` | Beyond 65,536-byte reserve |
| --- | ---: | ---: | ---: |
| Lifecycle, POIs on | 3,072,703 | 3,072,864 | **+7,328** |
| Lifecycle, POIs off | 3,033,499 | 3,033,664 | +46,528 |
| Production | 3,013,231 | 3,013,392 | +66,800 |

Ordinary 175 (3,210,087) and remote-debug (3,295,347) use the larger
development layout. The 206 POI image was not built (no 206 permission);
the changes are board-independent C++. Physical qualification of the new
image remains a separate gate.

## October 23 Claude review follow-up

Mode: publish. Profile: standard. Strategy: sequential-local, zero subagents.
Gate: P0/P1/P2. Iteration 3 freezes head
`c6181a7065e4f8eb5a0515ff48371708e6173fc8`, base/merge-base
`19c9787d61ff5b6526fea0ef9d73f953ecd766be`, plus only this loop's patch.
The four generated ESP32 files remain never-stage. Claude's Mac review of
that clean checkout completed and its 185-line report was retrieved from
`/tmp/pr378-claude-review-c6181a70.md`; no account/session files were inspected
to work around the locked Mac. It reported no P0/P1, one P2 routing gap and
six P3 notes. Independent correctness, reliability, packaging and verification
review reproduced that P2 and promoted two runtime notes after executing the
actual production activation method and UI retry branch in native fixtures.

| ID | Priority | Trigger, fix and verification | State |
| --- | --- | --- | --- |
| R29 | P2 | A shard-only backend change selected no OSM job. Three new routing subcases fail before the fix and pass afterward; shard producer/package initialization and shard contract tests now select both backend and mandatory native OSM equivalence | fixed+verified |
| R30 | P2 | Activation committed replacement metadata despite transient read/allocation failure, making valid POIs unhealthy until reactivation. Native fault injection aborts the baseline on `!committed`; the fix rejects the transaction before touching the old map/cache/health, distinguishes missing files from transient open errors, and preserves legacy/corrupt-POI degradation behavior | fixed+verified |
| R31 | P2 | The UI canceled any query at 15 seconds, including still-current bounded work, and could cancel a replacement generation. The native baseline aborts at the 15-second boundary. Retry now follows the atomic generation/shutdown state and retires only the stale UI sequence; long/wrapping-clock, supersession and shutdown cases pass | fixed+verified |

The new lifecycle fixtures compile production source fragments, not copies of
the fixed policy. Both pass on macOS and in the unchanged Ubuntu 22.04 product
tools image with warnings-as-errors. They are registered in the shared Nearby
host check, hence local and CI use the same test entry point. All 40 firmware
host checks and all 12 iOS fast checks pass with `sourceUnchanged=true`.
Development-runner and CI-routing checks pass; the pinned-LVGL preview remains
up to date without any generated asset changes. The initial preview invocation
without its required source argument did not run the check; the documented
invocation with the pinned source succeeded.

Iteration 4: fresh confirming review of transaction ordering, atomic query
liveness, error classification, CI dependency routing, production gates and
native test wiring finds no further in-gate defects. Current totals: 30
fixed+verified, one invalidated, zero active/user-deferred code findings.
Remaining nonblocking notes concern legacy/shadow extraction performance, a
stale comment, already-validated decoder preconditions and the documented
client-31/nonshipping-type-6 upgrade boundary; no speculative fixes were made.

The `c6181a70` baseline now has all 18 PR checks and the 16-job branch-bound
all-component run passing, plus verified exact-source 3 MiB evidence. Those
results are not relabeled as evidence for this runtime follow-up. Fresh clean
published-head checks, CI and the enabled-POI size/reserve manifest must be
recorded in the PR. No merge, flash, install, deployment, 206 build or shipping
POI enablement is included. Physical and rollout gates remain incomplete.

## October 23 remaining-requirements audit

Mode: publish. Profile: standard. Strategy: sequential-local, zero subagents.
Gate: P0/P1/P2. Initial target: PR #378 head
`9cab0b6fb59b878deca994f4449abf3479fcfd92`, base/merge-base
`19c9787d61ff5b6526fea0ef9d73f953ecd766be`. Tracked source is clean;
the four pre-existing ESP32 generated SDK/bootstrap files remain never-stage.
Iteration 1 audits correctness, reliability/security fences, packaging and
changed-path verification against the remaining implementation/qualification
requirements. Existing live review threads are empty; Claude's GitHub review
was skipped for usage limits, not approved.

| ID | Priority | Finding / current evidence | State |
| --- | --- | --- | --- |
| R26 | P1 | Main's released friend-size flag collided with the prior POI flag; bit 2/client 32 separation and independent/combined wire regressions pass at the initial target | fixed+verified |
| R27 | P2 | Retained simulator xcresult proved fixed-yield assertions preceded reconciliation; bounded condition waits pass 20 native repeats, full local contracts and final-head simulator CI | fixed+verified |
| R28 | P2 | Real Osmium/OGR full-source/prepared POI equivalence was not executable in CI; the new native fixtures pass in the actual product tools image and CI now requires them without dependency skips | fixed+verified |

R28 adds cold/warm sealed-shard and default/selected conversion fixtures,
all five categories, inactive/out-of-bounds exclusions, nonbuilding concave
areas, holes and multi-outer relations crossing shard and render-block
boundaries. CI must execute them inside the actual tools image and fail on
missing native dependencies rather than accept a skipped test.

Verification: both new tests pass in the unmodified Ubuntu 22.04 product tools
image (`sha256:b4e042942394ae2917b062cd0a35436002f1c6bd9673ae3daed717b30a5ff6d8`,
local arm64). The full Ubuntu 24.04 native-tool suite passes 183 tests with
eight existing font-fixture skips; a clean `9cab0b6f` baseline passes 181 tests
with the same eight skips. Neither new test skips. Backend tests pass 998
(three skips), deployment 58, and development/CI-routing checks pass, with
`sourceUnchanged=true` in both registered reports. Initial BuildKit registry
TLS failures preceded the build; pulling the unchanged official base through
OrbStack and rebuilding with that cached base succeeded. No image definition,
dependency requirement or test gate was relaxed.

Iteration 2: fresh correctness, security/reliability, packaging and verification
review of the five-file batch finds no further in-gate defects. Current ledger
totals are 27 fixed+verified, one invalidated and zero active/user-deferred;
R10/R18's historical active labels below describe their October 19 snapshot,
not their current state. Clean published-head checks and fresh GitHub results
are recorded in the PR after publication, not inferred from this dirty-source
run or the earlier head's successful CI.

Physical board/iPhone acceptance and digest-pinned deployment/rollout still
need separate authority under the user's no-flash/no-merge instruction. They
remain incomplete delivery gates, not code defects or inferred successes.

## October 22 integration refresh

Integrating main `ff0bb8bba5af1f5845e8959b42c4916808557565` into PR head
`7a030da46c3a25cfb882d0f7318b8003348b9c0a`. The historical review and table
below are retained as evidence, not a current pending-CI summary. All 18 checks
on `7a030da4` passed in run `39778840737` and the workout-zone workflow,
including the enabled 175 POI lifecycle build. R10/R18's earlier build gates
were closed by the exact `08d6a2ce` evidence recorded in the PR; physical
timing and acceptance remain separate and are not closed by compilation.

New integration finding: main assigns extended CAP2 bit 1/client 31 to
friend-marker sizing, colliding with this branch's earlier POI assignment.
Preserve main's released bit and setting 39, allocate POIs bit 2/client 32,
and regenerate both bindings and the native preview. Regression tests cover
old client rejection, independent flags with full POI prerequisites, combined
flags, exact C++ bytes, and preservation of friend-size delivery.
There is no alias for the old unpublished POI bit: earlier development apps
and firmware must be upgraded together before further POI qualification.

Local stable-source integration verification passed: all 40 firmware host
checks, all 12 iOS fast checks (including Swift navigation/BLE and Watch,
workout, diagnostics and social contracts), backend 998 tests (three skips),
and deployment 58 tests. Both generated BLE bindings and the pinned-LVGL
native preview check pass. These are uncommitted-source integration results,
not clean-head artifact attestations. Only documentation is edited afterward.
Fresh exact-head CI and 3 MiB/65,536-byte reserve evidence are maintained in
the PR description after publication, without changing the attested source
solely to record its artifact result.
No 206 qualification, device access, flash, application installation, service
deployment, target-5 promotion, or PR merge is included in this refresh.

Main advanced during verification to `71ff5f6c4d77e5cae395589e9f6563e127e08453`.
Merge its two changed approval/deployment files without changing their contents.
There are no additional app/firmware/extractor source changes in that merge.
These inherited approvals remain bound to their existing images and clients;
they do not qualify this POI worker, new firmware, or production target 5.
Recheck deployment contracts and start fresh final-head CI/budget evidence.

At `d24c863a`, all 18 PR checks and branch-bound run `39804697231` passed.
Its verified POI-enabled binary is 3,044,960 bytes, leaving 100,768 bytes in
the unchanged 3 MiB slot (35,232 above the unchanged reserve). The retained
manifest identifies exactly `d24c863a`, binary SHA-256
`30f6fd27e454f5b29ebceb71dccdcff6ee7f87a965774ce3b7a872779aff15f3`.
The final main check found development pin promotion #616 at
`19c9787d61ff5b6526fea0ef9d73f953ecd766be`: only eight Compose-lock lines,
no app/firmware/extractor or generation-policy code. Merge those unchanged
main pins and repeat deployment/CI/budget checks. The `d24c863a` results remain
explicit baselines rather than attestations of that last merge.

### Simulator verification follow-up

Fresh run `39800725264` passed the POI qualification firmware and full app
builds, but the simulator job exposed a pre-existing scheduler-dependent test:
`testInitialReconciliationReleasesRetractedTerminalLease`. Retained xcresult
evidence shows duplicate endings still empty, the lease still active and its
end count still zero when assertions run. Eight `Task.yield()` calls do not
guarantee completion of the asynchronous reconciliation chain.

Replace only that test's two fixed-yield waits with the existing bounded
`waitUntil` helper: first wait for the duplicate end to suspend, then wait for
that duplicate's completed end and lease release. All original assertions
remain; no production Live Activity code or timeout policy changes. Retain a
20-iteration native regression run and rerun the complete simulator contracts
before publishing the test repair. Fresh CI results supersede the initial
failed run rather than treating it as an environment failure or waiving it.

Verification: retained native xcresult reports all 20 iterations passed. The
registered complete iOS/Watch simulator check also passed in 177.2 seconds,
with `sourceUnchanged=true` (local uncommitted-source report
`/tmp/obc-pr378-refresh.nPGKSv/simulator-full.json`). Exact final-head CI remains
a separate gate recorded in the PR; prior firmware/app results are identified
as component baselines when source identity differs.

## Historical October 19 review

Mode: publish. Profile: standard. Strategy: sequential-local, zero subagents.
Blocking gate: P0/P1/P2. Iteration 1: complete initial review of Claude's
report, surrounding firmware/app/extractor/backend contracts and CI evidence.
Initial clean head: `30dc60690c8732ef8612594046bb62ec2e64d408`.
Base/merge-base: `5c7081aa1a7600a1bd6ba3234224b5e2d6da77bc`.
Live GitHub has no review threads. All edits below are loop-owned; no
pre-existing work was present. Production remains dual 3 MiB with its existing
reserve and runtime/rollout gates. No flash, deployment or merge is authorized.
The user identified the connected board as Waveshare 1.75-inch for build-only
validation on 2026-10-19.

| ID | Priority | Finding / evidence at initial head | State |
| --- | --- | --- | --- |
| R01 | P1 | CI 39142019842: all four 175 profiles fail gps.cpp -> settings.hpp -> battery.hpp; dependency cycle needs diagnosis | fixed+verified |
| R02 | P1 | firmware text-size test raises ValueError searching removed tokenizer; reproduced locally | fixed+verified |
| R03 | P1 | SwiftUI profile editor arguments violate memberwise initializer declaration order | fixed+verified |
| R04 | P1 | Default and migrated production screen documents contain unsupported POI bits; stored documents also need normalization | fixed+verified |
| R05 | P1 | Saved-map renderer policy rejects every target-5 artifact | fixed+verified |
| R06 | P1 | Extractor stats count source-halo POIs not encoded in emitted blocks | fixed+verified |
| R07 | P2 | Ambient candidate cap applied before viewport filtering | fixed+verified |
| R08 | P2 | Terrain screen creation retains unsupported POI bits and prevents autosave | fixed+verified |
| R09 | P2 | HTTP status omits POI/contour fields and invents font health | fixed+verified |
| R10 | P2 | Nearby reads entire FMB files and runs an unbounded search on the map worker; the final coverage scan was one unbounded step | active |
| R11 | P2 | Active-map regeneration cannot request POIs/drops contours; signed streams require normalized E7 bounds | fixed+verified |
| R12 | P2 | Nearby result focus leaks disabled GPS follow into ordinary Map | fixed+verified |
| R13 | P2 | Transient search I/O/allocation failure marks POI index corrupt | fixed+verified |
| R14 | P2 | Edge arrows use clamped anchor, not bearing; pin/edge groups can overlap | fixed+verified |
| R15 | P2 | v4 policy absent from worker-image change filters | fixed+verified |
| R16 | P2 | Multipolygon emits one icon per ring instead of agreed one per OSM object | fixed+verified |
| R17 | P2 | Local verification exposed oversized Swift test expressions, a python-only registry command, and stale generated preview source hashes | fixed+verified |
| R18 | P2 | Standard production size excludes enabled Nearby; require an enabled, production-behavior 3 MiB budget candidate | active |
| R19 | P1 | Device POI support alone forced target 5, so POI-capable boards could not create maps from v1/v2 services | fixed+verified |
| R20 | P1 | Shadow/legacy polygon and corridor target-5 output escaped signed Nearby coverage; packaging failed after the build | fixed+verified |
| R21 | P2 | A stored document with a Nearby screen failed to load on POI-disabled firmware, discarding custom screens | fixed+verified |
| R22 | P2 | The 1,024-block Nearby coverage cap ran only at manifest time, after admission and extraction | fixed+verified |
| R23 | P2 | Review hypothesis: old canary artifacts could be reused after the corrected worker is promoted | invalidated |
| R24 | P1 | Linux GCC/glibc rejects the fclose function-pointer deleter type under the Nearby host test's warnings-as-errors | fixed+verified |
| R25 | P2 | Canonical whole-block target-5 coverage still used exact selection-edge filtering in legacy/shadow extraction, omitting data inside signed blocks | fixed+verified |

Non-blocking observation: ambient limits 48/32 and 14 px icons differ from the
plan's qualification targets. These are not demonstrated correctness defects;
physical legibility/crowding qualification remains required, not claimed passed.

## Verification baseline

- `python3 esp32/tools/tests/test_firmware_text_size.py`: related failure (1 error).
- Head CI 39142618487: related host-test failure, heavy jobs skipped.
- Prior 175 matrix 39142019842: related compile failure; no current size result.
- `tools/dev-check --plan`: QR check unavailable in default Python (qrcode,
  zxingcpp missing). Select a verified dependency-capable interpreter or report
  this gate explicitly; do not silently omit it.
- Physical behavior, 206 builds, full-source/shard OGR equivalence, and target-5
  rollback boot qualification are outstanding. Dev/prod policy selection and
  old-client negotiation must not be expanded as part of these fixes.

## Results

Iteration 2: main advanced to `2bedd1fa061419ad53e830c57bcbad2ff5d9c185`.
The complete follow-up review preserves its social overlay and debug-shutdown
changes. Both conflicting Python tests adopt main's stronger recovery fences.
The review patch was preserved in stash
`3a1fcf9cddb9f0731c5aa0c9f99e0490be2ced9b` and reapplied without conflict;
the backup is retained. The merge remains uncommitted until verification.

R10 follow-up: index reads also resume every 4 KiB, and the query index limit
is bounded by signed coverage (1,024 blocks). Persistent query files close on
the storage owner under its power domain before storage control, activation
and shutdown. Unrelated storage control requeues the current query; map changes
invalidate its generation. R07 also filters physical round-panel corners before
candidate retention, including centered non-fullscreen crops.

Additional diagnostic evidence on the preceding source snapshot:

- 175 production compile passed; actual padded bin 2,981,840 bytes, remaining
  163,888 bytes in the unchanged 3,145,728-byte slot. Dirty build is not final
  clean-head reserve attestation and is not upload eligible.
- Full unsigned iPhone Debug build passed with Xcode 26.6. Repository container
  validation passed for iPhone, Watch, complication and Live Activity.
- Swift helpers passed with both installed toolchains after test-expression
  fixes; first Xcode 26.6 run took 930 seconds. Source hash drift from SDK
  generation means final stable-source verification still must be repeated.
- The real target-5 extractor CLI halo regression passed: encoded count and
  POI_STATS both equal one, excluding the source-halo cafe.
- Development runner, CI selection and conditional default-mask tests passed.

Added nonshipping `WAVESHARE_AMOLED_{175,206}_POI_LIFECYCLE_QUALIFICATION`
profiles. They inherit the production-behavior lifecycle candidate and enable
only the existing POI runtime flag. Existing dual-OTA partitions, 65,536-byte
reserve, production trust and no-debug-service checks remain unchanged.
Shipping/ordinary profiles remain POI-disabled. Hardware-scoped firmware CI now
also builds this candidate; only 175 is authorized for this run. No 206 build,
factory packaging, flash or production enablement is authorized by this change.

The first patch is implemented; final verification is pending. A written fix
alone does not close a finding. Exact published-head CI/build/size results will
be recorded here.

## Stable-source review batch, 2026-10-19

- All 40 firmware fast checks passed with `sourceUnchanged=true` (report
  `c1c5561a-3b42-403d-a9d6-f5cfdb9f48ce`). These include the banner/circular-crop
  crowding regressions, defaults/persistence, resumable query, layout, transfer,
  signed-stream faults, shutdown and size tests.
- Swift helpers passed with `sourceUnchanged=true` (report
  `7159ab02-4d44-443f-8d37-182cb7e05c84`), including target-5 compatibility,
  contour-preserving requests and actual terrain-screen controller validation.
- Backend 978 tests passed on a full rerun (report
  `f0f78225-3f0d-4b4d-8c03-7cc76a5fd30a`). The first heavily loaded run hit a
  child-PID creation/cancellation race in the unchanged pipeline progress test;
  its isolated 34-test group and full rerun passed. No pipeline change was made.
- Deployment and all 180 OSM tests passed, including real GDAL conversion and
  actual extractor CLI/statistics comparison. Development/CI routing passed
  (report `7dd2c34f-791f-4c0c-99cc-39cde3e09d43`). These reports are local
  uncommitted-source evidence, not published-head attestations.
- Enabled 175 remote-debug compiled. Both unsigned iPhone Debug and Release
  builds and their Watch/container checks passed on the integrated source.
- The nonshipping enabled 175 POI/lifecycle image compiled to 3,041,408 bytes:
  104,320 bytes remain in the unchanged 3,145,728-byte slot, 38,784 beyond the
  65,536-byte reserve. Dirty provenance was correctly not upload eligible.

Iteration 3 follow-up: sustained queued frames could starve the cursor because
the query slice ran only after draining the render queue. The worker now runs
one bounded slice after each frame and its shutdown/storage-control fences,
with a guarded idle fallback. All 17 status/handoff tests pass after this fix.
R10 and R18 remain active until the final enabled clean-source build verifies
the current worker and reserve. No other active P0/P1/P2 finding remains in the
source review; hardware and rollout qualification are still separate gates.

The reserved-banner baseline produced zero visible placements instead of one;
the regression checks over 256 hidden high-priority candidates plus the visible
shop and verifies rejection diagnostics before capacity selection.

## Re-review fixes for `5ba01364`, 2026-10-19

Claude implemented the six P1/P2 findings from the read-only re-review of
`5ba01364` (main `2bedd1fa`) in this worktree without commits or index/ref
writes. Codex owns integration, publication and final verification. "Fixed,
host-tested" means implemented with targeted local tests passing on
uncommitted source; it is not a clean-source or published-head attestation.

- **R19 (P1).** `.withMapPois(device support)` forced target 5 before the
  capability check, so POI-capable boards failed against the v1/v2 services.
  `OfflineMapPoiRequestPolicy` now decides before submission from the
  installation's validated capabilities. Target 5 needs device support and an
  offered format-5 profile, including `contours` when the request keeps them.
  Otherwise the original target-3/4 request is sent. Invalid capability
  payloads throw `invalidResponse`; HTTP 404 means no target 5. The POI
  section's **Download Active Map Again** (`purpose: .pointsOfInterest`) and
  any regeneration of an active target-5 map require target 5 and fail closed
  with the reason. Label regeneration of other maps stays opportunistic.
- **R11.** Codex's `previewBounds`/E7 regeneration edits are retained. The
  contract test also pins requirement selection, negotiation before
  `createJob` in both submission paths, and separate POI/label actions.
- **R20 (P1).** In legacy/shadow mode the selection mask keeps whole crossing
  features and the request grid is rectangular. Polygon/corridor target-5
  blocks therefore escaped signed coverage. The real-CLI triangle-plus-road
  reproduction emits block (2, 2), outside coverage. `nearby_output_blocks()`
  wraps `selection_output_blocks` (1,024 blocks) and is now the one target-5
  output set for the extractor (`--output-blocks`), subset reuse, combined
  contour composition and the manifest. Legacy/shadow processing bounds now
  also include coverage blocks beyond the request rectangle. A scratch probe
  found about 1% of random corridors at 40-62 degrees latitude whose physical
  buffer reaches one block column past the centre-latitude bbox expansion;
  those would otherwise sign coverage without extracted data. Selection masks,
  calibration (cells plus halo around the final blocks) and closure are
  unchanged. Selected and chunked plans already equal the coverage; the
  extractor now fails closed if a plan block falls outside it.
- **R22 (P2).** Only the manifest enforced the 1,024-block cap. `create_job`
  now rejects larger target-5 coverage with `NearbyCoverageLimitError`
  (HTTP 400) before persistence. `build()` raises a typed
  `building_scope_exceeded` before extraction for persisted jobs in every
  scope mode.
- **R10.** The final completeness check is now `CompletenessScan`: at most 64
  window blocks per cursor step, cancellable between steps, results unpublished
  until it finishes. It matches the single-pass check for every step budget.
  Coverage membership is tested before the trigonometric bound. On-device
  timing is not measured.
- **R21 (P2).** On POI-disabled firmware a stored document with Nearby decoded
  as unsupported, so boot rolled back or rebuilt migrated defaults. A
  CRC-checked stored decode now removes Nearby screens only when the runtime
  lacks them, keeping other screens' order, IDs and settings. A removed default
  moves to the first enabled screen. If none is enabled, the enabled default
  Nearby screen becomes an enabled Map screen with its ID and map settings.
  Normalization migrates through the other slot at the same revision. Wire
  uploads still return `Unsupported`, invalid originals are not repaired, and
  World Radio is unchanged.

Local verification on uncommitted source (Python modules with the framework
Python 3.11, which has the backend dependencies):

- iOS: the navigation-5 Swift shard compiled with `-D HOST_TESTING` and passed,
  including the new target matrix and the E7 regeneration tests. All 31
  `ios-app/scripts/tests` passed.
- Backend: new `tests/test_nearby_output_scope.py` passed 10/10. It covers the
  1,024/1,056-block admission boundary, selected-block versus rectangle
  admission, the build guard in legacy/shadow/selected/chunked mode,
  bbox/triangle/high-latitude corridor coverage, selected and chunked plan
  equality, the extractor argument and contour composition. Related modules
  passed: manifest, reuse, building scope, POI index, pipeline artifacts,
  sources/jobs, topography artifacts/geometry (124 run, 16 rasterio skips), map
  buildings and pipeline progress (87, 2 skips), catalog, generation profiles
  and building orchestration (33), and API (55). The full suite was not rerun.
- OSM: `test_poi_cli` passed 2/2, including the triangle/road reproduction and
  invalid `--output-blocks` inputs. The POI, label, target-3 and selected-area
  modules passed 20/21. `test_ogr_untagged_relation_outline_reaches_strict_target_three`
  aborts on the known host GDAL x265 dylib; it was not rerun in the container.
- Firmware host: Nearby query (oracle equivalence, bounded high-latitude scan,
  cursor publication and cancellation), map transfer with POI runtime 0 and 1,
  screen-configuration protocol (diagnostics 0/1, POI runtime 1), the store in
  default/legacy/downgrade/nearby modes with POI runtime 0 and 1, screen
  policy, main-screen registry (default, diagnostics, POI), device screen
  protocol, Nearby layout and map profile (POI). The new
  `test_screen_configuration_store nearby` run is registered in the
  screen-configuration check; development-check tests passed 22/22.

Remaining gates:

- No firmware build ran. The enabled clean-source 175 build and size/reserve
  attestation remain with Codex; no 206 build is authorized.
- No Xcode app-target build ran, so default MainActor isolation of the new
  Swift policy types is not verified here.
- Physical Nearby timing, downgrade boot on hardware and device/iPhone gates
  remain outstanding.
- Development compose still uses generation policy v2. POI-capable boards now
  receive target-3/4 maps until the service offers format 5 to their
  installation; no policy or rollout change was made.
- Previously downloaded maps and explicitly selected historical jobs are not
  rewritten. New-build cache reuse is fenced by the immutable producer
  identities; see R23 below.
- Admission computes coverage synchronously in the API. Its cost matches the
  worker planner and is bounded by the early exit at 1,025 blocks.

## Codex integration review, iteration 5

Reviewed the complete Claude batch against `5ba013642c7ae608291698bd858414af97d49f79`
and main/merge-base `2bedd1fa061419ad53e830c57bcbad2ff5d9c185`.
GitHub still has no review threads or reviews. The pre-integration tracked
patch hash was `5c046c831080a66629b7a2bf1bfd5098927be777b857ad3e372a1f03172f482f`.
The new iOS contract and backend coverage tests were included, while the four
build-owned untracked ESP32 SDK/bootstrap files remain excluded.

- Full map/deployment/OSM verification passed with `sourceUnchanged=true`,
  report `b89c2c82-5df0-4743-adae-9e3380cc7c3e`: backend 988 tests (four
  platform/prerequisite skips), deployment 58, extractor 181. Real OGR tests
  use the existing isolated GDAL 3.10.3 OrbStack container; no host library,
  deployment or policy was changed.
- Registered `navigation-5` compiled with Xcode 26.6 and executed successfully:
  `NavigationProtocolTests passed`. All 31 iOS script tests passed, including
  normalized E7 bounds and pre-submission/CTA wiring. Development and CI
  routing checks passed, report `21fa9ec3-baaa-4628-aa91-3018cf13d8c4`.
- The full firmware host run passed 39 of 40 checks with stable source,
  report `4a5ca38a-184a-49fd-8fce-e479531ab8df`. R17 recurred because the
  changed screen protocol invalidated the generated Ride Stats preview's
  source hashes. Regenerated it using the digest-verified pinned LVGL 9.2.2
  source. Atlas bytes and every JSON value outside `sourceHashes` are
  unchanged. The manifest check then passed with stable source, report
  `75ce624b-7521-4d20-9588-3ed3de77e815`; the pinned renderer's `--check`
  also reports up to date. All 40 host checks have passed across the full
  run and this targeted repair, rather than claiming the first run passed.
- R23 is invalidated: both exact and subset compatibility keys already bind
  the worker build SHA and image digest (`reuse.py`). Job candidate selection
  requires those keys (`jobs.py`). A target-5 triangle probe independently
  changed each producer identity and verified that both keys changed; equal
  identities remained deterministic. Promotion of a corrected immutable
  worker cannot reuse the preceding worker's generation cache. No cache purge,
  schema bump or production mutation is needed.

R10 and R18 retain their final clean enabled-175 build/reserve gate. App-target
MainActor isolation, final clean published-head checks and CI are not inferred
from portable Swift or dirty-source host passes. The earlier local firmware
build was canceled for resource coordination, not left paused; no device was
accessed and no artifacts were deleted. Full app/firmware verification will
run in CI, with 175 only and the existing 3 MiB/65,536-byte constraints.

Iteration 6: a fresh confirming review of the resulting implementation,
regression tests, generated products, packaging and capability/security fences
found no additional code defect within P0/P1/P2. R10/R18 are still active
verification gates, not claimed complete by that review. Final exact remote-head
verification and bounded CI observation follow publication. Ledger: 20
fixed+verified, two active, one invalidated, zero user-deferred.

## CI portability repair, iterations 7-8

The first `de81302207bfd81b7cf37ffdfa15d4446d4a9ee8` CI snapshot exposed R24
in both automatic and manual host checks. The failing step is
`Nearby POI query host tests`, job `117897240926` of run `39202140112`:
GCC rejects `unique_ptr<FILE, decltype(&fclose)>` because glibc annotates the
function type (`-Werror=ignored-attributes`). The expanded query test now
includes this storage helper, so the macOS Clang pass did not cover that
Linux compile failure. It is related, not waived as an environment failure.

Reproduced the exact error on the clean `de813022` checkout with Ubuntu 24.04,
GCC 13 and glibc 2.39 in an isolated OrbStack container. A stateless named
`FileCloser` now owns the same `fclose` operation without a function-pointer
template argument. No warning suppression or compiler flags changed. The
same strict Linux compile and Nearby executable pass after the repair.
macOS binary-map, Nearby query, feature-gate and transfer checks also passed
with stable source, report `5aee69a5-d76a-405a-9ea5-571615e663e9`.

Clean `de813022` verification also passed the Swift navigation executable,
31 iOS script tests, development/CI routing and backend/deployment tests.
The temporary GDAL wrapper initially escaped the clean checkout's `/private/tmp`
prefix into literal backslashes. Confirmed the fixture exists in the container,
fixed only that task-owned path mapping, and reran all 181 extractor tests:
passed, report `30bce377-a81c-46cf-a5e8-5e18a4e6254e`. No repository/GDAL
policy change or failing test was skipped.

A fresh review of the RAII repair and its storage/cancellation callers found
no additional code defect within P0/P1/P2. Publish the verified repair, then
revalidate its exact remote head; earlier CI results do not attest that head.
Ledger: 21 fixed+verified, two active (R10/R18 build/reserve), one invalidated,
zero user-deferred. No device, deployment, reserve or production gate changed.

## Whole-block completeness correction, iteration 10

A final contract review found R25 in the R20 boundary fix. The signed target-5
coverage names complete selected blocks, but legacy/shadow extraction still
filtered POIs and features to the exact polygon/corridor edge. Reproduced with
a cafe at projected (8,000, 8,000), outside the triangle but inside signed
block (1, 1): expected two POIs, emitted/reported only one. The unselected
corner block remains outside coverage.

Canonical `--output-blocks` now uses the existing complete-block selection
semantics for POI/base-vector features, matching selected/chunked mode. Other renderer
formats and unscoped CLI behavior retain their selection rules. Source closure,
calibration rules and rollout policy are not changed. Polygon holes and
corridors are represented at signed block-grid resolution; this profile does
not claim sub-block geofencing. The plan now says so explicitly.

The real extractor CLI regression passes: both the inside-polygon shop and
the cafe in signed block (1, 1) are retained, while a toilet in unselected
block (2, 2) is excluded. Full map verification passed with stable source,
report `bcde9101-ab6b-4cee-89f7-922faf22c06c`: backend 988 (four skips),
deployment 58, and all 181 extractor tests. The regression also compares the
record counts encoded in the actual FMB v6 sections against POI_STATS.
The strengthened encoded-record regression and all 181 OSM tests then passed
with stable source, report `6dde4810-618d-4375-9927-6ef945a0d555`.

The clean `7ca655d6` local Debug **and** Release app builds passed with Xcode
26.6, including iPhone, Watch, complication and Live Activity validation and
exact-source symbols: report `6e20e8fb-d8f1-4d24-a8c6-90080860afde`,
`sourceUnchanged=true`. All 40 firmware host checks also passed from that
clean head (report `4a15de93-2248-400c-95ad-ff5f1d8b66e9`). These are baseline
results for the unchanged app/firmware source, not attestations of a future
commit containing R25. CI app builds failed before compilation on GitHub
dependency transport; GitHub refused a job rerun while its workflow was active.
The ten-poll CI observation ended at 2026-10-19 05:13:24 UTC with firmware
profiles and iOS tests pending. No pending or network-failed result was waived.

Iteration 11: reviewed the final coverage correction, its source/selection
callers, signed-reader contract, cache identities and regression tests. No
additional in-gate code defect was found. Exact final remote-head verification
follows publication. Ledger: 22 fixed+verified, two active (R10/R18 clean enabled
firmware/reserve), one invalidated, zero user-deferred. Earlier canary packs are
not rewritten; qualification must regenerate packs with the corrected worker.

## Earlier diagnostic batch

First verification batch (local, uncommitted source; not final attestation):

- Swift helper tests passed after splitting the two oversized test expressions.
- Backend, deployment, and all 179 extractor tests passed after installing the
  declared social test extras and using GDAL 3.10.3 in an isolated OrbStack
  container. The installed Mac GDAL aborts on a missing x265 dylib; it was not
  modified. The container has read-only repository access and task-only scratch
  storage; it is not a deployment.
- Firmware host suite: all checks except stale POI default assertions and the
  generated preview source hashes passed, including HTTP parsing, transfer,
  signed streams, Nearby layout/query, and production/opt-in screen gates.
- Preview regenerated with digest-verified exported LVGL 9.2.2. Atlas pixels
  are unchanged; only preview source metadata changed.
- Firmware compilation advanced past battery.hpp after explicit direct header
  paths, then exposed GPS's unused widgets.hpp -> storage.hpp dependency. GPS
  only uses the LVGL label it already declares; the GUI include was removed.
- Concurrent firmware bootstrap generated sdkconfig files, changing the host
  runner's working-tree hash. These preliminary passes are therefore not final
  source attestations. Final checks must run without a concurrent firmware
  bootstrap or edits. Generated SDK files are build-owned, never stage them.
- Xcode 27.1 RC returned anomalous successful compiler exits without output;
  full app validation is being repeated with installed Xcode 26.6 via the
  repository wrapper and a per-command DEVELOPER_DIR (no global switch).
