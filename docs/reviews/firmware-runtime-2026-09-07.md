# ESP32 runtime, ownership, resource, and power architecture review

This document preserves the pre-fix review of the immutable main snapshot below.
For the subsequent implementation and verification ledger, see
[Runtime fixes](firmware-runtime-fixes-2026-09-07.md).

Date: 2026-09-07. Result: **4 P1 and 6 P2 active findings; no P0 established.**
This is an architecture review of current source, not hardware qualification.

## 1. Immutable target and authorization

| Field | Value |
| --- | --- |
| Repository | `https://github.com/seichris/open-bike-computer` |
| Freshly fetched GitHub main | `fe73e43431ed76c39159de7624c4cd9ede509434` |
| Main tree | `e419b7ca631392550896dce03ed77acd43562d60` |
| Main subject | `Fix workout navigation controls and rerouting (#393)` |
| Prior review baseline | `9ef7f09fce0e0d95e349e6ef9c54da137fcff286` |
| PR #388 frozen head | `18ca6e8e2d4c0e6d12d175e5e1313345ae6942f4` |
| PR #388 tree | `deb4ffe699fd008486599f74e656a3cc8a77833f` |
| PR #388 merge base with main | `fe73e43431ed76c39159de7624c4cd9ede509434` |
| Report branch | `docs/firmware-runtime-review-2026-09-07` |
| Profile / mode | `deep` / `review-only`, with the user's explicit report-file and local-branch exception |
| Strategy / subagents | `sequential-local` / `0` |
| Severity gate / iterations | `P0/P1/P2` / one complete refreshed four-lens iteration |
| Terminal state | `review-only-complete` |

