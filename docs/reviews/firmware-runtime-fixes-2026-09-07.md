# Firmware runtime fixes — implementation and verification ledger

## Target and authority

- Base, initial head, and merge base: `fe73e43431ed76c39159de7624c4cd9ede509434`,
  independently freshly fetched and checked with `git ls-remote origin refs/heads/main`.
- Branch: `fix/firmware-runtime-ownership`, isolated from the dirty primary checkout.
- Profile `deep`; mode `publish` (user explicitly requested fixes and a PR);
  strategy `sequential-local`; subagents `0`; severity gate `P0/P1/P2`.
- PR #388 was OPEN at resolution. Its projected integration was reviewed in the
  [baseline report](firmware-runtime-2026-09-07.md); it is not merged into this branch.
- No device enumeration, serial access, flashing, deployment, physical testing,
  dependency upgrades, generated-contract changes, or changes to the primary checkout.

## Finding ledger

The baseline report contains the concrete failure paths and immutable locations.
This ledger retains every root cause; physical qualification is not implied by
host or source verification. The post-fix four-lens pass found no remaining source-level P0/P1/P2 defect in
this change. `fixed+verified` below means the stated source/host/build evidence,
not physical fault-injection qualification.

| ID | Severity | Implementation | Verification / current state |
| --- | --- | --- | --- |
| FWRT-001 | P1 | Coherent bounded navigation/debug snapshots; atomic connection/authentication and battery flags. | Host producer/reader stress and reset; firmware wiring review. `fixed+verified`. |
| FWRT-002 | P1 | UI revokes admission; HTTP worker alone cleans OTA state after requests unwind. | Source contract checks owner cleanup before worker retirement. `fixed+verified`. |
| FWRT-003 | P1 | Full-frame PSRAM admission is all-or-nothing; partial internal fallback removed; failure enters retained boot recovery through panic. | Exact allocation helper rejects first/rotation allocation failures for both dimensions; no partial FULL mode. `fixed+verified`. |
| FWRT-004 | P1 | Route/render/activation/label-validation allocation rejection preserves prior state and retry; RAII frees blocks/directories. | Real map-transfer allocation fault injection rejects labels and then retries; source contract for route/front. `fixed+verified`. |
| FWRT-005 | P2 | Bounded rollback command and completion mailbox execute on map/storage owner, never UI filesystem path. | Source wiring and existing render-job cancellation/activation tests. `fixed+verified`. |
| FWRT-006 | P2 | Both light-sleep child sdkconfigs explicitly preserve watchdog initialization, panic, timeout and idle-core selection. | Profile test inspects each resolved environment rather than whole INI. `fixed+verified`. |
| FWRT-007 | P2 | Power runbooks distinguish native SDMMC 20 MHz from legacy SPI 4 MHz and require effective boot evidence. | Compared with storage/default source. `fixed+verified`. |
| FWRT-008 | P2 | Handler mutexes use object-owned static semaphore storage, eliminating fallible heap creation. | Both handlers wired to static allocation and compiled on the real 1.75 target. `fixed+verified`. |
| FWRT-009 | P2 | Check all recorder resources and task creation; expose readiness independently through serial, stats, health and HTTP. | Source contract checks degraded startup and truthful status; physical allocation faults not injected. `fixed+verified`. |
| FWRT-010 | P2 | Per-client interrupt lease fences shutdown against every early close and descriptor reuse. | Deterministic concurrent interrupt/withdraw test and source wiring. `fixed+verified`. |

## Changed behavior and contract matrix

