# Workout zones on the bike display (wire version 1)

This extends PR #446 end-to-end without raising the iOS 16.4 / watchOS 10
minimum deployment targets. The new device codec is Foundation-only. Native
HealthKit collection remains SDK- and runtime-gated to watchOS 27; an updated
app running iOS 26 with a supported older Watch uses the existing, explicitly
labelled Bicino maximum-heart-rate fallback. No native power zones, FTP, or
replacement power thresholds are fabricated on older systems.

## Compatibility and rollout

`protocol/ride-ble-contract-v1.json` is authoritative for the wire constants,
capability bit and append-only Ride Stats widget IDs. Generate both languages
with `python3 tools/generate_ride_ble_contract.py`; CI checks generated output.

Client protocol version 26 requests CAP2 bit 28 (`workout_zones_v1`). This
**protocol number is unrelated to iOS 26**. A sender requires that bit, the
native workout characteristic, origin/automation support, application ACK
support and capacity for the largest protected acknowledged member (182
bytes: 132 payload + 28 application header + 22 authenticated overhead).
Both phone-relayed and Watch-direct paths apply that admission policy.

Until the physical matrix passes, firmware advertises and accepts the feature
only in `FIRMWARE_DIAGNOSTICS` profiles. Production profiles omit the bit and
the five new widget capability bits; they keep legacy workout behaviour. Do not
promote this gate merely because host tests pass. No firmware was flashed by
this change, and SDK 27 compilation and physical acceptance remain required.

| Combination | Behaviour |
| --- | --- |
| Updated iOS 26 + supported older Watch + capable development firmware | Versioned, source-labelled Bicino HR configuration; power zone unavailable; watts/cadence unchanged |
| Native-capable updated Watch + updated phone/firmware | Native HR/power groups when HealthKit supplies them |
| Updated app + older/production firmware or insufficient MTU | Original core/extended/origin bytes; no new messages |
| Older app + updated firmware | Original messages and five-zone renderer remain supported |
| New configuration cannot be obtained or a native reading expires | Unavailable current zone, not a silently relabelled native result |

An older *binary* may not edit a screen layout containing newly introduced
widget IDs; the screen-settings capability mask and validation are unchanged.
This is distinct from running the updated app on iOS 26, which understands all
new IDs. Unsupported phone/Watch OS pairings are not promised.

## Why self-contained packets

Each metric carries its exact definition and values together. A cached
configuration plus a short configuration hash would require another ACK,
revision and recovery protocol; losing that cache could silently reinterpret an
ordinal. At most nine zones fit in one bounded BLE value, so self-contained
snapshots make each accepted update atomic, recover after a dropped packet and
avoid fingerprint collisions. They use no persistent configuration cache.

There are at most two additional values at the existing coalesced workout
cadence. The worst case is 264 unprotected payload bytes per update, before
transport overhead. This is a size bound, **not** a measured battery claim.
Long-ride battery, queue latency and combined navigation/transfer load must be
measured before production promotion. No per-sensor-sample timer was introduced.

The Watch remains the workout/zone authority. The iPhone relays validated
snapshots, including when its own OS lacks the new HealthKit API. Both senders
reuse `WorkoutZoneDeviceCodecV1`. Firmware neither runs HealthKit nor reclassifies
Apple's raw HR/power readings. Bicino fallback thresholds come from the
workout's captured maximum-HR profile, not today's changed settings.

## Packet layout

Kind 5, version 1; all multi-byte integers and IEEE-754 binary64 thresholds are
little-endian. The native authenticated workout characteristic carries this
payload; `WTLM` navigation fallback is not extended.

| Offset | Size | Meaning |
| --- | --- | --- |
| 0 | 1 | kind = 5 |
| 1 | 1 | schema = 1 |
| 2 | 1 | metric: 1 HR (BPM), 2 cycling power (watts) |
| 3 | 1 | source: 0 Bicino fallback, 1 HealthKit system, 2 HealthKit user, 3 HealthKit app, 4 HealthKit unknown |
| 4 | 1 | flags: bit 0 final, bit 1 explicit zero first lower bound, bit 2 durations available; others reserved |
| 5 | 1 | count: 3–9, or zero for an explicit unavailable replacement |
| 6 | 1 | current one-based ordinal; zero unavailable |
| 7 | 1 | existing workout session state in low six bits; core/extended pair generation in high two bits |
| 8 | 2 | nonzero short session token |
| 10 | 2 | raw sample age in milliseconds; `FFFF` iff current ordinal is unavailable |
| 12 | 4 | nonzero monotonic zone-update sequence, shared by HR/power for an update |
| 16 | 16 | full workout UUID in canonical byte order |
| 32 | 8 × (count − 1) | finite, positive, strictly increasing interior thresholds |
| following | 4 × count | accumulated time per zone in milliseconds, or `FFFFFFFF` when unavailable |

