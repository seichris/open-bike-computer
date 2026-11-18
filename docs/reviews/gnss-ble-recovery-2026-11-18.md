# GNSS bench follow-up: BLE recovery, phone totals, GNSS power — local review
record (2026-11-18)

Local branch `claude/gnss-ble-recovery-power` in the Claude worktree
`bike-computer-state-machines-11e2a7`. Not pushed, no PR, not merged: the
request for this change excluded push, PR, merge, flashing and any hardware or
phone access. This file carries the REVIEW.md ledger so another session can
resume the review.

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
  - this record.
- Code head for the checks below: `733bfa76`, plus the re-run of the two
  flagged checks at `dbacfa4f`. This record is the only later change.
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
- the iOS critical-command admission path;
- disconnected-shutdown and display policy on GNSS boards;
- what Ride Stats shows when phone data stops.

There is no BLE schema, partition, layout or backend change.

Recovery: revert the commits. A board flashed with them needs the previous
image reflashed, and an installed app needs the previous build reinstalled. No
persisted state or setting format changes, so a revert needs no migration.

## Review

Passes used: 3 of 3. The reviewer was an independent, read-only agent that did
not edit or run anything; I reviewed alongside it.

- **Pass 1** (the complete diff against `ad59ab25`, uncommitted): self-review
  plus the independent review. Found R1-1/IOS-1, R1-2, GNSS-1, TOT-1 and R1-3.
- **Pass 2** (delta `0f2098b3`, plus a check of IOS-1 at `30c94682`): clean for
  P0-P2. It confirmed all pass-1 fixes and raised two P3 notes, GNSS-2 and
  TOT-2.
- **Pass 3** (delta `733bfa76`): clean. It confirmed GNSS-2, found no caller
  that can see a timestamp more than 1 s ahead, and found the renewal ordering
  conservative. The only residual it noted is a 1-second slice every 2^32 ms,
  matching the pass-1 unsigned behaviour.

Findings ledger:

| ID | Sev | Status |
| --- | --- | --- |
| R1-1 / IOS-1 | P1 | Fixed and verified in `30c94682` before it was committed. The first critical admission capped a group at 4 frames, but the acknowledged workout group is 5 (core, extended, origin, 2 zones). It would have been refused where the old 6-frame lane admitted it, and a refused retry forces a reconnect. A group is now limited to the lane size, and queued critical frames to 2× the lane. Covered by a `NavigationProtocolTests` 5-frame case; confirmed in pass 2. |
| R1-2 | P3 | Fixed in `e12c554c`: the doc and comment now give the real retry timing (1, 2, 4, 8, 16, 32 s). |
| GNSS-1 | P1 | Fixed and verified in `0f2098b3`. The tick used the loop's `now`, which was older than the fix's capture time, so the unsigned stop check wrapped and cancelled movement in the same pass: no display hold, and stationary churn in the records. Ticks now run after the fix with signed-safe ages. Covered by `testTickBeforeCaptureKeepsMoving`; the mutant was killed. |
| TOT-1 | P2 | Fixed and verified in `0f2098b3`. A connected Watch navigating without a workout sends no GPS while stationary, so after 10 s its totals and Route Left would have been hidden. `LEASE_OK` after the packet now keeps them live. Covered by `testWatchStationaryKeepsTotalsWhileLeaseRenews`; the mutant was killed. |
| R1-3 | P3 | Fixed in `0f2098b3` (comment only): the retry placement comment now matches the code. |
| GNSS-2 | P3 | Fixed and verified in `733bfa76`. A signed age read timestamps older than 24.8 days as current, so a long-lived board might never sleep. Only up to 1 s ahead now counts as current. Covered by `testAncientMovementNeverHolds`; the mutant was killed. |
| TOT-2 | P3 | Deferred. A renewal is not tied to the lease generation, so a hypothetical client that re-claims a silently lapsed lease in the same session could keep old totals live. No current client does this: the Watch claims once per session and a lease change advances the generation. |

Active findings: none at P0-P2.

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

## Unverified behaviour and hardware retests owed

Nothing below has run on hardware. Host tests prove the policies; the firmware
builds prove compile, link and image size only.

1. **Advertising after a host reset (F1).** A NimBLE host reset has not been
   reproduced here. Restoring the identity in the sync hook and the supervisor
   are verified only by source analysis of the pinned NimBLE-Arduino 1.4.3 and
   by
   host tests.
   - Retest: flash a GNSS or plain 1.75 image from this branch and wait for, or
     force, a reset (`ble_hs_sched_reset(BLE_HS_ECONTROLLER)` from a
     diagnostics-only hook, which is not part of this change).
   - Expect `ble host_reset` `reset` followed by `synced` / `advertising`.
   - Expect the phone to reconnect within seconds to the same peripheral
     identifier, without pairing again.
   - The reason-12 trigger itself remains unknown.
2. **Short drops after a reconnect (app fix).** The host test reproduces the
   incident's sequence (ack lost, lane filled, retry). On a device:
   - With Bicino Dev from this branch, reconnect while navigating, for example
     by
     power-cycling the board.
   - Confirm no `criticalAdmissionFailed` and at most `ride_command_ack_retry`
     followed by an acknowledgement.
   - Watch for `ble ride_command_ack_resend` `queue_failed` records: they test
     the firmware lock hypothesis, which is not proven.
3. **Phone totals (F2).**
   - iPhone: navigate without a workout, turn the phone's Bluetooth off. Expect
     Distance and Elapsed `--` and Route Left gone at once. Stop navigation
     while
     disconnected, reconnect, and expect no old route totals.
   - Watch-direct navigation: wait at a light for more than 10 s; the totals and
     Route Left should stay.
   - Workout Ride Stats should be unchanged.
4. **GNSS power and display (F3).** These are product thresholds and need a
   physical phone-off ride on the GNSS 1.75 with the default 2-minute
   Disconnected Sleep.
   - While moving, the board stays on and the display stays active.
   - At a stop, the display dims and turns off after 15/45 s, and the board
     sleeps about 5 minutes after the last movement.
   - `power gnss_motion` records `moving` and `stationary`.
   - Parked at a window with a fix for 10+ minutes, disconnected: the board
     sleeps after 2 minutes and records no movement.
   - Recheck the plain 1.75 (no receiver): the 2-minute sleep is unchanged.
5. **Size and boards.** Only `WAVESHARE_AMOLED_175_GNSS` and
   `WAVESHARE_AMOLED_175_PRODUCTION` were built locally. CI builds the 2.06,
   e-paper, GNSS production and diagnostics profiles. Per-board physical gates
   stay as in AGENTS.md.

## State

**Clean:** 0 active findings at P0-P2 after review pass 3 of 3. TOT-2 (P3) is
deferred, as recorded above. The branch is local only: not pushed, no PR, not
merged.

Merging still needs a PR, the required `CI Gate` (which builds the 2.06,
e-paper, GNSS production and diagnostics profiles that were not built here),
and, per AGENTS.md, the per-board physical checks listed above or an explicit
maintainer risk acceptance. Owner: Chris.
