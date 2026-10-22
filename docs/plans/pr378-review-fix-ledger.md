# PR #378 review fixes

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
