# PR #378 review fixes

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
| R10 | P2 | Nearby reads entire FMB files and runs an unbounded search on the map worker | active |
| R11 | P2 | Active-map regeneration cannot request POIs and drops existing contours | fixed+verified |
| R12 | P2 | Nearby result focus leaks disabled GPS follow into ordinary Map | fixed+verified |
| R13 | P2 | Transient search I/O/allocation failure marks POI index corrupt | fixed+verified |
| R14 | P2 | Edge arrows use clamped anchor, not bearing; pin/edge groups can overlap | fixed+verified |
| R15 | P2 | v4 policy absent from worker-image change filters | fixed+verified |
| R16 | P2 | Multipolygon emits one icon per ring instead of agreed one per OSM object | fixed+verified |
| R17 | P2 | Local verification exposed oversized Swift test expressions, a python-only registry command, and stale generated preview source hashes | fixed+verified |
| R18 | P2 | Standard production size excludes enabled Nearby; require an enabled, production-behavior 3 MiB budget candidate | active |

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
