# Ride diagnostics format

Ride diagnostics are local-only, structured evidence. They are not an
analytics stream and are never uploaded automatically.

## Event record

Each stream is UTF-8 JSON Lines. Every complete line is one object with
`schema: 1` and these required fields:

```json
{
  "schema": 1,
  "source": "ios",
  "sequence": 42,
  "level": "info",
  "category": "ble",
  "event": "connected",
  "wallTime": "2026-08-19T08:20:31.412Z",
  "uptimeMs": 381231,
  "processId": "123e4567-e89b-12d3-a456-426614174000",
  "captureId": "123e4567-e89b-12d3-a456-426614174001",
  "fields": {"rssiBucket": "good"}
}
```

`wallTime`, `uptimeMs`, `processId`, `captureId`, and `fields` are optional
when the producer cannot provide them, but a producer must not invent a wall
clock. `sequence` is monotonically increasing across every chunk in one
process/boot stream; a chunk boundary does not reset it. Firmware additionally
includes a persistent, collision-free `bootSequence` and
`firmwareFingerprint` in `fields`. `runtimeBootSequence` preserves the RTC
boot-history sequence when it differs from the persistent storage stream.

Allowed sources are `ios`, `firmware`, and `host`. Levels are `debug`, `info`,
`warning`, and `error`. Categories are `lifecycle`, `boot`, `ble`,
`navigation`, `gps`, `workout`, `rideAutomation`, `storage`, `map`, `power`,
`transfer`, `user`, and `logger`.

The event name and fields are deliberately typed at each call site. Unknown
fields are rejected by the host validator and by the iOS device-chunk
validator. Fields are flat scalar values from the closed vocabulary maintained
in `tools/ride_diagnostics.py` and `RideDiagnosticsFieldPolicy`; nested objects
and arrays are not accepted. iOS field values are bounded strings. Firmware
counter/timing fields are numbers, state flags are booleans, and enum/identity
fields are strings; all three validators enforce the same source-specific type
contract. A truncated final line is reported and ignored; a
truncated line in the middle of a stream is an error.

Firmware may leave a zero-byte closed-chunk filename when power is lost after
file creation but before its first complete record. The authenticated device
index omits that empty artifact because it contains no evidence. It includes a
non-empty final chunk byte-for-byte even when the last JSON record is truncated;
the checksum binds the original crash tail and validators salvage the preceding
complete records. A truncated tail cannot be followed by another non-empty
chunk in the same boot. Any other non-empty candidate that cannot be read and
hashed makes the index fail closed instead of silently dropping evidence.

Firmware that starts before its wall clock is valid omits `wallTime`. Its first
later timestamped event and every subsequent RTC correction emit a
`lifecycle.clock_anchor` carrying the same uptime and persistent boot sequence.
The Mac summarizer uses the nearest anchor, including across unsigned 32-bit
uptime wrap, to derive a `correlatedWallTime`, reports `clockUncertaintyMs`, and
never rewrites the raw JSONL bytes.

## Privacy boundary

Never persist exact coordinates, addresses, route instructions, destination
names, Wi-Fi credentials, transfer tokens, owner keys, raw HealthKit values,
raw IMU arrays, or complete BLE/HTTP payloads. Use stable codes, lengths,
latencies, counters, freshness/accuracy buckets, and random per-capture IDs.

The detailed ride trace may use the normalized fields already allowed by
`docs/ride-automation-traces.md`; it still contains no coordinates or raw
health/sensor stream.

## Map recovery evidence

Firmware records map-selection and renderer-probe decisions as structured
`map` events so a missing map can be diagnosed from the SD card without a live
serial connection. Boot records cover the recovery check, selected map,
renderer probe, any rollback, and the final selection. Runtime activation and
rollback use the same probe codes. Map-availability transitions use `ok`,
`map_data_not_found`, or `active_map_unavailable`.

Renderer probe codes are `not_run`, `ok`, `worker_stop_failed`,
`root_unavailable`, `block_not_found`, `block_invalid`, `font_open_failed`,
`font_profile_mismatch`, `font_references_invalid`, `root_switch_failed`, and
`worker_restart_failed`.

Map records may include the validated map ID, a 16-character content-receipt
prefix, whether an authenticated transfer session supplied the activation, the
probe `durationMs`, `visitedEntries`, and detected `formatVersion`. Runtime
availability transitions include total `durationMs` and `blockLoadMs`.
They never include map geometry, coordinates, transfer credentials, or a full
content receipt. Availability is recorded only initially and when it changes,
not once per render loop.

The firmware also emits `logger.health` at lifecycle readiness and controlled
shutdown. Its enqueue/write/drop/storage-error counters and current/maximum
queue depth make missing diagnostics distinguishable from a healthy empty log.

## Bundle

An exported stored-ZIP contains `manifest.json`, `checksums.sha256`, `app/`,
`device/`, and `summary/`. The Mac summarizer extracts every validated archive
member byte-for-byte under `raw/` before writing derived files, so filtering or
timeline sorting never rewrites the evidence. The manifest inventories the
JSONL source streams and records the active capture, retained bytes, and iPhone
drop count. `checksums.sha256` binds every archive entry, imported device index
snapshots retain firmware counters, and the validated Mac summary reports
stream gaps, recoverable tails, and clock correlation. None of these files may
contain secrets or forbidden private values.
