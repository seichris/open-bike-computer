# Logging reliability repairs

Scope: the eleven findings from the logging review of main
`b5b110784f42087b7a6442dd8b59571ee93150d1`. This change does not include the
workout recovery/timer changes in PR #577. Verification uses host boundaries,
synthetic evidence, temporary loopback brokers and unsigned app builds.

| ID | Defect and repair | Direct regression evidence |
| --- | --- | --- |
| L01 (P1) | Cross-lane publication now shares the writer's selection fence. Admission remains zero-wait; contention is counted. | Production enqueue/peek harness covers empty lanes and attempted normal/critical publication between peeks, then verifies ordered admitted records. |
| L02 | Completed acquisitions are reconciled against recipient-scoped deterministic ZIP identities and durable hash receipts. Busy/full preparation leaves intent in the acquisition journal. | Actual client orchestration with real acquisition store covers startup without a notification, a completion during suspended export, full-outbox recovery and acknowledged replay. |
| L03 | Explicit deletion joins collection/handoff work and removes the acquisition cache and every local recipient outbox before deleting recorder data. Chunk/sequence identities continue monotonically; functional command anti-replay receipts survive deletion. | Actual deletion orchestration plus recorder/cache tests verify all owners, non-reused paths and export of an independently held old snapshot. |
| L04 | Explicit remounts fence admission and allocate a fresh namespace above both media. The paused writer acknowledges quiescence; unavailable-medium queued losses are accounted before remount. Nonempty chunks are never appended to. | Production namespace/open/closed-inventory and writer-pause functions run against distinct synthetic FFat/SD directories, preserving old bytes and exposing newer retained boots. |
| L05 | Coverage includes retained firmware health/index storage errors/drops and historical iPhone process drop counters. Repeated firmware snapshots use the maximum per device/boot. | Checksum-valid v1/v2 fixtures retain health after event loss; delivery stays complete while recording coverage degrades. Historical process loss is also exercised. |
| L06 | Watch batches persist producer identity and cumulative truncation counts; phone import records an explicit loss event. Legacy batches remain readable. | Actual Watch batching/retry methods, preference reload and phone import preserve loss through the full transport shape. Shared Swift contracts test bounded serialization. |
| L07 | Failed capsule writes release their in-flight checksum. Previous-boot RTC evidence stays until its own durable write acknowledgement. | Production capsule admission, failure receipt and acknowledgement functions cover retry, failed admission and reversed acknowledgement order. |
| L08 | `inbox archive` verifies a new external copy, retires active capacity and preserves the receipt/hash/location for replay validation. | A real public CLI archive frees a full 20-bundle synthetic inbox; new upload and old receipt replay succeed, and damaged archived bytes fail replay. |
| L09 | A server lifetime lock protects startup cleanup. Partial staging has a separate fixed budget; unindexed renamed evidence is preserved and charged to capacity. | A child TLS broker is killed during a real partial PUT and reopened. Active-server exclusion and quota accounting/recovery of unindexed renames are exercised separately. |
| L10 | HTTP reads enforce absolute header/body deadlines at each socket read, including continuously dripping clients. | Shortened test deadlines exercise both headers and authenticated upload bodies; a subsequent TLS request succeeds and partial staging is removed. |
| L11 | Debug mirror checkpoints compare all bounded fields except time. | The actual checkpoint helper updates state/credential changes under an unchanged reason and suppresses identical writes, using in-memory preferences. |

All remaining findings were P2. Existing privacy/byte/hash/sequence validation
remains strict. Complete delivery, no detected recording loss, source/build
identity and physical qualification remain separate claims.

## Behavior and contract checks

| Boundary | Expected behavior | Evidence / remaining limit |
| --- | --- | --- |
| Concurrent firmware admission | A newer lane head cannot overtake an unseen admitted older record; contention is explicit loss. | Deterministic RTOS stand-ins execute production functions. Physical contention/throughput is unmeasured. |
| Storage transition | Old handles stop before remount; old queued identities cannot be written under a new namespace; old files remain immutable. | Host filesystem and deterministic pause acknowledgement. Card faults/power cuts require physical qualification. |
| Completion to handoff | Missing callback, busy export, full outbox and relaunch retain discoverable work; acknowledged IDs are not recreated for that recipient. | Real Combine/store plus exporter/network doubles. Actual foreground/suspension behavior is not a device qualification. |
| Deletion | Join existing tasks, erase local owners, start replacement chunks without identity collisions. | Production orchestration and recorder/store tests. Delivered external files are intentionally separate. |
| Inbox full / process loss | Archive frees active payload capacity while keeping replay evidence; unfinished bodies cannot accumulate across server restarts. | Temporary real TLS servers, process termination and public archive command. Host power-loss durability remains unqualified. |
| Partial producer evidence | Health/Watch loss cannot become `no_detected_loss` merely because imported iOS storage sequences are contiguous. | Strict archive fixtures and production Watch/phone methods. Counters remain cumulative and scoped. |

## Verification entry points

- `python3 -m unittest discover -s tools/tests -p '*diagnostics*.py'`
- `python3 tools/dev_check.py --check esp32-host-ride-diagnostics-and-watchdog-host-tests`
- `ios-app/scripts/run-ride-diagnostics-tests.sh`
- `ios-app/scripts/run-diagnostics-acquisition-tests.sh`
- `ios-app/scripts/run-diagnostics-policy-tests.sh`
- `ios-app/scripts/run-diagnostics-broker-tests.sh` (includes the app lifecycle, Watch loss and checkpoint regressions on macOS)
- `ios-app/scripts/run-ride-shared-tests.sh`
- `python3 -m unittest discover -s tools/development/tests`
- `python3 tools/generate_diagnostics_contract.py --check`
- `python3 tools/development/ios_build.py` (unsigned Debug/Release iPhone and Watch containers; no install or launch)

The deep review uses the P0/P1/P2 gate and sequential code/integration/security,
claim/reachability, verification, and repository/PR hygiene lenses. Fixes found
while reviewing the repairs include parked-writer state ownership and charging
unindexed renamed files to broker capacity, and preserving command anti-replay state during diagnostic deletion. The confirming pass preserves these
regressions rather than inferring correctness from broad green suites.

No device/runner, serial, live broker, actual pairing credential, private user
bundle or physical workload is operated by this validation. The existing
qualification backlog in issue #576 remains separate from these repairs.
