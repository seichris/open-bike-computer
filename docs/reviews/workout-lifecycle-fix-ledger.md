# Workout lifecycle fixes

Profile: deep. Authorization: publish (user requested fixes in a PR).
Strategy: sequential-local; subagents: 0; severity gate: P0/P1/P2.
Base main: fe73e43431ed76c39159de7624c4cd9ede509434.
Dependency: PR #388 at 18ca6e8e2d4c0e6d12d175e5e1313345ae6942f4.
The fix branch was created from fetched main and fast-forwarded to that
dependency. PR #388 is still open from p0s/open-bike-computer, not a branch in
the destination repository. Therefore this draft targets main and includes
the #388 dependency until it merges; the new repair commit is separately
reviewable. No changes are pushed to the contributor's branch.

| Finding | State | Contract and verification |
| --- | --- | --- |
| WRK-001 P1 | active | Commit-unknown save recovery requires a product choice. Do not retry HealthKit blindly or label an unconfirmed save as saved/discarded. User asked whether to add a warned Watch-only stop-recovery action. |
| WRK-002 P2 | fixed+verified | One durable versioned phone journal for watermark plus pending/resolved operation; failure prevents ACK/control. Store failure/relaunch, coordinator failure-before-ACK and real file write/abrupt-process-exit/read tests pass. Legacy state migrates before replay. |
| WRK-003 P1 | fixed+verified | Actual Watch pause/resume policy output passes firmware encode/decode; all 32 defined masks round-trip through Swift, including the Watch-context path. Undefined bits remain rejected. Unencodable decisions cannot install logical outstanding state. |
| WRK-004 P2 | fixed+verified | Wheel, cadence, direct-conflict and GPS/IMU interruptions each require a fresh continuous five-second Watch stopped span in host regression tests. |
| WRK-005 P2 | fixed+verified | Both queues retain capture time and refresh age at actual submission; over-age samples expire before taking an ATT slot. Boundary tests and the complete navigation suite pass, including the real phone relay held for four seconds. Direct Watch integration is source/build evidence, not a physical ATT test. |

Scope excludes physical devices, flashing, deployment and production enablement.
No source from the dirty primary checkout is included.

## Review and verification

Iteration 1 reused the completed four-lens review at the unchanged dependency
SHA, revalidated the five findings, and implemented the authorized repairs.
Iteration 2 reviewed the resulting code/integration/security boundaries,
claims and reachability, test assertions, and repository policy separately.
No additional actionable defect was retained. WRK-001 remains active, not
silently deferred or reported as fixed: a product decision is still required
before permitting a rider to stop uncertain save recovery.

| Boundary | Required result | Evidence |
| --- | --- | --- |
| Decision admission and restart | Watermark/outbox commit together before side effects | Injected write failure; separate process `_exit` and reload; iOS coordinator test |
| Legacy decision state | Never replay defaults before durable migration | Migration path commits aggregate before returning pending state |
| Watch motion request | New evidence bit survives every validator | C++ policy-to-encoder and Swift mask/context tests |
| Movement interruption | Old stopped span is cancelled | Four veto variants assert no early pause |
| Queue delay | Actual capture age survives queueing and fallback | Same-size submission provider; expiry before ATT allocation; navigation queue tests |
| Workout save uncertainty | Never retry an unproven commit or fake a terminal outcome | Existing behavior retained pending user choice |

Passed locally: portable workout tests, RideShared tests, generated BLE
contract check, seven C++ host suites, all 11 trace-replay tests, iOS workout
platform suite, Watch workout platform suite, unsigned Debug iOS Simulator
container build including Watch sources. No firmware board build, physical
device, Health/Strava write, installation or deployment was performed.

Intermediate verification caught an outdated undefined-bit expectation and a
missing test argument; both were corrected. The new shared frame helper also
needed inclusion in the partial Catalyst preview test build; this introduced
packaging failure was corrected and the entire navigation script then passed,
including SavedMapPreviewCatalystTests. The opt-in live MapKit snapshot test was
not run. One navigation build was invalidated
by a source edit while compiling and was discarded, not classified as a baseline
failure. The final stable-snapshot navigation run exited zero before publication.
SDK deprecation and existing concurrency warnings are not treated as physical
qualification. Production automation gating is unchanged.

Ledger totals: 4 fixed+verified, 1 active, 0 invalidated, 0 user-deferred.
Terminal state: needs-user-input (WRK-001); this is not a clean review result.
Publication is a draft repair batch, not a claim that all lifecycle issues are
resolved. The final clean published-head verification and GitHub check state
are reported in the PR and handoff; draft CI skips heavy build jobs.
