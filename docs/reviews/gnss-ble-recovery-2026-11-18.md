# GNSS bench follow-up: BLE recovery, phone totals, GNSS power — review record
(2026-11-18)

Branch `claude/gnss-ble-recovery-power` in the Claude worktree
`bike-computer-state-machines-11e2a7`. The first round (passes 1-3) stayed
local: its request excluded push, PR, merge, flashing and any hardware or
phone access. Later on 2026-11-18 Chris directed a focused follow-up on the two
findings of Codex's handoff review and authorized the push, a draft PR,
physical retests with an exact flash approval per image and board, and a normal
merge once CI and the hardware checks pass. This file carries the REVIEW.md
ledger so another session can resume the review.

## Source

- Base: `origin/main` `ad59ab25` (fetched 2026-11-18 over HTTPS; no newer main).
- Commits (oldest first):
  - `30c94682` app: admit critical ride-command retries without competing for
    the priority lane;
  - `2452a64c` firmware: count standalone GNSS movement in disconnected sleep
    and
    display policy (F3);
  - `0fa3294a` firmware: give phone-fed ride totals their own freshness (F2);
  - `e12c554c` firmware: recover BLE advertising after a NimBLE host reset (F1),
    plus the ride acknowledgement resend;
  - `0f2098b3` review pass 1 fixes (GNSS-1, TOT-1, retry comment);
  - `733bfa76` review pass 2 note fix (GNSS-2);
  - `dbacfa4f` test pin updates the check runner flagged (concurrency stub
    signature, regenerated Ride Stats preview hash). This is not product code
    and was not separately reviewed; the checks that flagged it now pass;
  - `1cfcd1a8` the first version of this record.
- Follow-up commits (user-directed, see pass 4):
  - `8f285af0` app: ordinary priority capacity of its own, and per-command
    critical holds so a sent command can always retry once (QUEUE-RESERVE);
  - `95bbc7a4` firmware: fence deferred ride acknowledgements by session and
    lease under the ownership lock (ACK-SESSION-FENCE);
  - `070adb8c` test: the renderer delivery model test admits its command
    group through the critical path (the check runner flagged it);
  - this update of the record.
- Code head for the first-round checks: `733bfa76`, plus the re-run of the two
  flagged checks at `dbacfa4f`. The follow-up checks are listed separately
  below.
- Evidence scope: GNSS 1.75 `B8:1F:3F:CF:9C:D0`, firmware `3d409248` (build 107,
  fingerprint `E35D2CD9`), Bicino Dev `d1459933` (identical to `ad59ab25` for
  the
  touched app files). Sanitized evidence in `/tmp/bicino-gnss-followup-20261118`
  (boots 799/800 only) plus whitelisted transport fields (event, class, phase,
  outcome, latency) of the normalized phone recorder
  `events-000020.jsonl:452-562`.
  No raw console or NMEA, and no hardware, serial, BLE or phone access.

## Risk

High. The change touches:
- BLE recovery after a NimBLE host reset (identity restoration, advertising
  supervision, acknowledgement resend);
- the iOS priority lane: ordinary capacity and the per-command critical
  holds that keep room for a retry;
- the ride acknowledgement resend and its session/lease fence;
- disconnected-shutdown and display policy on GNSS boards;
- what Ride Stats shows when phone data stops.

There is no BLE schema, partition, layout or backend change.

Recovery: revert the commits. A board flashed with them needs the previous
image reflashed, and an installed app needs the previous build reinstalled. No
persisted state or setting format changes, so a revert needs no migration.

## Review

Passes used: 3 of 3 for the original change, plus pass 4 on explicit user
direction. The reviewer was an independent, read-only agent that did not edit
or run anything; I reviewed alongside it.

- **Pass 1** (the complete diff against `ad59ab25`, uncommitted): self-review
  plus the independent review. Found R1-1/IOS-1, R1-2, GNSS-1, TOT-1 and R1-3.
- **Pass 2** (delta `0f2098b3`, plus a check of IOS-1 at `30c94682`): clean for
  P0-P2. It confirmed all pass-1 fixes and raised two P3 notes, GNSS-2 and
  TOT-2.
