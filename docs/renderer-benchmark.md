# Renderer building benchmark

This experiment ranks bounded 3D-building profiles on a physical Bicino. It
automates the repeatable part of issue #210: exact route replay, profile order,
RAM and renderer telemetry, checkpoint screenshots, rejection gates, Pareto
selection, soak testing, and machine-readable reports. A passing report is a
candidate selection, not permission to change the default profile.

## What is automated

- one checked-in Shanghai route with 120 exact 1 Hz GPS samples and a SHA-256
  marker on every sample;
- `flat`, `current`, `medium`, and `high` profiles in a balanced order, with at
  least three runs per profile and 60–120 seconds per comparison run;
- authenticated, rate-limited snapshots from the same bounded firmware state
  over HTTP or BLE;
- internal RAM and PSRAM free/largest-block floors and monotonic-decline checks;
- render/building/display timings, UI and GPS gaps, render job outcomes,
building selection/reach, quota limiters, allocation fallback, GPS packet
cadence, route-marker freshness, reset identity, and remote-debug capture
overhead;
- four deterministic screenshots per comparison window;
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
changes the production default.

## Prerequisites

1. Identify whether the connected device is the 1.75-inch or 2.06-inch board.
   Build and flash the matching `*_REMOTE_DEBUG` profile for the automated
   sweep. Never infer the board from a transient serial path.
2. Install the exact Shanghai map artifact that will be supplied to the runner.
   Keep its signed `.bmap` artifact, its retained-path ZIP with one root
   `manifest.json`, or the retained manifest JSON. The runner reproduces the
   receipt used by that install path and refuses to start a measurement window
   unless the active map ID and receipt match.
3. Connect an authenticated Debug build of the iPhone app. In **Developer
   Settings → Renderer Benchmark Replay**, tap **Start Pinned 1 Hz Replay** and
   leave it running on the map-backed navigation screen with 3D buildings
   enabled. The iPhone sends the route window on the app's normal two-second
   cadence and sends GPS plus the fixture marker at 1 Hz.
4. Start **Remote Device Debugging** and put the Mac on the reported LAN or
   device-hotspot network. Store `baseUrl` and `token` in a mode-`0600` JSON
   session file as described in [Remote device debugging](remote-device-debugging.md).
   Do not paste the token into logs or reports.

The built-in route fixture is
`ios-app/BikeComputer/BikeComputer/Resources/renderer-benchmark-shanghai-v1.json`.
Its ID is `shanghai-center-renderer-v1`; its SHA-256 is
`d5171f6b30478a09948381bbdb86da33752bc646fa6077153f69a4bd840eb36e`.

## Run the automated sweep

From the repository root:

```sh
python3 esp32/tools/renderer_benchmark.py \
  --session-file /path/to/device-debug-session.json \
  --map-fixture /path/to/shanghai-map.bmap \
  --output /path/to/renderer-benchmark-output
```

The defaults are three balanced repeats, 120-second comparison windows, four
checkpoint screenshots per window, and a 600-second soak. A full issue #210 run
requires all four profiles, at least three repeats, 60–120-second windows,
screenshots, and a soak of at least 300 seconds.

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
  browser view.

Exit status `0` means every automated gate passed, `2` means the run completed
but at least one gate rejected it, and `1` means setup, identity, transport, or
schema validation failed. A reset, changed boot identity, wrong map receipt,
stale/missing fixture markers, missing samples/screenshots, or malformed
snapshot fails rather than producing an optimistic ranking.

## Predeclared gates

The checked-in gate file is
`esp32/tools/renderer_benchmark_gates.json`. Its initial safety floors include
32 KiB free/16 KiB largest internal-RAM block and 1.5 MB free/750 KiB largest
PSRAM block. It requires a dense view (at least 40 median candidates, 24
selected buildings, and 16 extrusions in every non-flat profile), so a wrong
map, screen, or disabled-3D setup cannot pass as a useful baseline. It also
rejects monotonic memory loss, allocation fallback,
renderer invariant failures, excessive stale/cancelled/interrupted work, route
marker loss or staleness (2.5-second age and 4-second progress limits), large
UI/GPS gaps, and display/render latency beyond the declared
limits. Candidate profiles must preserve headroom and latency relative to
`current` while gaining at least 5% building reach.

These are intentionally predeclared so results cannot be judged against a
moving target. If physical evidence shows a threshold should change, update it
in a separate reviewed change before rerunning the experiment.

## Confirm the winner without remote-debug overhead

After a remote-debug report selects a Pareto candidate, flash the corresponding
ordinary developer/diagnostic build for the same board and firmware commit.
The browser service is absent, but CAP2 bit 18 exposes the bounded metrics over
the authenticated BLE session.

1. In **Renderer Benchmark Replay**, select the remote report's candidate under
   **Ordinary Profile** and start the replay.
2. Let it run for at least 70 seconds. The app defers the first snapshot until
   the BLE window is active, then requests one every five seconds while
   continuing the exact 1 Hz fixture. Seventy seconds yields at least 60
   seconds between retained snapshots.
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
