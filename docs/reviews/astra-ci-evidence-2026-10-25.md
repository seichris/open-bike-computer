# CI selection and local evidence review — 2026-10-25

This is the historical review of the initial published commit `6c2ca6a622342ece89910e3f1f51907d165be449`. The user subsequently authorized a CI-cost redesign. Its revised policy, cost evidence, cumulative review passes and finding states are recorded in [the cost-revision report](astra-ci-cost-revision-2026-10-25.md).

## Scope and immutable source

- Repository: `seichris/open-bike-computer`; architecture review of main, not a main-to-main diff.
- Baseline head/base/merge base: `cd7ad00bb6c4f9566195cd44ab4d6a675518b94d`.
- Exclusive worktree: `/Users/chris/.codex/worktrees/astra-six-reviews-20261025-c5e83d/ci-evidence`.
- Initial state: detached HEAD, empty index/worktree diff, no untracked files. Other worktrees are excluded.
- Original review mode/profile/strategy/gate: `fix-local` / `deep-pr-review` / `sequential-local` / P0/P1/P2. Zero subagents. The subsequent publication handoff is recorded below.
- Risk: **high** because selection and evidence verification determine which CI checks may be omitted.
- New logical architecture review; no existing CI-evidence ledger was found. Passes used: **3/3**. Pass 1 covered the selected architecture; passes 2 and 3 were delta reviews plus all prior findings. Pass 3 is the clean confirming pass; no further automatic review round was run.
- Terminal state: **clean**. Ledger: **0 active, 5 fixed+verified (all P2), 0 invalidated, 0 user-deferred**. No P0/P1 defect was established within scope. Required local verification is complete; broader qualification limits are explicit below.
- The review phase performed no commit, staging, push, PR mutation, remote CI action, release, deployment, real signing/publication, or physical-device operation. The user subsequently authorized a new branch, commit, push, and PR against `main`, including this report and verification results.

## Behavior/contract matrix

| Contract | Conditions and expected outcome | Owning path and evidence |
| --- | --- | --- |
| Changed inputs select their consumers | PR/merge-group changed paths, deletions, unknown tooling and protocol inputs; explicit/manual scopes retain their stated limits | `changed_components.py`, `ci_scopes.py`; routing fixtures and real CLI tests |
| Local changes retain both rename paths | Committed or staged cross-component rename must select the old and new consumers | `tools/dev_check.py:changed_paths`; disposable Git-repository reproduction |
| Firmware profile selection covers conditional code | Production, lifecycle, ordinary diagnostics and remote-debug branches select profiles that compile them; common board/config changes select both families | `ci_scopes.py:firmware_targets`, `esp32/platformio.ini`; source/host tests only, no firmware build |
| Registry reaches CI execution | Every firmware host check must have a reachable CI invocation; iOS selections resolve registry entries | `checks.json`, `ci.yml`; registry/workflow integration assertions |
| Receipt identity and trust | Clean unchanged source, PR head plus actual merge tree, full recipe, trusted base policy, live environment/toolchain and simulator selection must match | `local_results.py`; temporary fixture keys and mocked transport, never configured signing keys |
| Receipt rejection runs tests | Missing, malformed, oversized, stale, wrong-source, wrong-toolchain, untrusted or altered evidence executes the original command; its failure remains failure | Real shared runner marker/failure tests |
| Gate fails closed | Selected failed/cancelled/skipped/missing jobs fail; unselected jobs must be skipped | Actual `ci.yml` gate shell executed with controlled job results |
| Artifacts bind the candidate | Checked merge tree in reports; signed receipt/log retained; same-run production artifact descriptor/profile/source and hashes checked | Runner reports, `firmware_release_candidate.py` and its fixture tests; no real release artifacts generated |

## Persistent finding ledger

