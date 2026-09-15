# PR #420 current-main integration

Reviewed main: `25b6352e69c39af66369743b57dd6f76c92c5e91`.
Published integration: `feb935c078f887f7aca03b80bb6ed9ef67d9d181`.
Reviewed tree: `8a4a4aa675d82f8197feac4b9ae2b1ac58cf30fd`.

The original #388 stack is already merged, with subsequent improvements. This
reconciliation preserves main's firmware, Watch coordination, generated BLE
contract, motion/source-health logic, and #423 shutdown state machine unchanged.
Only WRK-002's atomic phone decision journal and its tests remain in the runtime
diff. The branch was updated by a merge-parent commit without force-pushing.

New coverage includes failed legacy migration followed by successful recovery,
corrupt-journal fail-closed behavior, and an explicit check that no decision
acknowledgement is emitted after failed durable admission. Existing crash/relaunch
and write-failure coverage is retained.

Fresh macOS evidence from workflow run `34171103469`, job `101891409727`:

- Exact reviewed-tree verification and unchanged firmware/Watch/shared-contract checks: passed.
- Generated BLE contract and whitespace checks: passed.
- `ios-app/scripts/run-workout-contract-tests.sh`: passed.
- `ios-app/scripts/run-workout-platform-tests.sh ios`: passed, including the real coordinator regression tests.
- Branch publication occurred only after all preceding steps succeeded.

This documentation commit triggers normal PR CI for the resulting head. Its
required aggregate result must be checked separately; the isolated validation
workflow does not replace the protected CI gate.

WRK-001 remains a separate, pre-existing HealthKit unknown-save-outcome issue.
This PR does not retry uncertain saves, declare them saved/discarded without
proof, add a Watch stop-recovery flow, or enable production automatic start.
It must not be described as resolving all workout lifecycle findings.

No physical devices, real HealthKit writes, firmware uploads, releases, or
production deployments were used in this reconciliation.

## Fresh current-main validation and retirement failure fix

Integrated main `b082746e` in an isolated worktree. Firmware, Watch coordination,
BLEManager and shared contracts remain byte-identical to that main. The only
additional runtime fix gates the rejection ACK on successful journal retirement:
a rejected Watch pause/resume request followed by a failed journal clear must
not acknowledge a terminal result while leaving a replayable operation on disk.
The new production coordinator regression failed before the guard and passed
with it in the full iOS workout platform suite.

Passed locally: workout contracts, full iOS workout platform tests, unsigned
Debug iOS container build (including Watch sources), and whitespace checks.
The main Watch host matrix passed 35 cases / 192 assertions. #418's historical
report now explicitly identifies #423 as the R1–R3 implementation without
rewriting its baseline evidence. WRK-001 remains the separate preexisting
reconciliation-only HealthKit issue described above; no save retry or loss-risk
escape hatch was added. Physical qualification remains unperformed.
