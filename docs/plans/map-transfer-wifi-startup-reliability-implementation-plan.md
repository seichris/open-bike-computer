# Reliable map-transfer Wi-Fi startup

## Status and scope

Planning baseline: 2026-09-24, freshly fetched `origin/main` at
`b27d2c8dccb3cdfd9630b554997bed5f5268c695`. This is the first commit on a
dedicated Wi-Fi transfer reliability branch; the plan is not a firmware fix or
physical-device validation.

The topo-map download/build fixes are already on `main` (including PR #503),
and the development map-platform promotion is merged (PR #504). The development
`/healthz` reports `status: ok` and `admissionPolicyVersion: map-cost-v2`. The
rider reported that a small Expo Culture Park topo map downloaded successfully
to Bicino Dev. None of those facts proves that the map can be installed on the
Bike Computer.

The observed installation failure is `wifi_ap: could not start transfer Wi-Fi
fallback` on a Waveshare AMOLED 1.75 running version 0.3.4, build 100, Git
`80b82d2e6271341db3fd51f42bbfcf8b8342e8c5`. The error is raised before
the HTTPS listener and before map bytes are uploaded. The present status does
not distinguish internal-owner dispatch failure, Wi-Fi mode initialization,
RAM-backed Wi-Fi configuration, or `softAP` failure. Memory pressure is a
plausible inference, not a measured root cause. A later passive USB serial
connection unexpectedly reset the device; its post-reset log is **not** a
failure-time resource sample, and this project must not reopen serial merely
to inspect a map transfer.

This work must preserve authenticated BLE control, the per-session WPA2
hotspot, pinned HTTPS, signed map streams, rollback, and the OTA maintenance
path. It does not change the map server, topo format, map pricing, or release
policy. No firmware or app build, flash, installation, or release is authorized
by this document.

## Current resource and ownership model

- `HttpTransferServer::setEnabled` creates a 16 KiB **internal-RAM** HTTP
  worker for map mode. `MapTransferHttpServer::responseDidComplete` reuses that
  worker for the deep map-activation path after the upload response unwinds;
  allocating a second 16 KiB activation task at that peak was deliberately
  avoided.
- The shared `HttpTransferServer::startNetwork` delegates Wi-Fi startup to
  `FirmwareFlashOwner`, which lazily creates a separate 8 KiB internal-RAM
  task. Thus map-mode startup may need both internal stacks before Wi-Fi and
  TLS can acquire their own internal/DMA-capable allocations.
- Firmware-maintenance, diagnostics, and remote-debug TLS workers use PSRAM
  stacks; Wi-Fi changes and flash-capable OTA operations run on the internal
  owner. The owner currently remains alive after its first use in that boot.
- `DSTS` exposes current/minimum internal, DMA, and PSRAM free and largest
  blocks plus both stack high-water marks. The `wifi_ap` error only carries a
  generic message; it does not identify the failing suboperation or its heap
  snapshot.

ESP-IDF warns that PSRAM becomes inaccessible while flash cache is disabled.
Moving the map worker to PSRAM without moving **every** flash/cache-disabling
activation, rollback, and cleanup path off that stack is unsafe. See
[ESP32-S3 external-RAM restrictions](https://docs.espressif.com/projects/esp-idf/en/v5.5/esp32s3/api-guides/external-ram.html).
Wi-Fi/lwIP use dynamic heap, and total free heap is not a substitute for the
largest allocatable internal/DMA block. See
[ESP32-S3 heap allocation](https://docs.espressif.com/projects/esp-idf/en/v5.5/esp32s3/api-reference/system/mem_alloc.html)
and [Wi-Fi buffer usage](https://docs.espressif.com/projects/esp-idf/en/latest/esp32s3/api-guides/wifi-driver/wifi-performance-and-power-save.html).

## Decision: one internal operation owner, PSRAM protocol worker

Use one serialized, internal-stack device-operation owner for transfer-related
Wi-Fi configuration and all operations that may disable flash cache. Move the
map TLS/HTTP worker to PSRAM **only after** map activation and its recovery /
rollback paths have been audited and dispatched to that internal owner. Size
the owner for the deepest measured map path rather than retaining an 8 KiB OTA
assumption. Do not run a second internal activation task concurrently.

The owner may evolve from `FirmwareFlashOwner`, but its responsibilities and
name should become mode-neutral. Commands need explicit operation type,
generation/correlation, result ownership, cancellation boundary, and a
terminal state after timeout or mismatched result. Long-running map activation
must have its own bounded progress/cancellation protocol; it must not be placed
behind the existing 60-second synchronous Wi-Fi/OTA command timeout without
review. The TLS worker may wait for an activation result only after its HTTP
response and parser state have unwound. A BLE disconnect must revoke the
session and network access, not interrupt an already-committed map switch in a
way that loses rollback evidence.

The internal owner should be started only for an admitted transfer and released
after all network, flash, activation, and status handoffs have completed.
Lifecycle must be explicit: no stale owner task, command, queued result, or
internal stack should survive a completed or failed session. A poisoned owner
must fail closed for that boot; it must not be silently restarted with possibly
late work still outstanding.

Running map Wi-Fi calls inline on today's internal HTTP worker would be a
smaller short-term repair, but it would retain a separate mode-specific
architecture and would not reclaim an owner previously started by diagnostics
or OTA. It is not the target design for this PR. Likewise, increasing timeouts,
retrying `softAP` blindly, or moving only the TLS worker to PSRAM does not
establish a memory or cache-safety guarantee.

## Implementation sequence

1. **Make the failure observable.** Return a stable, non-secret subreason for
   owner creation/dispatch, `WiFi.mode`, `esp_wifi_set_storage`, and
   `WiFi.softAP` failures. Retain the underlying numeric `esp_err_t` where
   available, plus resource snapshots immediately before and after each
   transition. Publish the classification and internal/DMA free + largest
   blocks in authenticated `DSTS` and show a concise actionable app error.
   Never log the SSID password, bearer token, TLS private key, or map contents.
2. **Define and test the owner boundary.** Inventory every map install,
   activation, rollback, recovery, and teardown call that can touch flash/NVS
   or disable cache. Move those calls to the single internal owner; leave
   parsing, HTTPS/TLS, and ordinary SD streaming on the PSRAM HTTP worker only
   where the audit proves this safe. Preserve exact signed-stream verification
   and generation/authorization checks.
3. **Remove overlapping internal stacks.** Switch map HTTP to the explicit
   PSRAM-stack path only after step 2. Dispatch post-response activation to
   the internal owner instead of allocating or using another internal HTTP /
   activation stack. Make owner shutdown/reclaim deterministic across map,
   firmware, diagnostics, and debug modes.
4. **Add measured admission and error behavior.** Sample free and largest
   internal/DMA blocks at entry, owner start, Wi-Fi start, listener start,
   TLS admission, activation, and teardown. Fail before advertising a usable
   transfer session if the measured per-target reserve cannot be maintained.
   Derive thresholds from device evidence; do not invent a constant from one
   post-reset idle snapshot. Keep errors available over authenticated BLE
   after network startup fails.
5. **Update contract and user experience.** Extend firmware/iOS parsers and
   `docs/ble-protocol.md` together if the `DSTS` schema changes. Keep unknown
   fields optional for older firmware and preserve the existing secure
   transfer handshake. A failed map startup must leave the downloaded map on
   the iPhone, allow a deliberate retry, and not claim that the map installed.

## Verification gates

- Host policy and source-contract tests cover owner generation, late results,
  timeout poisoning, cancellation/commit races, status redaction, mode
  transitions, and map-activation handoff. Test failed owner creation and each
  Wi-Fi substep separately; old generic `wifi_ap` failures must map to a
  specific classification without leaking credentials.
- The portable Swift BLE/navigation tests cover new optional status fields,
  old-firmware compatibility, error presentation, and paused-map retry state.
  Exact-head CI must pass. Firmware builds for both Waveshare targets are
  separate build evidence, not physical acceptance.
- Before any physical flash, identify the exact board, stable serial, Git
  commit, profile, attested image and flash plan, and obtain fresh explicit
  confirmation. Test 1.75 and 2.06 separately; a green default CI gate only
  builds 1.75 profiles.
- On each target, measure resource minima and largest blocks during a small
  signed topo-map upload, HTTPS transfer, activation, renderer reload, reboot
  persistence, replacement, interrupted/resumed upload, and rollback. Verify
  map identity and contour rendering at a location inside the installed map.
  Repeat diagnostics LAN/hotspot fallback, remote debug, and signed OTA
  maintenance flows to catch shared-owner regressions.
- Do not merge a production-enabled hardware-path change as fully qualified
  without these physical gates; either keep it excluded from production or
  record an explicit maintainer risk acceptance. Do not publish a firmware
  release or flash a board merely because the PR/CI is green.

## Completion criteria

The map AP starts and a signed topo stream installs on both board families
with measured internal/DMA headroom; failed startup identifies the exact
suboperation and retains a safe retry; activation and rollback remain durable;
OTA and diagnostics still pass their own transfer paths; and the transfer
owner/worker lifecycle returns to the pre-session memory baseline. Source,
build, CI, and physical observations must be reported separately.

## Implementation record (2026-09-24)

The follow-up implementation uses a mode-neutral `DeviceOperationOwner` for
Wi-Fi mutations, OTA flash calls, and post-response map activation. The map
HTTPS/TLS worker uses a PSRAM stack; the internal owner has a 16 KiB stack and
is reclaimed after the network worker finishes. Dispatch command IDs still
poison the owner on timeout or a mismatched result, so late work cannot be
paired with a new caller. The map activation wait has a separate ten-minute
limit; a timeout leaves activation status unresolved rather than reporting a
safe retry while its journal might still commit. Boot recovery continues on
its dedicated internal task before transfer startup. Renderer rollback remains
on the existing serialized storage-control task, which uses the SD card rather
than flash/NVS operations and cannot run concurrently with transfer activation.

Authenticated `DSTS` now reports the AP startup substep and before/after
internal/DMA blocks, with numeric `esp_err_t` when one is returned. The iPhone
shows a retry message and keeps its local map artifact after startup failure.
The owner and worker release paths are explicit for map, diagnostics, debug,
and firmware modes. Physical evidence is still needed to determine whether
the reported 1.75-inch failure was memory pressure, driver state, or another
substep, to set justified per-target admission reserves, and to qualify map,
diagnostics, remote-debug, and OTA behavior on both boards. This PR must remain
hardware-gated until that evidence exists.

## Physical 1.75-inch finding and follow-up candidate (2026-09-24)

On an ordinary 1.75-inch image at Git `aaf0cdb55385cd2b4062eadc53d9dbe7c125c06b`,
the authenticated iPhone retained the downloaded signed Shanghai topo stream,
but AP startup returned `wifi_mode` before upload. After a controlled warm
reboot, the first attempt entered Wi-Fi initialization with internal free /
largest blocks of 42,811 / 14,836 bytes and DMA free / largest blocks of
35,179 / 14,836 bytes. Initialization returned failure after consuming about
21 KiB of internal memory. A separate controlled attempt panicked on core 0
in `ieee80211_hostap_attach` / `wifi_softap_start`, then rebooted. Neither
outcome qualifies a map transfer. The exact successful serial boot identity
and the panic belong to this same image; no cold-start or readback claim was
made.

The next image raises the ESP-IDF internal/DMA reserve from 64 to 96 KiB and
rejects AP/STA initialization below a conservative floor derived from the
observed unsafe region. The floor is a crash-avoidance preflight, not a proven
success threshold. Physical measurements must show Wi-Fi startup, signed
upload, activation, renderer reload, and safe teardown before choosing final
per-target admission thresholds. The revised image has not been flashed or
physically accepted.
