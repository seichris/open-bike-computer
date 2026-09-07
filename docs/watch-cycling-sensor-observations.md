# Watch-owned cycling sensor discovery

Issue: #383. Implementation baseline: `44e0df3bf87cce1aca0c4da9d5d7b776f1823c1b`.

## Ownership and data flow

The accessory remains paired to Apple Watch. HealthKit workout snapshots remain
its observation source. Watch-to-ESP32 workout delivery and mirrored numeric
metrics are unchanged. Nothing in this change scans for or connects an iPhone
Bluetooth peripheral, invents a physical accessory identity, or enrolls a sensor
automatically.

`WatchAppDelegate` observes the local workout envelope independently of mirror
transport success. It derives a `WatchCyclingSensorObservationV1` containing only
schema version, workout identity/start/capture dates, active state, and the
original cadence/power sample timestamps. The original sample values, names,
peripheral identifiers, heart rate, and route data are not copied into this
channel. Cadence and power remain separate logical capabilities unless the user
explicitly configures otherwise.

The existing `WatchConnectivityCoordinator` is still the sole Watch WCSession
owner. Its bounded publisher merges the observation under
`watchCyclingSensorObservation.v1` into `session.applicationContext`. Existing
metadata and HealthKit-setup fields survive both directions of the merge.
Activation, not reachability, gates submission. First observations and lifecycle
or capability changes are immediate when the transport permits; timestamp-only
refreshes are coalesced to one every two seconds, including a trailing flush.
A failed submission retains only the newest pending value and retries with
2–30-second backoff. It is never marked published on failure. New offers do not
reset the retry deadline. The in-memory pending value is reconstructed from the
workout after process recovery; raw workout metrics are not persisted here.

`PhoneWatchConnectivityCoordinator.refreshState` reads the latest
`receivedApplicationContext` on activation as well as delivery. Its current-value
publisher is bound alongside `WorkoutMetricsStore` before the iPhone UI starts.
Opening the iPhone after a sensor began reporting therefore consumes fresh
cached evidence without needing a mirrored workout or a subsequent callback.
Missing/invalid context or an unavailable paired app withdraws only the Watch
source. The original mirrored observation path remains compatible with an older
Watch app that does not publish the new key.

## Freshness and lifecycle invariants

`CyclingSensorObservationReducer` is the single source-independent admission and
lifecycle policy. Discovery requires both a capture and a sample no older than
five seconds, with no future timestamps. Accepted samples may report for ten
seconds from their **original sample time**, not their delivery time. An expiry
task clears published reporting and prompts even when no more callbacks arrive.
Recently observed enrollment candidates retain the existing 30-minute grace
period; that is not permission to label them as currently Reporting.

Mirror idle, stale, or disconnected means that one transport is unavailable. It
is not a Watch workout-end event. Losing that source neither clears independent
Watch evidence nor resets the workout-scoped prompt dismissal. Observations from
both paths update one candidate per capability; enrollment remains explicit.

An explicit ended/failed workout observation retires its session and removes
both sources' reporting immediately. The publisher uses the same lifecycle gate
so a late active callback cannot overwrite a not-yet-delivered end context. Late packets cannot reopen that same
session. A newer session is identified by a later workout start, and each source
also has a capture-time watermark. Rejected out-of-order packets do not mutate
the selected session. A confirmed Watch idle state publishes an inactive
tombstone; the initial idle value is deliberately suppressed while HealthKit
recovery is unresolved. Clock skew or stale delivery fails closed rather than
extending freshness.

WatchConnectivity application context is best-effort latest-state delivery, not
a guaranteed low-latency stream. A delayed packet may be rejected and discovery
may wait for another fresh observation. If an end cannot be delivered, the phone
still expires the previously admitted evidence; it does not keep Reporting
indefinitely. Test this delivery behavior on real paired devices before release.

## Regression tests

Run the Foundation-only contract, reducer, and actual publication-adapter tests
on Swift 6.2 or newer (Linux or macOS):

```sh
ios-app/scripts/run-cycling-sensor-observation-tests.sh
```

The suite covers codec bounds/version/date validation, context merging, original
timestamps, cold-cache staleness, both source lifecycles, terminal/replay ordering,
atomic rejection, sender-side terminal replay protection, publication before
activation, coalescing, retry backoff,
latest-only retention, and a real trailing publication timer.

On macOS, run the existing full host suite:

```sh
ios-app/scripts/run-navigation-tests.sh
```

It also runs `CyclingSensorObservationIntegrationTests` against the production
sensor coordinator/store, actual `WorkoutMetricsStore` publication, and a
current-value Watch-observation publisher. These cover cached launch, all three
unavailable mirror states, dual-source deduplication, explicit logical enrollment,
persisted dismissal, terminal retirement, stale/future/replayed data, and actual
silent-source expiry. This boundary test does not pretend to simulate WCSession
OS delivery or Bluetooth hardware.

Build the app using `ios-app/scripts/xcodebuild-cli.sh`, as required by AGENTS.md.
The new WorkoutShared files use the existing synchronized Xcode groups.

## Paired-device acceptance before release

1. Pair a cadence sensor on Watch, start a cycling workout there, and confirm
   cadence still appears on Watch and ESP32 with the iPhone mirror unavailable.
2. Open iPhone My Sensors / Connect new. A fresh logical cadence candidate must
   appear. Repeat with iPhone launched after cadence was already being received.
3. Connect it explicitly once, restore/disconnect the mirror, and confirm there
   remains one enabled logical profile with no duplicate prompt/candidate.
4. Stop sensor reports. Reporting and its prompt must clear without navigating
   away. A recently seen enrollment candidate may remain during its grace period.
5. End/discard the workout on Watch. Reporting clears on receipt of the tombstone;
   if delivery is unavailable it expires locally. Reopening the phone or receiving
   an older mirror packet must not bring that workout's Reporting state back.
6. Verify metadata/setup/route synchronization and Watch-direct ESP32 cadence
   continue to work. Exercise Watch recovery and a new workout after a previous
   prompt was dismissed. No hardware flashing or production ride automation is
   required or authorized by this PR.
