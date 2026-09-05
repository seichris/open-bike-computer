# Renderer building benchmark

This experiment ranks bounded 3D-building profiles on a physical Bicino. It
automates the repeatable part of issue #210: exact route replay, profile order,
RAM and renderer telemetry, checkpoint screenshots, rejection gates, Pareto
selection, soak testing, and machine-readable reports. A passing report is a
candidate selection, not permission to change the default profile.

## What is automated

- one checked-in Shanghai route with 120 exact 1 Hz GPS samples and a SHA-256
  marker on every sample, carried together in one authenticated atomic write;
- `flat`, `current`, `medium`, and `high` profiles in a balanced order, with at
  least three complete 120-second fixture loops per profile;
- authenticated, rate-limited snapshots from the same bounded firmware state
  over BLE-pinned HTTPS or BLE;
- internal RAM, DMA-capable internal RAM, and PSRAM free/largest-block floors
  and monotonic-decline checks;
- zero tolerated measurement-window BLE-crypto low-DMA rejections or
  operation failures;
- render/building/display timings, UI and GPS gaps, render job outcomes,
  building selection/reach, quota limiters, allocation fallback, GPS packet
  cadence, route-marker freshness, reset identity, and remote-debug capture
  overhead;
- DEBUG-app replay-timer lateness plus cumulative, class-bounded BLE queue,
  coalescing, backpressure, in-flight acknowledged-write, completion, error,
  and timeout evidence; these fields contain no characteristic values,
  credentials, network details, or protected payloads;
- frame-service snapshot-lock wait, CRC time, expected/actual body bytes, TLS
  write calls, short/zero writes, active TLS-write time, no-progress wait, and
  intentional inter-chunk delay;
- four deterministic screenshots per comparison window, each captured after
  and timestamp-bound to its observed route marker;
- absolute and relative rejection gates, a Pareto frontier, and a 300-second or
  longer soak of the selected candidate;
- JSON, CSV, Markdown, and PNG evidence tied to device, board, firmware commit,
  build profile, boot, map manifest receipt, route hash, tuning fingerprint,
  run ID, and repeat number.

The experiment does not automate AMOLED motion/tearing, color, daylight
readability, physical touch, natural Core Location/BLE jitter, battery or
thermal impact, or acceptance on both display targets. Those remain manual
gates after the automated report passes.

## Profiles under test

All profiles retain the total building limits of 96 records, 8192 points, and
220000 projected pixels. They vary only the subset admitted for extrusion:

| Profile | Extruded records | Extruded points | Extruded pixels |
| --- | ---: | ---: | ---: |
| `flat` | 0 | 0 | 0 |
| `current` | 32 | 3072 | 90000 |
| `medium` | 40 | 3840 | 112500 |
| `high` | 48 | 4608 | 135000 |

Profiles are session-scoped and RAM-only. The runner performs a checked
`current` cleanup window on success and a best-effort cleanup after setup or
transport failure. Disconnecting, ending remote debug, or ending an ordinary
replay also restores `current`; the experiment never writes a preference or
changes the production default. Firmware likewise restores `current` if a
queued window cannot be applied because its session or active-map identity is
no longer valid.

The total quotas remain authoritative even in dense scenes. Firmware sorts the
bounded bounds-based candidate set by rider distance and stops exact ring
projection once those same record/point/pixel quotas are full; farther records
cannot affect nearest-first admission. Polygon scanline workspace is reused for
the frame. The immutable frame projection caches its zoom and rotation
coefficients instead of repeating double-precision trigonometry for every
feature point, and variable frame scratch plus JSON escaping avoid short-lived
internal-RAM allocations. These are output-preserving latency and headroom
controls, not hidden profile or gate changes.

## Prerequisites

1. Identify whether the connected device is the 1.75-inch or 2.06-inch board.
   Build and flash the matching `*_REMOTE_DEBUG` profile for the automated
   sweep. Never infer the board from a transient serial path.
2. Install the exact Shanghai map artifact that will be supplied to the runner.
   Keep its signed `.bmap` artifact, its retained-path ZIP with one root
   `manifest.json`, or the retained manifest JSON. The runner reproduces the
   receipt used by that install path and refuses to start a measurement window
   unless the active map ID and receipt match.
3. Connect an authenticated Debug build of the iPhone app. Put the Bike Computer
   itself on the map-backed navigation screen
   with 3D buildings enabled. The iPhone sends the route window on the app's
   normal two-second cadence and sends the atomic GPS-plus-marker sample at
   1 Hz. CAP2 bit `23` is mandatory so older two-write replay firmware fails
   readiness instead of running an unreliable fallback.
   Stop any active navigation first. While replay is active, a scoped GPS
   override prevents live Core Location fixes from interleaving with the
   fixture; starting navigation stops replay and releases the override.
