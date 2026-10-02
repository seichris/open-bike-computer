# Workout finish and Ride Stats follow-up

This change is stacked on the round-layout/tabular-numeral fix in PR #443.
Chris reported testing that earlier version successfully on a device; that
report does not qualify the new changes below.

## Firmware

A right-hand altitude value shares the largest available **common** font that
fits both its own circle-safe rectangle and the numeric field immediately to
its left. This includes Smart fields resolving to altitude and a left heart
icon's reserved space. Both use the same font object. Tabular digits remain
stable within a numeric format; time/hour, digit-count or sign changes may
require a different tier. Empty, unavailable or zone-strip neighbors do not
force a numerical pairing. Legacy and configurable Workout Stats use the same
policy. The 2.06-inch rectangle keeps its existing geometry.

## Watch finish controls

The red STOP action calls End and Save directly. A gray text Discard Workout
action is below Settings. Destructive discard still has the existing final
Health disclosure/Keep Riding confirmation, captured to a specific session;
there is no intermediate save/discard choice from STOP.

A confirmed discard automatically leaves the transient Discarding view after
terminal publication, durable archival and detached-session cleanup finish.
There is no post-discard Done or Retry Recovery action. Save error and retry
behavior is unchanged.

## Discard recovery defect

A reproducible failure path in the previous code built a rich statistics
snapshot after calling `HKLiveWorkoutBuilder.discardWorkout()`. Its later
elapsed-time sample could exceed the wall time at the previously chosen stop
date; stale metrics/zone data could also invalidate the terminal envelope.
Terminal publication then failed, and retries reused the same invalid
confirmed snapshot. Without logs from the reported Watch, this is not asserted
to be the only possible cause of that device's recovery failure.

Discard now produces a minimal explicit terminal control snapshot retaining
session identity, start time and any durable terminal error, but no builder
statistics, route coordinates or zones. It never reads a discarded builder
to create the discard summary. Terminal-envelope validation stays strict.

Transient persistence failures for discard are retried automatically with
exponential backoff capped at 30 seconds, including beyond the former three
attempts. Pre-terminal retries are session/disposition fenced and use the
existing finalization/recovery operations. The retry does not invoke save,
clear a pending identity, bypass a tombstone write or force new-ride admission.
Save retains its existing bounded/manual cleanup. A permanent storage or
HealthKit failure cannot honestly be reported as a completed discard: the
operation remains safely pending without asking the rider to press recovery.

## Required verification

Run the root Python tests, both GUI-layout host variants, Ride Stats widget
tests, generated-preview check, shared workout contracts and Watch platform
tests. PR CI must compile the actual iPhone/Watch views and affected firmware.

Before release, test on the 1.75-inch device and Watch: direct STOP saves one
workout; canceling the final discard warning keeps riding; confirming discard
saves no workout/route and returns to the start screen automatically; another
ride starts normally; one- and ten-hour boundaries and negative altitude
remain visible; iPhone preview agrees with custom field permutations.
No firmware flash, app installation, merge or deployment is authorized by
these source changes alone.
