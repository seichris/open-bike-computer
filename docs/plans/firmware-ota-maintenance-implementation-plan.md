# Reliable firmware OTA through maintenance boot

## Status and scope

Status: **source implementation and automated host/iOS coverage complete;
locked firmware builds, CI, and physical qualification pending**.

Planning date: 2026-09-21. The branch was rebased onto freshly fetched GitHub
`origin/main`, `6e2f03b11794f877e1ef7475b3a5bd1eecea4276`. The source review began at
`fd2fcb4ca2b2516c1ae4e6755a903915744e0a50`; the intervening main change only
updated the map-platform production Compose lock. This document and its
implementation are on `plan/firmware-ota-maintenance` in an isolated worktree;
successful firmware builds and physical OTA acceptance remain separate pending
gates.

The objective is reliable future iPhone-driven OTA upgrades on both Waveshare
AMOLED boards, using the existing dual-3-MiB production partition layout.

Explicitly out of scope:

- The 3 MiB to 4 MiB partition migration, bootloader migration, and repartitioning.
- OTA rescue or app workarounds for already-installed build 95. USB is the
  accepted provisioning/recovery route for those devices.
- Replacing pinned HTTPS with plaintext, BLE-only image transfer, or a new
  cloud/device transport.
- Redesigning map transfer, adding an independent recovery partition, or requiring
  an SD card for firmware installation.

Checking that a distinct inactive OTA slot exists remains ordinary eligibility
validation; it is not a partition migration project. No firmware flash, release,
or production enablement is authorized by this planning document.

Implementation update, 2026-09-21: the branch now contains the one-shot RTC
boot request, explicit boot-diagnostics terminal state, minimal pre-display and
pre-storage maintenance route, owner-authenticated BLE prepare and re-entry
commands, OTA eligibility reporting, status revisions and resource telemetry,
named resource admission floors and inactivity deadlines, the serialized
pre-commit cancellation boundary with deterministic race tests, an
SD-independent boot checkpoint, and the durable iOS download/prepare/reconnect/
re-authenticate/reconcile flow. Host boot-policy checks and the portable Swift
navigation/BLE suite pass, as does the unsigned generic iOS Release build. No
locked firmware build, device flash, physical memory measurement, repeated OTA
cycle, CI result, or release claim is recorded here yet.

Implementation update, 2026-09-22: repeated 1.75-inch attempts reached the
authenticated maintenance reconnect but published no fresh transfer session and
uploaded zero bytes. Quieting the app's ordinary BLE traffic did not change the
result, localizing the remaining failure before image transfer without proving a
specific reset cause. The measured-history-driven split now keeps TLS/HTTP on a
PSRAM-backed worker and routes direct OTA calls plus indirect flash-capable Wi-Fi
initialization/configuration/teardown through one serialized internal-stack
owner. The owner disables Wi-Fi persistence before initialization and becomes
terminal for the current boot after a command timeout or mismatched result.

## Decision

Make a dedicated **maintenance boot mode in the existing application image** the
normal firmware update path. Reboot before starting the OTA network service,
initialize only the services needed by the updater, keep TLS/HTTP on a
PSRAM-backed worker, and use one internal-RAM owner for Wi-Fi state changes and
the complete OTA flash lifecycle.

Keep the existing owner-authenticated BLE control plane, BLE-pinned HTTPS,
session-token authorization, signed firmware manifest, image hash validation,
inactive-slot installation, and deferred boot confirmation.

Do not make the PSRAM-network-worker/internal-flash-worker split the initial
design. Introduce it only if measurements show that the minimal updater cannot
meet its resource budget with a correctly sized internal stack. Merely reducing
the current stack to 8 KiB is not the reliability architecture.

Maintenance boot reduces resident allocations and starts from a predictable
heap state. Future riding features must not silently join this boot path and
consume its resource budget. A same-image updater cannot rescue arbitrary image
corruption; ROM USB recovery remains available.

## Evidence and limits