GitHub still reported [PR #388](https://github.com/seichris/open-bike-computer/pull/388)
as **OPEN**, with `mergedAt: null`, both at resolution and final recheck. The
instruction to consider it merged is therefore modeled as a **projected combined
state**, not reported as an actual merge. Its head already contains the exact
fetched main, so its immutable tree is the combined source; no synthetic merge
or modification of firmware was necessary. Findings below apply to main and
remain present in that projected tree unless explicitly stated otherwise.

Main was independently checked with `git ls-remote origin refs/heads/main`.
The report worktree was created directly from that main on the named branch.
PR #388 was inspected in a separate detached worktree. The dirty primary
checkout was not used as review input or altered. No firmware fixes, staging,
commits, pushes, PR/issue changes, CI dispatch/rerun, deployment, device
enumeration, serial access, flashing, or physical tests were performed.
The only repository content added by this run is this report, left uncommitted.

Source references below are immutable GitHub permalinks at main (`S` references)
or the projected PR head (`P` references). A source-proven race or failure branch
does not prove that a particular shipped device has encountered it.

## 2. Prioritized findings

### FWRT-001 — P1 — Maneuver presentation crosses cores without a coherent snapshot

**Scenario and proof.** An authenticated navigation instruction arrives while
the UI evaluates or renders the current maneuver. NimBLE's navigation callback
calls `parseNavigationData` directly at
[ble_navigation.cpp:5302–5316][S-nav-callback]. The parser independently writes
icon, distance, and instruction bytes at
[ble_navigation.cpp:1221–1228][S-nav-write]. The UI obtains a struct copy through
the unsynchronized `getCurrentNavigationData()` at
[ble_navigation.cpp:526–529][S-nav-read], called by
[main.cpp:848 and 896][S-ui-nav]. No common mutex, atomic publication, or owner
mailbox protects this particular state. A volatile update indication is not
publication synchronization. Related plain connection/statistics fields are
also copied across execution contexts; see
[ble_navigation.hpp:249][S-connected] and
[ble_navigation.cpp:6114–6118][S-ble-stats].

**Impact.** The native host and UI can access overlapping C++ objects
concurrently, with at least one writer. That data race is source-proven.
Mixed maneuver icon/distance/text or stale transition decisions are plausible
observable consequences, not a measured device reproduction. This concerns a
normal riding path, not only diagnostic traffic.

**Recommendation and verification.** Publish a generation-tagged immutable
maneuver snapshot to the UI owner, following the existing route/GPS mailbox
pattern. Snapshot connection/diagnostic state under its actual owner lock.
Test rapid alternating, internally distinguishable maneuvers concurrent with
UI reads and disconnect/reset; require no mixed records under a concurrency
harness/ThreadSanitizer. Existing mailbox, freshness, and protocol tests do not
exercise this production shared-state access. Do not incorrectly extend this
finding to GPS: its normal supported-board ingress is already deferred.

### FWRT-002 — P1 — OTA cancellation can abort a handle still being written

**Scenario and proof.** During a production OTA upload, BLE disconnect or a
disable request reaches `FirmwareUpdateHttpServer::setEnabled(false)`.
[firmware_update_http.cpp:269–272][S-ota-disable] calls `resetUploadState()`
before disabling the shared server. Meanwhile the HTTP worker has copied
`otaHandle_` at [507–513][S-ota-write] and calls `esp_ota_write(handle, ...)`
at line 551 outside the state lock. Reset clears ownership under the lock and
then calls `esp_ota_abort(handle)` outside it at
[689–707][S-ota-abort]. UI-side transfer cleanup reaches that disable path at
[ble_navigation.cpp:3110–3120][S-transfer-cleanup].

Current main's socket interruption does not repair OTA ownership. Revocation
[clears the generation and interrupts network I/O][S-revoke], but does not join
the worker or fence an in-progress flash operation. Checking authorization
before reading the next chunk is not atomic with writing the current chunk.
In the pinned [ESP-IDF OTA implementation][U-ota], abort removes/frees the OTA
entry while write continues to use that entry; the application must serialize
this lifecycle.

**Impact.** An ordinary disconnect/cancel can overlap write and abort.
Use-after-free/list corruption or a panic during interrupted update is an
inference from that unsynchronized SDK lifecycle; no crash was induced here.
This does **not** establish that the incomplete inactive image becomes the boot
image: final validation/boot selection are separate gates.

**Recommendation and verification.** Make one worker own begin/write/end/abort.
Send cancellation to it and acknowledge only after it has stopped using the
handle; never abort from another task. Add deterministic barriers inside an
OTA stub's write and race disable/disconnect against it. Assert exactly one
terminal close and no use after close, then separately qualify interrupted
uploads and recovery on each production target. Current tests verify control
and manifest policies, not concurrent production OTA calls.

### FWRT-003 — P1 — Full-refresh display allocation failure has an invalid fallback and no recovery

**Scenario and proof.** On either Waveshare target, a full-screen PSRAM
allocation fails during LVGL setup. The shared panel file allocates a one-tenth
screen internal buffer at
[WAVESHARE_AMOLED_175.cpp:1163–1171][S-buffer-fallback], then still registers
`LV_DISPLAY_RENDER_MODE_FULL` at [1210–1215][S-buffer-full]. The filename is
historical: this implementation serves **both** boards. LVGL 9.2.2
[requires full-height storage for FULL mode][U-lvgl]. Allocation/display-object
failure also enters explicit infinite delay loops; the 1.75 software-rotation
buffer has another such branch at [1191–1200][S-buffer-full]. The configured
LVGL assert handler is an infinite loop at
[lv_conf.h:348][S-lvgl-assert].

**Impact.** Successful allocation of the smaller fallback does not make the
FULL-mode display valid: the source reaches LVGL's failing precondition. Failed
display or rotation allocations instead leave setup permanently stuck. Normal
profiles subscribe only IDLE0 to TWDT; a UI/setup stall on core 1 can therefore
remain unrecovered. These branches are source-proven; actual fragmentation
frequency and the exact screen seen on a device were not measured.

**Recommendation and verification.** Preserve full-screen buffering and full
refresh. Reserve the required full buffers deliberately, validate the complete
set before display registration, and take an explicit diagnostic safe-mode or
controlled recovery path on failure. Do not introduce partial refresh as the
fix. Inject failure at display creation, full-buffer allocation, and rotation
allocation; assert bounded recovery and no undersized FULL registration for
both dimensions. Current buffer/layout source contracts do not inject these
allocation failures into LVGL setup.

### FWRT-004 — P1 — Resource rejection is not contained at route/render/activation task boundaries

**Scenario and proof.** A valid route or label-bearing map is handled while
PSRAM is exhausted or sufficiently fragmented. The explicit PSRAM allocator
[throws `std::bad_alloc` on allocation failure][S-allocator]. The route owner
performs uncaught vector reserve/push operations at
[route_overlay.cpp:30–51][S-route-alloc]; label rendering reserves candidate,
item, and index containers at [maps.cpp:2171–2179][S-label-alloc]. The render
task thunk has no enclosing allocation-failure handler at
[maps.cpp:4363–4368][S-map-thunk]. Map activation additionally reads each allowed
label block into a whole-file `std::vector<uint8_t>` at
[map_transfer.cpp:3120–3152][S-map-validation], with a format maximum of 2 MiB,
before decoding more structures. Its execution boundary is likewise not an
exception containment boundary.

**Impact.** Memory pressure can turn a rejectable route/frame/install into an
uncaught exception and task/process termination rather than retaining the last
usable presentation. Which allocation fails on real hardware is unmeasured;
the uncaught failure paths are explicit. The building-specific flat-footprint
fallback only protects its own scope, not these callers.

**Recommendation and verification.** Define a consistent resource-rejected
result at every external-input/task boundary. Preserve old route/map state
until construction succeeds; contain all temporary allocations, and stream
validation where whole-file residency is unnecessary. Main's recent movement
of scratch to PSRAM reduces internal pressure but is not failure containment.
Run allocator-failure sweeps across route parsing, label layout, map validation,
and task startup, checking unchanged active state, released allocations, and
continued UI service. Existing geometry/format tests run with ample host memory
and do not establish this behavior.

### FWRT-005 — P2 — Runtime map rejection performs filesystem rollback on the UI task

**Scenario and proof.** The renderer rejects an activated map, or encounters a
runtime label failure. Main calls `acknowledgeActivatedMapRoot(..., false)` at
[main.cpp:2113–2115][S-ui-rollback], which synchronously invokes
`installer_.rollbackActiveMap()` at
[map_transfer_http.cpp:679–712][S-rollback]. The alternate label-failure path
directly reads selection metadata, rolls it back, and reads it again at
[main.cpp:2145–2167][S-label-rollback]. These are real filesystem operations,
not merely commands submitted to the map worker.

**Impact.** A slow/failing SD/FAT operation blocks the owner of LVGL, touch
consumption, maneuver presentation, and housekeeping. This contradicts the
[documented worker-owned map-control boundary][S-scheduler-doc]. Exact stall
duration depends on the driver/card and remains unmeasured; source reachability
does not. The successful activation path's worker handoff does not prove the
failure path is nonblocking.

**Recommendation and verification.** Execute rollback/readback as a serialized
worker control job, then publish one completion to the UI. Add a fake slow
filesystem plus an assertion of task identity on every activation/rollback
operation. Existing activation-handoff tests check deferred executor/stack
contracts, not these failure-path filesystem calls.

### FWRT-006 — P2 — Light-sleep profiles omit the explicit watchdog contract, and tests miss it

**Scenario and proof.** Selecting either `*_LIGHT_SLEEP` profile replaces the
common `custom_sdkconfig` value. The ordinary common section explicitly sets
TWDT initialization, panic, five seconds, IDLE0 on, and IDLE1 off at
[platformio.ini:183–190][S-wdt-config]. The complete child replacements at
[381–400 and 495–515][S-light-config] omit those watchdog entries. The profile
test resolves an environment-local option before inherited values, but does
not require the missing light-sleep watchdog keys. The watchdog source test
[searches the whole INI text][S-wdt-test], so keys in the unrelated common
section satisfy it.

**Impact.** A green host contract does not establish the intended watchdog
behavior for the sleep experiment. ESP-IDF 5.5.1's
[defaults include panic off and IDLE1 monitoring on][U-wdt], unlike the explicit
normal policy. Omission and false-green assertion strength are verified;
the exact generated sdkconfig/binary result remains an **inference** until the
locked custom-core build is inspected. This is a limited but material
verification/configuration defect, not a claim that a physical sleep build
already reset or failed to reset.

**Recommendation and verification.** Compose or explicitly repeat the intended
watchdog policy for every child, and test the resolved per-environment config
plus generated sdkconfig. Intentionally remove one child watchdog key and
require a failing test. Qualify sleep/watchdog interaction separately on both
boards; do not infer it from the ordinary build.

### FWRT-007 — P2 — Power qualification documents describe the wrong active SD clock

**Scenario and proof.** Following the current power/battery validation notes
treats SD as 4 MHz; see
[firmware-power-management.md:313–314][S-power-sd] and
[firmware-battery-life-hardware-validation.md:297][S-battery-sd]. Supported Waveshare source
instead defaults `WAVESHARE_SDMMC_FREQ_KHZ` to `SDMMC_FREQ_DEFAULT` at
[storage.cpp:35–40][S-sd-default], uses native one-bit SDMMC at
[398–438][S-sd-mount], and documents its 20 MHz override/default in
[platformio.ini:285–291][S-sd-config]. The 4 MHz setting belongs to the legacy
SPI path, not the normal native backend.

**Impact.** A qualification performed against the written checklist can record
the wrong workload/control variable and attribute throughput or battery changes
to the wrong configuration. This is an operationally material stale contract,
not a request to tune SD clocks or a claim that 20 MHz is itself unsafe.

**Recommendation and verification.** Correct the native-versus-migration
backend distinction and capture the effective backend and clock in each
power/soak record. Test documentation/config consistency and require the actual
`SDIO` boot marker in later physical evidence. Existing hardware notes already
distinguish native SDMMC, but these two qualification references do not.

### FWRT-008 — P2 — Map/OTA handler mutex allocation failure silently enables unlocked state

**Scenario and proof.** A handler's `xSemaphoreCreateMutex()` fails during boot
but the shared server's own resources succeed. Both
[map_transfer_http.cpp:143–157][S-map-configure] and
[firmware_update_http.cpp:259–267][S-ota-configure] continue to register the
handler. Their lock helpers simply do nothing for a null handle:
[map_transfer_http.cpp:601–609][S-map-lock] and
[firmware_update_http.cpp:733–740][S-ota-lock].

**Impact.** The service advertises a handler whose strings, state machine, and
lifecycle flags can then be accessed concurrently without protection. Low-memory
boot is a concrete trigger; corruption/panic is the inferred manifestation.
This is distinct from FWRT-002, which remains possible with a healthy mutex
because it covers only state copies, not the OTA handle's full lifetime.

**Recommendation and verification.** Fail handler configuration closed, return
explicit readiness, and do not register/enable the endpoint if its lock is
unavailable. Inject each handler mutex failure independently while allowing the
shared server to initialize; assert an unavailable endpoint and no lockless
state access. Host HTTP policy tests currently do not replace this FreeRTOS
allocation boundary.

### FWRT-009 — P2 — Recorder startup failures do not prevent a misleading ready state

**Scenario and proof.** Persistent diagnostics queues/locks fail allocation, or
the writer task cannot be created. Allocations at
[ride_diagnostics.cpp:1211–1224][S-recorder-alloc] are unchecked as an aggregate,
and `startWriterTask()` ignores `xTaskCreatePinnedToCore`'s return value at
[1052–1062][S-recorder-task]. Producers subsequently drop records or sealing
returns `RecorderUnavailable` at [1574–1576][S-recorder-seal]. Main ignores the
ready record result and still marks boot ready at
[main.cpp:1970–1979][S-ready].

**Impact.** A low-memory boot can appear operational while the persistent
diagnostic trail needed to investigate later faults is absent. Drop counters
and retained fault capsules provide partial evidence, so this is not a claim
of total diagnostic silence. They do not establish a functioning writer or
durable ready record.

**Recommendation and verification.** Publish recorder readiness/degraded status
separately from UI readiness; validate all required resources and task creation,
retain a bounded serial/RTC startup-failure reason, and make export status
explicit. Fault-inject every queue, lock, semaphore, and task creation. Existing
queue/seal policy tests prove policies, not startup allocation behavior.

### FWRT-010 — P2 — Revocation's socket interrupt is not fenced against an earlier close

**Scenario and proof.** BLE session revocation overlaps completion/abort of an
HTTP response. The worker publishes a pointer to its stack-owned client at
[device_transfer_http.cpp:761–763][S-client-lifetime] and unpublishes it only
after `handleClient` returns, at lines 784–791. But `handleClient` itself calls
`client.stop()` at [1051 and 1081][S-client-close], and handlers can close a
failed stream before returning. `stop()` closes the owned socket then writes
plain `socket_ = -1` at [device_transfer_tls.cpp:751–765][S-tls-close]. In
parallel, revocation holds the server state mutex and reads that same plain
descriptor in [interruptSocket():691–694][S-tls-interrupt]. The close path does
not take the server lock. The comment at
[device_transfer_http.cpp:1156–1160][S-client-interrupt] protects object
destruction but incorrectly extends that protection to descriptor reuse.

**Impact.** The unsynchronized descriptor read/write and close/interrupt
ordering are source-proven. If a closed descriptor is reused between load and
`shutdown`, revocation can shut down an unrelated socket; an intermittent
transfer/network failure is the inferred consequence. Descriptor reuse timing
was not reproduced. This is a separate root cause from the OTA handle race.

**Recommendation and verification.** Give cancellation a synchronized lifetime
that ends before **every** descriptor close, not just before client object
destruction. Keep blocking TLS cleanup worker-owned; do not solve this by
holding a broad state lock through it. Add a deterministic concurrent
close/revoke test with forced descriptor reuse and a sanitizer harness. Current
source-shape tests assert publication/unpublication and `shutdown` are present,
but do not exercise their interleaving.

## 3. Persistent finding ledger and change reconciliation

| ID | Severity | State | Reconciliation against the earlier review |
| --- | --- | --- | --- |
| FWRT-001 | P1 | active | Maneuver bypass remains; deferred route/GPS/settings improvements do not cover it. |
| FWRT-002 | P1 | active | Socket interruption was added, but OTA abort/write ownership is unchanged. |
| FWRT-003 | P1 | active | Invalid fallback/halt remains; corrected scope to the shared implementation on both boards. |
| FWRT-004 | P1 | active | More scratch now uses PSRAM; uncaught allocation failures remain. |
| FWRT-005 | P2 | active | Normal activation stays deferred; UI rollback branches remain synchronous. |
| FWRT-006 | P2 | active | Child config omission and false-green test remain; actual generated core not built here. |
| FWRT-007 | P2 | active | Native SD default and stale power checklist still disagree. |
| FWRT-008 | P2 | active | Handler-specific mutex failure still enables no-op locking. |
| FWRT-009 | P2 | active | Recorder resource/task readiness still not propagated. |
| FWRT-010 | P2 | active | Additional close-versus-interrupt lifetime defect identified in current main. |

Counts: active 10; fixed+verified 0; invalidated 0; user-deferred 0. There is no
numeric finding cap. The gate includes P2; review-only authorization is why no
fixes were attempted, not a downgrade or deferral of these defects.

Material improvements since the prior baseline were reviewed as actual
architecture changes, rather than copying the old report:

- The map worker now runs core 0 at priority 1, with cooperative one-tick
  blocking at approximately 10 ms checkpoint intervals. The previous
  idle-priority description is no longer current. Bounded CPU service still
  depends on reaching checkpoints; this is not a hard wall-clock guarantee.
- Renderer scratch, settings-mailbox storage, and benchmark state were moved
  toward PSRAM; per-pass scanline workspace and cached projection coefficients
  reduce allocation churn and repeated work. Nearest-first admission stops
  exact building projection once bounded quotas are satisfied.
- Debug-only HTTP now uses a 16 KiB PSRAM stack; upload/activation modes retain
  16 KiB internal stacks. Capability-aware creation/deletion is paired.
- Authenticated debug HTTP persistence is bounded and avoids repeated TLS
  setup. Generation revocation, explicit response outcomes, and delivery-stage
  evidence improve cancellation and observability, with FWRT-010 remaining.
- Diagnostic window epochs prevent old render jobs from satisfying a new
  measurement window. In-flight callback phase evidence supplements completed
  timing records. Memory gates distinguish window minima from retained
  cross-run allocations.
- Stable-camera rendering is enabled in development profiles on both boards,
  not production. It reuses decoded-scene residency and existing surfaces;
  accepted camera state owns route/marker projection and stale/loading display.
  Neither its implementation nor green host tests prove its physical latency
  targets. See [map-stable-camera.md][S-camera-doc].
- Build tooling preserves source-clock provenance, suppresses bytecode writes
  in attested environments, and recreates the final link/map output rather
  than treating a reused final ELF as a fresh source attestation.

## 4. Execution, queues, and watchdog map

Task stack numbers below are configured ESP-IDF byte budgets, not measured
high-water values. Framework tasks are included as shared-runtime consumers;
no live RTOS task census was taken.

| Execution context | Core / priority / stack | Ownership and work | Blocking / wake / watchdog coverage |
| --- | --- | --- | --- |
| Arduino `setup` / `loopTask` | Core 1 / 1 / 16 KiB | Sole normal LVGL/UI owner; consumes mailboxes, services display/touch, workout/automation, power, transfer control and map publication | Task-notification wake bits; LVGL/deadline wait capped at 50 ms during connected navigation or 250 ms static. Synchronous display flush, I2C, exceptional map rollback and diagnostics sealing can exceed those waits. UI progress is recorded, not independently enforced by TWDT. |
| NimBLE host | Core 0 default / `configMAX_PRIORITIES - 4` / 8 KiB | GATT callbacks, authentication, ingress admission, workout reducer, connection/session revocation | Network host callbacks are task context, not ISR. Parsing, crypto, serial/diagnostics, mutex waits and notifications occur here. No application TWDT subscription; a core-0 CPU monopoly can starve subscribed IDLE0. |
| `map_render` | Core 0 / 1 / 24 KiB PSRAM | Map block cache/IO, decoded geometry, prepared scene, hidden RGB565 frame, building/label work; no normal LVGL calls | Task notification; latest pending request and one ready result under render mutex; generation cancellation. `vTaskDelay(1 tick)` at cooperative 10 ms checkpoints. Exceptional stop waits up to 2.5 s and preserves state if worker has not exited. Role/phase retained, not a progress watchdog. |
| `device_http` | Unpinned / 1 / 16 KiB | One accepted TLS client at a time; debug, map, diagnostics, OTA handlers; deferred activation after response unwind | Debug stack PSRAM, other modes internal. Socket/TLS read/write/handshake and FAT/flash work; idle accept loop sleeps 2 ms. Generation cancellation and transfer PM lock. No dedicated TWDT subscription. |
| `map_activate` | Unpinned / 1 / 16 KiB internal | Recovery/resume activation where a separate task is needed | Progress callback yields a tick. Normal upload completion reuses the already-unwound HTTP worker instead of allocating another stack. Filesystem validation/commit can be lengthy. |
| `ride_diag_writer` | Core 1 / 0 / 6 KiB | Only writer of queued persistent ride records; flush, bounded retention pruning, SD recovery | Normal queue 24 + critical queue 8; waits/yields, flush/retry cadence; can be delayed by UI/audio and can spend driver timeout time in FAT. Not TWDT-subscribed. Retained role records are forensic, not recovery enforcement. |
| `speaker` | Unpinned / 2 / 6 KiB internal | Codec/I2S lifecycle and playback exclusively in worker | Queue of four immutable playback requests, blocking receive; finite PCM/synthesis loops and driver writes; audio PM lock. Idle cleanup/retry retains failed resource state rather than blindly double-freeing it. No dedicated watchdog. |
| Wi-Fi driver, lwIP TCP/IP, event/ESP timer and BT controller support tasks | Framework-owned; effective task configuration not enumerated locally | Radio/IP protocol progress, driver event callbacks, system timing | Share internal/DMA RAM and cores with all consumers. Exact created-task inventory, effective affinities and stack minima require generated SDK config plus runtime capture; not inferred from application task creation sites. |
| FreeRTOS idle/timer infrastructure | One idle per core plus framework timer service | Reclamation, idle hooks, scheduler services | Normal explicit TWDT: initialized, fatal panic, 5 s, **IDLE0 only**. Interrupt WDT is a separate framework mechanism, not an application progress monitor. Sleep-profile caveat FWRT-006. |
| BOOT and touch GPIO interrupts | ISR on configured interrupt core | Latch state and notify UI; no bus transaction or LVGL rendering | BOOT latch uses ISR critical section; notifications use `xTaskNotifyFromISR` and conditional yield. Touch transaction/acknowledgment remains in task context. Automatic-sleep wake handling accounts for active-low level/latching. |
| LVGL input/timer/flush callbacks | UI task | Touch decoding and GUI events; synchronous QSPI write/rotation | Not separate FreeRTOS tasks. `lv_display_flush_ready` follows transfer completion or explicitly suppressed off-panel flush. |
| Optional legacy GPS/CLI tasks | GPS core 0 / 1 / 8 KiB; CLI core 1 / 1 / 20 KiB | UART parser under GPS mutex; CLI loop | Compiled out on the two reviewed normal Waveshare targets (`HAS_HARDWARE_GPS` absent, CLI disabled). They are not extra active competitors in the supported task budget. |

Primary creation/ownership sources: [main startup/loop][S-main],
[map worker lifecycle][S-map-worker], [HTTP lifecycle][S-client-lifetime],
[activation execution][S-activation], [diagnostics writer][S-recorder-task],
[speaker worker][S-speaker], [task-notification scheduler][S-ui-scheduler],
[legacy tasks][S-tasks], and [pinned NimBLE task creation][U-nimble].

### Queue, lock, and lifetime rules

| Boundary | Existing protection / ownership | Residual limitation |
| --- | --- | --- |
| BLE to UI | Latest-value route/GPS slots and bounded per-setting slots; owned payload replacement under mailbox mutex; auth generation invalidates old work. The 256-entry settings table is allocated in PSRAM before host start and fails closed if absent. | Maneuver bypass is FWRT-001. Bounded slot count is not proof of callback latency under authentication or allocator contention. |
| Workout / automation | Workout reducer mutation and snapshot copy share a critical section. Automation has an eight-entry inbound queue and fixed evidence windows, including a bounded GPS history; UI runs policy, not ISR. | Queue capacity limits retained backlog, not the runtime cost of all surrounding callback/owner work. Watch topology/cadence is still physical qualification. |
| UI to renderer | Render mutex protects request/result handoff; atomics carry cancellation/shutdown generations. UI owns visible front/live foreground; worker owns back and decoded scene. Prepared-scene lease invalidates before cache mutation. | Exceptional stop can block 2.5 s. OOM containment and UI rollback still fail as recorded above. |
| TLS server / handlers | Separate server-state and TLS-identity mutexes; generation checks; stack-owned connection worker. Handler state locks are distinct. | Locking a copied handle does not own its later use. FWRT-002/008/010 are precisely those boundaries. Some mutexes wait `portMAX_DELAY`; no formal global lock-order proof was established. |
| SD / FAT | Mount mutex serializes remount decisions; normal native peripheral separates SD from QSPI. Diagnostics has one file owner; installer/renderer own their own handles. PM Storage scopes protect active operations. | Mount serialization is not a global transaction around all filesystem clients. Directory scans, metadata changes and driver stalls remain variable-latency. Shutdown/remount with open consumers needs physical fault testing. |
| Shared I2C | Common timed mutex (50 ms acquisition/driver timeout), bounded retry helpers, per-operation PM scope; repeated-start helpers preserve sensor transaction shape. 2.06 recovery occurs inside serialized helper. | Retry count multiplies timeout and can delay UI; priority inheritance cannot shorten a held bus transaction. No new proven steady-state bus deadlock was found. |
| Audio | Queue copies request parameters; worker owns codec handles and I2S lifecycle; configuration mutex serializes PMIC button setup; playback flag atomic | Priority 2 playback can preempt priority 1 tasks until driver blocking/yield. Actual worst-case synthesis/codec timing and shutdown overlap unmeasured. |
| Diagnostics / metrics | Bounded records, nonblocking producer/queue mutation admission, atomics/critical sections for counters and retained fault capsule; bounded writer retention work | Records can drop deliberately, and writer readiness can fail silently (FWRT-009). Formatting/logging cost on callers still matters. |
| Display / remote frame capture | UI flush owner, snapshot lock/copy for remote capture, serialized HTTP output | Full-screen copy/rotation/TLS cost is real; remote-debug measurements include capture overhead and do not substitute for ordinary-profile measurements. |

The watchdog module records only UI, map-render, and diagnostics-writer roles
and their latest phases. Its `esp_task_wdt_isr_user_handler` retains a bounded
trigger for later analysis; it does not register all tasks or feed on their
behalf. Consequently a UI blocked on a semaphore, a stalled transfer, or a
starved core-1 writer can coexist with a healthy IDLE0. That blind spot is a
coverage boundary, not proof that every such wait is a deadlock.

The HTTP parser caps a line at 512 bytes, all headers at 8,192 bytes/64 lines,
and header completion at 5 s. First-request idle timeout is 1 s and persistent
request idle timeout 2 s; a connection permits at most 4,096 requests.
Persistence is opt-in for authenticated debug responses, not an authorization
to pipeline arbitrary handlers. Those limits bound retained/parser work but
do not make long image/map responses fast or provide fairness between multiple
active clients. OTA uses a 2 KiB chunk and a 10 s no-read-progress timeout;
that deadline is not a bound on a single flash/driver operation. Diagnostics
and map operations likewise have bounded admission/progress checkpoints but
not a demonstrated end-to-end hardware deadline.

## 5. Memory, display, storage, and board-specific resource budget

Both profiles target ESP32-S3 with 16 MiB flash and 8 MiB OPI PSRAM. The
review does not equate total free heap with usable DMA or largest-contiguous
allocation. Internal stacks, Wi-Fi/BT state, DMA descriptors/bounce buffers and
hardware-crypto allocations compete even when PSRAM is plentiful.

| Resource | Source architecture and budget | Assessment |
| --- | --- | --- |
| LVGL / full refresh | Full RGB565 screen: 1.75 = 466×466×2 = 434,312 bytes; 2.06 = 410×502×2 = 411,640 bytes. Both use full-screen FULL mode. 1.75 default software rotation adds another 434,312-byte PSRAM buffer; 2.06 uses native orientation. | Requirement preserved. Allocation failure path is defective, not the full-refresh design. UI flush is synchronous and consumes time proportional to a whole image. |
| Map persistent surfaces | Documented 1.75 maximum: two 658×658 RGB565 frames = 1,731,856 bytes; live 466×466 RGB565+A8 foreground = 651,468 bytes; map total 2,383,324 bytes. | Separate from LVGL buffers. Adding the default rotated display buffers gives 3,251,948 bytes before map cache, glyphs, scratch, debug capture, stacks and TLS. Static arithmetic, not measured residency. |
| 2.06 map surfaces | Rectangular viewport, 96-pixel overscan policy and dimension-derived surfaces, unlike 1.75 physical-circle adaptive coverage. | Do not reuse 1.75's square byte total or circular coverage proof. Exact allocator stride/capacity and peak overlap require this target's artifact/heap evidence. |
| Building workspaces | Total limits 96 records / 8,192 points / 220,000 projected pixels; extruded default 32 / 3,072 / 90,000. Courtyard underlay cap 180,000 pixels; reused scanline workspace and deterministic lower-cost fallback. | Bounded admission is a strength. Label, route and whole-block validation allocations remain separate OOM paths. |
| Label/cache residency | Bounded candidate collection and glyph/block validation; PSRAM vectors/maps for major workspaces; camera projection signature in placement identity. | `reserve`, hash-node growth and decode temporaries can still require a contiguous block and throw. Reuse reduces churn, not a proof of zero fragmentation. |
| Stable camera | Development-only prepared-scene metadata lease (small fixed state, no duplicate geometry cache); existing front/back/foreground allocations | Latest demanded camera coalesces, accepted camera owns all live projection, stale/loading state after bounded demanded lag. 100 ms intake and 500 ms concealment policy are not proof of ≤250 ms p95 rendering. Production path remains gated off. |
| TLS / crypto | Common SDK uses default allocator, dynamic record buffers, 16 KiB RX and 4 KiB TX, DTLS disabled; 64 KiB internal allocator reserve. | Correctly distinguishes large PSRAM-eligible buffers from internal-only crypto requirements. Reserve is shared and is not a per-handshake guarantee. Largest internal/DMA block must be measured concurrently with BLE and display/map load. |
| Runtime stacks | UI16 + NimBLE8 + map24 + writer6 + speaker6 KiB; transient HTTP16 and sometimes activation16 KiB, plus task control blocks/framework stacks | Explicit budgets are not peak measured usage. Matching `WithCaps` deletion is present; task-allocation and exception coverage gaps remain. |
| SD | Native one-bit SDMMC CLK2/CMD1/D0=3; default20 MHz. Legacy SPI migration/recovery path remains; D3/legacy-CS must not be driven in normal one-bit mode. | SDMMC avoids normal QSPI bus sharing but still needs internal/DMA memory and can block on FAT/card behavior. Recovery/probe attempts are bounded; no end-to-end fixed map-activation deadline follows. |
| Flash layout | Production: two 3 MiB OTA app slots, 9 MiB FFat, retained coredump tail. Developer/diagnostic: one 6 MiB app slot; same FFat start, development USB images | Do not judge developer image size against the production slot or claim OTA coverage from a developer build. Profile transition preserves FFat location; valid app marking follows startup ready path, not a ride soak. |
| Diagnostics | Normal24 + critical8 bounded event queue, maximum record size; retained RTC capsule and flash coredump; benchmark state in PSRAM, bounded JSON reservation | Measured free/largest/minimum values and drop/gap counters are stronger than total-heap-only reports. Allocation or writer starvation can still remove the persistent trail. |
| Audio / I2S | Lazy codec allocation, bounded queue, worker-owned DMA/codec resources, chunked PCM/synthesized frames, cleanup when queue drains | Avoids permanent idle I2S residency. Failure-state cleanup tests cover helper ownership; they do not establish maximum driver blocking or acoustic/current behavior. |

### Two distinct hardware paths

| Boundary | 1.75-inch | 2.06-inch |
| --- | --- | --- |
| Panel | 466×466 physical round viewport, CO5300 column offset6; default software90° rotation | 410×502 rectangular viewport, offset22; native rotation, follow-up one-pixel window write to commit completed frame |
| Touch | CST9217, two-contact frame/acknowledgment, reset via TCA9554 P0 | FT3168, direct resetGPIO9 and distinct interrupt/pin mapping; single-contact format |
| Power boot | AXP2101 current output-rail state must be preserved | One-way display-enable recovery allowed and verified; not the 1.75 read-only rail rule |
| I2C recovery | Proven shared transaction helpers without importing 2.06 recovery sequence | Driver-specific bus recovery/reset sequence under helper ownership |
| SD | Native shared CLK/CMD/D0; legacy-CS traceGPIO41 | Same native bus; legacy-CS traceGPIO17 |
| Qualification | Historical evidence exists for particular 1.75 images only | Separate compile, boot, touch, display, SD, power, sleep and soak evidence required |

These distinctions are represented in [hardware/README.md][S-hardware],
[display constants][S-display-constants], the shared panel implementation and
board drivers. A test of the 1.75's circular overscan, software rotation or
CST9217 parser does not qualify the rectangle, native flush commit or FT3168.

## 6. Startup, power transitions, sensors, and shutdown

Normal setup order is materially coupled: framework initialization → boot and
retained watchdog evidence → metrics/power-management startup lock and UI task
binding → board-specific I2C/PMIC/display bring-up → RTC and configured IMU
handling → SD mount/fallback and diagnostics setup → transfer handlers/map
state → LVGL/UI → speaker → BLE → waiting screen/ready record → mark running
app valid, resume pending activation, release startup PM lock. Board-probe and
boot-diagnostic-hold profiles deliberately stop earlier and are not normal
ready firmware. BLE availability is therefore downstream of display/storage
setup, explaining why FWRT-003 can make a board undiscoverable rather than just
map-less.

Power management requests 80–240 MHz DFS. Ordinary/production profiles keep
tickless automatic light sleep disabled; `*_LIGHT_SLEEP` explicitly enables
the experiment. Startup, display, map, storage, transfer, audio and I2C have
NO_LIGHT_SLEEP lock domains with scoped/persistent ownership. These locks
coordinate automatic sleep; they are not a global shutdown barrier. CPU
frequency, radio duty cycle, AMOLED content/brightness and SD/codec activity
must be measured independently before making battery claims.

The UI applies display power changes, suppresses panel writes while off, and
forces coherent refresh on wake. Display off is not CPU sleep or a proof that
every peripheral rail is off. Boot/touch wake sources are active-low; latched
input and release/rearm gates avoid treating a held level as a stream of fresh
presses. The 2.06 light-sleep touch path must be separately qualified.

RTC/PMIC/speaker/touch/IMU share I2C, but transactions use the common mutex,
timeout/retry helpers and PM scope. QMI8658 uses the maintained separate
accelerometer/gyro reads; internal automation sampling is bounded and IMU
alone is not a recording authority. The LC76G/hardware-GPS parser remains an
optional legacy capability, not a hidden task active in these Waveshare builds.
GPS for normal display/navigation comes from authenticated companion ingress.
RTC reads/time updates and PMIC interrupt monitoring are task work, not ISR
bus work. The AXP write policy restricts register mutation; no newly proven
unauthorized charging-rail write was found in the reviewed paths.

Controlled deep shutdown currently seals diagnostics, retries once after
25 ms with a 3 s seal budget, requests display off, calls `SPI.end()` and
`Wire.end()`, stops radio/controller, configures BOOT wake and enters deep sleep;
see [power.cpp:128–144][S-shutdown]. It does not explicitly join every map,
HTTP and audio worker before peripheral teardown. That is a **residual risk**,
not an additional proven data-loss finding: the actual caller's transfer/workout
guards and device timing matter. Add a future two-phase quiescence test before
claiming shutdown safety under concurrent activity. The legacy explicit
`deviceSuspend` helper should not be confused with the supported automatic
light-sleep path; its existence alone does not prove a reachable Waveshare
manual-suspend defect.

Brownout, battery removal during FAT/OTA writes, PMIC rail settling, touch wake
electrical behavior, audio peaks, DFS timing and thermal behavior were not
tested physically. Filesystem receipts, checksums and transactional markers
improve recovery but are not proof of power-fail atomicity for every card.

## 7. PR #388 projected integration assessment

The PR changes 47 files across firmware, shared/generated contracts, Watch,
iPhone, tests and documentation. It adds no firmware FreeRTOS task, ISR,
unbounded history, display buffer, or persistent recorder. Firmware changes
extend the existing locked workout reducer with fixed-size Watch-motion
sample state and extend the pure automation policy with bounded sample-span
latches. The runtime consumes a coherent workout snapshot through
[workout_telemetry_runtime.cpp][P-workout-runtime], preserving the shared-runtime
ownership boundary rather than adding another sensor thread.

The projected contract uses capability bit25/client23 after the already-merged
orientation allocation bit24/client22. Watch producer epoch/sequence and source
age prevent repeated delivery of one sample from advancing elapsed evidence.
Profile4 uses qualified Watch sample spans for pause/resume and retains
fallback/veto behavior. Production automatic control remains disabled. This
review checked scheduling, bounded state, snapshot ownership, generation/reset
integration and profile reachability, **not a second full audit of BLE protocol
semantics or HealthKit recording**.

Five focused C++ binaries, 11 replay tests, profile-config validation and the
generated-contract check passed on the exact PR tree. They support deterministic
policy integration, not real Watch callback cadence, source age across both
topologies, device queue latency, saved distance, or power. Those require the
explicit gates in [the PR's consistency document][P-autopause-doc] and the
updated implementation plans. No additional independently proven P0/P1/P2
firmware runtime finding was established specifically in PR #388. The ten
shared-runtime findings above remain relevant to it.

## 8. Behavior/contract matrix and four review lenses

| Material contract | Reachable conditions/path | Expected observable result | Evidence and gap |
| --- | --- | --- | --- |
| UI ownership and responsiveness | Normal navigation, BLE bursts, renderer/SD activity | Coherent input snapshots; worker work does not freeze UI | Deferred route/GPS, renderer ownership and scheduler policy inspected; FWRT-001/005 remain; no device worst-case latency proof. |
| Memory rejection preserves operation | Route, labels, map install, startup under low largest-block headroom | Reject a frame/operation or explicit safe boot failure, not corruption/hang | Bounded workspaces/PSRAM placement strong; FWRT-003/004/008/009; no production allocator-failure harness. |
| Cancel means no later use of owned resource | BLE disconnect/disable during TLS or OTA | Single owner completes/cancels once; no access after close | Generation policy passes; FWRT-002/010 show lifetime fence gaps. |
| Full-screen rendering | Both dimensions; display off/wake; rotation | Full valid buffer and coherent refresh, no partial-strip substitution | Preserved source architecture; host layout/policy coverage; actual motion/tearing/flush latency untested. |
| Watchdog is attributable | Normal versus light-sleep profiles; stalled task/card | Configured fault response and truthful forensic coverage | Normal IDLE0 explicit; role records bounded; FWRT-006 and non-subscribed task blind spots. |
| Stable camera | Developer profile, turns/labels, delayed view | Camera-consistent route/marker, stale concealment and bounded residency | Pure projection/camera tests pass; production disabled; both-board physical age/visual gates pending. |
| Safe power transition | Cold boot, idle off/wake, audio/transfer, deep shutdown | Correct per-board PMIC rule, quiescent bus users, durable shutdown boundary | Policy tests and source order reviewed; no brownout/electrical/soak proof; FWRT-007 affects qualification records. |
| PR388 adds bounded evidence | Direct Watch or relayed, duplicate/stale sample, phase reset | Fixed-state coherent observation, no synthetic sample duration | Exact-tree deterministic tests pass; topology, HealthKit and four-hour physical gates not run. |
| Build/qualification claims match artifacts | Ordinary/debug/production and both targets | Exact source/profile/runtime identity; no debug/development trust in production | Generated/profile/build-tool tests pass; no local firmware artifacts; live CI only as separately recorded below. |

The four lenses were completed before final reconciliation:

1. **Code/integration/security:** task creation, callback ingress, allocator and
   bus lifetimes, cancellation, failure recovery, display ownership, boot and
   power ordering. Bluetooth was one consumer, not the central protocol scope.
2. **Claims/spec/reachability:** compared current source to renderer ownership,
   PSRAM budget, power/battery, stable-camera, OTA, build provenance and PR388
   plans. Distinguished compiled-out legacy and production-disabled paths from
   enabled functionality and historical measurements from current acceptance.
3. **Tests/verification:** read assertion strength and host-vs-production seams,
   ran focused C++/C and Python checks, examined both target/profile selection,
   generated contracts, CI workflows, and hardware gate definitions. No passing
   policy test was treated as a race reproduction or physical timing result.
4. **Repository policy/hygiene:** reviewed root AGENTS, CONTRIBUTING and PR
   template, scoped instruction inventory, hardware/runbooks, generated-contract
   rules, target ancestry, live PR state/reviews and changed scope. PR388's
   generated outputs passed `--check`; no current review threads supplied
   additional actionable claims. No firmware/runtime dependency or generated
   source was changed by this report.

The diff-oriented skill was adapted to current-main system boundaries and the
main→PR388 integration delta. Relevant unchanged source/contracts from the
earlier review were revalidated against the new snapshot; materially changed
paths were traced afresh. This is not a claim to have audited unrelated backend,
iOS/Watch internals or all third-party driver implementation code line-by-line.

## 9. Verification record and evidence separation

### Local source/host evidence

All output-producing commands ran in isolated worktrees or a disposable
temporary directory. No actual ESP32 compile/link was run. In particular,
mocked build-tool tests print sample provenance messages: **those are not
firmware build evidence**.

| Check | Exact target | Result |
| --- | --- | --- |
| `PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=tools python -m unittest discover -s tools/tests -p 'test_*.py'` from `esp32` | Main | 448 tests passed, 38.775 s, using disposable venv with pinned preconnection-assets requirements. Initial ambient run had a missing `qrcode` import; resolved only in that venv, no source change. |
| Root `tools/tests` unittest discovery | Main | 74 passed. |
| `.github/scripts/tests` unittest discovery | Main | 73 passed. |
| Focused C++ host binaries, `g++ -std=c++17 -Wall -Wextra -Werror` where prescribed | Main | 55 passed, including camera enabled/disabled, both GUI dimensions, automatic-light-sleep policy, watchdog/diagnostic queues, power/display/audio/I2C policies, map jobs/geometry/workspaces, renderer timing, transfer limits and workout/automation. |
| Source-linked format/layout/transfer tests and codec interface deletion | Main | 9 additional binaries passed: block format, font format, label block, font asset (4 KiB frame-warning gate), label layout/raster/selection, map transfer, codec deletion. |
| Generated ride BLE contract `tools/generate_ride_ble_contract.py --check` | Main and PR388 | Passed on each tree. |
| C++ capabilities/workout protocol/workout state/automation policy/automation protocol | PR388 | 5 binaries passed. |
| `python -m unittest tools.tests.test_ride_trace_replay` | PR388 | 11 tests passed. |
| `python tools/tests/test_firmware_profile_config.py` | PR388 | Passed. |
| Final report whitespace/link-target checks and worktree status | Report branch | Report only; no firmware/source edits. |

The scratch host scripts reproduce the repository CI compile commands without
running its device/firmware workflows. C++ host counts describe executables,
not individual assertions. These tests cover valuable pure policies and binary
formats, but neither real FreeRTOS scheduling nor allocator/flash/socket
interleavings, DMA pressure or bus electrical failures. No sanitizer-based
production race reproduction was executed. No claim-specific finding above is
marked fixed by a broad green suite.

### Live GitHub evidence

- Exact PR388 head `18ca6e8e...`: [CI run 34042221518][CI-388] succeeded,
  including 1.75 ordinary, remote-debug and production, ESP32 host tests,
  iOS checks and aggregate gate. This is remote build/test evidence for that
  head, not a merge, 2.06 result or installed-image proof.
- Merged stable-camera PR407 head
  `0e979620a96dcf863623ef5af497167b814a6b38`:
  [CI run 34019707853][CI-407] succeeded. It is ancestor/PR evidence, not
  an exact-main `fe73...` build claim.
- The exact fetched main commit had no matching run/check result returned by
  the point-in-time queries. That means unavailable exact-main CI evidence,
  not a failed build. No remote CI was dispatched or rerun.
- Automatic firmware CI's selected board is 1.75. Diagnostic/release/manual
  matrices cover additional profiles/boards by explicit workflow selection;
  a green aggregate does not by itself prove 2.06 compilation. The runtime
  performance workflow's host/runtime checks are not RTOS/device performance
  measurements.

### Deployed and physical-device evidence

None was collected for either reviewed SHA. No current installed firmware,
device heap/stack minima, task census, DMA headroom, watchdog reset, battery,
thermal, touch wake, acoustic output, display motion or brownout result is
claimed. Historical benchmark evidence in [renderer-benchmark.md][S-benchmark]
is explicitly tied to `88cd0e8b9bdb699e82f37839872f95e837747d8f`, the 1.75
remote-debug target and its recorded fixture. Its temporary coverage-rejection
policy reassessment is not a new run or renderer fix; it cannot qualify either
review target, a factory image, or 2.06.

## 10. Strengths, residual risk, and dependency-ordered remediation

The central architecture has useful separation: UI owns LVGL; renderer owns
decoded/raster work; callbacks mostly hand off immutable input; audio owns
codec resources; diagnostics has bounded admission and a dedicated writer;
transfer modes share one authenticated server. Memory capability selection,
finite prediction, semantic generations, worker-stop state preservation,
bounded building admission, protected PMIC writes and per-profile production
gates are substantive strengths. Full-screen/full-refresh is an explicit
artifact-avoidance contract and should remain intact.

Remaining uncertainty is greatest at boundary conditions: memory exhaustion,
cross-core cancellation, filesystem recovery, peripheral shutdown, and actual
cooperative-checkpoint service under simultaneous Wi-Fi/TLS, BLE, full display
flush, map work and audio. No general deadlock, leak, brownout regression or
DMA misuse was asserted without a concrete proof path. Some operations remain
variable-duration despite bounded queue sizes; a priority-inheriting mutex is
not a latency bound. Exact framework task stacks/affinities, heap fragmentation
and cache-disabled PSRAM safety require artifact-specific and physical evidence.

Recommended implementation order (recommendations only; no changes made):

1. **Establish ownership primitives first:** coherent maneuver publication
   (FWRT-001), single-owner OTA terminal lifecycle (FWRT-002), descriptor
   cancellation/close fence (FWRT-010), fail-closed handler initialization
   (FWRT-008). Add deterministic interleaving and resource-creation fault tests
   while changing those boundaries.
2. **Make memory failure a defined result:** complete display-buffer admission
   and bounded boot recovery (FWRT-003), then route/render/install exception
   containment and streaming validation (FWRT-004). Preserve the last usable
   map/route and the full-refresh requirement; verify every failure injection.
3. **Finish control-plane isolation:** move both rollback paths to the worker
   (FWRT-005), then design two-phase shutdown/quiescence using the corrected
   lifecycle primitives. Test delayed SD/codec/HTTP completion without freeing
   or shutting down resources still owned by another task.
4. **Make evidence trustworthy:** propagate recorder readiness (FWRT-009),
   test effective per-profile watchdog config (FWRT-006), correct the SD
   qualification contract (FWRT-007). Treat progress monitoring separately
   from idle-starvation detection rather than blindly subscribing every task.
5. **Qualify exact artifacts in dependency order:** authorized locked builds
   for both ordinary/production targets and relevant diagnostic/sleep variants;
   inspect generated config, map/ELF sizes and stack placement; then separately
   authorized device identity/cold boot, allocator pressure and cancellation,
   display/touch/SD/audio contention, sleep/deep-shutdown/power-fail recovery,
   stable-camera sweeps and long navigation/workout soaks. Retain free/minimum/
   largest internal, DMA and PSRAM blocks, every task's high-water mark, maximum
   UI gap, render/flush latency, queue drops, reset identity and exact profile.
   Repeat PR388's direct-Watch and relayed topologies and both-board physical
   gates before enabling production automation.

Final state: **`review-only-complete`**. Active ledger: **4 P1, 6 P2**.
Main target: **`fe73e43431ed76c39159de7624c4cd9ede509434`**.
Projected main + PR388: **`18ca6e8e2d4c0e6d12d175e5e1313345ae6942f4`**.
This report is local, uncommitted and unpublished; no implementation fixes
were authorized or performed.

## Immutable source references

[S-nav-callback]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/ble_navigation/ble_navigation.cpp#L5302-L5316
[S-nav-write]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/ble_navigation/ble_navigation.cpp#L1221-L1228
[S-nav-read]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/ble_navigation/ble_navigation.cpp#L526-L529
[S-ui-nav]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/src/main.cpp#L848-L896
[S-connected]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/ble_navigation/ble_navigation.hpp#L249
[S-ble-stats]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/ble_navigation/ble_navigation.cpp#L6114-L6118
[S-ota-disable]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/firmware_update/firmware_update_http.cpp#L269-L272
[S-ota-write]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/firmware_update/firmware_update_http.cpp#L507-L551
[S-ota-abort]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/firmware_update/firmware_update_http.cpp#L689-L707
[S-transfer-cleanup]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/ble_navigation/ble_navigation.cpp#L3110-L3120
[S-revoke]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/device_transfer/device_transfer_http.cpp#L273-L290
[S-buffer-fallback]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/panel/WAVESHARE_AMOLED_175.cpp#L1163-L1171
[S-buffer-full]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/panel/WAVESHARE_AMOLED_175.cpp#L1191-L1215
[S-lvgl-assert]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/lvgl/lv_conf.h#L348
[S-allocator]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/utils/src/psram_allocator.hpp#L32-L47
[S-route-alloc]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/route_overlay/route_overlay.cpp#L30-L51
[S-label-alloc]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/maps/src/maps.cpp#L2171-L2179
[S-map-thunk]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/maps/src/maps.cpp#L4363-L4368
[S-map-validation]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/map_transfer/map_transfer.cpp#L3120-L3152
[S-ui-rollback]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/src/main.cpp#L2113-L2115
[S-rollback]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/map_transfer_http/map_transfer_http.cpp#L679-L712
[S-label-rollback]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/src/main.cpp#L2145-L2167
[S-scheduler-doc]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/docs/firmware-map-render-scheduler.md#L14-L72
[S-wdt-config]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/platformio.ini#L183-L190
[S-light-config]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/platformio.ini#L381-L400
[S-wdt-test]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/tools/tests/test_watchdog_scheduler_contract.py#L35-L45
[S-power-sd]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/docs/firmware-power-management.md#L313-L314
[S-battery-sd]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/docs/firmware-battery-life-hardware-validation.md#L297
[S-sd-default]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/storage/storage.cpp#L35-L40
[S-sd-mount]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/storage/storage.cpp#L398-L438
[S-sd-config]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/platformio.ini#L285-L291
[S-map-configure]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/map_transfer_http/map_transfer_http.cpp#L143-L157
[S-ota-configure]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/firmware_update/firmware_update_http.cpp#L259-L267
[S-map-lock]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/map_transfer_http/map_transfer_http.cpp#L601-L609
[S-ota-lock]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/firmware_update/firmware_update_http.cpp#L733-L740
[S-recorder-alloc]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/ride_diagnostics/ride_diagnostics.cpp#L1211-L1224
[S-recorder-task]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/ride_diagnostics/ride_diagnostics.cpp#L1052-L1062
[S-recorder-seal]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/ride_diagnostics/ride_diagnostics.cpp#L1574-L1576
[S-ready]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/src/main.cpp#L1970-L1979
[S-client-lifetime]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/device_transfer/device_transfer_http.cpp#L761-L794
[S-client-close]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/device_transfer/device_transfer_http.cpp#L1047-L1083
[S-tls-close]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/device_transfer/device_transfer_tls.cpp#L751-L765
[S-tls-interrupt]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/device_transfer/device_transfer_tls.cpp#L691-L694
[S-client-interrupt]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/device_transfer/device_transfer_http.cpp#L1156-L1160
[S-camera-doc]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/docs/map-stable-camera.md
[S-main]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/src/main.cpp#L1420-L1987
[S-map-worker]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/maps/src/maps.cpp#L4269-L4368
[S-activation]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/map_transfer_http/map_transfer_http.cpp#L820-L876
[S-speaker]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/speaker/speaker.cpp#L609-L731
[S-ui-scheduler]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/ui_scheduler/ui_scheduler.cpp
[S-tasks]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/tasks/tasks.cpp
[S-hardware]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/hardware/README.md
[S-display-constants]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/waveshare_board/display.hpp#L12-L49
[S-shutdown]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/power/power.cpp#L128-L144
[S-benchmark]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/docs/renderer-benchmark.md#L74-L95
[P-workout-runtime]: https://github.com/seichris/open-bike-computer/blob/18ca6e8e2d4c0e6d12d175e5e1313345ae6942f4/esp32/lib/ble_navigation/workout_telemetry_runtime.cpp#L7-L50
[P-autopause-doc]: https://github.com/seichris/open-bike-computer/blob/18ca6e8e2d4c0e6d12d175e5e1313345ae6942f4/docs/bicino-autopause-distance-consistency.md
[U-ota]: https://github.com/espressif/esp-idf/blob/v5.5.1/components/app_update/esp_ota_ops.c#L269-L408
[U-lvgl]: https://github.com/lvgl/lvgl/blob/v9.2.2/src/display/lv_display.c#L384-L410
[U-wdt]: https://github.com/espressif/esp-idf/blob/v5.5.1/components/esp_system/Kconfig#L444-L480
[U-nimble]: https://github.com/h2zero/NimBLE-Arduino/blob/1.4.3/src/nimble/porting/npl/freertos/src/nimble_port_freertos.c#L54-L63
[CI-388]: https://github.com/seichris/open-bike-computer/actions/runs/34042221518
[CI-407]: https://github.com/seichris/open-bike-computer/actions/runs/34019707853