| ID | Severity | State | Root cause, trigger and impact |
| --- | --- | --- | --- |
| CI-EVID-001 | P2 | fixed+verified | Unclassified executable/shared inputs defaulted to no product checks. A change only to `protocol/fixtures/workout-zones-v1.json` or `tools/firmware_release_history.py` selected no consumers; the actual CI Gate returned 0 with every product job skipped. Unknown tooling/protocol/CI inputs now select all components. Existing explicitly scoped inputs and unconditional CI/development test suites retain their policies. |
| CI-EVID-002 | P2 | fixed+verified | `firmware_targets` selected only production/lifecycle for `ble_navigation` and `map_transfer`. Those profiles omit ordinary diagnostics and remote-debug/development-trust branches. BLE now also selects ordinary/remote-debug, and map transfer selects remote-debug. Regression cases pass for explicit 175, 206 and all matrices. This verifies selection, not firmware compilation. |
| CI-EVID-003 | P2 | fixed+verified | Local `changed_paths` used rename detection and returned only the destination. A staged/committed rename from `ios-app/retired.swift` to `docs/retired.swift` selected no product component. Both local diffs now use `--no-renames`; disposable Git tests prove both paths and iOS consumers are retained. |
| CI-EVID-004 | P2 | fixed+verified | `esp32-host-usb-recovery-status` existed in the shared registry but had no CI invocation. The host workflow now runs it; a registry-to-workflow coverage test prevents another omission. The actual C++ USB request parser test passed through the shared runner. |
| CI-EVID-005 | P2 | fixed+verified | Reuse initialization failure clears `contracts`, which selected the ambient rather than normalized execution environment. With `ONLY_TESTING` set, a policy/fingerprint miss could narrow the simulator fallback and hide a failure. Controlled original reproduction: ordinary absent receipt exited 1 (full command exited 8); policy transport failure exited 0 (filtered subset). Every eligible `--reuse-local` fallback now uses the normalized profile independently of receipt initialization; all eight absent/error/ineligible/dirty/sparse cases retain the full command's failure. |

All four original findings were verified against the baseline; CI-EVID-002 was introduced by `7cdfc949`. The other original gaps predate that simplification and are in scope for this main architecture review.

CI-EVID-005 was exposed by new verification during pass 1 and reconciled only after the complete pass 2 delta review. Its root cause is the existing reuse implementation; it was not introduced by the rename fix.

Tight locations and regressions:

- CI-EVID-001: baseline `.github/scripts/changed_components.py:274` returns an unchanged all-false selection for unmatched inputs; fixed `classify_paths` fallback is at lines 166–178. Consumers: `ios-app/scripts/run-native-workout-zone-tests.sh:24`, `esp32/tools/tests/test_workout_zone_protocol.cpp:22`. Regression: `test_unclassified_shared_inputs_cannot_skip_their_consumers`.
- CI-EVID-002: `.github/scripts/ci_scopes.py:49–57`; conditional production code in `esp32/lib/ble_navigation/ble_navigation.cpp:1022` and `esp32/lib/map_transfer/map_stream_compiled_trust.cpp:26`. Regression: `test_firmware_conditional_consumers_keep_the_profiles_that_compile_them`.
- CI-EVID-003: `tools/dev_check.py:54–55`, `changed_paths`. Regression: `test_renames_keep_deleted_source_consumers_for_committed_and_local_changes`.
- CI-EVID-004: `.github/workflows/ci.yml:514–515` and `tools/development/checks.json:433–437`. Regression: `test_every_registered_firmware_host_check_is_reachable_in_ci`; actual `esp32-host-usb-recovery-status` execution.
- CI-EVID-005: baseline `tools/dev_check.py:168`, fixed at lines 168–171, chooses the environment after `tools/development/local_results.py:306–309` clears contracts; actual simulator filter at `ios-app/scripts/run-workout-platform-tests.sh:66`. Regressions: `tools/development/tests/test_local_results.py:281` and `:289`.

## Pass 1 lenses

1. **Code/integration/security:** traced event selection, source identity, execution environment, receipt parsing/signature/age/log bounds, trusted-base policy reads, normal fallback, per-check reporting, artifact handoff and aggregate results. Candidates retained for later reconciliation; no edits during this lens.
2. **Claims/spec/reachability:** compared `AGENTS.md`, `REVIEW.md`, `CONTRIBUTING.md`, development/local-result documentation and recent simplification/reuse commits with actual consumers. Checked explicit/manual, draft, merge-group, full-release, map lock/catalog/source and unknown Swift paths. Default 175 for ordinary known libraries is the documented policy, not an unsupported claim of both-board acceptance.
3. **Tests/verification:** baseline development and CI routing/policy suites pass (58 + 105 tests). Independently checked exact test entry points, marker-based receipt hit/miss/failure tests and the real gate shell. Reproduced the zone fixture green-with-all-consumers-skipped and local rename omission in fixtures. No native/firmware/hardware qualification is inferred.
4. **Repository policy/hygiene:** read root instructions, review policy, contributing guide, PR template and relevant existing review index; no scoped instruction files or prior ledger for this CI review. Kept baseline immutable and all operations in the assigned worktree. No remote actions or credential reads.