### Reported physical evidence

The originating diagnosis reported a Waveshare AMOLED 1.75 running version
0.3.4, build 95, source `dc6ec5b964117504eaf3ff52a4c16a54be364029`:

- Firmware accepted transfer entry and emitted an initial 633-byte, five-chunk
  DSTS status before hotspot startup completed.
- The hotspot and HTTPS listener subsequently started.
- Free DMA-capable memory fell from approximately 61 KiB to approximately
  1.5 KiB, with an approximately 820-byte largest block.
- Authenticated BLE status, telemetry, and exit traffic was rejected by the
  existing 4096-byte-free / 1024-byte-largest-block crypto guard.
- The app reported that no firmware transfer session was received.

This was supplied physical evidence, not reproduced during this architecture
review. It does not establish the exact allocation breakdown, installed
partition layout, production-profile behavior, or 2.06-inch behavior.

### Source evidence at the planning baseline

- `esp32/lib/device_transfer/device_transfer_http.cpp` uses a 16 KiB internal
  worker stack for firmware/map modes; debug uses PSRAM. Entry publishes enabled
  state and starts a worker asynchronously. Network details become usable later.
- `esp32/lib/ble_navigation/ble_navigation.cpp` emits generic transfer status
  after applying entry. An initial notification can therefore describe a
  starting session rather than a usable listener.
- `esp32/lib/firmware_update/firmware_update_http.cpp` owns OTA begin, writes,
  verification, boot selection, and cleanup on the HTTP worker. Its image path
  includes a 2048-byte stack buffer.
- Commit `32fbb790c5d1220a1183751186330eac945c789c` restored the larger shared
  stack for deep map activation calls. Idle stack usage does not qualify the
  TLS, signature verification, or OTA call paths.
- Commit `83d70b36a6636b58aeb3173a825adc926793b9b1` established worker-owned OTA
  cleanup after cancellation. Preserve that ownership guarantee.
- `esp32/platformio.ini` already reserves 64 KiB for internal-only allocation
  and configures dynamic TLS record buffers. This is not a guaranteed amount
  of free DMA memory after Wi-Fi and other internal allocations occur.
- Ordinary/diagnostic profiles use one 6 MiB slot; production uses two 3 MiB
  slots. The actual table, not the version string, determines OTA eligibility.
- `esp32/src/main.cpp` has an inert crash safe mode, not a network updater. Normal
  startup confirms a pending OTA image only after its readiness checks.
- Between the supplied build-95 source and this baseline, the only `esp32/`
  change is firmware revision 95 to 96. Build 96 is not a fix for this failure.

### Inference to validate

The immediate observed failure is loss of the authenticated BLE control path
before HTTPS upload. The 16 KiB stack contributes but cannot explain the entire
reported memory loss. Staging status publication fixes readiness semantics, not
the resource shortage. A minimal maintenance boot is expected to provide more
predictable headroom; only measurements and physical qualification can establish
that it is sufficient.

ESP-IDF's normal cache-disabled flash path requires an internal caller stack.
Other tasks are suspended/coordinated during those operations. Do not assume
that an external task stack is safe merely because a particular TLS request
does not directly call `esp_ota_write`. Begin/erase, boot selection, NVS, and
indirect filesystem paths also require review. Verify the effective generated
SDK configuration rather than relying on default assumptions about PSRAM XIP.

References:

