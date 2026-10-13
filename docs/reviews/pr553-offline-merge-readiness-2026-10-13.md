# PR 553 offline merge-readiness review

This follow-up reviews source and retained test evidence without a connected bike
computer. Its starting snapshot is `daee25c59700c0489cd966387e6774cb6d4e3c8c`,
against base/merge-base `5ea614da581ae4d4357e203ebd7139ecceb5adb4`. All 16 checks
passed on that snapshot. The follow-up changes the iPhone recorder checkpoint
and executable host tests; it does not change firmware or workout transport.
The final PR head requires its own CI result.

## Logging behavior established by retained physical evidence

- A user-confirmed outdoor Watch ride lasting about 19 minutes 29 seconds
  automatically delivered its original inventory to the paired Mac: 78 firmware
  chunks, five iOS chunks and 46,924,701 archive bytes. Returned bytes and hashes
  were checked, with both required sources and zero scoped sequence gaps.
- An interrupted inventory resumed automatically from 28/83 to 83/83 after an
  exact development-app process termination. Acquisition/capture identity,
  original index, expected hashes and the previously verified subset survived.
  The resulting 43,055,468-byte handoff was independently verified.
- A lost acknowledgment after Mac file/SQLite commit retried the same bundle
  identity and bytes, producing one durable receipt. A separate offline-Mac
  bundle survived an app restart and delivered after inbox capacity was freed.
- A subsequent automatic 70,320,997-byte handoff delivered all 94 inventoried
  chunks. Complete delivery is independent of recording coverage: its retained
  iPhone stream reports new queue-overflow loss, so it remains degraded.

These proofs belong to their recorded source/build and capture identities. They
are not a physical retest of this follow-up. Automatic handoff requires an
opted-in collection, foreground iPhone, trusted LAN and paired Mac broker.
Queues, retention and storage can still lose recording evidence; counters and
degraded coverage must remain visible.

## Recorder checkpoint repair

The retained iPhone capture reports 151 queue-overflow drops and writer delays
up to 19,012 ms. The record names identify queue admission loss, rather than
failed chunk integrity or a missing Mac acknowledgment. They do not identify
the rejected event payloads or prove a single cause for the writer delay.

Source review found an avoidable cost: a manifest update every 16 records called
`updateRetainedBytes()`, repeatedly enumerating and sorting all historical app
and imported-device files on the writer queue. An executable test fails on the
old behavior with 64 retained historical files. Routine updates now account for
the replaced sidecar's exact size delta. Full reconciliation remains at storage
initialization, import, retention and export boundaries. Queue size, priority,
privacy and retention limits are unchanged.

The regression checks that routine checkpoints do not walk the historical
inventory, their byte accounting matches actual files, and all admitted records
are retained. A separate blocked-writer overflow test checks that a critical
record displaces a normal record and that rejection plus eviction are reported
exactly in persisted counters. Existing retention, immutable acquisition and
archive checks remain required. No physical throughput or zero-loss claim is
made for this repair.

## Firmware findings and production boundaries

F13 identified a real IPC-stack startup overflow with the pinned 1,024-byte
configuration. The repair selects 1,536 bytes for both Waveshare families and
rejects smaller effective SDK values at compile time. Retained 1.75-inch startup
and transfer tests exercised the repair. Full per-target reserve, repeated-mode,
error, OTA, idle-power and card qualification remains open.

F16 identified a real nested HTTP manifest-admission stack overflow. The journal
read and restore workspaces moved bounded data off the task stack; size/EOF,
allocation-failure and file-ownership checks remain strict. Retained physical
admission reached HTTP 200 and terminal installed/cleanup results after repair.
Host compiler-frame and production-adapter fault tests guard the repaired paths.
Neither sampled reserves nor source-possible call chains establish worst-case
SDK/IRQ/ROM/register-window or alternate-storage-backend stack bounds.

The original findings therefore have repaired, exercised triggers, but their
broader qualification entries remain open. This review does not silently waive
those entries or convert missing physical evidence into a clean safety result.
Firmware sources are unchanged from the retained `1bb8d47` image to the starting
snapshot and this follow-up.

`MAP_OPERATIONS_V1_ENABLED` and `FIRMWARE_OPERATIONS_V1_ENABLED` default to zero.
Only the two explicitly nonshipping lifecycle-qualification environments set
them to one. Shipping ordinary/production/debug profiles and release packaging
remain excluded. Tests check inheritance, flags and release exclusion.

Shared network/flash ownership, resident Wi-Fi driver/netifs, shutdown handling
and startup configuration are enabled changes, however. Their remaining
physical gates cannot be dismissed solely because the new operation protocols
are disabled. In particular, 2.06-inch hardware, additional FAT32 cards,
100-session/per-mode campaigns, power cuts and complete resource bounds remain
unqualified. Production-signed map interruption and controlled cold start are
explicitly skipped by the user.

## Workout recovery boundary

Retained tests prove bounded iPhone-primary segment/restart/save behavior and
radio-isolated Watch-plus-bike Pause/Resume/display behavior. Reliable paused
and running Watch-to-iPhone recovery after an iPhone app restart is not yet
physically qualified. The current Watch installation failed after transfer;
neither an embedded Watch app nor passing simulator tests proves deployment.

Source/contract tests cover fixed recording ownership, reserved Watch identity,
failure fallback without admitting a second recording, fresh phone recovery
before another ride, timeout/retry fencing and preservation of the native Watch
workout. Explicit unresolved-owner controls remain reachable. Native HealthKit
reattachment and the three physical device combinations remain follow-up tests.

## Merge and release decision

The review uses the standard P0/P1/P2 gate, sequential local execution, and no
subagents. Scope includes changed acquisition/delivery, recorder, workout,
firmware ownership/shutdown/resource, security and packaging paths, supported by
earlier source review and retained executable/physical evidence. It is not an
independent line-by-line review or complete diagnostics-roadmap implementation;
the [scope matrix](diagnostics-pr553-2026-10-01.md) remains applicable.

Under [AGENTS.md](../../AGENTS.md), a change with pending physical validation may
merge only when the affected capability is excluded from production or the
maintainer explicitly accepts and records the residual risk. The shared enabled
firmware changes still require that decision. No risk acceptance, merge,
production rollout or factory-image qualification is recorded by this document.
The per-board [resource matrix](../wifi-lifecycle-resource-qualification.md)
remains open; a merge does not authorize a tagged/distributed factory image.
