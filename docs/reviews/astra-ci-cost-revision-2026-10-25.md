# PR #633: correctness with bounded CI work

## Target and authorization

- Repository/PR: `seichris/open-bike-computer`, #633, `fix/ci-evidence-coverage-20261025` → `main`.
- Base: `cd7ad00bb6c4f9566195cd44ab4d6a675518b94d`; initial published head: `6c2ca6a622342ece89910e3f1f51907d165be449`.
- User explicitly requested a revision that preserves the five correctness fixes while reducing CI time to a reasonable minimum. This authorizes the cost redesign and its additional delta review; it does not reset the original three passes.
- Mode/profile/strategy/gate: `publish` / `deep-pr-review` / `sequential-local` / P0/P1/P2. Zero subagents. High risk: selection determines which checks may be omitted.
- Original review: 3/3 passes, retained in [the original report](astra-ci-evidence-2026-10-25.md). The explicitly authorized cost revision used 3/3 additional passes, numbered 4–6 cumulatively. Pass 6 is the clean confirming pass; **0 active findings, 8 fixed+verified, 0 invalidated, 0 deferred**. This is the local review state; new-head hosted qualification is recorded separately in the PR.
- Work remains in the assigned isolated worktree. No unrelated worktree, release, deployment, physical device, real signing key or receipt publication is part of this change.

## Resulting policy

Unknown executable/shared inputs now stop the selection job with an explicit mapping error. They cannot turn an omitted check into a green gate or automatically schedule every component. Known missing inputs map to the executable checks that consume them; the mapping is shared with local automatic selection.

BLE and map-transfer library changes select production plus remote-debug. Remote-debug inherits ordinary diagnostics and adds debug/development-trust branches; production covers their disabled paths. An independent C++ preprocessor test compares the actual source and inherited definitions of all four profiles on both boards, rejects uncovered conditional arms, and includes counterexamples that require an ordinary/lifecycle profile. This establishes conditional source coverage, not equivalent binaries, runtime behavior or physical acceptance. Lifecycle adapter implementations, board/runtime/build inputs and explicit full/manual/release requests retain broader qualification.

CI/runner changes validate the requested board family instead of automatically expanding to both boards. Documentation and already-unconditional CI/development unit tests no longer expand product scope. Board/build paths take priority in mixed changes so accompanying CI files cannot hide the 206 board or common-board qualification.

The host workflow validates a nonempty list of registered check IDs, runs matching named steps, and rejects unknown/duplicate/malformed lists. Python release-tool changes avoid native dependency installation and unrelated wire/display contracts. BLE/transfer-only changes avoid the rider-badge rasterizer benchmark. Missing or failed selected jobs still fail the aggregate gate; unselected jobs must skip.

## Deterministic work comparison

The following comparison executes the base, initial PR and revised selectors against the same path sets. The normal requested hardware family is 175.

| Change | Before the PR | Initial PR | Revised |
| --- | --- | --- | --- |
| BLE implementation | 2 builds, missing diagnostics/debug coverage | 4 builds | 2: production + remote-debug |
| Map-transfer implementation | 2 builds, missing development trust | 3 builds | 2: production + remote-debug |
| BLE plus documentation | 8 builds | 8 builds | 2 builds |
| CI/runner inputs | 8 builds | 8 builds | Requested family's 4 profiles |
| Common board/build configuration plus CI | 8 builds | 8 builds | 8 builds; mixed-path regression covered |
| Workout fixture | No product validation: false green | All components, 8 builds, 15 Swift checks, apps/simulators | 1 Swift workout helper + both-board wire/display contracts; no firmware image or app/simulator build |
| Release-history / boot-acceptance Python tool | No product validation: false green | All components | Existing Python manifest/tool suite only |
| Unmapped new shared input | No product validation: false green | All components | Fail selection before product jobs; require a mapping |
| BLE plus device-transfer library | 2 builds, missing debug coverage | 4 builds | 3: union of production, debug and lifecycle consumers |