After all four lenses, reconciled the four findings above. No speculative/style findings retained. Receipt `RecursionError` handling is not a defect: it is already caught through `RuntimeError`.

## Pass 2 delta lenses

1. **Code/integration/security:** examined the new selector wrapper, profile mapping, rename commands, workflow invocation and new receipt tests against the same pinned HEAD plus local patch. The first four fixes preserve known routes and required gate behavior. Traced the failing new environment test through initialization rejection to the actual subprocess environment; retained CI-EVID-005 for reconciliation.
2. **Claims/spec/reachability:** checked normalized execution-profile claims against every initialization-miss branch and the simulator script's real `ONLY_TESTING` switch. The fault is reachable on policy transport/fingerprint failure, dirty/sparse checkout or ineligible event while reuse is requested; successful receipt initialization must not decide which tests a fallback runs.
3. **Tests/verification:** the initial new test's fake SDK caused Git/tool lookup to fail, exposing initialization fallback rather than an ordinary missing receipt. A second controlled reproduction using only `ONLY_TESTING` and a mocked policy transport error proved a false green (exit 0) versus full-suite failure (exit 8, runner exit 1). All four original regressions pass; broader artifact/USB/Swift/board-host checks and pinned actionlint passed. No other failure was present.
4. **Repository policy/hygiene:** HEAD remains pinned, index empty, all modifications are loop-owned; publication override still active. No new scope outside the changed runner/selector contracts. Reconciled CI-EVID-005 as P2 and retained the 3-pass ceiling. Fix and verify it before pass 3; any active finding at that final pass must remain `needs-rethink`.

## Pass 3 confirming delta lenses

1. **Code/integration/security:** reviewed the new fallback environment choice and affected eligibility/session/subprocess paths. Normalization now depends on requested reuse and intrinsic check eligibility, not successful evidence initialization. Ineligible build/Linux checks retain their existing execution behavior. Local publication and signature/base-policy authorization are unchanged. The complete recipe already binds the runner bytes, so this fix invalidates earlier receipts without a schema or key change.
2. **Claims/spec/reachability:** followed missing receipt, policy failure, fingerprint failure, dirty/sparse source, fork/manual/disabled reuse and accepted receipt paths. The fallback uses the existing normalized profile; accepted receipts still require matching head/tree, recipe, toolchain, age and signature. Earlier routing fixes retain old/new rename consumers, conditional firmware profiles and the USB CI invocation. No added permission or release bypass.
3. **Tests/verification:** final shared development/CI suites passed, **67 + 109 tests**. The eight initialization scenarios now execute the full failing marker command and return nonzero. A second valid temporary Ed25519 key proves rejection of a valid but untrusted signer. Source/recipe/toolchain/stale/malformed/oversized/blocked/change-during-run negatives and real gate result combinations pass. Earlier product host checks remain applicable: the last code change only affects eligible requested-reuse execution, which those non-reuse checks did not use.
4. **Repository policy/hygiene:** checked pinned HEAD/base/merge base, empty index, loop-owned path list, unchanged patch hash over this pass and disabled publication. No new dependency, key, profile, build flag, release control or product source change. Documentation matches the final behavior. Reconciled all five findings as fixed+verified; **0 active findings**. Stop at `clean`, 3/3 passes.

## Verification and publication controls

Every setup/check command uses the process-local override:

```sh
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=bicino.localResultsKey GIT_CONFIG_VALUE_0=
```

The runner was inspected before execution. A real `Session` initialized with an eligible iOS check under this override has `key is None` and `contracts == {}`: no signing key was loaded, and automatic publication is disabled. Shared Git configuration is unchanged. Signature tests use disposable fixture keys and mocked publication/transport only.

