# Bicino auto-pause and distance consistency

This contract closes the August 29 false-pause/distance-gap class without
enabling ride automation in production profiles. It covers coasting, sensor
dropout, uncertain workout provenance, and route continuity.

## Root cause

Three independent shortcuts combined into one inconsistent outcome:

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
| Fresh, definitively stopped wheel speed | Five continuous seconds on the short path. |
| Wheel moving | Movement veto; cancel/reset a stopped candidate. |
| Cadence moving | Movement veto; may start/resume. |
| Cadence zero or cadence only | Not stopped evidence; require GPS plus IMU fallback. |
| No cycling sensor | Require ten continuous seconds of trustworthy GPS plus IMU stopped evidence. |
| Wheel dropout | Reset the short candidate; require a new qualified fallback window. |
| Trustworthy GPS plus IMU movement | Movement veto, including while cadence is zero. |
| Missing, stale, conflicting, or poor-quality evidence | Reset the candidate; never convert unavailable to zero. |

Generic HealthKit cycling speed remains eligible for display for five seconds,
but its source flag is HealthKit. The paired-speed flag is reserved for an
explicitly confirmed paired sensor. Paired speed still has presentation
precedence when that future confirmed source is available.

Profile 3 keeps the existing thresholds and hysteresis: wheel stopped below
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

`esp32/tools/tests/fixtures/ride_automation/aug-29-coasting-regression.jsonl`
contains no coordinates or raw HealthKit data. It covers cadence-zero coasting,
wheel dropout, and a genuine stopped control. The pre-profile-3 rule would emit
the false pause after five seconds of cadence zero. Profile 3 emits no pause for
the moving samples and pauses only after the full ten-second qualified stopped
control.

Host acceptance covers the sensor matrix, trace replay, wire origin values,
HealthKit-versus-paired provenance, transition recovery diagnostics, paused
route drift rejection, and distance continuity. A generic iOS/Watch build
proves source integration only; it does not establish physical behavior.

Before merge, the owner must test a real Watch and supported Bicino board with:

- pedalling, coasting, cadence-only, speed-only, and combined sensors;
- no cycling sensor, wheel dropout/reconnect, and sensor disagreement;
- short stops, slow crawl, genuine ten-second stops, GPS drift, and weak GPS;
- automatic versus manual pause/resume and interrupted recovery; and
- route/distance continuity across false-pause movement with stationary drift
  excluded.