This is not a promise that every previously false-green change can gain validation at zero cost. Newly covered fixtures/tools need small targeted tests. A mixed change may require three distinct profiles; reducing that union would reintroduce a gap. The large unnecessary expansions are removed while release, board and lifecycle gates remain explicit.

## Timing evidence and limits

[Initial-head CI run 40161900566](https://github.com/seichris/open-bike-computer/actions/runs/40161900566) completed successfully, including all 20 jobs and CI Gate. Summing job start/end durations gives **11,261 seconds / 187.7 runner-minutes**; eight firmware jobs account for **8,865 seconds / 147.8 runner-minutes**. These are runner durations, not billing data or a wall-time sum.

For this CI-only revision, removing the four unrequested 206 jobs removes **4,345 measured seconds / 72.4 runner-minutes** from that scheduling model: **6,916 seconds / 115.3 runner-minutes**, about **38.6% less**. This estimate reuses durations from the same successful run; it is not a measured new-head speedup. It excludes small additional selector-test overhead and cannot eliminate cache, runner or queue variance. The longest retained firmware job still dominates elapsed time.

The same run measured the Swift workout helper at **7.6 seconds**, zone-contract job at **23 seconds**, Python manifest/tool step at **38 seconds**, and complete firmware host job at **242 seconds**. Narrowing newly covered input cases avoids unrelated long firmware/native jobs. The renderer benchmark took 50 seconds on 175 and 22 seconds on 206; it remains selected for potential rendering changes.

Read-only timing data and three-version scope comparison are retained in this worktree's ignored `.venv/review-evidence/pr633-initial-timings.json` and `cost-revision-comparison.json`. No workflow dispatch, rerun or cancellation was used to collect them.

## Finding ledger

| ID | Severity | Revised resolution |
| --- | --- | --- |
| CI-EVID-001 | P2 | Explicit fast consumer mappings plus fail-closed rejection of unknown shared inputs; replaces the expensive blanket fallback. |
| CI-EVID-002 | P2 | Production/remote-debug pair covers current conditional arms; both-board preprocessor guard prevents future silent gaps. Lifecycle adapter inputs retain qualification. |
| CI-EVID-003 | P2 | Both rename paths remain selected through `--no-renames`; original regression retained. |
| CI-EVID-004 | P2 | USB host check remains reachable and selected for ordinary host scope; registry-to-workflow coverage and conditional-ID assertions prevent omissions. |
| CI-EVID-005 | P2 | Every eligible requested-reuse fallback still executes the normalized environment; original eight failure cases retained. |
| CI-EVID-006 | P2 | Initial PR's shared-input/profile expansion violated the clarified cost constraint. Targeted selection, conditional profile coverage and executable work-budget cases replace it. |
| CI-EVID-007 | P2 | Pre-existing non-firmware/doc paths escalated routine firmware changes to both boards. Consumer filtering and requested-family selection remove this expansion. |
| CI-EVID-008 | P2 | Revision pass 5 found that the initial cheaper mixed-path rule could hide a board/build edit behind a CI edit. Board/runtime routing now takes precedence; mixed 206/common-board regressions verify it. |

All eight findings are **fixed+verified** within the stated source/selection scope. No findings were dropped or severity-downgraded to meet the review bound. Runtime/physical limits and timing-estimate limits remain explicit.

## Delta review record

**Pass 4 — authorized cost redesign, all four lenses.** Code/integration: traced classifier, profile flags, lifecycle consumers, local auto selection, workflow invocations and aggregate gate. Claims: compared the user cost constraint with source-level job expansion and actual successful-run timings. Tests: reproduced three-version scope counts and identified existing registry consumers, conditional branches and failure assertions. Repository/hygiene: revalidated clean PR ownership, base/head, instructions, original ledger and disabled publication; no production or device effects. Reconciled CI-EVID-006/007, then implemented one batch.

**Pass 5 — delta review, all four lenses.** Code/integration: checked narrower scopes, profile inheritance, local/hosted parity, selection-list validation and mixed paths; found CI-EVID-008. Claims: confirmed source-level branch coverage differs from full-image/runtime acceptance and separated estimated runner savings from elapsed-time measurements. Tests: development/routing and workflow lint passed before this review; the new coverage guard also passed under Linux GCC. Added mixed board/config and CI-unit-test companion cases after reconciliation. Repository/hygiene: retained the original five regressions, exact branch/base, report-only artifacts and three additional-pass ceiling. Fixed CI-EVID-008 in the final batch before the confirming pass.

**Pass 6 — clean confirming delta, all four lenses.** Code/integration: checked the final mixed-path precedence, shared consumer filtering, actual profile flags, fail-closed condition-input model, selected-step validation and gate propagation. Claims: rechecked consumer references and the scope/timing tables; broader board/lifecycle/manual qualification and the three-profile mixed-library case remain explicit. Tests: final shared-runner verification passed **69 development + 122 CI tests**, including all prior rename/receipt/gate regressions, work budgets, malformed selections and uncovered/unknown preprocessor counterexamples. The platform context is modeled explicitly; this guard is not a replacement for real builds or arbitrary include-graph/runtime equivalence. Repository/hygiene: source remained unchanged during verification, the PR base stayed pinned, only owned files changed, and local signing/publication remained disabled. Reconciled **0 active findings**; stop at the authorized cumulative six-pass limit.

## Verification and recovery

All actual shared-runner commands use `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=bicino.localResultsKey GIT_CONFIG_VALUE_0=` to disable automatic receipt signing/publication. Receipt tests use isolated fixture keys and mocked transport. Workflow lint uses the pinned actionlint digest under OrbStack with a read-only mount.

The preprocessor path passed on macOS Clang and Linux GCC 12.2.0 in an ephemeral OrbStack container based on `python:3.13-slim-bookworm` (resolved digest `sha256:e32be0e55814a08977501ca863271d9bd02443710db8f2afaf8372e2c4508530`). The Linux run executed three guard tests in 0.787 seconds; the final macOS suite also includes the subsequent alias/comment counterexamples. This is compiler/preprocessor portability evidence, not a hosted-runtime receipt or firmware build.

Final pre-commit verification:

```sh
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=bicino.localResultsKey GIT_CONFIG_VALUE_0= \
  tools/dev-env tools/dev-check --suite development \
  --report .venv/review-evidence/cost-revision-final-local.json
```

- Exit 0, source unchanged; 69 development tests (6.641 s), 122 CI tests (5.814 s).
- Pinned actionlint under OrbStack: exit 0; `git diff --check`: exit 0.
- Confirmed source patch against the recorded base, excluding `docs/reviews/*`: SHA-256 `7547c8094438a154a405d4fa2cae721d377d991c409c2d3bcbe6c3081ecec594` (79,100 bytes). The cost-revision delta against the initial published head, with the same exclusions, is `1784db08cf213776e70f15136f5d5552ff578225b8b3cd4f24af87234ca30690`. Subsequent publication bookkeeping does not change this reviewed source identity.
- The first intermediate verification failed on incomplete new test fixtures (CLI output expectations and preprocessor context); those failures were retained and resolved before the confirming run, not reported as green.
- The original Swift, manifest/artifact, USB and both-board host results are retained in the original report. Fresh verification of the committed live PR head and hosted status are recorded in the PR description; no pre-commit result is represented as clean-head verification.
- No local firmware image/app-container build, simulator run, physical-device operation or real receipt publication was performed for this revision. Only one batched source push is intended; no intermediate CI runs were requested.

Recovery: revert the cost-revision commit on the PR branch to restore the first published head, or revert both PR commits to restore the recorded base. The former restores the expensive selection; the latter also restores the original correctness gaps. Neither requires device, service, signing-key or receipt-branch rollback. Keep all existing merge, release and physical acceptance requirements.