- **Pass 3** (delta `733bfa76`): clean. It confirmed GNSS-2, found no caller
  that can see a timestamp more than 1 s ahead, and found the renewal ordering
  conservative. The only residual it noted is a 1-second slice every 2^32 ms,
  matching the pass-1 unsigned behaviour.

- **Handoff review** (Codex, read-only, at `1cfcd1a8`): two active P2
  findings, QUEUE-RESERVE and ACK-SESSION-FENCE. Codex reproduced the queue
  case with a Swift harness against the committed source. That harness, adapted
  to the new API, now admits both the ordinary transfer and the retry. REVIEW.md
  allows rounds after pass 3 only on explicit user direction; Chris directed
  fixing both.
- **Pass 4** (user-directed; delta `1cfcd1a8..070adb8c`): clean for P0-P2, and
  both requirements are met. The same independent reviewer worked on
  `git archive` copies and confirmed the following:
  - the map group fails at `95bbc7a4` and passes at `070adb8c`;
  - Codex's harness admits everything and sends the retry first;
  - the fence test fails with the in-lock check disabled and with the old check
    restored before the lock.

  Class checks:
  - every ordinary admission path refuses command frames;
  - holds and queued frames stay consistent across finish, cancel and
    `removeAll`;
  - `onDrop` re-entrancy is safe;
  - only the navigation-clear and workout builders create command frames;
  - every session or lease replacement moves at least one of the fenced
    values.

  It left four P3 notes. Two (ACK-DOC, ACK-COMMENT) are fixed in `f0b2a4d0`,
  a comment- and doc-only commit that also covers this pass. ACK-FIRST-SEND is
  deferred, and ASAN-GCC waits for CI.

Findings ledger:

| ID | Sev | Status |
| --- | --- | --- |
| R1-1 / IOS-1 | P1 | Fixed and verified in `30c94682` before it was committed. The first critical admission capped a group at 4 frames, but the acknowledged workout group is 5 (core, extended, origin, 2 zones). It would have been refused where the old 6-frame lane admitted it, and a refused retry forces a reconnect. A group is now limited to the lane size, and queued critical frames to 2× the lane. Covered by a `NavigationProtocolTests` 5-frame case; confirmed in pass 2. |
| R1-2 | P3 | Fixed in `e12c554c`: the doc and comment now give the real retry timing (1, 2, 4, 8, 16, 32 s). |
| GNSS-1 | P1 | Fixed and verified in `0f2098b3`. The tick used the loop's `now`, which was older than the fix's capture time, so the unsigned stop check wrapped and cancelled movement in the same pass: no display hold, and stationary churn in the records. Ticks now run after the fix with signed-safe ages. Covered by `testTickBeforeCaptureKeepsMoving`; the mutant was killed. |
| TOT-1 | P2 | Fixed and verified in `0f2098b3`. A connected Watch navigating without a workout sends no GPS while stationary, so after 10 s its totals and Route Left would have been hidden. `LEASE_OK` after the packet now keeps them live. Covered by `testWatchStationaryKeepsTotalsWhileLeaseRenews`; the mutant was killed. |
| R1-3 | P3 | Fixed in `0f2098b3` (comment only): the retry placement comment now matches the code. |
| GNSS-2 | P3 | Fixed and verified in `733bfa76`. A signed age read timestamps older than 24.8 days as current, so a long-lived board might never sleep. Only up to 1 s ahead now counts as current. Covered by `testAncientMovementNeverHolds`; the mutant was killed. |
| QUEUE-RESERVE | P2 | Fixed and verified in `8f285af0`. Ordinary priority admission still counted critical frames against its limits, and new critical groups and the timeout retry shared one allowance. Two newer five-frame groups queued behind a sent command therefore rejected the first ordinary priority write and the retry, which ends in `criticalAdmissionFailed` and a reconnect. Ordinary priority writes now have their own count and byte capacity and refuse command frames. Each admitted critical command holds its group size until it leaves the caller's live set. New commands fit within 3× the lane; the retry reuses its hold and goes to the head of the lane. Covered by `testCriticalCommandAdmissionReserve`: Codex's scenario, ordinary and critical saturation, settled holds released, and the admission guards. |
| ACK-SESSION-FENCE | P2 | Fixed and verified in `95bbc7a4`. The deferred acknowledgement resend compared the session generation before `notifyAuthenticatedNavigation` took the ownership lock, so a link or lease replaced in between could carry the old acknowledgement into the new session. The slot now keeps the session and lease. `notifyAuthenticatedPayloadResult` checks them with `mayApply` under the lock that admits the notification, and retires a fenced acknowledgement (`phase` `fenced`). Covered by `tools/tests/test_ride_acknowledgement_fence.py`, which compiles both marked blocks verbatim with ASan/UBSan and replaces the session or lease while the lock is granted. A mutant without the fence fails. |
| ACK-DOC | P3 | Fixed in `f0b2a4d0` (docs only): `docs/diagnostics-v2.md` still named the retired `session_ended` phase. It now names `resent`, `dropped` and `fenced` and says what each means. |
| ACK-COMMENT | P3 | Fixed in `f0b2a4d0` (comment only). The comment on the stored authorization said both values are read on the host task, but route acknowledgements are emitted on the loop task. |
| ACK-FIRST-SEND | P3 | Deferred; it predates this branch. An acknowledgement's first notification is not fenced. For a route acknowledgement emitted on the loop task, the window between the lease check and the notification lock is microseconds plus at most a 100 ms lock wait, and a full reconnect and re-authentication would have to fit inside it. Passing the acknowledgement's authorization to the first send would close the class, but it changes the path every acknowledgement takes, so it was left out before the hardware tests. |
| ASAN-GCC | P3 | Open until CI. `test_ride_acknowledgement_fence` is the first host test built with ASan/UBSan. It passes with macOS clang; Linux GCC is verified only by CI. |
| TOT-2 | P3 | Deferred. A renewal is not tied to the lease generation, so a hypothetical client that re-claims a silently lapsed lease in the same session could keep old totals live. No current client does this: the Watch claims once per session and a lease change advances the generation. |

