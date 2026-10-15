# Companion connection reliability

Original implementation base: `645350373f37e9474ad8967e794dadd69cd55953` (GitHub main).
Original publication base (2 October): `0f6fc8c6f0238d5508df199f2a50b1482b62ca1d`; the intervening
commit updates map-workflow action versions without overlapping this change.
Scope: firmware BLE, iPhone CoreBluetooth, Watch direct BLE, HealthKit mirroring,
and WatchConnectivity control/file delivery. Topology and application security
mode remain unchanged.

Review: standard, publish, sequential-local, P0/P1/P2 gate. The primary checkout
and all pre-existing changes are excluded. Only this isolated branch is owned by
the implementation loop.

## Refresh on 15 October 2026

Integration base: `4fc844bdf5f64164fedc06c9db08d14a0f7245e4` (94 commits
newer than the original base). The existing PR branch merges this mainline
history without rewriting its published commits.

The update preserves mainline workout recovery, diagnostics startup and device
operation handling. Watch mirroring uses mainline's ten-second startup/live-send
watchdogs and shared disconnect recovery, including its retained-session and
late-callback tests; the superseded eight-second Watch timer and duplicate test
are removed. iPhone send liveness retains its separate eight-second deadline.
Phone clear/adoption regressions move into `NavigationProtocolRideTests.swift`
without restoring tests that mainline split out. Both protocol-document additions
are retained.

The refreshed integration passed local verification. Its published commit and
GitHub CI must be checked independently; the October 2 results below remain
historical. Review profile: standard; mode: publish; strategy: sequential-local;
gate: P0/P1/P2; no delegated review agents.

The current-main baseline passed shared contracts, Watch source typechecking,
and both native simulator suites. The refreshed merge passed the full phone
navigation suite (215 route checks), shared contracts and actual Watch adapter
(48 cases / 241 assertions), full Watch typechecking/persistence, native iPhone
and Watch suites, and Development/Release app-container validation. Firmware
ownership, lease, automation, source-admission guards, and the full firmware host
suite also passed. The first host run lacked the YAML test prerequisite; the
same check passed after installing that package in a task-owned virtual
environment without changing source. Current firmware image builds are delegated
to this refreshed PR's CI; no local firmware build or device action was performed
for this refresh.

## Finding ledger

| ID | Defect or policy gap | State | Verification |
| --- | --- | --- | --- |
| F1 | Protected feature writes can bypass authentication on fallback channels | fixed+verified | Callback wiring guards, mandatory admission matrix, ownership crypto/state/role tests, firmware build |
| F2 | Failed logical navigation clear leaves sibling writes and loses intent | fixed+verified | Actual phone manager: either member ATT error, sibling retirement, reconnect replay, exact application ACK |
| F3 | Restored phone connections bypass the lifecycle reducer | fixed+verified | Shared production adoption path: connecting/connected, duplicate adoption rejection, generation and readiness assertions; native build |
| F4 | RAUT notifications select an unsubscribed channel | fixed+verified | Native/fallback/neither subscription and protected MTU matrix; host notification dispatch tests |
| F5 | Missing HealthKit completion blocks subsequent controls | fixed+verified | Native iPhone/Watch manager tests: missing completion, authoritative response first, terminal successor, late callback |
| F6 | Late route install resurrects a deleted Watch route | fixed+verified | Actual route libraries and filesystem: restart, stale file/receipt, duplicate delivery, newer reinstall, corrupt journal, sender crash windows |
| F7 | Rejected phone preparation retires a live Watch connection by timer | fixed+verified | Actual Watch adapter host harness: rejection before/after setup completion and real cancellation boundary |
| F8 | Controller revocation leaves durable outbox before receiver application | fixed+verified | Production outbox model: persistence/restart, rejected cleanup, wrong request, duplicate intent, exact applied receipt; native packaging |
| F9 | Deferred automation commands lack an explicit authorization lifetime | fixed+verified | Session/lease generation rejection matrix, ownership-lock application wiring, firmware build and existing lease/state tests |

## Historical evidence from 2 October

The unmodified base passed the shared route and actual Watch BLE adapter suite,
Watch offline persistence suite, firmware controller lease suite, and automation
policy/trace suite. Report: `/tmp/bicino-connection-baseline.json` (local only).

The final implementation review used two sequential passes covering correctness,
regressions, authorization, lifecycle, persistence, compatibility, and packaging.
The first closed the eviction-receipt deletion retry edge case; the confirming
pass found no remaining P0/P1/P2 issue. No implementation subagents were used.
At original publication all nine entries were fixed and verified. The refreshed
ledger above is supported by the separate October 15 checks.

The frozen implementation (excluding documentation) has SHA-256
`1f6c29e6a4c8dc84703d2d1e9c59372bb145ed74dfb691752b2d741a193fa776` using sorted
changed paths followed by their contents. Local verification includes:

- All 42 affected fast checks: 41 passed in the broad run; its Swift build was
  invalidated by an overlapping source edit and replaced by a complete frozen
  `ios-app/scripts/run-navigation-tests.sh` pass, including 215 route checks.
- The actual Watch BLE adapter harness: 47 cases, 234 assertions.
- Both native HealthKit simulator suites via `tools/dev-check --check ios-simulator`.
- Development and Release phone containers, embedded Watch, complication, and
  Live Activity validation via `tools/development/ios_build.py`.
- Locked 1.75 firmware compilation, final linking and artifact verification.
- Six notification/admission/application wiring guards and executable firmware
  admission/lease tests; ownership crypto/state tests using MbedTLS 2.28.9.

Initial runs invalidated by editing or generated build state do not attest the
published commit. Publication verification and CI must be evaluated at the PR's
exact head. Route schema 2 requires both companion apps to be updated; older
Watch apps receive an update instruction before new transfers.

These are source, host, simulator, and build results. The firmware callback guards
are source-wiring checks plus executable policy tests, not a real BLE injection.
Phone restoration tests exercise the shared adoption owner, not operating-system
restoration scheduling. Outbox tests inject a rejected receipt, not a physical
Keychain failure. No radio, wrist-down/background, real HealthKit recording,
WatchConnectivity delivery order, flash, app installation, or cold boot is proven.
Physical qualification still needs phone-only/Watch-direct rides, rejected
handoff, locked restoration, reconnect during clear, cached GATT/MTU pressure,
and restart during route deletion and credential cleanup.