Length is exactly `32 + 8*(count-1) + 4*count` for a populated packet, at most
132 bytes. Count zero is exactly 32 bytes, flags zero, ordinal zero and
unavailable age. The first lower bound is unbounded unless bit 1 supplies zero;
the last upper bound is unbounded. Interior thresholds retain binary64 precision.
The ordinal comes from HealthKit rather than guessing inclusion at a shared
boundary. Compact range text is display-only and never feeds classification.

Durations are nonnegative, floored to milliseconds and must fit below the
reserved unavailable value. Their sum may not exceed the accompanying active
elapsed time plus one second of wire rounding tolerance. A populated ended
packet must be final with durations and without a current ordinal. Native final
groups originate only from the saved HealthKit workout; live groups and recovery
checkpoints are not relabelled final. Discard emits an explicit empty result.
Bicino source zero is valid only for five HR zones, never for power.

## Admission, recovery and freshness

A valid protected write still needs an authenticated, feature-negotiated
connection and the existing ride lease. Native data is accepted only after the
core/extended pair and origin: token, full UUID, state and nonzero pair generation
must agree. The committed pair generation is stored separately from legacy
source flags; those flags continue to expose only their original metric bits.

A critical `.workoutState` ACK group may contain the original 1–3 members, or,
only with negotiated support, exactly five members in order: core, extended,
origin, HR zones, power zones. It reuses the current application ACK, retry,
lease and authenticated-write machinery. Unknown versions, metrics, source
values, reserved flags, malformed lengths/thresholds/durations and wrong
identity/phase are rejected before zone-state mutation.

The zone sequence increases per writer connection and is not reset on pause,
resume or a settings update. Duplicate sequences do not renew freshness or
replace definitions; older sequences are rejected. Full-UUID replacement and
authenticated reconnection reset zone state. Fresh resynchronization sends full
definitions again rather than reusing encrypted packets or configuration caches.
Sequence exhaustion stops sidecars until reconnect, instead of wrapping.

Freshness is not the transition callback date. The Watch's raw sample age is
validated when encoding and increased with monotonic queue delay immediately
before dispatch/encryption, including application retries. Invalid clocks or a
queue delay of ten seconds clear the current ordinal. Firmware independently
expires power after five seconds, HR after thirty seconds, and either live
highlight after ten seconds without a new zone packet. Local `millis()` wrap is
handled with unsigned elapsed arithmetic. Pause/link loss/failed or incomplete
origin also removes current highlights. Definitions and accumulated totals can
remain available without pretending that a current measurement exists.

A received unavailable sidecar suppresses the legacy zone; an old app that never
sends sidecars retains the legacy five-band path. Recovery may have native
configuration/totals but no valid transition: that remains unavailable rather
than inferred. No health values, thresholds or workout UUIDs are added to logs,
backend services or device persistent storage.

## Display and validation

The existing zone renderer now supports 3–9 segments, reuses the five-color
palette with interpolation, and keeps the five-zone geometry/typography.
Non-five/power strips use compact `Z1` … `Z9` labels; a power strip does not show
a heart icon. Unused segments are hidden when counts shrink. Existing circular
466×466 and rectangular 410×502 slot bounds remain authoritative.

The default HR widget uses the new group when received and labels its source
`HR: Health` or `HR: Bicino`. Additional capability-gated widget IDs are:
17 Power Zone, 18 HR Zone Time, 19 Power Zone Time, 20 HR Zone Range,
21 Power Zone Range. Time/range refer to the current zone; they become unavailable
without a current ordinal. Saved full breakdowns remain in the phone/Watch UI;
this change does not invent a current zone for a completed workout.

Automated acceptance includes independent golden bytes shared by Swift/C++,
legacy-byte comparisons, source/OS fallback, malformed and truncated packets,
full-UUID mismatch, replay without timestamp renewal, pair/phase mismatch,
local-clock wrap, queue expiry, all zone counts and both display layouts.
Existing crypto/scoped authorization, workout lifecycle and Watch adapter tests
must continue to pass. Physical acceptance additionally requires native SDK 27
builds, real HR/power zone transitions, same-zone riding, sensor disconnect,
pause/resume, Save/Discard, reconnection, Watch-direct and phone-relayed rides,
both boards and sustained battery/thermal/queue measurements.