- [ESP-IDF 5.5 flash concurrency](https://docs.espressif.com/projects/esp-idf/en/v5.5/esp32s3/api-reference/peripherals/spi_flash/spi_flash_concurrency.html)
- [ESP-IDF 5.5 external RAM](https://docs.espressif.com/projects/esp-idf/en/v5.5/esp32s3/api-guides/external-ram.html)
- [ESP-IDF 5.5.1 flash stack checks](https://github.com/espressif/esp-idf/blob/v5.5.1/components/spi_flash/cache_utils.c)
- [ESP-IDF 5.5.1 OTA implementation](https://github.com/espressif/esp-idf/blob/v5.5.1/components/app_update/esp_ota_ops.c)

## Rider-visible update flow

1. The app checks eligibility and downloads/verifies the signed release before
   requesting a reboot. An active workout, map activation, or other conflicting
   durable operation blocks entry with an actionable explanation; do not silently
   stop a ride or discard work.
2. An authenticated owner request asks the device to prepare maintenance boot.
   Firmware acknowledges acceptance or a specific failure before rebooting.
3. Firmware consumes a one-shot boot request and enters the minimal updater.
   The app treats this BLE disconnect as expected and reconnects to the same
   device identity with a bounded deadline.
4. The owner authenticates again. No prior BLE session, transfer token, network
   credential, or certificate assumption substitutes for fresh session setup.
5. Firmware starts the network after resource admission and publishes a fresh
   ready status containing complete session details. The app joins and probes
   the authenticated HTTPS endpoint before uploading.
6. Firmware validates, installs, and selects the inactive image, then reboots.
7. The app reconnects and queries the resulting boot. Only matching image
   identity plus successful normal-boot acceptance completes the update.

Cancellation before commit returns to the old application through a normal
reboot. Lost app connectivity after commit produces an unknown/reconciling state,
not an assertion that installation failed or an automatic second upload.

## Firmware design and invariants

### Boot selection and one-shot request

Create a small, host-testable boot-mode policy independent of peripheral startup.
Prefer a dedicated versioned/checksummed RTC request for the immediately following
intentional software reboot. It carries only non-secret intent and correlation
metadata, bound to the requesting source identity and intended next boot. It is
not an authentication credential and cannot authorize image installation.

Consume and clear it before initialization. Reject invalid, stale, mismatched,
or unexpected-reset requests. A cold power interruption loses the request and
returns to normal startup. Do not add a sticky NVS flag that can trap the device
in maintenance mode. If implementation finds RTC retention unsuitable, review an
alternative with the same one-shot and interruption properties before proceeding.

Boot routing must run before normal renderer, storage scanning, audio, and other
nonessential initialization. Audit constructors and shared initialization helpers
as well as `setup()`: an early branch alone does not guarantee a minimal boot.

Maintenance mode is distinct from crash safe mode and normal ready state. Extend
boot diagnostics explicitly so expected maintenance reboots neither count as
unexplained early-boot crashes nor clear genuine crash history improperly.

A pending-verification image must complete normal startup qualification before
it can request another maintenance update. Maintenance readiness must never call
the normal application confirmation gate. After successful installation, the new
image must take the normal boot path, not inherit maintenance intent.

### Minimal service boundary

| Service | Maintenance policy |
| --- | --- |
| Required board/power initialization | Retain board-specific safety requirements and transfer power lock |
| Owner identity and BLE authentication | Retain existing identity and trust; no re-pairing requirement |
| Wi-Fi, TLS identity, HTTPS updater | Initialize deliberately after admission |
| Progress and cancellation | Minimal UI and bounded local control; measure display/DMA cost |
| Map renderer and activation | Do not start; reject map-transfer requests |
| Audio and nonessential sensors | Do not start |
| Riding telemetry and navigation | Suppress/reject through explicit maintenance policy |
| SD and persistent diagnostics | Optional; failure or absence cannot block OTA |
| Resource and boot evidence | Bounded counters/status available without SD |

Audit shared BLE initialization for hidden dependencies on the normal UI,
renderer, recorder, and sensor tasks. Authentication, status, exit, disconnect,
and required security maintenance must remain functional. Do not disable BLE to
save RAM: the authenticated connection remains part of transfer authorization.

### Transfer state and readiness

Represent preparation, awaiting authentication, network starting, ready,
receiving, verifying, committing, rebooting, cancelling, and failed states
explicitly. Publish enabled/starting separately from usable readiness.

- Keep session generation for authorization; use a monotonic status revision
  within that session for state updates.
- Queue a ready notification after listener startup and resource checks, without
  depending exclusively on app polling.
- Chunked statuses must be coherent snapshots. A partially delivered starting
  snapshot cannot indefinitely block a newer ready/error snapshot; supersession
  must not mix chunks from different revisions.
- Prioritize authenticated status and cancellation over optional notifications.
- Enforce both bounded inactivity and an overall maintenance deadline. Status
  polling, unauthenticated clients, and repeated retries cannot prolong it forever.
- Failure unwinds the listener, clients, Wi-Fi, worker resources, and power lock.
  Recover enough memory to report a retained authenticated error when possible.
  Local cancel and timeout must not depend on accepting another encrypted frame.
- All exits are idempotent and have a defined terminal state.

Update `docs/ble-protocol.md`, firmware and iOS framing, capabilities, and host/
Swift tests together. Negotiate the maintenance capability explicitly; an older
client's firmware-enter command must not silently trigger a reboot it cannot
handle. Unsupported clients receive an actionable app-update requirement.

### Single internal operation owner and commit boundary

Use the PSRAM-backed worker for TLS/HTTP protocol work and one internal-stack
owner for every operation that can disable the flash cache directly or
indirectly: Wi-Fi initialization/configuration/teardown and `esp_ota_begin`,
writes, end/validation, boot selection, and abort. Disable Arduino Wi-Fi
persistence before the first station or hotspot mode transition so credentials
and AP configuration use RAM-backed driver storage. A BLE callback or UI task
may revoke admission and interrupt network waiting, but may not close the OTA
handle concurrently. Shutdown joins/acknowledges owner completion before reusing
any state or buffer.

An issued owner command either returns its matching result or makes the owner
terminal for the remainder of that boot. A timeout must not release a shared
staging buffer for reuse while the worker may still consume it, and a delayed
result must never satisfy a later caller. Command correlation is defense in
depth, not permission to continue after an indeterminate flash operation.

Define one serialized commit boundary. Cancellation accepted before that boundary
prevents boot selection. After commit starts, cancellation is too late; report
committing/rebooting and reconcile the result after boot. An authorization check
followed by an unfenced boot-selection call is not enough to define this race.

Preserve device-side signed-manifest, target, size, hash, and image validation.
Do not rely solely on app verification. Never overwrite the running slot. An
interrupted partial upload is discarded; initial implementation restarts the
whole upload rather than adding persistent resume machinery.

Keep application rollback enabled and confirmation after normal readiness.
Expose a compact owner-authenticated boot checkpoint with target, profile, full
source SHA, version/build, boot identity, normal-ready state, and OTA state.
This must work without Wi-Fi or SD. An image merely booting or reporting its
version is insufficient for acceptance; byte equality remains a separate digest/
readback claim.

### Resource budget

Instrument free, minimum-free, and largest-block values for internal 8-bit and
DMA capabilities, PSRAM usage, per-task stack high-water marks, allocation
failures, and crypto-headroom rejections. Report units explicitly; do not inherit
misleading stack metric labels. Never record owner secrets, TLS private keys,
session tokens, or hotspot passwords.

The iPhone must retain the non-secret DSTS resource snapshot, maintenance
correlation, boot/source identity, transfer-worker stack margin, and internal-
owner stack margin in its debug log. Publishing a field that the client discards
does not create usable hardware evidence.

Measure at boot baseline, worker creation, AP startup, phone association, TLS
setup/handshake, manifest verification, erase, sustained upload, finalize,
cancellation, and teardown. Include success, timeout, malformed-request, and
repeated-session paths on both production targets.

Choose the worker stack from measured worst-case usage plus a documented margin.
Do not assert that 8 KiB or an idle watermark is sufficient. Move large buffers
only after verifying their capability and lifetime requirements.

Set named per-phase admission thresholds and an overall budget after measurement.
The BLE guard's 4096/1024-byte thresholds are rejection floors, not a healthy
operating margin. Account for future association/TLS allocations, concurrent
authenticated control traffic, fragmentation, and teardown. A preflight snapshot
alone is insufficient: enforce bounded allocation policies and retain an
emergency cleanup/control allowance that optional work cannot consume.

Preserve the existing map stack budget and allocation behavior. Mode-specific
worker sizing must not accidentally shrink map activation. Audit task destruction
and error reporting for low-memory allocations as well as successful startup.

## iPhone implementation

Extend `FirmwareUpdateManager.swift` and `DeviceTransferManager.swift` with an
explicit maintenance transaction spanning two expected device reboots.

- Persist non-secret update intent: device identity, requested release identity,
  transaction correlation, and stage. Do not persist an authenticated session.
- Confirm the local image remains present and verified before requesting reboot.
- Separate request acknowledgement, expected disconnect, reconnect/authentication,
  session readiness, upload, and post-install verification deadlines.
- Refresh all transfer credentials and generation after reconnect. Never use a
  cached base URL/token as evidence of a new ready session.
- Suppress optional navigation/telemetry producers during maintenance while
  preserving authentication, status, cancellation, and required connection upkeep.
- Recover after app backgrounding, termination, or Wi-Fi interruption by querying
  authoritative device state. Do not replay reboot or finalize blindly.
- Show normal rebooting, cancelled, rolled back, failed, and unresolved outcomes
  distinctly. Timeout after finalize remains unresolved until boot reconciliation.
- Stop offering OTA when the actual firmware reports no distinct inactive slot.

Legacy firmware rescue is outside this work. Existing legacy behavior may remain
for compatibility, but it is not the success criterion for the maintenance path.

## Implementation phases

### Phase 1: contracts and measurement

- Define boot-mode policy, transfer states, cancellation/commit linearization,
  protocol capability, status revision, boot checkpoint, and compatibility rules.
- Add bounded resource instrumentation and a dependency inventory of normal versus
  maintenance startup. Record exact current SDK configuration and artifacts.
- Add host tests for one-shot intent, reset classification, eligibility, and
  state transitions. Add Swift tests for the reboot/reconnect transaction.

Exit: contracts are reviewable and tested; no claim of sufficient physical memory.

### Phase 2: maintenance firmware

- Split startup orchestration into normal and minimal maintenance paths while
  preserving board initialization requirements and existing crash recovery.
- Implement fresh owner authentication, deadlines/local cancel, mode admission,
  explicit ready/error publication, and single-owner OTA lifecycle.
- Implement the SD-independent authenticated boot checkpoint and normal-boot-only
  confirmation. Add deterministic barriers around OTA calls in host tests to
  exercise cancellation and commit races.
- Introduce firmware-specific stack sizing without changing map-mode sizing.

Exit: host checks and both-board builds pass; functionality remains gated pending
physical qualification. Stay within the existing production image-size reserve.

### Phase 3: app integration

- Implement capability negotiation, durable non-secret intent, both reboot
  boundaries, fresh transfer sessions, and authoritative outcome reconciliation.
- Update user-facing progress/errors and protocol documentation in the same change.
- Validate compatibility and run the portable navigation/BLE Swift tests plus the
  relevant iOS build through the repository wrapper.

Exit: app/firmware protocol tests pass, including stale and partially delivered
statuses, app restart, lost acknowledgement, and lost finalize response.

### Phase 4: physical resource qualification

- Confirm the connected board before the first build/device-debug action and
  obtain exact-artifact authorization immediately before each flash write.
- Bootstrap the candidate through USB on a dedicated dual-slot test device.
- Measure each phase using exact production bytes, including no-SD operation.
- Record the chosen stack, budget, thresholds, margins, and worst observed values.
- Require at least ten consecutive complete OTA cycles on each board, alternating
  slots with valid signed test releases, plus the failure matrix below. These
  cycles are a minimum regression gate, not a statistical reliability claim.

If the minimal updater fails its budget, first identify actual consumers. Only
then consider splitting TLS into a PSRAM worker and flash into an internal owner.
Such a change requires a new call-path audit, bounded internal staging, full
begin/write/end/abort/commit serialization, buffer lifetime/backpressure tests,
and qualification of the net internal-memory saving. Do not enable PSRAM XIP or
flash auto-suspend merely to bypass an unsafe stack arrangement.

### Phase 5: release enablement

- Rebase/integrate current main and validate the exact final source/artifacts.
- Run normal required CI; dispatch and await explicit 2.06 firmware CI when that
  validation is authorized. Automatic 1.75 CI is not 2.06 build evidence.
- Retain visible per-target hardware gates. Production enablement/distribution
  requires their completion; any permitted pre-qualification merge follows the
  repository's explicit exclusion or recorded maintainer-risk-acceptance rule.
- Update `docs/firmware-ota-hardware-validation.md` and release/support guidance.
- Verify an upgrade to the candidate and another upgrade from it, including
  rollback and subsequent successful retry. USB provisioning alone is not proof.

## Required failure and acceptance matrix

| Scenario | Required result |
| --- | --- |
| Missing/identical inactive slot or oversized image | Reject before maintenance network startup or flash mutation |
| Active ride or map activation | Explain conflict; no silent loss of work |
| Lost maintenance acknowledgement / app restart | Query device state; no reboot loop |
| Cold power loss before maintenance boot | One-shot request cannot trap device; old image remains usable |
| Maintenance crash or timeout | Bounded escape to normal boot or existing crash recovery; never false normal-ready |
| Failed authentication / stale session | No network authorization or image admission |
| Starting/ready chunks delayed, duplicated, reordered | Coherent revision; stale status cannot authorize upload |
| Low memory at startup, association, or TLS | Safe failure and cleanup; control recovery without reset loop |
| BLE disconnect during erase/write | Owner serializes cancellation; no concurrent abort or use after close |
| Cancellation racing commit | Defined before/after boundary; exactly one terminal outcome |
| Bad signature, wrong target, bad hash, invalid image | No boot selection; running image preserved |
| Upload stalls or client disappears | Bounded timeout; no permanent maintenance session |
| Power loss during erase/write/verification | Old application remains bootable; retry starts cleanly |
| Power loss around boot selection / first boot | Valid old/new selection and expected rollback; no partial image accepted |
| New application fails readiness | No premature confirmation; previous usable image selected |
| Finalize succeeds but response/reconnect is lost | App reports unresolved until authenticated boot reconciliation |
| SD absent, unreadable, or full | OTA and boot acceptance remain available |
| Repeated entry/cancel/update cycles | No accumulating allocation loss or shrinking largest-block trend |
| Return to normal operation | Pairing retained; maps, display, audio, navigation, and riding behavior still work |
| Subsequent OTA from newly installed image | Same maintenance contract succeeds again |

Physical records must identify board, stable serial, profile, source SHA, artifact
and flash-plan identity, installed partition layout, iPhone app identity, test
scenario, resource extrema, running boot checkpoint, and outcome. Keep source,
host-test, CI, upload, running-image, rollback, and physical observations separate.
Diagnostic firmware measurements can guide implementation but do not qualify
replacement production bytes.

## Definition of done

- Maintenance boot is the capability-negotiated production OTA path on both boards.
- OTA succeeds without SD and without initializing normal riding services.
- The authenticated control path remains usable with documented memory/stack
  margins through the entire update and failure lifecycle.
- Firmware maintains exclusive OTA ownership and a tested cancellation/commit
  boundary; normal readiness remains the only new-image confirmation gate.
- The app handles both reboots and reconciles cancellation, rollback, failure,
  and ambiguous completion without stale credentials or blind replay.
- Exact production images pass both-board complete-update, interrupted-update,
  rollback, and subsequent-update gates on the existing partition layout.
- All physical gates and evidence are recorded; no partition migration or build-95
  rescue work has been introduced into this scope.