Active findings: none at P0-P2. ACK-FIRST-SEND and TOT-2 (P3) are deferred.

## Commands and results

All commands were executed locally on this Mac; none reused results. Every
working tree was dirty only by the untracked, generated `esp32/sdkconfig.*`
sidecars of the firmware builds. Receipt signing was disabled
(`bicino.localResultsKey` overridden to empty), so nothing was published.

- **Firmware builds** (`python3 tools/build_firmware.py <env>`, build only, no
  upload). All exited 0 and were attested clean at `733bfa76`
  (`uploadEligible=1`):
  - `WAVESHARE_AMOLED_175_GNSS`: app 2,838,491 B of 8 MiB, RAM 105,776 B.
  - `WAVESHARE_AMOLED_175_PRODUCTION`: app 2,592,255 B of 4 MiB (61.8 %), RAM
    100,820 B.
  - Earlier builds of the same two profiles at `e12c554c` and `0f2098b3` also
    passed.
- **Unsigned iOS app build** (`ios-app/scripts/xcodebuild-cli.sh -project
  BikeComputer/BikeComputer.xcodeproj -scheme BikeComputer -destination
  'generic/platform=iOS' -derivedDataPath <scratch> CODE_SIGNING_ALLOWED=NO
  build`, Debug) at `733bfa76`: `BUILD SUCCEEDED`.
- **iOS host tests:**
  - `bash ios-app/scripts/run-navigation-tests.sh` (all groups): passed on the
    first version of the app change.
  - `python3 tools/development/swift_compile.py navigation-5 -- -D HOST_TESTING`
    and the resulting binary: `NavigationProtocolTests passed`, after the R1-1
    rework and again after the pass-1 fixes. This covers
    `testCriticalCommandAdmissionReserve`, which reproduces the incident
    (acknowledgement lost, lane filled, retry admitted at the head, no
    reconnect), checks the 5-frame workout group and the bounds.
