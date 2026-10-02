# Build evidence and incident replay

`tools/build-and-record-firmware WAVESHARE_AMOLED_175` invokes the repository's
locked firmware build and retains its matching ELF, final linker map and build
manifest. Identify the actual board first. It does not flash the device.

Ordinary builds through `ios-app/scripts/xcodebuild-cli.sh` use the caller's
debug-information settings and perform no symbol collection. Request evidence
with `tools/dev-check --check ios-build-containers --evidence`, or set
`BICINO_COLLECT_BUILD_EVIDENCE=1` for an explicit DerivedData path and BikeComputer
scheme build. Evidence mode requires clean source before compilation and retains
Debug/Release dSYMs. The app code image UUIDs must match its dSYM. Debug builds may put that code
in `BikeComputer.debug.dylib`; the executable launcher is identified separately. The checkout must remain
clean at the same commit throughout the build. Ordinary dirty builds still work
locally. CI uses `--fresh --evidence` and sets `BICINO_REQUIRE_BUILD_EVIDENCE=1`
so missing or mismatched symbols fail validation. Simulator contract builds keep
their existing separate lifecycle.

The default local store is
`~/Library/Application Support/OpenBikeComputer/build-evidence/`. Set
`BICINO_BUILD_EVIDENCE_DIR` to an explicit private store (CI uses runner temp and
uploads artifacts). Symbols are retained under the SHA-256 of a canonical index;
files are hashed before and after copying. Existing records are verified and
never overwritten. `python3 tools/build_evidence.py verify /absolute/path/HASH`
checks the complete record. Retention is local and deliberate; no pruning,
public uploading, device installation or deployment occurs.

Use evidence collection for release/qualification builds and builds chosen for
device debugging. Distinct symbol records accumulate without automatic pruning;
ordinary local builds add no records. `tools/build-and-record-firmware` remains
the explicit firmware build-and-record command; `tools/dev-check --suite firmware
--level full --board 175 --evidence` provides the same strict retention mode.

Firmware observations record actual `coreCache` status and phase timings from
the successful build manifest. Each profile's latest observation is the default
baseline and every observation also has a content-addressed JSON file. Use
`--previous /absolute/path/observation.json` for an explicit cold/warm comparison:

```sh
python3 tools/build_evidence.py firmware --environment WAVESHARE_AMOLED_175 \
  --previous /absolute/path/cold-observation.json
```

Comparisons show changed manifest input dimensions and previous/current timings.
A key change without further recorded input changes remains unexplained. A miss
with identical recorded inputs needs build logs to distinguish absence, eviction
and rejected cache entries. Observations do not authorize a cache restore or
firmware upload. Existing immutable runtime/core verification, size limits and
final-link safeguards remain authoritative. CI retains these observations with
exact-build symbols; evaluate several cold/warm runs before changing cache policy.

Versioned fixtures in `protocol/scenarios/` drive the actual production Swift
navigation queue with a controlled monotonic clock and transport availability:

```sh
python3 tools/replay_scenario.py
python3 tools/replay_scenario.py protocol/scenarios/ble-backpressure-reconnect.json
```

The initial library covers coalescing under backpressure, clearing stale traffic
on disconnect, reconnect delivery and workout update coalescing. Assertions
check delivered labels, queue depth, pending age and counters. The same fixtures
run in the existing Swift helper CI. Extend this library with minimal regressions
from actual incidents; host replay alone does not establish physical radio or
power-loss behavior.

Export a diagnostic ZIP with the app's existing diagnostics flow. Create a
private context JSON describing the observed failure and exact capture range:

```json
{
  "schema": 1,
  "description": "Pending turn was replayed after reconnect",
  "boardProfile": "WAVESHARE_AMOLED_175",
  "captureIds": ["123e4567-e89b-12d3-a456-426614174001"],
  "operationIds": [],
  "observedFailureAt": "2026-10-02T08:00:00Z"
}
```

```sh
python3 tools/incident_bundle.py create --bundle /absolute/path/bundle.zip \
  --context /absolute/path/context.json \
  --scenario protocol/scenarios/ble-backpressure-reconnect.json \
  --symbols /absolute/path/build-evidence/HASH
python3 tools/incident_bundle.py verify /absolute/path/incidents/HASH
python3 tools/incident_bundle.py replay /absolute/path/incidents/HASH
```

An incident pins the original archive bytes, context, scenario snapshot, log
inventory/clock/drop metadata and optional verified symbol records together.
The bundle's capture range must exactly match the selected incident. It retains
all hashes without rewriting the original logs. Replay produces a separate
immutable receipt with the regression-test commit and scenario hash. The
reported failure-to-replay latency uses the supplied wall clock, including its
uncertainty; it is not a physical measurement.

Repeat `--symbols` to add app and firmware records. Optional `--native-crash`
accepts a local Apple `.ips` report and matches the app's UUIDs and bundle version.
Association of that crash with a capture remains caller supplied. A version/build
match alone is recorded only as a candidate. Current main's schema-1 firmware
fingerprint does not identify exact ELF/bin hashes, so its firmware records also
remain candidates. Missing identity evidence remains explicit in the incident;
the tool never substitutes another capture or claims an exact firmware match.

PR #553's diagnostic schema/provider work is not on main yet. This implementation
uses main's existing authoritative ZIP validator and rejects unsupported schemas.
After that protocol lands, add its validator adapter and exact runtime identity
binding rather than weakening validation here. This tooling retains supplied
native crashes; automatic OS crash collection and physical incident acceptance
remain separate device work.