- `tools/dev-setup`: passed, created this worktree's ignored `.venv` using Python 3.13.14.
- `tools/dev-env tools/dev-check --suite development --plan --report .venv/review-evidence/baseline-plan.json`: passed, both checks planned and source unchanged.
- `tools/dev-env tools/dev-check --suite development --report .venv/review-evidence/baseline-development.json`: passed, 58 development tests plus 105 CI tests, source unchanged, all executed locally.
- Initial plan output was mistakenly put under unignored `.review-evidence`; it correctly reported a source change. Moved those owned outputs under ignored `.venv/review-evidence` and reran the plan. No product source changed.
- Controlled reproduction: real gate shell with fixture-only selection returned 0 while all consumer jobs were skipped; disposable Git rename listed only `docs/retired.swift` locally versus both paths with CI's `--no-renames`.

Additional exact verification commands, all from the exclusive worktree with the override above for Python/setup/check commands:

```sh
tools/dev-env tools/dev-check --suite development --report .venv/review-evidence/regressions-before-fix.json
tools/dev-env tools/dev-check --check development-tools --check ci-routing --check esp32-host-usb-recovery-status --check ios-navigation-workout --check esp32-host-firmware-manifest-tests --plan --report .venv/review-evidence/fix-plan.json
tools/dev-env tools/dev-check --check development-tools --check ci-routing --check esp32-host-usb-recovery-status --check ios-navigation-workout --check esp32-host-firmware-manifest-tests --report .venv/review-evidence/fix-verification.json
tools/dev-env tools/dev-check --suite development --plan --report .venv/review-evidence/final-development-plan.json
tools/dev-env tools/dev-check --suite development --report .venv/review-evidence/final-development.json
docker --context orbstack run --rm --mount type=bind,source=/Users/chris/.codex/worktrees/astra-six-reviews-20261025-c5e83d/ci-evidence,target=/repo,readonly --workdir /repo rhysd/actionlint@sha256:887a259a5a534f3c4f36cb02dca341673c6089431057242cdc931e9f133147e9 -shellcheck=
git diff --check
```

| Evidence | Result and classification |
| --- | --- |
| Baseline development | Exit 0; 58 + 105 tests, source unchanged. |
| Regressions before fixes | Exit 1; all four original defects reproduced. Related failures retained in `regressions-before-fix.json`; no unrelated failure. |
| Fix plan | Exit 0; all five selected checks ready; source unchanged. |
| Swift workout helper | Passed, 58.342 s; real production Swift zone code and fixture assertions. |
| Firmware manifest/artifact suite | Passed, **228 tests**, 85.697 s; includes candidate artifact identity/tamper/replay/bounds/profile/source tests. Existing SQLite ResourceWarnings did not fail the suite. |
| USB recovery request test | Passed through shared runner, 1.135 s. |
| Initial fix verification aggregate | Exit 1 solely for CI-EVID-005's new environment test; development 66 tests with one failure, CI 109 passed, source unchanged. This report is not described as green. |
| Final development plan/run | Exit 0; **67 development + 109 CI tests**, 12.725 s + 1.454 s, source unchanged. This closes CI-EVID-005 and reconfirms CI-EVID-001–004. |
| Two-board zone fixture workflow | Loaded `jobs.contracts.steps[name="Independent wire fixtures, decoder lifecycle and display geometry"].run` from `.github/workflows/workout-zone-contracts.yml` with PyYAML, then ran that exact script via `bash -euo pipefail -c` from the repository root, setting only `RUNNER_TEMP` to `.venv/review-evidence/zone-contracts`. Exit 0; 24 host executions, 12 per board. Log: `.venv/review-evidence/zone-contracts/output.log`. No source list copied or modified. |
| Workflow syntax/policy | PyYAML parsed all 9 CI jobs; pinned actionlint 1.7.7 under **OrbStack**, read-only worktree mount, exit 0; shared workflow policy tests pass. |
| Actual local fingerprint | `tools/dev-env python3` imported `tools.development.local_results` and called `fingerprint(simulator=True)`: passed. Saved `.venv/review-evidence/live-fingerprint.json`; canonical SHA-256 `9c304ee0850c6c4a0d66dd1cf43d4529775e6c472b19d324f928825dd8a8a175`. Selected runtime builds: iOS `24A94401`, watchOS `24R362`. Inventory only; no simulator created. |
| Hygiene/publication | `git diff --check` exit 0; index empty. Eligible-check `Session` probe again returned `key=None`, no contracts. No top-level check report contains a published receipt. All real checks executed locally; receipt hits exist only in isolated fixture tests. |