| Boundary | Conditions | Required result | Owner / evidence |
| --- | --- | --- | --- |
| Navigation publication | Concurrent BLE write, disconnect reset and UI read | Entire maneuver comes from one publication; formatting outside lock | Short critical section; threaded helper test |
| Transfer shutdown | Disable/disconnect during HTTP/TLS/OTA, including idle upload | Revoke first; finish/abort on worker; withdraw fd lease before close | HTTP worker and socket lease; cancellation source contract and barrier test |
| Map memory rejection | Route reserve, cache insertion, label block or activation allocation fails | Preserve previous route/front; reject operation; allow retry; release locks/resources | Worker catch boundaries, move publication and RAII; label fault-injection test |
| Rollback | Renderer rejects newly selected map or runtime label error | UI submits bounded command; worker does filesystem work; UI consumes completion | Map worker control lane and map-transfer mailbox |
| Display boot | 1.75/2.06, optional rotation, insufficient contiguous PSRAM | Never register partial FULL buffer; explicit restart recovery | Shared full-frame admission helper; both dimension cases |
| Configuration | Both automatic-light-sleep profiles | Same explicit watchdog policy as production defaults | Resolved profile assertions |
| Diagnostics degradation | Queue, lock, semaphore or writer task unavailable | No falsely ready recorder; UI may still become ready | Resource admission, retained fault marker, status/health fields |

## Verification record

Baseline: 448 firmware Python tests, 74 root Python tests, 73 workflow tests,
55 policy C++ executables and 9 source-linked C/C++ executables passed on main.
Build-tool unit tests use mocked artifacts; their sample provenance is not an
ESP32 compile/link result.

Implementation checks so far:

- Firmware Python discovery: 455 passed. Three initial source-shape failures
  were related to the new lease and checked task creation; updated assertions
  preserve the actual shutdown and core/priority contracts.
- Existing C++ policy executables: 55 passed. Source-linked executables: 9 passed.
- New ownership/allocation helper executable: passed, including threaded
  coherent snapshots, concurrent socket revocation/withdrawal and both display sizes.
- Map-transfer label allocation fault injection: passed; failed validation leaves
  the active pointer untouched and the same transfer succeeds on retry.
- ThreadSanitizer: new ownership helper passed with `-fsanitize=thread`.
- Root tools tests: 74 passed. Workflow tests: 73 passed. Generated ride BLE
  contract `--check`: passed. Whitespace check: passed.
- Real `python3 tools/build_firmware.py WAVESHARE_AMOLED_175`: passed
  compile/link/image verification; application flash 3,268,515 bytes, static RAM
  90,176 bytes. These are linker sizes, not runtime heap/stack headroom.
  The first real compile found a missing `<atomic>` header; it was fixed before
  the successful build. The wrapper's expected first-use toolchain bootstrap
  retry is separate from this introduced compile failure.
- The pre-commit image was deliberately marked `uploadEligible=0` because source
  changes were uncommitted. It was not uploaded. Final clean published-head
  checks and the separate 2.06 build are recorded in PR delivery evidence;
  they are not implied by this pre-commit result.

## Review passes and residual qualification

The complete pre-fix four-lens architecture pass is preserved in the baseline
report. Two post-fix confirming passes covered code/integration/security;
claims/spec/reachability; tests/verification; and policy/hygiene, sequentially
without agents. The first implementation pass was followed by corrections for
the real-build header dependency and recovery diagnostics: count discarded ready
frames as stale, label rollback work as activation in watchdog attribution, and
log the activation root before moving its string. The fresh pass rechecked those
boundaries and the full changed contract matrix. Ledger: 10 `fixed+verified`,
0 active, 0 invalidated, 0 user-deferred. Iterations including baseline: 3.
Final publication/CI terminal state and exact remote head belong in the PR
delivery record, since a document cannot name its own containing commit.

No host test proves ESP32 scheduling latency, DMA/PSRAM fragmentation margins,
flash cancellation under electrical fault, bus contention timing, brownout behavior,
power consumption, or physical light/deep-sleep recovery. Qualification must still
exercise both boards with concurrent BLE, maps, SD recovery, HTTP/OTA and audio;
inject allocation failures; cancel at begin/write/end; and capture watchdog,
heap/stack, display and power evidence. Full-screen buffering/FULL refresh remains
a requirement, not a performance shortcut removed by this change.
