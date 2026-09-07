# Ride automation trace format

Ride automation profile changes must be supported by replayable evidence.
Production firmware remains feature-off. Internal development profiles retain
shadow traces and may exercise the gated end-to-end control path.

## Privacy and schema

New traces use one JSON object per line with `schema: 4` and `profile: 4`.
Schema 1 through 3 fixtures remain replayable; a schema-1
positive HDOP value is
converted at the compatibility boundary to the original `HDOP * 5 m`
horizontal-uncertainty estimate. Traces may contain only
normalized policy inputs. Do not record coordinates, raw accelerometer samples,
raw gyroscope samples, or an unbounded sensor stream. The replay loader uses a
strict allowlist at the record, settings, evidence, metric, policy-output, and
counter levels. Unknown fields are rejected; a small explicit denylist adds a
second check for common private/raw field names.

Each record has this shape:

```json
{"schema":4,"profile":4,"label":"sensorless-stop","t_ms":5000,"lifecycle":"running","settings":{"start_mode":"ask","auto_pause":true},"evidence":{"watch_gps_mps":{"value":0.1,"age_ms":0},"watch_gps_fix_valid":true,"watch_gps_horizontal_uncertainty_m":5.0,"watch_gps_epoch":7,"watch_gps_sequence":6},"expected":"pause"}
```

Allowed lifecycle values are `idle`, `running`, `auto_paused`,
`manual_paused`, and `finished`. Allowed start modes are `off`, `ask`, and
`automatic`. A numeric metric can be a number (age zero), an object containing
`value` and `age_ms`, or absent. GPS validity and stationary flags can be a
Boolean (age zero), a timed object, or absent. Every age is a `uint32` and trace
timestamps must move monotonically, allowing a legitimate `uint32` wrap.
Absence stays unavailable; it is never converted to a zero measurement.
`gps_source` is `0` none, `1` hardware NMEA, or `2` authenticated BLE. Exact
coordinates remain forbidden.
Watch evidence adds speed, fix validity, horizontal uncertainty, and paired
nonzero producer epoch/sequence values. The identity is privacy-safe and lets
replay prove that duplicate BLE delivery did not advance a candidate.

Firmware capture emits the same input fields plus an `output` object containing
the shadow decision, evidence mask, sequence/timing, and bounded counters. Add
the human-labelled `expected` field before using a captured trace as an
acceptance fixture; no conversion step is required.

`expected` is one of `none`, `start`, `pause`, or `resume`. The replay command
fails when an output differs from its labelled expectation. Its JSON summary
reports false starts, false pauses, missed/wrong transitions, and total/sample
latency for every emitted transition type.

## Replay

From `esp32/`:

```sh
python3 tools/ride_trace_replay.py \
  tools/tests/fixtures/ride_automation/synthetic-regression.jsonl
```

The Python wrapper validates privacy/schema rules and compiles the small replay
driver. The driver executes `RideAutomationPolicy`, so replay does not maintain
a second detector implementation.

`aug-29-coasting-regression.jsonl` is a synthetic, privacy-safe model of the
reported false-pause class, not a capture from the historical ride. Its cadence
is zero while trustworthy GPS plus IMU still show movement, then wheel evidence
drops out before a genuine stopped control. The pre-profile-3 direct-sensor
rule would have paused after five seconds of zero cadence under those modeled
inputs; profile 3 keeps the ride running and pauses only after ten continuous
seconds of qualified GPS-plus-IMU stopped evidence.
`watch-gps-sensorless-regression.jsonl` covers profile 4's primary five-second
Watch stop and two-second Watch resume without wheel, cadence, power, or IMU.

## Physical trace gate

Before profile 4 can control a ride in production, collect and label traces for:

- genuine starts with no cycling sensor, cadence, wheel speed, and both;
- short stops and traffic lights of 10, 30, 90, and 180 seconds;
- walking/carrying the bike and loading it into a vehicle;
- city/highway car travel, bus/train travel, elevators, and escalators;
- stationary GPS drift, urban canyons, tunnels, and sensor dropout; and
- rough roads, cobbles, desk vibration, maintenance spins, and coasting.

For each trace, retain only the normalized evidence above and record false
starts, false pauses, missed transitions, start latency, pause latency, and
resume latency. Production firmware must keep the capability and control path
absent until the physical validation and resource-impact gates in the
implementation plan pass on both supported Waveshare boards.