- **New firmware host tests** (`test_ble_advertising_recovery_policy`,
  `test_phone_ride_totals`, `test_gnss_power_policy`): passed plain, with `-O2`
  and with `-fsanitize=address,undefined`. Touched existing tests also passed
  with the sanitizers: `test_display_inactivity_policy`,
  `test_workout_telemetry_state` and `test_device_ownership` (which covers the
  shutdown tracker's four-argument callers).
- **Per-commit checks:** each commit's own new host test passes at that commit
  (`git archive` extraction).
- **Mutation checks:** the following mutants were all killed by the new tests:
  - restoring the unsigned tick wrap (GNSS-1);
  - ignoring lease renewals (TOT-1);
  - signed motion-hold age (GNSS-2).
- **Repo guards:** `tools/tests/test_board_macro_confinement.py` and
  `tools/tests/test_ldf_include_paths.py` pass.
- **Check runner:** `tools/dev-env tools/dev-check` (automatic fast selection
  against `origin/main`) at `733bfa76`: 60 checks were selected: 58 passed, 2
  failed, 0 blocked. Both failures were caused by this change and are fixed in
  `dbacfa4f`:
  - **Firmware manifest tests:** the Ride Stats preview pins the presenter's
    source hash.
  - **Runtime ownership and allocation recovery tests:**
    `test_firmware_concurrency.py` stubs `handleGpsPayload` with the old
    signature.

  Both pass when re-run at `dbacfa4f` (`tools/dev-check --check
  esp32-host-firmware-manifest-tests --check
  esp32-host-runtime-ownership-and-allocation-recovery-tests`). The preview was
  regenerated with `tools/generate_ride_stats_preview.py` from the PlatformIO
  LVGL 9.2.2 tree, whose digest matches the pinned lock; `--check` reports it up
  to date, and the atlas is byte-identical.

## Follow-up checks (pass 4)

Executed locally on this Mac unless marked otherwise; none reused results.

- **Check runner:** `tools/dev-env tools/dev-check` (automatic fast selection
  against `origin/main` `ad59ab25`) at `95bbc7a4`, with a clean tree: the
  generated `esp32/sdkconfig.*` sidecars were set aside for the run. 60 checks
  were selected: 59 passed and 1 failed. **Swift navigation: map** failed
  because the `RendererDeliveryRegressionTests` model test still admitted a
  command group through the ordinary priority path, which `8f285af0` now
  refuses. The test was moved to the critical path in `070adb8c`, and
  `bash ios-app/scripts/run-navigation-tests.sh map` then passed (every map
  test binary, including `NavigationProtocolTests`). The independent reviewer reproduced both results on
  `git archive` copies: the group fails at `95bbc7a4` and passes at `070adb8c`.
- **Queue regression:** `testCriticalCommandAdmissionReserve` in
  `NavigationProtocolTests` passed. It covers Codex's scenario, ordinary and
  critical saturation, the production five-frame group, retry order, holds
  released when a command settles, and the admission guards. Codex's own
  harness, adapted to the new API, admits both the ordinary transfer and the
  retry.
- **Fence regression:** `python3 -m unittest
  tools.tests.test_ride_acknowledgement_fence` (from `esp32/`) passed with
  ASan/UBSan. It is registered in the "Runtime ownership and allocation
  recovery tests" check, which passed in the run above. Removing the fence
  makes it fail.
- **App:** a signed Bicino Dev (Debug) build from a clean detached checkout of
  `95bbc7a4`. `** BUILD SUCCEEDED **`; `codesign --verify --deep --strict`
  passed. Bundle `LetItRide.BikeComputer.dev` 1.11 (33), team `4H5PK8686H`.
  `MapStreamBuildIdentity.json` reports `gitSha` `95bbc7a4` with no `dirty-`
  prefix. `070adb8c` changes only a test, so the app sources are identical.
- **Firmware:** `python3 tools/build_firmware.py <env>` (build only) at the
  code head `f0b2a4d0`. Both builds were attested clean (`uploadEligible=1`, core
  cache hit):
  - `WAVESHARE_AMOLED_175_GNSS`: 2,838,911 B of 8 MiB, RAM 105,776 B,
    `firmware.bin` `57732194f326c722f745af499e9d3824cf7dc228e8f2a0b1d08789c6b19c8cb4`,
    flash plan `5aa5f891f7890a019aa2be81e780a657d7ffa60667e1f0fbd27d0b56c7e185a1`.
  - `WAVESHARE_AMOLED_175_PRODUCTION`: 2,592,759 B of 4 MiB (61.8 %), RAM
    100,820 B, `firmware.bin`
    `50b7c8924a00a853a1b3a01f7a20548a44f360a6d3c336106aa30a3fa3054d58`, flash
    plan `1b027f5f75cd2d8d6bd0f0e43fa869c292f59c5fdce301fa94b66637ea3af746`.
  - Builds of both profiles at `070adb8c` also passed, with the same sizes.
- **CI:** draft PR
  [#817](https://github.com/seichris/open-bike-computer/pull/817) runs the
  fast selection. The heavy selection (every hardware profile, plus e-paper and
  GNSS) runs when the PR is marked ready, and the merge needs that run's
  `CI Gate`. Results are tracked in the PR.

## Hardware validation

All six planned checks passed on November 18–19, 2026. Both candidate images
ran build 107 from `f0b2a4d0e7501ee5e490eac909242d762bfee271`. The GNSS
image (`6AF4FB93`) used firmware SHA-256 `57732194…8cb4`. The plain 1.75
production image (`ADA131F1`) used `50b7c892…4d58`. Bicino Dev used the app
sources from the candidate, built at `95bbc7a4`.

**Test-only fault image (never merged).** Branch
`claude/gnss-ble-recovery-fault-test` holds one test-only commit on top of the
candidate's code head. It changes only `ble_navigation.cpp`, behind
`static_assert(FIRMWARE_DIAGNOSTICS)`, and is built only for
`WAVESHARE_AMOLED_175_GNSS`. Once per boot:
- it withholds the acknowledgement of the first workout command applied at
  least 15 s into an authenticated session;
- 45 s later, while a session is authenticated, the host task calls
  `ble_hs_sched_reset(BLE_HS_ECONTROLLER)`, the reason-12 reset of the bench
  incident.

It records `ble test_fault`, with `phase` `armed`, `ack_withheld` and
`host_reset_scheduled`. The candidate image replaces it as soon as those tests
are done.

| Check | Board and image | Result |
| --- | --- | --- |
| Forced BLE host reset (F1) | GNSS 1.75, fault image `7586270c` | **Pass.** After reason 12, advertising resumed. Ultra reconnected and authenticated in about 4 seconds without pairing. |
| Withheld workout acknowledgement | GNSS 1.75, same fault image and Bicino Dev | **Pass.** One retry sent the five-member command group and received the device's duplicate acknowledgement. The link stayed connected and the next command was acknowledged in 122 ms. |
| Mid-route BLE loss, Stop and reconnect (F2) | GNSS 1.75, candidate | **Pass.** The route stopped while disconnected and the clear was acknowledged after reconnect. Ride Stats showed zero totals and no Route Left. Display clearing latency during the outage was unobserved. |
| Parked sleep (F3) | GNSS 1.75, candidate, onboard fix and battery power | **Pass.** Shutdown began 120.383 s after the last BLE link dropped. The retained audit linked the BOOT press to confirmed deep sleep, GPIO0 wake and a sealed recorder. |
| Standalone GNSS ride (F3) | GNSS 1.75, candidate | **Pass across two legs.** With both companions powered off for the second leg, the board stayed on the same boot throughout the roughly 11-minute ride and kept the display active during sustained movement. In the first leg, both companions were disconnected at the stop, and the board slept about five minutes after the last moving fix. The retained audit confirmed deep sleep and BOOT wake. The phone reconnected before the sleep window elapsed after the second leg. |
| Existing timeout on the plain 1.75 | 175-b, production candidate, battery power | **Pass.** Shutdown began 120.592 s after the last BLE link dropped. The retained audit confirmed deep sleep and GPIO0 wake. The production boot checkpoint reported ready and Ultra authenticated after wake. |

The parked GNSS, standalone ride, and plain 1.75 support bundles verified both
iPhone and firmware sources with 34/34, 62/62, and 51/51 chunks delivered,
respectively. The verifier reported recording coverage limits. Raw logs are
retained locally.

The 2.06 and e-paper profiles are covered by CI builds. The original reason-12
trigger remains a separate investigation.

## State

The hardware gate passed. The branch update onto `31f05db4` preserved the PR's
runtime changes and merged the two overlapping test files without conflicts.
Physical evidence applies to the images listed above. The integrated revision
requires the ready-for-review run's `CI Gate`.

Findings after the user-directed follow-up review remain at zero active P0–P2.
ACK-FIRST-SEND and TOT-2 (P3) are deferred.
