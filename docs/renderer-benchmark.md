# Renderer building benchmark

This experiment ranks bounded 3D-building profiles on a physical Bicino. It
automates the repeatable part of issue #210: exact route replay, profile order,
RAM and renderer telemetry, checkpoint screenshots, rejection gates, Pareto
selection, soak testing, and machine-readable reports. A passing report is a
candidate selection, not permission to change the default profile.

## What is automated

- one checked-in Shanghai route with 120 exact 1 Hz GPS samples and a SHA-256
  marker on every sample, serialized after that sample's GPS write;
- `flat`, `current`, `medium`, and `high` profiles in a balanced order, with at
  least three complete 120-second fixture loops per profile;
- authenticated, rate-limited snapshots from the same bounded firmware state
  over BLE-pinned HTTPS or BLE;
- internal RAM, DMA-capable internal RAM, and PSRAM free/largest-block floors
  and monotonic-decline checks;
- zero tolerated BLE-crypto low-DMA rejections or operation failures;
- render/building/display timings, UI and GPS gaps, render job outcomes,
  building selection/reach, quota limiters, allocation fallback, GPS packet
  cadence, route-marker freshness, reset identity, and remote-debug capture
  overhead;
- four deterministic screenshots per comparison window, each captured after
  and timestamp-bound to its observed route marker;
- absolute and relative rejection gates, a Pareto frontier, and a 300-second or
  longer soak of the selected candidate;
- JSON, CSV, Markdown, and PNG evidence tied to the clean iOS Git/component
  identity, device, board, firmware commit, build profile, boot, map manifest
  receipt, native-SDMMC state, route hash, tuning fingerprint, run ID, and
  repeat number.

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

## Prerequisites

1. Identify whether the connected device is the 1.75-inch or 2.06-inch board.
   Build and flash the matching `*_REMOTE_DEBUG` profile for the automated
   sweep. Never infer the board from a transient serial path.
2. Perform the required full power cycle, then confirm authenticated BLE status
   reports `storage.backend=sdmmc` and `storage.powerCycleRequired=false`. The
   in-app controller refuses to start or continue without both values.
3. Install the exact Shanghai map artifact used for the benchmark.
   The in-app controller reads the active map ID and signed manifest receipt
   directly from authenticated BLE state and refuses to start unless both are
   available. Keep the Bike Computer on the Shanghai map-backed navigation
   screen with 3D buildings enabled.
4. Connect an authenticated Debug build of the iPhone app and stop any active
   navigation or manual renderer replay. Start **Remote Device Debugging** and
   leave the authenticated iPhone connected over BLE for the entire run.
5. Keep **Developer Settings → Renderer Benchmark Replay** open while the sweep
   runs. The controller keeps the iPhone awake, starts the checked-in route
   replay itself, and prevents live Core Location fixes from interleaving with
   the exact 1 Hz fixture.

The benchmark does not copy a URL, TLS fingerprint, or transfer token to a Mac.
It constructs the pinned `URLSession` from the active `DeviceTransferSession`,
keeps the token and certificate pin in app memory, rejects redirects, caches,
cookies, proxies, and cellular transport, and exports none of those session
values. Ending BLE or remote debug revokes the run.

The built-in route fixture is
`ios-app/BikeComputer/BikeComputer/Resources/renderer-benchmark-shanghai-v1.json`.
Its ID is `shanghai-center-renderer-v1`; its SHA-256 is
`d5171f6b30478a09948381bbdb86da33752bc646fa6077153f69a4bd840eb36e`.

## Run the automated sweep

In **Developer Settings → Renderer Benchmark Replay**, tap **Run Secure Full
Sweep**. The app performs three balanced repeats, twelve 120-second comparison
windows, four checkpoint screenshots per window, Pareto selection, and a
300-second soak. Warm-up, window acknowledgement, and report generation add a
few minutes; budget roughly half an hour and keep both screens awake and near
each other. Tap **Stop Secure Full Sweep** to request a checked `current`-profile
cleanup before the replay ends.

The in-app acceptance path is deliberately full-only: it has no shortened-run,
profile-subset, no-soak, or screenshot-skip switch. When it finishes, tap
**Share Benchmark Evidence ZIP**. The stored ZIP contains:

- `renderer-benchmark.json`: identities, exact fixtures and gates, bounded time
  series, per-run failures, aggregates, Pareto frontier, and soak result;
- `renderer-benchmark.csv`: one compact summary row per comparison/soak run;
- `renderer-benchmark.md`: a reviewable result table, failures, screenshots,
  and remaining physical gates;
- `screenshots/*.png`: target-oriented checkpoints whose rotation matches the
  browser view; the JSON records each frame timestamp, marker timestamp,
  capture lag, byte count, and SHA-256 digest;
- `manifest.json` and `checksums.sha256`: bounded file identities for review.

The app reports **Automated gates passed** only when every comparison and soak
gate passes and the checked `current` cleanup is observed. A reset, changed boot
identity, wrong map receipt, stale/missing fixture markers, missing samples or
screenshots, malformed metrics, revoked session, or cleanup failure fails rather
than producing an optimistic ranking. A completed ZIP is non-secret evidence;
it is still not physical acceptance.

`esp32/tools/renderer_benchmark.py` remains the protocol reference, host-tested
evaluator, and ordinary-capture evaluator. Its direct remote endpoint mode is
not the ordinary iOS workflow and must not be fed credentials copied from the
app.

## Predeclared gates

The canonical checked-in gate file is
`esp32/tools/renderer_benchmark_gates.json`; the iOS Debug target embeds an
exact byte-for-byte copy and host tests reject drift. Its initial safety floors
include 32 KiB free/16 KiB largest internal-RAM block, 8 KiB free/2 KiB largest
DMA-capable block, and 1.5 MB free/750 KiB largest PSRAM block. The DMA floor
protects task-stack and hardware-crypto allocations that cannot fall back to
PSRAM; any crypto headroom rejection or operation failure also rejects the
run. It requires a dense view (at least 40 median candidates, 24
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

## Confirm the winner without remote-debug overhead

After a remote-debug report selects a Pareto candidate, flash the corresponding
ordinary developer/diagnostic build for the same board and firmware commit.
The browser service is absent, but CAP2 bit 18 exposes the bounded metrics over
the authenticated BLE session. Keep map, firmware, and debug transfers stopped;
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