4. Start **Remote Device Debugging**. Return from its display console to
   **Developer Settings → Renderer Benchmark Replay**, then tap **Run Secure
   Full Sweep**. Keep Settings open and the authenticated iPhone connected;
   the runner keeps the phone awake. Use **Refresh Sweep Readiness** if active
   map or storage status has not arrived. The runner verifies signed map
   coverage and opens and verifies an HTTPS measurement window before replay.
   The manual **Start Pinned 1 Hz Replay** control is for ordinary diagnostics
   firmware, which opens its window over BLE; it is disabled for remote-debug
   builds to prevent accidentally collecting an unmeasured replay.
5. Let the sweep finish automatically (roughly 35 minutes including warmups
   and the five-minute soak), then tap **Share Benchmark Evidence ZIP**.
   **Stop Secure Full Sweep** or leaving Settings requests bounded cleanup and
   exports partial evidence rather than claiming acceptance. Partial exports
   contain an explicitly failed interrupted report and available samples;
   they do not replace a complete sweep. Opening the live console leaves
   Settings and therefore stops the sweep; do not stream it simultaneously.

Replay cadence is owned by a cancellable main-actor async loop, armed before
the first sample. Missed ticks are coalesced instead of sent as a catch-up
burst; stopping or restarting invalidates callbacks from the previous run.
Exports also include `renderer-benchmark-startup.json`: a bounded trace of the
latest 128 startup/warm-up observations, with a discarded-sample count. It
records app scheduler activity, callback/sample counters, BLE queue state,
and device window/marker state when a metrics response is available. Failure
and manual-stop observations are captured before cleanup clears replay state.
These diagnostics distinguish app emission from BLE delivery without exporting
session credentials; they do not substitute for a successful physical sweep.
All app window changes (including setup and cleanup) share a 1.1-second
response-to-request cooldown to respect the firmware's one-second admission
limit. Only explicit `429 renderer_window_rate_limited` responses are retried,
with at most three attempts per admission. Other HTTP failures and ambiguous
network failures are not automatically retried by window admission. Stop or
session revocation during pacing prevents the next normal-run window POST;
bounded cleanup remains separately responsible for restoring Current.
Atomic replay uses the same native GPS write selection as ordinary positions:
acknowledged writes are preferred when supported and fitting. A legacy
write-without-response-only endpoint still respects transport credits, and a
sample that fits neither native mode is rejected rather than split or sent on
the navigation channel. ATT completion never substitutes for a device marker.

For a separately authorized external automation
   harness, put the Mac on the reported LAN or device-hotspot network and store
   `baseUrl`, `tlsCertificateSha256`, and `token` in a mode-`0600` JSON session
   file as described in [Remote device debugging](remote-device-debugging.md).
   The ordinary iOS console intentionally does not export this file. Do not
   paste the token into logs or reports.

The built-in route fixture is
`ios-app/BikeComputer/BikeComputer/Resources/renderer-benchmark-shanghai-v1.json`.
Its ID is `shanghai-jingan-renderer-v1`; its SHA-256 is
`0fec6228e89cdb6841b971226c5fdedcc5e711dcb9b0e72bcaf95da4f6452f64`.

## External automation harness

The app's built-in sweep above needs no exported credentials or Mac runner.
The CLI below additionally requires a separately provisioned, authenticated
atomic replay source. The app's ordinary manual replay button is not that
source on remote-debug firmware. Never run two window controllers together.

From the repository root:

```sh
python3 esp32/tools/renderer_benchmark.py \
  --session-file /path/to/device-debug-session.json \
  --map-fixture /path/to/shanghai-map.bmap \
  --output /path/to/renderer-benchmark-output
```

The defaults are three balanced repeats, 120-second comparison windows, four
checkpoint screenshots per window, and a 600-second soak. A full issue #210 run
requires all four profiles, at least three repeats, one complete 120-second
fixture loop per window, screenshots, and a soak of at least 300 seconds.

For wiring or fixture development only, `--allow-partial` permits shorter runs,
a subset of profiles, no soak, or `--skip-screenshots`. Partial output is not
acceptance evidence.

The output directory must be empty. A completed sweep writes:

- `renderer-benchmark.json`: identities, exact fixtures and gates, bounded time
  series, per-run failures, aggregates, Pareto frontier, and soak result;
- `renderer-benchmark.csv`: one compact summary row per comparison/soak run;
- `renderer-benchmark.md`: a reviewable result table, failures, screenshots,
  and remaining physical gates;
- `screenshots/*.png`: target-oriented checkpoints whose rotation matches the
  browser view; the JSON records each frame timestamp, marker timestamp,
  capture lag, byte count, and SHA-256 digest.