All retained command reports and logs are under this worktree's ignored `.venv/review-evidence/`. The final development suite was repeated because CI-EVID-005 changed the runner and tests; already-passing unchanged host/product checks were not unnecessarily repeated.

## Reviewed source identity and owned files

- At review completion, HEAD/base/merge base were `cd7ad00bb6c4f9566195cd44ab4d6a675518b94d`; baseline committed tree `36d1c7691bbcb20a5210b234e0820105599c7900`.
- Baseline patch SHA-256 (empty): `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`.
- Final reviewed patch SHA-256: **`497a51c80ef53c8fcc1fe626aa2bad863466c107ead88934a26d14512bc088a7`** (27,523 bytes).
- Review-time patch definition: `git diff --binary HEAD -- . ':(exclude)docs/reviews/astra-ci-evidence-2026-10-25.md'`. After committing, compare `cd7ad00bb6c4f9566195cd44ab4d6a675518b94d` to the published head with the same path exclusion. The report is excluded to avoid a self-referential hash; only report bookkeeping changed after the confirming pass. Copy retained at `.venv/review-evidence/final.patch`; descriptor at `.venv/review-evidence/pass3-identity.json`.
- Loop-owned source: `.github/scripts/changed_components.py`, `.github/scripts/ci_scopes.py`, `.github/workflows/ci.yml`, `tools/dev_check.py`.
- Loop-owned tests: `.github/scripts/tests/test_changed_components.py`, `.github/scripts/tests/test_ci_scopes.py`, `.github/scripts/tests/test_workflow_policy.py`, `tools/development/tests/test_development_checks.py`, `tools/development/tests/test_local_results.py`.
- Loop-owned documentation: `docs/development-checks.md`, `docs/local-ci-results.md`, and this report/ledger. These twelve files constitute the publication scope. Ignored environment/evidence outputs remain worktree-private.

## Limits and recovery

During the local review, no firmware build, app-container build, native simulator test, physical iPhone/Watch/ESP32 action, real signing-key access, receipt publication, hosted workflow dispatch or live CI observation occurred. Firmware builds would first require connected-board clarification under `AGENTS.md`; no build was attempted, so no device question was necessary. The both-board executions above are host C++ fixtures using board definitions, not firmware images or physical acceptance. The local Swift/host toolchain is macOS; Linux/GCC execution and the full native app/backend/OSM CI lanes were not replayed here.

Adversarial runtime/toolchain cases use injected fixtures; the real local fingerprint was also computed successfully, but hosted compatibility, real receipt transport/authentication, end-to-end reuse frequency and savings remain unmeasured. The repository's reviewed CI code, signing host and GitHub control plane remain trust boundaries; this review does not claim protection against arbitrary malicious modifications to the verifier/workflow itself or compromise of the trusted signing machine. Existing draft/manual hardware scope limits remain as documented. Unknown shared inputs deliberately cost full CI until a narrower consumer mapping is established.

Recovery after publication: revert the publication commit on the PR branch. Restoring the baseline also restores these coverage gaps. The runner hash/tree change makes older receipts miss and run normal CI, both on adoption and rollback. No key, evidence branch, deployed service or device state needs rollback. The committed candidate still needs its required hosted checks; this local clean review is not a release or physical-acceptance claim.

## Publication handoff — 2026-10-25

- User authorization: commit these five fixes on a new branch and open a PR against `main`, including the review report and verification results.
- Branch: `fix/ci-evidence-coverage-20261025`; the twelve owned files above are the complete commit scope.
- Before publication, live `refs/heads/main` still matched the reviewed baseline, and the source/test/documentation patch excluding this report still had SHA-256 `497a51c80ef53c8fcc1fe626aa2bad863466c107ead88934a26d14512bc088a7`.
- The completed review remains **clean, 3/3 passes, 0 active findings**. Publication and candidate verification do not reset or extend the review budget.
- The PR description records the published head SHA, clean-head shared-runner verification, workflow lint result, and hosted CI status. Local receipt signing/publication remains disabled through the process-local Git configuration override above.
- Hosted checks triggered by the push/PR are observed without manual dispatch, rerun, or cancellation. Merge, release, deployment, signing and device actions are outside this publication handoff.
