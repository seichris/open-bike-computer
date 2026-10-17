# PR 553 diagnostics and lifecycle integration review

This is a source/software review, not a hardware acceptance report. The logging
implementation originally recovered in `6eef692407958999a4c967bc518b3c5b77fdccba`
was not the complete long-term diagnostics roadmap. The CI dependency/path repair
in `9a04c14e32a2aea242c342e3004bd6de5e521561` passed CI run `36842099446` and Workout
Zone Contracts. Later software changes require their own exact-head CI results.

## Reviewed and corrected

- The independent Catalyst preview compiler invocation lacked the diagnostics
  types referenced by BLEManager; three diagnostics CI steps used the wrong
  working directory. Each compiler invocation and effective script directory now
  has a regression check; no test, dependency or safety gate was removed.
- An unconditional capture-policy publisher forwarded iPhone-only requests to
  the connected bike and double-forwarded device requests. Forwarding is now
  explicit. A phone-only collect queues a local snapshot instead of switching
  the bike's transport. A failed device stop request is no longer reported as
  successfully queued.
- Completed collections could automatically start another cutoff. Admission now
  selects only independently persisted pending jobs for the original device,
  respects explicit cancellation and post-ride opt-out, and fences delayed
  selection against newer operations. Restoration must finish before collection.
- Ride end queues bounded, idempotent requests using the original authenticated
  device/capture contexts. Leaving Settings does not own the task. A ride starting
  during collection interrupts retrieval and retains resumable partial evidence;
  cleanup retains the existing cancellation-independent lease owner.
- Authenticated-readiness handling runs after Combine's `Published.willSet`
  boundary so it reads committed BLE state. Ride-end resumes previously paused
  manual work even without new post-ride contexts, and completion rechecks the
  queue after transport cleanup. Explicit-cancel and transport-error guards
  remain in force. Apple CI exercises the real Combine delivery boundary;
  portable hosts report that platform-specific case as unexercised.
- Outbox admission now includes the prepared bundle in its 400 MiB prospective
  byte budget. It cannot append a 104 MiB bundle merely because the old outbox
  was just below the limit. Request validation precedes retention eviction.
- Capture/device/acquisition-scoped verification and analysis no longer use
  another ride's source coverage or unrelated historical acquisition failures.
  Integrity covers the full archive; stream/global loss counters remain labelled
  as conservative evidence, not invented per-capture loss attribution.
- Live source gaps remain sticky for their boot/process stream; the first event
  after a cursor is checked even when older cached history remains.
- Matching-registry v2 markers share an incident UUID between phone and firmware.
  Device Settings has a local marker control which neither starts Wi-Fi nor
  consumes the phone's anti-replay counter. Queue admission is not described as
  durable media acknowledgement. Ordinary retention still applies.

## Other lifecycle work inspected

The review covered the shared MainActor `DeviceOperationCoordinator`, restored
OS claims and generation fencing, cancellation-independent cleanup, diagnostics
snapshot sealing and catalog publication, the firmware commit-boundary owner,
shutdown admission/unmount sequencing, and predecessor-selection anchor checks.
The existing operation, replay, shutdown, resource and metadata tests were run
where the local toolchain/dependencies were available. No new map/OTA production
admission, ownership bypass, TLS bypass, partition change, signing change or
hardware write was introduced. The metadata-compatibility floor and 64 KiB
application reserve remain release requirements.

The app-wide operation coordinator is intentionally stricter than per-device
parallelism because iOS accessory networking/configuration removal is shared.
The shutdown barrier's deadline does not grant permission to sleep; it remains
fail-closed. A checksummed catalog only accelerates inventory and never proves
that returned chunk bytes are intact. FAT/card power durability and actual radio
races still require physical qualification. This review is not a claim that
every line of the large original lifecycle PR has been independently verified.

## Roadmap coverage — do not conflate these states

| Requirement | Software state |
| --- | --- |
| Health-event schema correctness and emission timestamps | Implemented. |
| Shared field types, domains, levels and registry identity | Implemented vocabulary; not a full migration of every event producer to generated per-event constructors. |
| Bounded production journal policies | Implemented for emitted privacy-safe events; does not enable compiled-out SDK/RAUT/raw providers. |
| Independent local recording, immutable catalogs and resumable collection | Implemented; unflushed tails, storage failures and retention loss remain possible and must be reported. |
| CLI, explicitly paired Mac broker, bounded live observations and evidence queries | Implemented. Cloud Codex still needs a deliberately shared artifact or bridge; no implicit access to local hardware. |
| App-owned post-ride queue | Implemented as an explicit opt-in. A request survives process loss after persistence; process loss before ride end needs manual retrieval. |
| Phone/device incident IDs and local device marker | Implemented, with conservative v1 fallback. |
| Shared IDs through every navigation/BLE/authentication/apply/render stage | Partial: existing lifecycle operation identities and incident IDs are available, but comprehensive per-navigation-operation instrumentation is not implemented. |
| Bounded persistent pre/post-incident pinning | Not implemented. A marker is not a retention pin. |
| Native iOS MetricKit/system/crash artifacts and firmware SDK/core-dump retrieval | Not implemented in this pipeline. Standard bundles explicitly report native crash evidence absent. |
| Automatic exact-image ELF/dSYM retention, acquisition and symbol resolution | Not implemented end to end. Never symbolize against an arbitrary checkout. |
| Every domain/level producer migration and measured cost qualification | Incomplete; selectable severity alone does not establish provider coverage. |
| Optional MCP wrapper/remote inbox | Not implemented; CLI/local handoff are the supported interface. |
| Both-board physical qualification and battery/latency/power-cut campaigns | Not performed by this source review. |

Native/raw artifacts and pinning need actual bounded storage, privacy, permission,
collection and validation implementations; adding placeholder capability flags
or declaring them complete would not satisfy these requirements. Keep this
matrix accurate as subsequent commits close the remaining work.
