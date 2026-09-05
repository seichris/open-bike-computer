# Bicino auto-pause and distance consistency

This contract addresses the code-level false-pause/distance-gap class reported
after the August 29 ride and adds the profile-4 Watch-GPS-primary path without
enabling ride automation in production profiles. No immutable sensor trace from
that ride is available, so this document does not claim its exact historical
cause. It covers sensorless rides, coasting, sensor dropout, uncertain workout
provenance, and route continuity.

## Demonstrated code-level risks

Three independent shortcuts can combine into an inconsistent outcome:

1. Watch `HKQuantityTypeIdentifier.cyclingSpeed` aggregates were labelled as a
   paired cycling sensor even though HealthKit delivery alone did not prove the
   sample came from the rider's paired sensor. Firmware therefore selected the
   direct-sensor branch from unconfirmed provenance.
2. The direct-sensor pause branch treated zero cadence as definitive stopped
   evidence. A coasting rider legitimately has zero cadence while GPS and IMU
   show movement, so five seconds of cadence zero could pause the workout.
3. `WatchRouteRecorder` dropped every location while the session reported
   paused and broke its distance segment. A false pause therefore removed real
   route points and introduced a cycling-distance gap even after motion resumed.

Separately, uncorroborated Watch session callbacks defaulted to `manual`. That
made recovery provenance appear stronger than the evidence and could hide
whether an automatic transition was safe to reverse.

## Source and stop policy

| Available evidence | Pause rule |
| --- | --- |
| Qualified raw Watch workout GPS | Primary path: below `0.8 m/s` across distinct location samples spanning five seconds, with no gap over three seconds. |
| Fresh, definitively stopped wheel speed | Five continuous seconds on the short path. |
| Wheel moving | Movement veto; cancel/reset a stopped candidate. |
| Cadence moving | Movement veto; may start/resume. |
| Cadence zero or cadence only | Not stopped evidence; require GPS plus IMU fallback. |
| Watch GPS unavailable and no cycling sensor | Require ten continuous seconds of trustworthy device GPS plus IMU stopped evidence. |
| Wheel dropout | Reset the short candidate; require a new qualified fallback window. |
| Trustworthy GPS plus IMU movement | Movement veto, including while cadence is zero. |
| Missing, stale, conflicting, or poor-quality evidence | Reset the candidate; never convert unavailable to zero. |

Generic HealthKit cycling speed remains eligible for display for five seconds,
but its source flag is HealthKit. The paired-speed flag is reserved for an
explicitly confirmed paired sensor. Paired speed still has presentation
precedence when that future confirmed source is available.

Profile 4 retains profile 3's direct/fallback thresholds and adds qualified raw
Watch workout GPS as the normal active-workout source. Watch GPS is fresh for
three seconds, requires horizontal accuracy no worse than `12.5 m`, pauses
below `0.8 m/s` after a five-second source-sample span, and resumes at or above
`2.0 m/s` after two seconds. A new sample epoch, stale/poor-quality data, a gap
over three seconds, or a regressing sequence resets the Watch candidate; BLE
heartbeats and retries cannot advance it. Wheel stopped remains below
`0.5 m/s`, wheel/cadence movement at or above `1.5 m/s`/`20 rpm`, qualified
GPS stopped below `0.8 m/s`, and GPS resume at or above `2.0 m/s` with moving
IMU evidence.

## Route and provenance contract

Pause/resume does not itself break the current route segment. While the workout
reports paused, a point is accepted only when either:

- reported speed is at least `0.8 m/s` with horizontal accuracy no worse than
  25 metres; or
- displacement is at least both 10 metres and the combined uncertainty of the
  previous and current points, and computed speed is at least `0.8 m/s`.

Accepted points preserve HealthKit route geometry and cycling distance through
a false pause. Stationary drift, duplicate/regressing time, poor quality, and
delayed batches remain rejected.

Transition origin has four durable values: `manual`, `automatic`, `system`, and
`unknown`. Only explicit rider control is manual. An automatic marker stores a
privacy-safe schema-2 diagnostic bundle: detector profile, evidence mask,
source-health mask, candidate-began seconds, and decided-at seconds. Legacy
schema-1 markers remain readable; partial schema-2 bundles fail closed.

## Replay and acceptance evidence

The privacy-safe fixtures contain no coordinates or raw HealthKit data.
`aug-29-coasting-regression.jsonl` is a synthetic, normalized scenario shaped
to the reported failure class; it is not a capture from the historical ride.
It covers cadence-zero coasting, wheel dropout, and a genuine fallback stopped
control. `watch-gps-sensorless-regression.jsonl` simulates a sensorless Watch
ride and proves the five-second pause and two-second resume paths from distinct
source samples.

Host acceptance covers the sensor matrix, trace replay, wire origin values,
HealthKit-versus-paired provenance, transition recovery diagnostics, paused
route drift rejection, and distance continuity. A generic iOS/Watch build
proves source integration only; it does not establish physical behavior.

Before merge, the owner must test a real Watch and supported Bicino board with:

- pedalling, coasting, cadence-only, speed-only, and combined sensors;
- no cycling sensor, wheel dropout/reconnect, and sensor disagreement;
- short stops, slow crawl, genuine five-second Watch stops, fallback ten-second
  stops, Watch/device GPS drift, weak GPS, delayed samples, and Watch relaunch;
- automatic versus manual pause/resume and interrupted recovery; and
- route/distance continuity across false-pause movement with stationary drift
  excluded.