Exit status `0` means every automated gate passed, `2` means the run completed
but at least one gate rejected it, and `1` means setup, identity, transport, or
schema validation failed. A reset, changed boot identity, wrong map receipt,
stale/missing fixture markers, missing samples/screenshots, or malformed
snapshot fails rather than producing an optimistic ranking.

## Predeclared gates

The checked-in gate file is
`esp32/tools/renderer_benchmark_gates.json`. Its initial safety floors include
32 KiB free/16 KiB largest internal-RAM block, 8 KiB free/2 KiB largest
DMA-capable block, and 1.5 MB free/750 KiB largest PSRAM block. The DMA floor
protects task-stack and hardware-crypto allocations that cannot fall back to
PSRAM; any crypto headroom rejection or operation failure also rejects the
run. Every render request captures its diagnostics-window ID and only job
events carrying the active ID enter that window's counters. Work started before
a profile transition therefore cannot appear as a completion or publication
in the next run. The snapshot envelope timestamp is captured under the same
critical section as the copied route marker, so a snapshot cannot contain a
marker newer than its own timestamp. It requires a dense view
(at least 40 median candidates, 24
selected buildings, and 16 extrusions in every non-flat profile), so a wrong
map, screen, or disabled-3D setup cannot pass as a useful baseline. It also
rejects monotonic memory loss, allocation fallback,
renderer invariant failures, excessive stale/cancelled/interrupted work, route
marker loss, incomplete wall-clock route progress, or staleness (2.5-second age
and 4-second progress limits), large UI/GPS gaps, and display/render latency
beyond the declared limits. Candidate profiles must preserve headroom and latency relative to
`current` while gaining at least 5% building reach.

These are intentionally predeclared so results cannot be judged against a
moving target. If physical evidence shows a threshold should change, update it
in a separate reviewed change before rerunning the experiment.

Per-window memory minima remain the absolute-floor and within-window trend
evidence: a transient low watermark can still fail the run or expose unsafe
headroom. Cross-run retained-allocation and fragmentation checks use each
run's terminal current free and largest-block values, ordered by repeat. They
ignore one largest step as a possible bounded cache or allocator transition,
but fail when meaningful decline continues beyond that step and the existing
per-region allowance. This distinction does not weaken the absolute floors or
the 20-sample within-window leak detector.

New diagnostic firmware also attributes the first observation of each DMA
window minimum to a bounded phase (`session_start`, `session_end`,
`window_start`, `periodic`, `render_complete`, or `metrics_snapshot`), device
uptime, the observed value, and whether a checkpoint frame transfer was active.
Equal observations retain the original attribution. These fields identify
where transient pressure was first observed without exporting credentials,
payloads, certificates, pins, or allocator traces.

## Confirm the winner without remote-debug overhead

After a remote-debug report selects a Pareto candidate, flash the corresponding
ordinary developer/diagnostic build for the same board and firmware commit.
The browser service is absent, but CAP2 bits 18 and 23 expose bounded metrics
and atomic replay over the authenticated BLE session. Keep map, firmware, and
debug transfers stopped;
firmware rejects a new ordinary window and ends an active one if any device
transfer becomes active.

1. In **Renderer Benchmark Replay**, select the remote report's candidate under
   **Ordinary Profile** and start the replay.
2. Let it run for at least 110 seconds. The app defers the first snapshot until
   the BLE window is active, then requests one every five seconds while
   continuing the exact 1 Hz fixture. This provides the 20 retained samples
   required by the shared memory-trend gate, with at least 60 seconds between
   the first and last snapshots.
3. Stop the replay and tap **Copy Ordinary Capture**. Save the clipboard JSON to
   a file without editing it.
4. Evaluate it against the original report and exact map artifact:

```sh
python3 esp32/tools/renderer_benchmark.py \
  --map-fixture /path/to/shanghai-map.bmap \
  --ordinary-capture /path/to/ordinary-capture.json \
  --comparison-report /path/to/remote-output/renderer-benchmark.json \
  --output /path/to/ordinary-confirmation-output
```

The evaluator binds the ordinary capture to the same device, board, firmware
commit, map receipt, route hash, tuning definition, and Pareto-selected profile.
It applies the same absolute and memory-trend gates and rejects remote-debug
build identities. It writes `ordinary-renderer-confirmation.json` and
`ordinary-renderer-confirmation.md`.

## Final physical matrix

Only after both automated reports pass, repeat the winning profile on each
supported board and record:

- 1.75-inch and 2.06-inch: motion/tearing, color, brightness, daylight clutter,
  physical touch, and a natural outdoor route with ordinary GPS/BLE jitter;
- battery and temperature impact over a representative ride;
- any visual regression visible in the checkpoint locations.

Keep the candidate session-scoped until these checks pass and a separate PR
deliberately changes the default quota.
