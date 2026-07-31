# Firmware map-render scheduler

The firmware retains every accepted GPS fix for telemetry and the current
position marker, but it no longer treats each fix as a request to read map data
and regenerate the vector-map background.

## Default policy

An ordinary follow-mode GPS update regenerates the base map only when both of
these conditions are true:

- at least 750 ms has passed since the last completed base-map render; and
- position moved at least 8 m, or course-up heading changed at least 12 degrees.

North-up ignores heading-only changes. A manually panned map continues to move
its position marker without recentering or regenerating its base map. Course-up
rotation remains eligible while panned because it affects the whole visible
map.

Route, style, zoom, screen, and recovery requests bypass the GPS cadence and
threshold gates. A failed/interrupted render retains its original pending
reason and adds `recovery` for the next attempt.

## Separation of work

The LVGL owner performs four independent operations:

1. ingest the latest GPS model (outside LVGL);
2. apply lightweight telemetry and marker updates;
3. apply navigation/maneuver overlay changes immediately; and
4. ask the pure `map_render_policy::Scheduler` whether the vector background
   is due.

Only a completed base-map generation advances the scheduler baseline. This
prevents a blocked or interrupted render from dropping pending work.

## Diagnostics and validation

`PWRMET` schema version 2 reports map-render reasons separately as `position`,
`route`, `style`, `heading`, `zoom`, `screen`, `recovery`, and `other`.

The host policy test covers movement, cadence, heading wraparound, stationary
course noise, forced changes, retry retention, `millis()` rollover, and a
deterministic 60-second 4 Hz GPS replay. Physical GPX replay, visible-position
latency, gesture behavior, and both-board display validation remain required
before the stacked battery work leaves draft status.
